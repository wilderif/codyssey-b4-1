#!/usr/bin/env bash

fail() { # Stop monitoring with a useful diagnostic.
    printf '[ERROR] %s\n' "$*" >&2 # Keep failures separate from successful samples.
    exit 1 # Use the required failure status.
} # End error reporting.

check_health() { # Identify the actual process owning the required listener.
    local sockets pids parent parent_exe expected=$agent_home/agent-app-linux-arm64 # Keep process details local.
    sockets=$(ss -H -ltnp 'sport = :15034') || fail 'Cannot inspect TCP listeners.' # Query only the assignment port.
    [[ -n $sockets ]] || fail 'Application process/port check failed: TCP 15034 is not listening.' # Fail on an absent listener.
    [[ $(awk 'END {print NR}' <<< "$sockets") == 1 && $(awk '{print $4}' <<< "$sockets") == 0.0.0.0:15034 ]] || fail 'Expected one listener on 0.0.0.0:15034.' # Reject a different address or ambiguous sockets.
    pids=$(grep -oE 'pid=[0-9]+' <<< "$sockets" | cut -d= -f2 | sort -u) || fail 'Cannot identify the listening PID; run as agent-admin.' # Extract socket ownership rather than a shortened name.
    [[ $pids =~ ^[0-9]+$ ]] || fail 'Expected one identifiable listening process.' # Do not select an arbitrary first PID.
    app_pid=$pids # Record the verified socket owner for the sample.
    [[ $(readlink -f "/proc/$app_pid/exe") == "$expected" ]] || fail "PID $app_pid is not the installed application." # Reject an unrelated listener.
    [[ $(stat -c %u "/proc/$app_pid") == "$admin_uid" ]] || fail "PID $app_pid is not owned by agent-admin." # Enforce ordinary-account execution.
    parent=$(awk '/^PPid:/ {print $2}' "/proc/$app_pid/status") # Inspect the observed parent relationship.
    parent_exe=$(readlink -f "/proc/$parent/exe" || true) # Resolve the parent only when access is available.
    if [[ $parent_exe == "$expected" ]]; then # Validate a same-executable parent when the app creates one.
        [[ $(stat -c %u "/proc/$parent") == "$admin_uid" ]] || fail 'Application parent has an unexpected owner.' # Check the parent's identity too.
    fi # End parent identity check.
    printf '[OK] PID:%s PPID:%s EXE:%s USER:agent-admin PORT:0.0.0.0:15034\n' "$app_pid" "$parent" "$expected" # Print independently verified health details.
} # End application health check.

check_firewall() { # Warn without interrupting resource collection.
    local status # Keep status output within this check.
    if ! status=$(sudo -n /usr/sbin/ufw status 2>&1); then # Use only the specifically authorized read-only command.
        printf '[WARNING] UFW status query failed: %s\n' "$status" # Distinguish a query failure from inactivity.
    elif grep -qx 'Status: active' <<< "$status"; then # Match the actual activation state.
        printf '[OK] UFW active\n' # Report a confirmed active firewall.
    elif grep -qx 'Status: inactive' <<< "$status"; then # Recognize a confirmed inactive state.
        printf '[WARNING] UFW inactive\n' # Keep monitoring after the required warning.
    else # Handle unexpected status output without inventing a state.
        printf '[WARNING] UFW status could not be interpreted.\n' # Disclose the uncertainty.
    fi # End firewall status handling.
} # End the nonfatal firewall check.

cpu_snapshot() { # Read system-wide counters visible inside Linux.
    awk '/^cpu / {for (i=2;i<=9;i++) total+=$i; printf "%.0f %.0f\n", total, $5+$6; found=1; exit} END {if (!found) exit 1}' /proc/stat # Preserve counter precision and exclude duplicate guest time.
} # End CPU counter collection.

cpu_usage() { # Calculate utilization from two counter samples.
    awk -v before_total="$1" -v before_idle="$2" -v after_total="$3" -v after_idle="$4" 'BEGIN {total=after_total-before_total; idle=after_idle-before_idle; if (total<=0 || idle<0 || idle>total) exit 1; printf "%.4f", 100*(total-idle)/total}' # Reject invalid counters before calculating a percentage.
} # End CPU calculation.

