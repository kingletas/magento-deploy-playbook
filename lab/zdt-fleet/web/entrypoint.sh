#!/usr/bin/env bash
# Starts sshd, PHP-FPM and nginx, and exits when any of them does, so Docker
# sees a node that lost a service as stopped rather than half alive.
set -euo pipefail

ssh-keygen -A >/dev/null
install -o deploy -g deploy -m 600 /run/zdtfleet/authorized_keys /home/deploy/.ssh/authorized_keys

/usr/sbin/sshd -D -e &
php-fpm -F &
nginx -g 'daemon off;' &

wait -n
echo "zdtfleet: a service on $(hostname) exited; stopping the node" >&2
exit 1
