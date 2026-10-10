#!/usr/bin/env bash

set -Eeuo pipefail
trap 'printf "[ERROR] Startup failed at line %s\n" "$LINENO" >&2' ERR

if [[ $EUID -ne 0 ]]; then
    printf '[ERROR] Start services as root.\n' >&2
    exit 1
fi

# Generate missing SSH host keys at runtime.
install -d -m 0755 /run/sshd
ssh-keygen -A
/usr/sbin/sshd -t

# Start both services without systemd; keep SSH as PID 1.
/usr/sbin/cron
exec /usr/sbin/sshd -D -e