warn_threshold() { # Apply a strict greater-than comparison before display rounding.
    local label=$1 value=$2 limit=$3 # Use the fixed assignment thresholds supplied by main.
    if awk -v value="$value" -v limit="$limit" 'BEGIN {exit !(value>limit)}'; then # Do not warn when the value equals its threshold.
        printf '[WARNING] %s %.2f%% > %s%%\n' "$label" "$value" "$limit" # Report the observed threshold breach.
    fi # End the optional warning.
    return 0 # Threshold warnings never fail monitoring.
} # End threshold comparison.

append_sample() { # Rotate and append while the caller holds the log lock.
    local directory=$1 sample=$2 active size bytes temporary archive name names # Support isolated checks of this private function.
    local -a archives=() # Track only files created by this rotation policy.
    active=$directory/monitor.log # Restrict the active filename to monitoring output.
    [[ ! -L $active && ( ! -e $active || -f $active ) ]] || fail 'monitor.log must be a regular file.' # Do not follow substituted paths.
    if [[ -e $active ]]; then # Validate an existing active log before opening it.
        [[ $(stat -c %h "$active") == 1 ]] || fail 'monitor.log has unexpected hard links.' # Avoid altering another path's data.
    else # Create only a missing active log.
        : > "$active" # Preserve all existing log contents.
    fi # End active-log initialization.
    chgrp agent-core "$active" # Keep group access restricted to core.
    chmod 0660 "$active" # Preserve read/write access without exposing other users.
    size=$(stat -c %s "$active") # Read the actual current byte count.
    bytes=$(LC_ALL=C printf '%s\n' "$sample" | wc -c) # Include the appended newline in the size calculation.
    [[ $bytes -le 10000000 ]] || fail 'A monitoring sample exceeds the log size limit.' # Reject an impossible oversized sample.
    if (( size + bytes > 10000000 )); then # Rotate only when the next sample would exceed the decimal 10MB limit.
        archive=$active.$(date +%s%N).gz # Use a sortable unique filename without renumbering existing logs.
        [[ ! -e $archive && ! -L $archive ]] || fail 'Rotated filename conflict.' # Never overwrite an existing archive.
        temporary=$(mktemp "$directory/.monitor.rotate.XXXXXX") # Keep compression staging on the same filesystem.
        if ! gzip -c "$active" > "$temporary" || ! gzip -t "$temporary"; then # Verify compression before touching the active contents.
            rm -f -- "$temporary" # Remove only the newly created incomplete staging file.
            fail 'Log compression failed; active log preserved.' # Retain the useful original data.
        fi # End compression validation.
        chgrp agent-core "$temporary" # Keep the staged archive core-only.
        chmod 0660 "$temporary" # Set retained archive permissions explicitly.
        mv -T "$temporary" "$archive" # Publish the verified compressed archive atomically.
        : > "$active" # Clear the active file only after its archive exists.
        printf '[OK] Monitoring log rotated\n' # Report a successful rotation.
    fi # End size-triggered rotation.
    names=$(find "$directory" -maxdepth 1 -regextype posix-extended -type f -regex '.*/monitor\.log\.[0-9]{19}\.gz' -printf '%f\n' | sort) || fail 'Cannot enumerate monitoring archives.' # Check retention collection failures explicitly.
    while IFS= read -r name; do # Select only this script's exact archive naming pattern.
        [[ -z $name ]] || archives+=("$directory/$name") # Keep the deletion list within the requested directory.
    done <<< "$names" # Order archives from oldest to newest.
    while (( ${#archives[@]} > 9 )); do # Retain up to nine compressed files plus the active log.
        rm -- "${archives[0]}" # Delete only the oldest monitoring archive.
        archives=("${archives[@]:1}") # Continue until retention is satisfied.
    done # End retention cleanup.
    printf '%s\n' "$sample" >> "$active" # Append the completed sample after successful rotation and cleanup.
} # End safe sample recording.

main() { # Run the selected assignment monitor as its ordinary account.
    set -Eeuo pipefail # Treat collection, locking, and recording failures as errors.
    trap 'printf "[ERROR] Monitoring failed at line %s\n" "$LINENO" >&2; exit 1' ERR # Give unexpected failures a useful diagnostic and status.
    export LC_ALL=C # Keep parsing and numeric formatting consistent under cron.
    umask 0007 # Restrict new monitoring files to owner and core group.
    agent_home=${AGENT_HOME:-/home/agent-admin/agent-app} # Accept only the selected application location.
    local log_directory=${AGENT_LOG_DIR:-/var/log/agent-app} before_total before_idle after_total after_idle cpu memory disk sample tool # Keep measurements local.
    [[ $agent_home == /home/agent-admin/agent-app && ${AGENT_PORT:-15034} == 15034 && $log_directory == /var/log/agent-app ]] || fail 'Unexpected application home, port, or log directory.' # Reject unsupported environment settings.
    [[ $# -eq 0 ]] || fail 'This monitor accepts no arguments.' # Keep its public interface minimal.
    admin_uid=$(id -u agent-admin) # Resolve the configured application's account.
    [[ $EUID -eq $admin_uid ]] || fail 'Run monitor.sh as agent-admin.' # Avoid root or unrelated account execution.
    for tool in ss grep cut sort readlink stat awk sudo df flock gzip mktemp date find wc chgrp chmod mv rm sleep; do # Validate the required Linux tools.
        command -v "$tool" >/dev/null || fail "Missing tool: $tool" # Identify a missing monitoring dependency.
    done # End tool checks.
    [[ -d $log_directory && ! -L $log_directory && -w $log_directory ]] || fail 'Monitoring log directory is unavailable.' # Check the effective ordinary-account access.
    [[ ! -L $log_directory/.monitor.lock && ( ! -e $log_directory/.monitor.lock || -f $log_directory/.monitor.lock ) ]] || fail 'Unexpected monitoring lock type.' # Avoid following a substituted lock file.
    exec 9>> "$log_directory/.monitor.lock" # Open one persistent lock shared by manual and cron runs.
    flock -w 5 9 || fail 'Cannot acquire monitoring lock within five seconds.' # Serialize writes and rotations with bounded waiting.
    check_health # Fail before collecting a sample for an unhealthy application.
    check_firewall # Continue after nonfatal firewall warnings.
    read -r before_total before_idle < <(cpu_snapshot) # Capture the first Linux CPU snapshot.
    sleep 1 # Measure utilization over a short real interval.
    read -r after_total after_idle < <(cpu_snapshot) # Capture the second snapshot.
    cpu=$(cpu_usage "$before_total" "$before_idle" "$after_total" "$after_idle") || fail 'CPU collection failed.' # Calculate a validated system percentage.
    memory=$(awk '/^MemTotal:/ {total=$2} /^MemAvailable:/ {available=$2; found=1} END {if (!found || total<=0 || available<0 || available>total) exit 1; printf "%.4f", 100*(total-available)/total}' /proc/meminfo) || fail 'Memory collection failed.' # Use available memory rather than process RSS or quotas.
    disk=$(df -P / | awk 'NR==2 {gsub(/%/, "", $5); print $5}') # Read the root filesystem used percentage.
    [[ $disk =~ ^[0-9]+$ && $disk -le 100 ]] || fail 'Root filesystem collection failed.' # Reject unusable disk output.
    warn_threshold CPU "$cpu" 20 # Apply the fixed CPU warning threshold.
    warn_threshold MEM "$memory" 10 # Apply the fixed memory warning threshold.
    warn_threshold DISK_USED "$disk" 80 # Apply the fixed root-filesystem warning threshold.
    sample=$(printf '[%s] PID:%s CPU:%.2f%% MEM:%.2f%% DISK_USED:%s%%' "$(date '+%Y-%m-%d %H:%M:%S')" "$app_pid" "$cpu" "$memory" "$disk") # Build the required single-line log format.
    append_sample "$log_directory" "$sample" # Record the validated listener PID and system measurements.
    printf '%s\n[OK] Monitoring sample appended\n' "$sample" # Report success only after logging completes.
} # End the monitoring operation.

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then # Allow private functions to be checked without running the full monitor.
    main "$@" # Execute the ordinary-account monitoring workflow.
fi # End the direct-execution guard.
