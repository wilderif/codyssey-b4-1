#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

agent_home=/home/agent-admin/agent-app
log_file=/var/log/agent-app/monitor.log

fail() {
    echo "[ERROR] $*" >&2
    exit 1
}

check_health() {
    local sockets listener_pids pid
    sockets=$(ss -H -ltnp 'sport = :15034')
    if [[ -z $sockets ]]; then
        fail 'Application port 15034 is not listening.'
    fi

    # Use the listener's executable, not a shortened process name.
    if ! listener_pids=$(grep -oE 'pid=[0-9]+' <<< "$sockets" | cut -d= -f2); then
        fail 'The listener is not the agent-admin application.'
    fi
    for pid in $listener_pids; do
        if [[ $(readlink -f "/proc/$pid/exe") != "$agent_home/agent-app-linux-arm64" ]]; then
            continue
        fi
        if [[ $(stat -c %u "/proc/$pid") != "$EUID" ]]; then
            continue
        fi

        app_pid=$pid
        echo "[OK] Application PID:$app_pid PORT:15034"
        return
    done
    fail 'The listener is not the agent-admin application.'
}

check_firewall() {
    local status
    if ! status=$(sudo -n /usr/sbin/ufw status 2>&1); then
        echo "[WARNING] Cannot query UFW: $status"
    elif ! grep -qx 'Status: active' <<< "$status"; then
        echo '[WARNING] UFW is inactive.'
    fi
}

collect_resources() {
    # The second vmstat row measures one second of Linux system CPU activity.
    cpu=$(vmstat 1 2 | awk 'END {print 100 - $15}')
    memory=$(awk '
        /^MemTotal:/ {total = $2}
        /^MemAvailable:/ {available = $2}
        END {
            used = total - available
            printf "%.4f", 100 * used / total
        }
    ' /proc/meminfo)
    disk=$(df -P / | awk '
        NR == 2 {
            gsub(/%/, "", $5)
            print $5
        }
    ')
}

warn_threshold() {
    local resource=$1
    local usage=$2
    local limit=$3
    local exceeds_limit

    exceeds_limit=$(awk -v usage="$usage" -v limit="$limit" 'BEGIN {print (usage > limit)}')
    if [[ $exceeds_limit == 1 ]]; then
        printf '[WARNING] %s %.2f%% > %s%%\n' "$resource" "$usage" "$limit"
    fi
}

rotate_log() {
    local current_size next_size
    local number archive next_archive

    current_size=$(stat -c %s "$log_file")
    # Include the newline added when the sample is written.
    next_size=$((current_size + ${#sample} + 1))
    if (( next_size <= 10000000 )); then
        return 0
    fi

    # Finish compression before moving archives or clearing the active log.
    gzip -c "$log_file" > "$log_file.tmp.gz"
    for ((number = 8; number >= 1; number--)); do
        archive="$log_file.$number.gz"
        next_archive="$log_file.$((number + 1)).gz"
        if [[ -f $archive ]]; then
            mv -f "$archive" "$next_archive"
        fi
    done
    mv -f "$log_file.tmp.gz" "$log_file.1.gz"
    truncate --size=0 "$log_file"
}

if [[ $(id -un) != agent-admin ]]; then
    fail 'Run monitor.sh as agent-admin.'
fi

check_health
check_firewall

collect_resources
warn_threshold CPU "$cpu" 20
warn_threshold MEM "$memory" 10
warn_threshold DISK_USED "$disk" 80

timestamp=$(date '+%Y-%m-%d %H:%M:%S')
sample=$(printf '[%s] PID:%s CPU:%.2f%% MEM:%.2f%% DISK_USED:%s%%' \
    "$timestamp" "$app_pid" "$cpu" "$memory" "$disk")
rotate_log
printf '%s\n' "$sample" >> "$log_file"
printf '%s\n' "$sample"
