#!/usr/bin/env bash
set -Eeuo pipefail # Stop on failed preparation commands and pipelines.
export LC_ALL=C # Keep tool output predictable for validation.
trap 'printf "[ERROR] Setup failed at line %s; inspect the command above.\n" "$LINENO" >&2' ERR # Report useful failure context.
agent_home=/home/agent-admin/agent-app # Fix the selected application location.
source_app=/workspace/agent-app/agent-app-linux-arm64 # Use only the supplied ARM64 binary.
key_file=$agent_home/api_keys/t_secret.key # Preserve the assignment fixture path.
key_link=$agent_home/api_keys/secret.key # Expose the approved relative compatibility link.
ssh_file=/etc/ssh/sshd_config.d/00-agent.conf # Keep managed SSH settings in one drop-in.
sudo_file=/etc/sudoers.d/agent-ufw-status # Limit unattended elevation to firewall status.

fail() { # Print a diagnostic and stop without replacing conflicting data.
    printf '[ERROR] %s\n' "$*" >&2 # Send the reason to standard error.
    exit 1 # Never report a failed setup as successful.
} # End failure reporting.

check_group() { # Validate a group's name and stable numeric identity.
    local name=$1 number=$2 entry # Keep identities local to this check.
    entry=$(getent group "$name" || true) # Read an existing group without treating absence as failure.
    [[ -z $entry || $(cut -d: -f3 <<< "$entry") == "$number" ]] || fail "Group conflict: $name" # Reject a mismatched GID.
    entry=$(getent group "$number" || true) # Check whether another name already owns this GID.
    [[ -z $entry || ${entry%%:*} == "$name" ]] || fail "GID conflict: $number" # Preserve unrelated groups.
} # End group preflight.

check_user() { # Validate an account before changing any memberships.
    local name=$1 number=$2 entry # Use the selected fixed UID and private GID.
    entry=$(getent passwd "$name" || true) # Inspect an existing account.
    [[ -z $entry || $(cut -d: -f3-4,6-7 <<< "$entry") == "$number:$number:/home/$name:/bin/bash" ]] || fail "Account conflict: $name" # Reject incompatible identities.
    entry=$(getent passwd "$number" || true) # Detect numeric UID reuse.
    [[ -z $entry || ${entry%%:*} == "$name" ]] || fail "UID conflict: $number" # Preserve unrelated accounts.
    check_group "$name" "$number" # Verify the private group as well.
} # End account preflight.

prepare_directory() { # Set policy on the directory itself without rewriting existing contents.
    local path=$1 group=$2 # Select its intended shared group.
    install -d -o agent-admin -g "$group" -m 2770 "$path" # Retain group inheritance for new entries.
    setfacl -m u::rwx,g::rwx,m::rwx,o::--- "$path" # Set the effective access mask.
    setfacl -m d:u::rwx,d:g::rwx,d:m::rwx,d:o::--- "$path" # Give new children the same group policy.
} # End directory preparation.

