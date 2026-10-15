#!/usr/bin/env bash
set -e

mkdir -p /run/sshd
/usr/sbin/cron

# Keep SSH in the foreground as the container's main process.
exec /usr/sbin/sshd -D
