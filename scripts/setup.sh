#!/usr/bin/env bash
set -euo pipefail

agent_home=$AGENT_HOME
source_app=/workspace/agent-app/agent-app-linux-arm64
source_monitor=/workspace/scripts/monitor.sh
key_file=$agent_home/api_keys/t_secret.key
key_link=$agent_home/api_keys/secret.key

# Report setup failures to stderr and stop with a nonzero status.
fail() {
    echo "[ERROR] $*" >&2
    exit 1
}

# Apply setgid and default ACLs so new entries inherit shared group access.
prepare_directory() {
    local directory=$1
    local group=$2

    install -d -o agent-admin -g "$group" -m 2770 "$directory"
    # Creation modes still limit the permissions inherited from default ACLs.
    setfacl -m d:u::rwx,d:g::rwx,d:m::rwx,d:o::--- "$directory"
}

# Create missing accounts and apply the assignment's supplementary groups.
create_user() {
    local username=$1
    local user_id=$2
    local groups=$3

    if ! getent passwd "$username" >/dev/null; then
        useradd -m -u "$user_id" -s /bin/bash "$username"
    fi
    # Replace supplementary memberships to keep core access limited to admin/dev.
    usermod -G "$groups" "$username"
}

# Check privileges and required sources before changing system settings.
if [[ $EUID -ne 0 ]]; then
    fail 'Run setup as root inside the container.'
fi
if [[ ! -f $source_app || ! -f $source_monitor ]]; then
    fail 'Missing application or monitor source.'
fi

# Validate existing keys and links without overwriting conflicting data.
# Check -L as well as -e so dangling symlinks are not treated as missing files.
if [[ -e $key_file || -L $key_file ]]; then
    if [[ ! -f $key_file || -L $key_file ]]; then
        fail 'Existing key must be a regular file.'
    fi
    if ! printf 'agent_api_key_test\n' | cmp -s "$key_file" -; then
        fail 'Existing key differs from the assignment fixture.'
    fi
fi
if [[ -e $key_link || -L $key_link ]]; then
    if [[ ! -L $key_link || $(readlink "$key_link") != t_secret.key ]]; then
        fail 'Existing key link differs.'
    fi
fi

# Stable UIDs/GIDs preserve named-volume ownership across container recreation.
if ! getent group agent-common >/dev/null; then
    groupadd -g 2101 agent-common
fi
if ! getent group agent-core >/dev/null; then
    groupadd -g 2102 agent-core
fi
create_user agent-admin 2001 agent-common,agent-core
create_user agent-dev 2002 agent-common,agent-core
create_user agent-test 2003 agent-common

# Export Compose settings on admin login; defer id evaluation until login.
cat > /etc/profile.d/agent-app.sh <<PROFILE
if [ "\$(id -un)" = agent-admin ]; then
    export AGENT_HOME="$AGENT_HOME"
    export AGENT_PORT="$AGENT_PORT"
    export AGENT_UPLOAD_DIR="$AGENT_UPLOAD_DIR"
    export AGENT_KEY_PATH="$AGENT_KEY_PATH"
    export AGENT_LOG_DIR="$AGENT_LOG_DIR"
fi
PROFILE
chmod 644 /etc/profile.d/agent-app.sh

# Allow common members to traverse the private home without listing its contents.
chown agent-admin:agent-admin /home/agent-admin
chmod 700 /home/agent-admin
setfacl -m g:agent-common:--x /home/agent-admin
# Separate common upload access from core-only keys, scripts, and logs.
install -d -o agent-admin -g agent-common -m 710 "$agent_home"
prepare_directory "$agent_home/upload_files" agent-common
prepare_directory "$agent_home/api_keys" agent-core
prepare_directory "$agent_home/bin" agent-core
prepare_directory /var/log/agent-app agent-core
# Preserve existing log contents while restoring ownership and permissions.
touch /var/log/agent-app/monitor.log
chown agent-admin:agent-core /var/log/agent-app/monitor.log
chmod 660 /var/log/agent-app/monitor.log

# Create only missing key entries; the directory path/link is the approved app exception.
if [[ ! -e $key_file ]]; then
    printf 'agent_api_key_test\n' > "$key_file"
fi
chown agent-admin:agent-core "$key_file"
chmod 660 "$key_file"
if [[ ! -L $key_link ]]; then
    ln -s t_secret.key "$key_link"
fi
# Install the supplied binary unchanged and give dev ownership of the monitor.
install -o agent-admin -g agent-core -m 750 "$source_app" "$agent_home/agent-app-linux-arm64"
install -o agent-dev -g agent-core -m 750 "$source_monitor" "$agent_home/bin/monitor.sh"

# Configure SSH and validate it before the later reload.
cat > /etc/ssh/sshd_config.d/00-agent.conf <<'SSH'
Port 20022
PermitRootLogin no
PasswordAuthentication yes
SSH
/usr/sbin/sshd -t
# Allow unattended UFW status queries without granting firewall changes.
echo 'agent-admin ALL=(root) NOPASSWD: /usr/sbin/ufw status' > /etc/sudoers.d/agent-ufw-status
chmod 440 /etc/sudoers.d/agent-ufw-status

# Replace UFW rules with inbound denial and only the two required TCP exceptions.
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow 20022/tcp
ufw allow 15034/tcp
ufw --force enable
# start.sh execs sshd as PID 1; reload the validated SSH settings.
kill -HUP 1

# Replace admin's crontab with one monitoring job and an explicit command PATH.
crontab -u agent-admin - <<CRON
PATH=/usr/sbin:/usr/bin:/sbin:/bin
* * * * * $agent_home/bin/monitor.sh >> /var/log/agent-app/cron.log 2>&1
CRON
