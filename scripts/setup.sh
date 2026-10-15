#!/usr/bin/env bash
set -Eeuo pipefail
export LC_ALL=C
trap 'echo "[ERROR] Setup failed at line $LINENO" >&2' ERR

agent_home=${AGENT_HOME:?Run setup with the compose.yaml environment.}
source_app=/workspace/agent-app/agent-app-linux-arm64
key_file=$agent_home/api_keys/t_secret.key
key_link=$agent_home/api_keys/secret.key

fail() {
    echo "[ERROR] $*" >&2
    exit 1
}

prepare_directory() {
    install -d -o agent-admin -g "$2" -m 2770 "$1"
    setfacl -m d:u::rwx,d:g::rwx,d:m::rwx,d:o::--- "$1"
}

[[ $EUID -eq 0 ]] || fail 'Run setup as root inside the container.'
[[ -f $source_app && -f /workspace/scripts/monitor.sh ]] || fail 'Missing application or monitor source.'
bash -n /workspace/scripts/monitor.sh

# Preserve the fixture and reject conflicting existing key data.
if [[ -e $key_file || -L $key_file ]]; then
    if [[ ! -f $key_file || -L $key_file ]] || ! cmp -s "$key_file" <(printf 'agent_api_key_test\n'); then
        fail 'Existing key differs from the assignment fixture.'
    fi
fi
if [[ -e $key_link || -L $key_link ]]; then
    [[ -L $key_link && $(readlink "$key_link") == t_secret.key ]] || fail 'Existing key link differs.'
fi

# Stable UIDs keep application ownership consistent across container recreation.
getent group agent-common >/dev/null || groupadd -g 2101 agent-common
getent group agent-core >/dev/null || groupadd -g 2102 agent-core
for pair in agent-admin:2001 agent-dev:2002 agent-test:2003; do
    name=${pair%:*}
    getent passwd "$name" >/dev/null || useradd -m -u "${pair#*:}" -s /bin/bash "$name"
    usermod -aG agent-common "$name"
done
usermod -aG agent-core agent-admin
usermod -aG agent-core agent-dev
if id -nG agent-test | grep -qw agent-core; then
    fail 'agent-test must not belong to agent-core.'
fi

# Copy Compose settings into agent-admin's SSH login environment.
{
    printf 'if [ "$(id -un)" = agent-admin ]; then\n'
    for variable in AGENT_HOME AGENT_PORT AGENT_UPLOAD_DIR AGENT_KEY_PATH AGENT_LOG_DIR; do
        printf '    export %s=%q\n' "$variable" "${!variable}"
    done
    printf 'fi\n'
} > /etc/profile.d/agent-app.sh
chmod 0644 /etc/profile.d/agent-app.sh

chown agent-admin:agent-admin /home/agent-admin
chmod 0700 /home/agent-admin
setfacl -m g:agent-common:--x /home/agent-admin
install -d -o agent-admin -g agent-common -m 0710 "$agent_home"
prepare_directory "$agent_home/upload_files" agent-common
prepare_directory "$agent_home/api_keys" agent-core
prepare_directory "$agent_home/bin" agent-core
prepare_directory /var/log/agent-app agent-core

if [[ ! -e $key_file ]]; then
    printf 'agent_api_key_test\n' > "$key_file"
fi
chown agent-admin:agent-core "$key_file"
chmod 0660 "$key_file"
[[ -L $key_link ]] || ln -s t_secret.key "$key_link"
if [[ ! -e $agent_home/agent-app-linux-arm64 ]]; then
    install -o agent-admin -g agent-core -m 0750 "$source_app" "$agent_home/agent-app-linux-arm64"
fi
chown agent-admin:agent-core "$agent_home/agent-app-linux-arm64"
chmod 0750 "$agent_home/agent-app-linux-arm64"
install -o agent-dev -g agent-core -m 0750 /workspace/scripts/monitor.sh "$agent_home/bin/monitor.sh"

cat > /etc/ssh/sshd_config.d/00-agent.conf <<'SSH'
Port 20022
PermitRootLogin no
PasswordAuthentication yes
SSH
/usr/sbin/sshd -t
ssh_settings=$(/usr/sbin/sshd -T)
grep -qx 'port 20022' <<< "$ssh_settings"
grep -qx 'permitrootlogin no' <<< "$ssh_settings"
printf 'agent-admin ALL=(root) NOPASSWD: /usr/sbin/ufw status\n' > /etc/sudoers.d/agent-ufw-status
chmod 0440 /etc/sudoers.d/agent-ufw-status
visudo -cf /etc/sudoers.d/agent-ufw-status

# Preserve existing firewall state; reject unrelated inbound allowances.
while IFS= read -r rule; do
    case "$rule" in
        'ufw allow 20022/tcp'|'ufw allow 15034/tcp') ;;
        ufw\ *) fail "Unexpected UFW rule: $rule" ;;
    esac
done < <(ufw show added)
ufw default deny incoming
ufw default allow outgoing
ufw allow 20022/tcp
ufw allow 15034/tcp
ufw --force enable
kill -HUP 1

# Replace the previous monitor entry without replacing unrelated cron jobs.
old_cron=$(crontab -u agent-admin -l 2>/dev/null || true)
{
    printf '%s\n' "$old_cron" | sed '/^# BEGIN agent-monitor$/,/^# END agent-monitor$/d; \@/bin/monitor.sh@d'
    printf '* * * * * umask 0007; PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin %s/bin/monitor.sh >> /var/log/agent-app/cron.log 2>&1\n' "$agent_home"
} | crontab -u agent-admin -
echo '[OK] Setup complete. Set agent-admin password interactively.'
