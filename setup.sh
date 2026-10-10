#!/usr/bin/env bash

set -Eeuo pipefail
export LC_ALL=C
trap 'printf "[ERROR] Setup failed at line %s; inspect the command above.\n" "$LINENO" >&2' ERR

agent_home=/home/agent-admin/agent-app
source_app=/workspace/agent-app/agent-app-linux-arm64
installed_app=$agent_home/agent-app-linux-arm64
key_file=$agent_home/api_keys/t_secret.key
key_link=$agent_home/api_keys/secret.key
ssh_file=/etc/ssh/sshd_config.d/00-agent.conf
sudo_file=/etc/sudoers.d/agent-ufw-status
umask_file=/etc/profile.d/agent-umask.sh
accounts=(agent-admin:2001 agent-dev:2002 agent-test:2003)
ssh_settings=$'Port 20022\nPermitRootLogin no\nPasswordAuthentication yes\n'
sudo_settings=$'agent-admin ALL=(root) NOPASSWD: /usr/sbin/ufw status\n'
umask_settings=$'case "$USER" in\n    agent-admin|agent-dev|agent-test) umask 0007 ;;\nesac\n'

fail() {
    printf '[ERROR] %s\n' "$*" >&2
    exit 1
}

# Stable numeric identities preserve ownership across container recreation.
check_group() {
    local name=$1 number=$2 entry

    entry=$(getent group "$name" || true)
    [[ -z $entry || $(cut -d: -f3 <<< "$entry") == "$number" ]] \
        || fail "Group conflict: $name"

    entry=$(getent group "$number" || true)
    [[ -z $entry || ${entry%%:*} == "$name" ]] || fail "GID conflict: $number"
}

check_user() {
    local name=$1 number=$2 entry

    entry=$(getent passwd "$name" || true)
    [[ -z $entry || $(cut -d: -f3-4,6-7 <<< "$entry") == "$number:$number:/home/$name:/bin/bash" ]] \
        || fail "Account conflict: $name"

    entry=$(getent passwd "$number" || true)
    [[ -z $entry || ${entry%%:*} == "$name" ]] || fail "UID conflict: $number"
    check_group "$name" "$number"
}

prepare_directory() {
    local path=$1 group=$2 group_id

    # Host bind mounts do not support default ACLs; use setgid and session umask.
    install -d -o agent-admin -g "$group" -m 2770 "$path"
    group_id=$(getent group "$group" | cut -d: -f3)
    [[ $(stat -c '%u:%g:%a' "$path") == "2001:$group_id:2770" ]] \
        || fail "Bind mount does not preserve Linux ownership/setgid: $path"
}