[[ $EUID -eq 0 ]] || fail 'Run setup as root inside the Linux container.' # Require administrative setup privileges.
[[ $# -eq 0 ]] || fail 'This setup accepts no arguments.' # Avoid unsupported configuration choices.
exec 8> /run/agent-setup.lock # Keep simultaneous setup runs from changing the same configuration.
flock -n 8 || fail 'Another setup is already running.' # Refuse overlapping administrative changes.
[[ $(readlink -f /proc/1/exe) == /usr/sbin/sshd ]] || fail 'Start this container with start.sh before setup.' # Reload only the intended PID 1 SSH daemon.
for tool in getent groupadd useradd usermod install setfacl getfacl runuser ss ufw iptables ip6tables file readelf ldd cmp flock visudo crontab awk stat sha256sum; do # Check prerequisites before mutation.
    command -v "$tool" >/dev/null || fail "Missing tool: $tool" # Identify the missing package.
done # Finish command checks.
source /etc/os-release # Read the actual container operating system.
[[ $ID == ubuntu && $VERSION_ID == 22.04 && $(uname -m) == aarch64 ]] || fail 'Require Ubuntu 22.04 on ARM64.' # Enforce the selected environment.
[[ -f $source_app && ! -L $source_app ]] || fail 'Missing regular ARM64 application file.' # Reject unexpected source types.
file "$source_app" | grep -q 'ARM aarch64' || fail 'Application is not an AArch64 ELF.' # Check external file metadata only.
ldd "$source_app" | tee /tmp/agent-dependencies.txt # Show direct Linux runtime dependencies.
! grep -q 'not found' /tmp/agent-dependencies.txt || fail 'Install the reported missing runtime dependency.' # Do not add speculative libraries.
iptables -L -n >/dev/null || fail 'NET_ADMIN/firewall access is unavailable.' # Check IPv4 firewall capability without changing rules.
ip6tables -L -n >/dev/null || fail 'IPv6 firewall access is unavailable.' # Keep IPv6 firewall coverage as well.
check_user agent-admin 2001 # Validate the administration identity.
check_user agent-dev 2002 # Validate the development identity.
check_user agent-test 2003 # Validate the QA identity.
check_group agent-common 2101 # Validate the shared group identity.
check_group agent-core 2102 # Validate the restricted group identity.
if getent passwd agent-test >/dev/null; then # Check existing QA membership before changing anything.
    ! id -nG agent-test | tr ' ' '\n' | grep -qx agent-core || fail 'agent-test unexpectedly belongs to agent-core.' # Do not silently change existing membership.
fi # End membership conflict check.
for path in /home/agent-admin "$agent_home" "$agent_home/upload_files" "$agent_home/api_keys" "$agent_home/bin" /var/log/agent-app /var/lib/agent-evidence; do # Validate managed directory types.
    [[ ! -L $path && ( ! -e $path || -d $path ) ]] || fail "Directory conflict: $path" # Avoid following a substituted directory.
done # End directory type checks.
for path in "$agent_home/upload_files" "$agent_home/api_keys" "$agent_home/bin" /var/log/agent-app /var/lib/agent-evidence; do # Inspect existing shared paths before changing their access policy.
    if [[ -d $path ]]; then # Allow only the selected owner/group ACL structure.
        getfacl -cp "$path" | awk '/^(default:)?(user|group):[^:]+:/ {exit 1}' || fail "Unexpected named ACL: $path" # Reject hidden extra grants rather than silently retaining them.
    fi # End existing ACL preflight.
done # End access conflict scan.
if [[ -e $key_file || -L $key_file ]]; then # Inspect an existing fixture before applying permissions.
    [[ -f $key_file && ! -L $key_file ]] && cmp -s "$key_file" <(printf 'agent_api_key_test\n') || fail 'Key fixture conflict; existing data preserved.' # Require the exact single-line fixture.
fi # End fixture preflight.
if [[ -e $key_link || -L $key_link ]]; then # Include dangling links in conflict detection.
    [[ -L $key_link && $(readlink "$key_link") == t_secret.key ]] || fail 'Key link conflict; existing data preserved.' # Accept only the selected relative target.
fi # End link preflight.
if [[ -e $agent_home/agent-app-linux-arm64 || -L $agent_home/agent-app-linux-arm64 ]]; then # Inspect a previously installed executable.
    [[ -f $agent_home/agent-app-linux-arm64 && ! -L $agent_home/agent-app-linux-arm64 ]] && cmp -s "$source_app" "$agent_home/agent-app-linux-arm64" || fail 'Installed application differs; preserve it and investigate.' # Never overwrite a different binary.
fi # End installed executable check.
ufw_added=$(ufw show added) # Inspect configured rules before adding assignment rules.
while IFS= read -r rule; do # Examine only commands reported by UFW.
    [[ $rule != ufw\ * || $rule == 'ufw allow 20022/tcp' || $rule == 'ufw allow 15034/tcp' ]] || fail "Unexpected UFW rule: $rule" # Reject unrelated or broader allowances.
done <<< "$ufw_added" # Finish the rule conflict scan.
if [[ -f $ssh_file ]]; then # Preserve any conflicting managed drop-in.
    cmp -s "$ssh_file" <(printf 'Port 20022\nPermitRootLogin no\nPasswordAuthentication yes\n') || fail 'Managed SSH configuration differs.' # Require the expected settings.
fi # End managed SSH conflict check.
if [[ -e $sudo_file || -L $sudo_file ]]; then # Reject a substituted or broader sudo rule.
    [[ -f $sudo_file && ! -L $sudo_file ]] && cmp -s "$sudo_file" <(printf 'agent-admin ALL=(root) NOPASSWD: /usr/sbin/ufw status\n') || fail 'Managed sudo configuration differs.' # Keep elevation narrowly scoped.
fi # End sudo conflict check.

for pair in agent-admin:2001 agent-dev:2002 agent-test:2003 agent-common:2101 agent-core:2102; do # Create only missing groups.
    getent group "${pair%:*}" >/dev/null || groupadd -g "${pair#*:}" "${pair%:*}" # Reuse stable existing GIDs.
done # End group creation.
for pair in agent-admin:2001 agent-dev:2002 agent-test:2003; do # Create only missing accounts.
    name=${pair%:*} # Extract the selected account name.
    number=${pair#*:} # Extract its fixed UID.
    getent passwd "$name" >/dev/null || useradd -m -u "$number" -g "$name" -s /bin/bash "$name" # Leave passwords locked until interactive configuration.
    usermod -aG agent-common "$name" # Preserve other supplementary groups.
done # End account creation.
usermod -aG agent-core agent-admin # Give administration access to restricted paths.
usermod -aG agent-core agent-dev # Give development access to restricted paths.
chown agent-admin:agent-admin /home/agent-admin # Keep the personal home private.
chmod 0700 /home/agent-admin # Avoid exposing its directory listing.
setfacl -m g:agent-common:--x,m::--x /home/agent-admin # Permit only traversal toward assignment directories.
install -d -o agent-admin -g agent-admin -m 0700 "$agent_home" # Keep the application parent private.
setfacl -m g:agent-common:--x,m::--x "$agent_home" # Permit traversal without exposing its listing.
prepare_directory "$agent_home/upload_files" agent-common # Grant shared read/write access.
prepare_directory "$agent_home/api_keys" agent-core # Restrict key-directory access.
prepare_directory "$agent_home/bin" agent-core # Restrict monitoring-script access.
prepare_directory /var/log/agent-app agent-core # Restrict log access and inheritance.
prepare_directory /var/lib/agent-evidence agent-core # Preserve diagnostics on a dedicated volume.
if [[ ! -e $agent_home/agent-app-linux-arm64 ]]; then # Install the binary only when absent.
    install -o agent-admin -g agent-core -m 0750 "$source_app" "$agent_home/agent-app-linux-arm64" # Make only the installed copy executable.
fi # End first-time executable installation.
chown agent-admin:agent-core "$agent_home/agent-app-linux-arm64" # Restore the selected installed ownership.
chmod 0750 "$agent_home/agent-app-linux-arm64" # Allow ordinary admin execution.
if [[ ! -e $key_file ]]; then # Create the fixture only when missing.
    (umask 0007; printf 'agent_api_key_test\n' > "$key_file") # Store one exact line without exposing other access.
fi # End fixture creation.
chown agent-admin:agent-core "$key_file" # Keep the fixture core-only.
chmod 0660 "$key_file" # Allow core read/write while denying other accounts.
[[ -L $key_link ]] || ln -s t_secret.key "$key_link" # Reuse the matching relative link.
chown -h agent-admin:agent-core "$key_link" # Assign link ownership without following it.
runuser -u agent-admin -- test -x "$agent_home/agent-app-linux-arm64" # Check executable access as the actual app account.
runuser -u agent-dev -- test -r "$key_link" # Check core traversal through the compatibility link.
! runuser -u agent-test -- test -r "$key_link" || fail 'QA unexpectedly has key access.' # Verify effective denied access.

ssh_existed=0 # Track whether rollback must restore or remove the drop-in.
[[ ! -e $ssh_file ]] || ssh_existed=1 # Preserve the original managed state.
printf 'Port 20022\nPermitRootLogin no\nPasswordAuthentication yes\n' > "$ssh_file" # Write the selected SSH policy.
chmod 0644 "$ssh_file" # Keep configuration readable to SSH diagnostics.
if ! /usr/sbin/sshd -t || ! /usr/sbin/sshd -T | awk '$1=="port" {ports++; if ($2!=20022) bad=1} $1=="permitrootlogin" && $2=="no" {root=1} $1=="passwordauthentication" && $2=="yes" {password=1} END {exit !(ports==1 && !bad && root && password)}'; then # Validate syntax and effective policy before reload.
    [[ $ssh_existed -eq 1 ]] || unlink "$ssh_file" # Restore the original absence on first-time validation failure.
    fail 'SSH validation failed; inspect other sshd settings before retrying.' # Leave the running console-accessible daemon unchanged.
fi # End SSH validation.
printf 'agent-admin ALL=(root) NOPASSWD: /usr/sbin/ufw status\n' > "$sudo_file" # Authorize only the read-only status query.
chmod 0440 "$sudo_file" # Apply sudoers file permissions.
visudo -cf "$sudo_file" # Validate the exact sudoers rule.
ufw default deny incoming # Deny unsolicited inbound traffic.
ufw default allow outgoing # Permit outbound traffic required by the app.
ufw allow 20022/tcp # Allow the selected SSH port only.
ufw allow 15034/tcp # Allow the supplied application port only.
ufw --force enable # Activate the firewall after checking its rule set.
ufw status | grep -qx 'Status: active' || fail 'UFW did not become active.' # Confirm real activation.
kill -HUP 1 # Reload the foreground SSH daemon after validated configuration changes.

if [[ -f /workspace/monitor.sh ]]; then # Install and schedule only a real monitoring implementation.
    bash -n /workspace/monitor.sh # Reject syntactically invalid monitoring code.
    install -o agent-dev -g agent-core -m 0750 /workspace/monitor.sh "$agent_home/bin/.monitor.sh.new" # Prepare the replacement with intended ownership.
    mv -f "$agent_home/bin/.monitor.sh.new" "$agent_home/bin/monitor.sh" # Replace the script atomically.
    if ! old_cron=$(crontab -u agent-admin -l 2>&1); then # Distinguish a missing table from a real read failure.
        [[ $old_cron == 'no crontab for agent-admin' ]] || fail "Cannot read crontab: $old_cron" # Do not overwrite a table after an unexpected error.
        old_cron='' # Treat a genuinely absent crontab as empty.
    fi # End crontab read validation.
    clean_cron=$(awk '/^# BEGIN agent-monitor$/ {if (skip) exit 1; skip=1; next} /^# END agent-monitor$/ {if (!skip) exit 1; skip=0; next} !skip {print} END {if (skip) exit 1}' <<< "$old_cron") || fail 'Malformed managed cron block; existing crontab preserved.' # Reject broken markers before removing a managed block.
    { # Build one idempotent block after unrelated entries.
        printf '%s\n' "$clean_cron" # Keep all unmanaged entries.
        printf '# BEGIN agent-monitor\n' # Mark the start of managed scheduling.
        printf '* * * * * PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin AGENT_HOME=%s AGENT_PORT=15034 AGENT_UPLOAD_DIR=%s/upload_files AGENT_KEY_PATH=%s/api_keys AGENT_LOG_DIR=/var/log/agent-app %s/bin/monitor.sh >> /var/lib/agent-evidence/cron.log 2>&1\n' "$agent_home" "$agent_home" "$agent_home" "$agent_home" # Set absolute paths and explicit environment.
        printf '# END agent-monitor\n' # Mark the end of managed scheduling.
    } | crontab -u agent-admin - # Install the assembled crontab without duplication.
else # Keep security preparation usable before monitoring is implemented.
    printf '[INFO] monitor.sh not present; installation and cron registration deferred.\n' # Disclose the incomplete monitoring step.
fi # End monitoring installation.
sha256sum "$agent_home/agent-app-linux-arm64" # Record the installed app identity without exposing key data.
printf '[OK] Setup complete; set agent-admin password interactively.\n' # Report only successful preparation.
