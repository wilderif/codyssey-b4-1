#!/usr/bin/env bash
set -euo pipefail

agent_home=$AGENT_HOME
source_app=/workspace/agent-app/agent-app-linux-arm64
source_monitor=/workspace/scripts/monitor.sh
key_file=$agent_home/api_keys/t_secret.key
key_link=$agent_home/api_keys/secret.key

fail() {
    echo "[ERROR] $*" >&2
    exit 1
}

prepare_directory() {
    local directory=$1
    local group=$2

    install -d -o agent-admin -g "$group" -m 2770 "$directory"
    setfacl -m d:u::rwx,d:g::rwx,d:m::rwx,d:o::--- "$directory"
}

create_user() {
    local username=$1
    local user_id=$2

    if ! getent passwd "$username" >/dev/null; then
        useradd -m -u "$user_id" -s /bin/bash "$username"
    fi
    usermod -G agent-common "$username"
}

if [[ $EUID -ne 0 ]]; then
    fail 'Run setup as root inside the container.'
fi
if [[ ! -f $source_app || ! -f $source_monitor ]]; then
    fail 'Missing application or monitor source.'
fi

# Preserve the fixture and reject conflicting existing key data.
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

# Stable UIDs keep application ownership consistent across container recreation.
if ! getent group agent-common >/dev/null; then
    groupadd -g 2101 agent-common
fi
if ! getent group agent-core >/dev/null; then
    groupadd -g 2102 agent-core
fi
create_user agent-admin 2001
create_user agent-dev 2002
create_user agent-test 2003
usermod -aG agent-core agent-admin
usermod -aG agent-core agent-dev

# Copy Compose settings into agent-admin's SSH login environment.
cat > /etc/profile.d/agent-app.sh <<PROFILE
if [ "\$(id -un)" = agent-admin ]; then
    export AGENT_HOME="$AGENT_HOME"
    export AGENT_PORT="$AGENT_PORT"
    export AGENT_UPLOAD_DIR="$AGENT_UPLOAD_DIR"
    export AGENT_KEY_PATH="$AGENT_KEY_PATH"
    export AGENT_LOG_DIR="$AGENT_LOG_DIR"
fi
PROFILE
chmod 0644 /etc/profile.d/agent-app.sh

# Set directory access and prepare the monitoring log.
chown agent-admin:agent-admin /home/agent-admin
chmod 0700 /home/agent-admin
setfacl -m g:agent-common:--x /home/agent-admin
install -d -o agent-admin -g agent-common -m 0710 "$agent_home"
prepare_directory "$agent_home/upload_files" agent-common
prepare_directory "$agent_home/api_keys" agent-core
prepare_directory "$agent_home/bin" agent-core
prepare_directory /var/log/agent-app agent-core
touch /var/log/agent-app/monitor.log
chown agent-admin:agent-core /var/log/agent-app/monitor.log
chmod 0660 /var/log/agent-app/monitor.log

# Install the key fixture and application files.
if [[ ! -e $key_file ]]; then
    printf 'agent_api_key_test\n' > "$key_file"
fi
chown agent-admin:agent-core "$key_file"
chmod 0660 "$key_file"
if [[ ! -L $key_link ]]; then
    ln -s t_secret.key "$key_link"
fi
install -o agent-admin -g agent-core -m 0750 "$source_app" "$agent_home/agent-app-linux-arm64"
install -o agent-dev -g agent-core -m 0750 "$source_monitor" "$agent_home/bin/monitor.sh"

cat > /etc/ssh/sshd_config.d/00-agent.conf <<'SSH'
Port 20022
PermitRootLogin no
PasswordAuthentication yes
SSH
/usr/sbin/sshd -t
printf 'agent-admin ALL=(root) NOPASSWD: /usr/sbin/ufw status\n' > /etc/sudoers.d/agent-ufw-status
chmod 0440 /etc/sudoers.d/agent-ufw-status

# Configure only the two assignment ports.
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow 20022/tcp
ufw allow 15034/tcp
ufw --force enable
kill -HUP 1

# Replace the previous monitor entry without replacing unrelated cron jobs.
old_cron=$(crontab -u agent-admin -l 2>/dev/null || true)
cron_path=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
{
    printf '%s\n' "$old_cron" | grep -vF '/bin/monitor.sh' || true
    printf '* * * * * PATH=%s %s/bin/monitor.sh >> /var/log/agent-app/cron.log 2>&1\n' \
        "$cron_path" "$agent_home"
} | crontab -u agent-admin -