# Check prerequisites before changing accounts, data, or configuration.
[[ $EUID -eq 0 ]] || fail 'Run setup as root inside the Linux container.'
[[ $# -eq 0 ]] || fail 'This setup accepts no arguments.'
for tool in getent groupadd useradd usermod install setfacl getfacl runuser ufw \
    iptables ip6tables file ldd cmp flock visudo crontab awk sha256sum \
    readlink uname grep tee id tr cut chown chmod ln unlink mv bash stat; do
    command -v "$tool" >/dev/null || fail "Missing tool: $tool"
done

exec 8> /run/agent-setup.lock
flock -n 8 || fail 'Another setup is already running.'
[[ $(readlink -f /proc/1/exe) == /usr/sbin/sshd ]] \
    || fail 'Start this container with start.sh before setup.'

source /etc/os-release
[[ $ID == ubuntu && $VERSION_ID == 22.04 && $(uname -m) == aarch64 ]] \
    || fail 'Require Ubuntu 22.04 on ARM64.'
[[ -f $source_app && ! -L $source_app ]] || fail 'Missing regular ARM64 application file.'
[[ -f /workspace/monitor.sh ]] || fail 'Missing /workspace/monitor.sh.'
bash -n /workspace/monitor.sh

file "$source_app" | grep -q 'ARM aarch64' || fail 'Application is not an AArch64 ELF.'
ldd "$source_app" | tee /tmp/agent-dependencies.txt
! grep -q 'not found' /tmp/agent-dependencies.txt \
    || fail 'Install the reported missing runtime dependency.'
iptables -L -n >/dev/null || fail 'NET_ADMIN/firewall access is unavailable.'
ip6tables -L -n >/dev/null || fail 'IPv6 firewall access is unavailable.'

# Reject conflicting identities, paths, keys, and managed settings.
for pair in "${accounts[@]}"; do
    check_user "${pair%:*}" "${pair#*:}"
done
check_group agent-common 2101
check_group agent-core 2102

if getent passwd agent-test >/dev/null; then
    ! id -nG agent-test | tr ' ' '\n' | grep -qx agent-core \
        || fail 'agent-test unexpectedly belongs to agent-core.'
fi

for path in /home/agent-admin "$agent_home" "$agent_home/upload_files" \
    "$agent_home/api_keys" "$agent_home/bin" /var/log/agent-app /var/lib/agent-evidence; do
    [[ ! -L $path && ( ! -e $path || -d $path ) ]] || fail "Directory conflict: $path"
done

for path in "$agent_home/upload_files" "$agent_home/api_keys" "$agent_home/bin" \
    /var/log/agent-app /var/lib/agent-evidence; do
    if [[ -d $path ]]; then
        getfacl -cp "$path" | awk '/^(default:)?(user|group):[^:]+:/ {exit 1}' \
            || fail "Unexpected named ACL: $path"
    fi
done

if [[ -e $key_file || -L $key_file ]]; then
    [[ -f $key_file && ! -L $key_file ]] \
        && cmp -s "$key_file" <(printf 'agent_api_key_test\n') \
        || fail 'Key fixture conflict; existing data preserved.'
fi

if [[ -e $key_link || -L $key_link ]]; then
    [[ -L $key_link && $(readlink "$key_link") == t_secret.key ]] \
        || fail 'Key link conflict; existing data preserved.'
fi

if [[ -e $installed_app || -L $installed_app ]]; then
    [[ -f $installed_app && ! -L $installed_app ]] && cmp -s "$source_app" "$installed_app" \
        || fail 'Installed application differs; preserve it and investigate.'
fi

ufw_added=$(ufw show added)
while IFS= read -r rule; do
    [[ $rule != ufw\ * || $rule == 'ufw allow 20022/tcp' || $rule == 'ufw allow 15034/tcp' ]] \
        || fail "Unexpected UFW rule: $rule"
done <<< "$ufw_added"

if [[ -e $ssh_file || -L $ssh_file ]]; then
    [[ -f $ssh_file && ! -L $ssh_file ]] && cmp -s "$ssh_file" <(printf '%s' "$ssh_settings") \
        || fail 'Managed SSH configuration differs.'
fi

if [[ -e $sudo_file || -L $sudo_file ]]; then
    [[ -f $sudo_file && ! -L $sudo_file ]] && cmp -s "$sudo_file" <(printf '%s' "$sudo_settings") \
        || fail 'Managed sudo configuration differs.'
fi

if [[ -e $umask_file || -L $umask_file ]]; then
    [[ -f $umask_file && ! -L $umask_file ]] \
        && cmp -s "$umask_file" <(printf '%s' "$umask_settings") \
        || fail 'Managed umask configuration differs.'
fi

# Create accounts and apply shared/core directory permissions.
for pair in "${accounts[@]}" agent-common:2101 agent-core:2102; do
    getent group "${pair%:*}" >/dev/null || groupadd -g "${pair#*:}" "${pair%:*}"
done
for pair in "${accounts[@]}"; do
    name=${pair%:*}
    number=${pair#*:}
    getent passwd "$name" >/dev/null || useradd -m -u "$number" -g "$name" -s /bin/bash "$name"
    usermod -aG agent-common "$name"
done
usermod -aG agent-core agent-admin
usermod -aG agent-core agent-dev

# Grant traversal only through the private home and application parent.
chown agent-admin:agent-admin /home/agent-admin
chmod 0700 /home/agent-admin
setfacl -m g:agent-common:--x,m::--x /home/agent-admin
# The application parent is a bind mount: group execute grants traversal only.
install -d -o agent-admin -g agent-common -m 0710 "$agent_home"

prepare_directory "$agent_home/upload_files" agent-common
prepare_directory "$agent_home/api_keys" agent-core
prepare_directory "$agent_home/bin" agent-core
prepare_directory /var/log/agent-app agent-core
prepare_directory /var/lib/agent-evidence agent-core

# Login shells inherit group write access without exposing new files to others.
printf '%s' "$umask_settings" > "$umask_file"
chmod 0644 "$umask_file"

# Install only missing app/key data and preserve matching existing contents.
if [[ ! -e $installed_app ]]; then
    install -o agent-admin -g agent-core -m 0750 "$source_app" "$installed_app"
fi
chown agent-admin:agent-core "$installed_app"
chmod 0750 "$installed_app"

if [[ ! -e $key_file ]]; then
    (umask 0007; printf 'agent_api_key_test\n' > "$key_file")
fi
chown agent-admin:agent-core "$key_file"
chmod 0660 "$key_file"
[[ -L $key_link ]] || ln -s t_secret.key "$key_link"
chown -h agent-admin:agent-core "$key_link"

runuser -u agent-admin -- test -x "$installed_app"
runuser -u agent-dev -- test -r "$key_link"
! runuser -u agent-test -- test -r "$key_link" || fail 'QA unexpectedly has key access.'

# Validate SSH syntax and effective settings before reloading PID 1.
ssh_existed=0
[[ ! -e $ssh_file ]] || ssh_existed=1
printf '%s' "$ssh_settings" > "$ssh_file"
chmod 0644 "$ssh_file"
if ! /usr/sbin/sshd -t || ! /usr/sbin/sshd -T | awk '
    $1 == "port" {ports++; if ($2 != 20022) bad = 1}
    $1 == "permitrootlogin" && $2 == "no" {root = 1}
    $1 == "passwordauthentication" && $2 == "yes" {password = 1}
    END {exit !(ports == 1 && !bad && root && password)}
'; then
    [[ $ssh_existed -eq 1 ]] || unlink "$ssh_file"
    fail 'SSH validation failed; inspect other sshd settings before retrying.'
fi

# Grant only the read-only UFW status command to unattended monitoring.
printf '%s' "$sudo_settings" > "$sudo_file"
chmod 0440 "$sudo_file"
visudo -cf "$sudo_file"

ufw default deny incoming
ufw default allow outgoing
ufw allow 20022/tcp
ufw allow 15034/tcp
ufw --force enable
ufw status | grep -qx 'Status: active' || fail 'UFW did not become active.'
kill -HUP 1

# Replace the monitoring script atomically with the required owner and mode.
install -o agent-dev -g agent-core -m 0750 /workspace/monitor.sh "$agent_home/bin/.monitor.sh.new"
mv -f "$agent_home/bin/.monitor.sh.new" "$agent_home/bin/monitor.sh"

if ! old_cron=$(crontab -u agent-admin -l 2>&1); then
    [[ $old_cron == 'no crontab for agent-admin' ]] || fail "Cannot read crontab: $old_cron"
    old_cron=''
fi

# Replace one managed block, preserving unrelated cron entries.
clean_cron=$(awk '
    /^# BEGIN agent-monitor$/ {
        if (skip) exit 1
        skip = 1
        next
    }
    /^# END agent-monitor$/ {
        if (!skip) exit 1
        skip = 0
        next
    }
    !skip {print}
    END {if (skip) exit 1}
' <<< "$old_cron") || fail 'Malformed managed cron block; existing crontab preserved.'

{
    printf '%s\n' "$clean_cron"
    printf '# BEGIN agent-monitor\n'
    printf '* * * * * umask 0007; PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin '
    printf 'AGENT_HOME=%s AGENT_PORT=15034 ' "$agent_home"
    printf 'AGENT_UPLOAD_DIR=%s/upload_files AGENT_KEY_PATH=%s/api_keys ' "$agent_home" "$agent_home"
    printf 'AGENT_LOG_DIR=/var/log/agent-app %s/bin/monitor.sh >> /var/lib/agent-evidence/cron.log 2>&1\n' "$agent_home"
    printf '# END agent-monitor\n'
} | crontab -u agent-admin -

sha256sum "$installed_app"
printf '[OK] Setup complete; set agent-admin password interactively.\n'
