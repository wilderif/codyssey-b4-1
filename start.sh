#!/usr/bin/env bash
set -Eeuo pipefail # Stop when service startup fails.
trap 'printf "[ERROR] Startup failed at line %s\n" "$LINENO" >&2' ERR # Identify the failed operation.
[[ $EUID -eq 0 ]] || { printf '[ERROR] Start services as root.\n' >&2; exit 1; } # Require service privileges.
install -d -m 0755 /run/sshd # Prepare the OpenSSH runtime directory.
ssh-keygen -A # Generate missing host keys at runtime, never in the image.
/usr/sbin/sshd -t # Validate the current configuration before starting SSH.
/usr/sbin/cron # Start the cron daemon without systemd.
exec /usr/sbin/sshd -D -e # Keep SSH in the foreground as the container's main process.
