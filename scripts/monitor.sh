#!/usr/bin/env bash
set -Eeuo pipefail
export LC_ALL=C
umask 0007
trap 'echo "[ERROR] Monitoring failed at line $LINENO" >&2; exit 1' ERR

agent_home=/home/agent-admin/agent-app
log_directory=/var/log/agent-app
log_file=$log_directory/monitor.log

fail() {
    echo "[ERROR] $*" >&2
    exit 1
}

check_health() {
    local sockets pid
    sockets=$(ss -H -ltnp 'sport = :15034')
    [[ -n $sockets ]] || fail 'Application port 15034 is not listening.'

    # Use the listener's executable, not a shortened process name.
    for pid in $(grep -oE 'pid=[0-9]+' <<< "$sockets" | cut -d= -f2 | sort -u); do
        if [[ $(readlink -f "/proc/$pid/exe") == "$agent_home/agent-app-linux-arm64" \
            && $(stat -c %u "/proc/$pid") == "$EUID" ]]; then
            app_pid=$pid
            echo "[OK] Application PID:$app_pid PORT:15034"
            return
        fi
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
    cpu=$(vmstat 1 2 | awk 'NR > 2 {idle = $15}
        END {if (idle == "" || idle < 0 || idle > 100) exit 1; print 100 - idle}')
    memory=$(awk '/^MemTotal:/ {total = $2} /^MemAvailable:/ {available = $2; found = 1}
        END {if (!found || total <= 0) exit 1; printf "%.4f", 100 * (total - available) / total}' /proc/meminfo)
    disk=$(df -P / | awk 'NR == 2 {gsub(/%/, "", $5); print $5}')
    [[ $disk =~ ^[0-9]+$ ]] || fail 'Cannot collect root filesystem usage.'
}

warn_threshold() {
    if awk -v value="$2" -v limit="$3" 'BEGIN {exit !(value > limit)}'; then
        printf '[WARNING] %s %.2f%% > %s%%\n' "$1" "$2" "$3"
    fi
}

rotate_log() {
    local size i
    size=$(stat -c %s "$log_file")
    (( size + ${#sample} + 1 > 10000000 )) || return 0

    # Finish compression before moving archives or clearing the active log.
    if ! gzip -c "$log_file" > "$log_file.tmp.gz"; then
        rm -f "$log_file.tmp.gz"
        fail 'Compression failed; active log preserved.'
    fi
    for ((i = 8; i >= 1; i--)); do
        if [[ -f $log_file.$i.gz ]]; then
            mv -f "$log_file.$i.gz" "$log_file.$((i + 1)).gz"
        fi
    done
    mv -f "$log_file.tmp.gz" "$log_file.1.gz"
    : > "$log_file"
}

[[ $(id -un) == agent-admin ]] || fail 'Run monitor.sh as agent-admin.'
exec 9>> "$log_directory/.monitor.lock"
flock -w 5 9 || fail 'Another monitor is running.'

check_health
check_firewall
collect_resources
warn_threshold CPU "$cpu" 20
warn_threshold MEM "$memory" 10
warn_threshold DISK_USED "$disk" 80
sample=$(printf '[%s] PID:%s CPU:%.2f%% MEM:%.2f%% DISK_USED:%s%%' \
    "$(date '+%Y-%m-%d %H:%M:%S')" "$app_pid" "$cpu" "$memory" "$disk")
[[ ! -L $log_file && ( ! -e $log_file || -f $log_file ) ]] || fail 'Invalid monitor.log file type.'
touch "$log_file"
chgrp agent-core "$log_file"
chmod 0660 "$log_file"
rotate_log
printf '%s\n' "$sample" >> "$log_file"
printf '%s\n' "$sample"
