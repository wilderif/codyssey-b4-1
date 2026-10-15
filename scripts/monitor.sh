#!/usr/bin/env bash
set -euo pipefail
# Keep parsed command output and decimal formatting independent of locale.
export LC_ALL=C

agent_home=/home/agent-admin/agent-app
log_file=/var/log/agent-app/monitor.log

# Report fatal health or execution errors to stderr and stop monitoring.
fail() {
    echo "[ERROR] $*" >&2
    exit 1
}

# Require the listener to use the installed binary and the monitoring account.
check_health() {
    # Extract the owning PID from ss output rather than matching a process name.
    app_pid=$(ss -ltnp 'sport = :15034' | sed -n 's/.*pid=\([0-9]*\).*/\1/p')
    if [[ -z $app_pid ]]; then
        fail 'Application port 15034 is not listening.'
    fi
    if [[ $(readlink "/proc/$app_pid/exe") != "$agent_home/agent-app-linux-arm64" ]]; then
        fail 'The listener is not the agent-admin application.'
    fi
    if [[ $(stat -c %u "/proc/$app_pid") != "$EUID" ]]; then
        fail 'The application is not running as agent-admin.'
    fi
    echo "[OK] Application PID:$app_pid PORT:15034"
}

# Warn on inactive UFW or query failure and continue collecting resources.
check_firewall() {
    local status
    # Never prompt for a password when cron runs this command unattended.
    if ! status=$(sudo -n /usr/sbin/ufw status 2>&1); then
        echo "[WARNING] Cannot query UFW: $status"
    elif ! grep -qx 'Status: active' <<< "$status"; then
        echo '[WARNING] UFW is inactive.'
    fi
}

# Collect Linux system usage, not application usage or container quota usage.
collect_resources() {
    # Skip the since-boot average; use 100 - idle from the one-second sample.
    cpu=$(vmstat 1 2 | awk 'END {print 100 - $15}')
    # MemAvailable includes reclaimable memory; subtract it from MemTotal.
    memory=$(awk '
        /^MemTotal:/ {total = $2}
        /^MemAvailable:/ {available = $2}
        END {print 100 * (total - available) / total}
    ' /proc/meminfo)
    # Use the root filesystem's Used% field and remove its percent suffix.
    disk=$(df -P / | awk '
        NR == 2 {
            gsub(/%/, "", $5)
            print $5
        }
    ')
}

# Warn only above the limit; awk compares decimal values without ending the run.
warn_threshold() {
    awk -v resource="$1" -v usage="$2" -v limit="$3" '
        BEGIN {
            if (usage > limit)
                printf "[WARNING] %s %.2f%% > %s%%\n", resource, usage, limit
        }
    '
}

# Rotate before the next sample exceeds 10 MB; retain up to nine gzip archives.
rotate_log() {
    local current_size number

    current_size=$(stat -c %s "$log_file")
    # Include the newline added when the sample is written.
    if (( current_size + ${#sample} + 1 <= 10000000 )); then
        return
    fi

    # Leave existing archives and active contents untouched if compression fails.
    gzip -c "$log_file" > "$log_file.tmp.gz"
    # Shift archives in descending order; overwriting .9.gz discards the oldest.
    for ((number = 8; number >= 1; number--)); do
        if [[ -f $log_file.$number.gz ]]; then
            mv "$log_file.$number.gz" "$log_file.$((number + 1)).gz"
        fi
    done
    mv "$log_file.tmp.gz" "$log_file.1.gz"
    # Keep the active file's ownership and permissions when clearing its contents.
    truncate -s 0 "$log_file"
}

# Match the account used to run the app and to register the cron job.
if [[ $(id -un) != agent-admin ]]; then
    fail 'Run monitor.sh as agent-admin.'
fi

# Stop on app health failure; firewall problems only produce warnings.
check_health
check_firewall

# Resource warnings do not prevent the sample from being recorded.
collect_resources
warn_threshold CPU "$cpu" 20
warn_threshold MEM "$memory" 10
warn_threshold DISK_USED "$disk" 80

# Build the complete sample so rotation can include its exact size and newline.
timestamp=$(date '+%Y-%m-%d %H:%M:%S')
sample=$(printf '[%s] PID:%s CPU:%.2f%% MEM:%.2f%% DISK_USED:%s%%' \
    "$timestamp" "$app_pid" "$cpu" "$memory" "$disk")
rotate_log
printf '%s\n' "$sample" >> "$log_file"
printf '%s\n' "$sample"
