#!/usr/bin/env bash
set -e

# Prepare SSH's runtime directory and start cron for scheduled monitoring.
mkdir -p /run/sshd
/usr/sbin/cron

# Run sshd as PID 1 so setup can reload it with SIGHUP.
exec /usr/sbin/sshd -D
