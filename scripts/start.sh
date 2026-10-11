#!/usr/bin/env bash
set -euo pipefail

# Start services without systemd; keep SSH in the foreground.
install -d -m 0755 /run/sshd
ssh-keygen -A
/usr/sbin/sshd -t
/usr/sbin/cron
exec /usr/sbin/sshd -D -e
