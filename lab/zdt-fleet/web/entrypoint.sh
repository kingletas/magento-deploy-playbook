#!/usr/bin/env bash
# Starts sshd, PHP-FPM and nginx, and exits when any of them does, so Docker
# sees a node that lost a service as stopped rather than half alive.
set -euo pipefail

# The host key lives on the node's own volume, so a recreated container keeps
# its identity and the arms' strict host-key checking still passes.
host_keys=/var/www/magento/.host-keys
install -d -o root -g root -m 700 "$host_keys"
[[ -f $host_keys/ssh_host_ed25519_key ]] || ssh-keygen -q -t ed25519 -N '' -f "$host_keys/ssh_host_ed25519_key"
install -o deploy -g deploy -m 600 /run/zdtfleet/authorized_keys /home/deploy/.ssh/authorized_keys

/usr/sbin/sshd -D -e -h "$host_keys/ssh_host_ed25519_key" &
php-fpm -F &
nginx -g 'daemon off;' &

wait -n
echo "zdtfleet: a service on $(hostname) exited; stopping the node" >&2
exit 1
