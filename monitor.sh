#!/usr/bin/env bash

set -Eeuo pipefail
export LC_ALL=C
umask 0007
trap 'printf "[ERROR] Monitoring failed at line %s\n" "$LINENO" >&2; exit 1' ERR

agent_home=${AGENT_HOME:-/home/agent-admin/agent-app}
log_directory=${AGENT_LOG_DIR:-/var/log/agent-app}
log_file=$log_directory/monitor.log

fail() {
    printf '[ERROR] %s\n' "$*" >&2
    exit 1
}

check_health() {
    local sockets pids parent parent_exe
    local expected=$agent_home/agent-app-linux-arm64

    sockets=$(ss -H -ltnp 'sport = :15034') || fail 'Cannot inspect TCP listeners.'
    [[ -n $sockets ]] || fail 'Application process/port check failed: TCP 15034 is not listening.'
    awk 'END {exit !(NR == 1 && $4 == "0.0.0.0:15034")}' <<< "$sockets" \
        || fail 'Expected one listener on 0.0.0.0:15034.'

    # Check the socket owner instead of relying on a shortened process name.
    pids=$(grep -oE 'pid=[0-9]+' <<< "$sockets" | cut -d= -f2 | sort -u) \
        || fail 'Cannot identify the listening PID; run as agent-admin.'
    [[ $pids =~ ^[0-9]+$ ]] || fail 'Expected one identifiable listening process.'
    app_pid=$pids

    [[ $(readlink -f "/proc/$app_pid/exe") == "$expected" ]] \
        || fail "PID $app_pid is not the installed application."
    [[ $(stat -c %u "/proc/$app_pid") == "$admin_uid" ]] \
        || fail "PID $app_pid is not owned by agent-admin."

    parent=$(awk '/^PPid:/ {print $2}' "/proc/$app_pid/status")
    parent_exe=$(readlink -f "/proc/$parent/exe" || true)
    if [[ $parent_exe == "$expected" ]]; then
        [[ $(stat -c %u "/proc/$parent") == "$admin_uid" ]] \
            || fail 'Application parent has an unexpected owner.'
    fi

    printf '[OK] PID:%s PPID:%s EXE:%s USER:agent-admin PORT:0.0.0.0:15034\n' \
        "$app_pid" "$parent" "$expected"
}

check_firewall() {
    local status

    # Query failures and inactivity are warnings, not collection failures.
    if ! status=$(sudo -n /usr/sbin/ufw status 2>&1); then
        printf '[WARNING] UFW status query failed: %s\n' "$status"
    elif grep -qx 'Status: active' <<< "$status"; then
        printf '[OK] UFW active\n'
    elif grep -qx 'Status: inactive' <<< "$status"; then
        printf '[WARNING] UFW inactive\n'
    else
        printf '[WARNING] UFW status could not be interpreted.\n'
    fi
}

cpu_snapshot() {
    # Exclude guest counters because user and nice already include them.
    awk '
        /^cpu / {
            for (i = 2; i <= 9; i++) total += $i
            printf "%.0f %.0f\n", total, $5 + $6
            found = 1
            exit
        }
        END {if (!found) exit 1}
    ' /proc/stat
}

collect_resources() {
    local before_total before_idle after_total after_idle

    # Measure the Linux system visible inside the container, not app resources.
    read -r before_total before_idle < <(cpu_snapshot)
    sleep 1
    read -r after_total after_idle < <(cpu_snapshot)

    cpu=$(awk \
        -v before_total="$before_total" -v before_idle="$before_idle" \
        -v after_total="$after_total" -v after_idle="$after_idle" '
        BEGIN {
            total = after_total - before_total
            idle = after_idle - before_idle
            if (total <= 0 || idle < 0 || idle > total) exit 1
            printf "%.4f", 100 * (total - idle) / total
        }
    ') || fail 'CPU collection failed.'

    memory=$(awk '
        /^MemTotal:/ {total = $2}
        /^MemAvailable:/ {available = $2; found = 1}
        END {
            if (!found || total <= 0 || available < 0 || available > total) exit 1
            printf "%.4f", 100 * (total - available) / total
        }
    ' /proc/meminfo) || fail 'Memory collection failed.'

    disk=$(df -P / | awk 'NR == 2 {gsub(/%/, "", $5); print $5}')
    [[ $disk =~ ^[0-9]+$ && $disk -le 100 ]] || fail 'Root filesystem collection failed.'
}

warn_threshold() {
    local label=$1 value=$2 limit=$3

    # Compare before rounding; values equal to the threshold do not warn.
    if awk -v value="$value" -v limit="$limit" 'BEGIN {exit !(value > limit)}'; then
        printf '[WARNING] %s %.2f%% > %s%%\n' "$label" "$value" "$limit"
    fi
}

append_sample() {
    local sample=$1 size bytes temporary archive names name
    local -a archives=()

    [[ ! -L $log_file && ( ! -e $log_file || -f $log_file ) ]] \
        || fail 'monitor.log must be a regular file.'
    if [[ -e $log_file ]]; then
        [[ $(stat -c %h "$log_file") == 1 ]] || fail 'monitor.log has unexpected hard links.'
    else
        : > "$log_file" || fail 'Cannot create monitor.log.'
    fi

    chgrp agent-core "$log_file" || fail 'Cannot set monitoring log group.'
    chmod 0660 "$log_file" || fail 'Cannot set monitoring log permissions.'
    size=$(stat -c %s "$log_file") || fail 'Cannot read monitoring log size.'

    # LC_ALL=C makes string length a byte count; include the appended newline.
    bytes=$(( ${#sample} + 1 ))
    [[ $bytes -le 10000000 ]] || fail 'A monitoring sample exceeds the log size limit.'

    # Publish a verified archive before clearing the active log.
    if (( size + bytes > 10000000 )); then
        archive=$log_file.$(date +%s%N).gz
        [[ ! -e $archive && ! -L $archive ]] || fail 'Rotated filename conflict.'
        temporary=$(mktemp "$log_directory/.monitor.rotate.XXXXXX")

        if ! gzip -c "$log_file" > "$temporary" || ! gzip -t "$temporary"; then
            rm -f -- "$temporary"
            fail 'Log compression failed; active log preserved.'
        fi

        chgrp agent-core "$temporary" || fail 'Cannot set archive group; active log preserved.'
        chmod 0660 "$temporary" || fail 'Cannot set archive permissions; active log preserved.'
        mv -T "$temporary" "$archive" || fail 'Cannot publish archive; active log preserved.'
        : > "$log_file" || fail 'Cannot reopen monitor.log after archiving.'
        printf '[OK] Monitoring log rotated\n'
    fi

    # Keep only this monitor's newest nine archives; leave app logs untouched.
    names=$(find "$log_directory" -maxdepth 1 -regextype posix-extended -type f \
        -regex '.*/monitor\.log\.[0-9]{19}\.gz' -printf '%f\n' | sort) \
        || fail 'Cannot enumerate monitoring archives.'
    while IFS= read -r name; do
        [[ -z $name ]] || archives+=("$log_directory/$name")
    done <<< "$names"

    while (( ${#archives[@]} > 9 )); do
        rm -- "${archives[0]}" || fail 'Cannot delete oldest monitoring archive.'
        archives=("${archives[@]:1}")
    done

    printf '%s\n' "$sample" >> "$log_file" || fail 'Cannot append monitoring sample.'
}

# Validate the selected environment and ordinary monitoring account.
[[ $# -eq 0 ]] || fail 'This monitor accepts no arguments.'
[[ $agent_home == /home/agent-admin/agent-app && ${AGENT_PORT:-15034} == 15034 \
    && $log_directory == /var/log/agent-app ]] \
    || fail 'Unexpected application home, port, or log directory.'
admin_uid=$(id -u agent-admin)
[[ $EUID -eq $admin_uid ]] || fail 'Run monitor.sh as agent-admin.'

for tool in ss grep cut sort readlink stat awk sudo df flock gzip mktemp date find \
    chgrp chmod mv rm sleep; do
    command -v "$tool" >/dev/null || fail "Missing tool: $tool"
done

[[ -d $log_directory && ! -L $log_directory && -w $log_directory ]] \
    || fail 'Monitoring log directory is unavailable.'
[[ ! -L $log_directory/.monitor.lock \
    && ( ! -e $log_directory/.monitor.lock || -f $log_directory/.monitor.lock ) ]] \
    || fail 'Unexpected monitoring lock type.'

# Share one lock between manual and cron runs, including rotation.
exec 9>> "$log_directory/.monitor.lock"
flock -w 5 9 || fail 'Cannot acquire monitoring lock within five seconds.'

check_health
check_firewall
collect_resources

warn_threshold CPU "$cpu" 20
warn_threshold MEM "$memory" 10
warn_threshold DISK_USED "$disk" 80

sample=$(printf '[%s] PID:%s CPU:%.2f%% MEM:%.2f%% DISK_USED:%s%%' \
    "$(date '+%Y-%m-%d %H:%M:%S')" "$app_pid" "$cpu" "$memory" "$disk")
append_sample "$sample"
printf '%s\n[OK] Monitoring sample appended\n' "$sample"
