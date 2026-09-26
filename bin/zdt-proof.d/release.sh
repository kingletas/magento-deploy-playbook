#!/usr/bin/env bash
#
# Helpers for proofs on a site laid out as releases. Sourced after lib.sh.
#
# `flip` repoints magento_current atomically, the way Ansible's file module
# does with force: a new link beside it, renamed over the old one.
# `reload_php` runs the container's /etc/init.d/php-fpm reload, the init script
# the playbook's service module reaches on a host without systemd, which sends
# USR2 to php-fpm. `marker` fetches the storefront past Varnish and prints the
# static version each response renders, one per request.

# shellcheck disable=SC2034  # read by the proofs that source this file
RELEASES="$CONTAINER_MOUNT/releases"
CURRENT_LINK="$CONTAINER_MOUNT/magento_current"

current_release() { docker exec "$PHP_CONTAINER" readlink "$CURRENT_LINK"; }

flip() {
    docker exec "$PHP_CONTAINER" sh -c "ln -sfn '$1' '$CURRENT_LINK.zdt-new' && mv -T '$CURRENT_LINK.zdt-new' '$CURRENT_LINK'"
}

reload_php() {
    docker exec "$PHP_CONTAINER" /etc/init.d/php-fpm reload >/dev/null
    sleep 3
}

static_version() { docker exec "$PHP_CONTAINER" cat "$1/pub/static/deployed_version.txt"; }

flush_cache() {
    docker exec -u www-data -w "$CURRENT_LINK" "$PHP_CONTAINER" php bin/magento cache:flush >/dev/null
}

# $1 number of requests. Prints the distinct versions seen, with counts.
marker() {
    local i
    for _ in $(seq 1 "$1"); do
        curl -s --max-time 60 "$(bust "$BASE_URL/")" | grep -o 'static/version[0-9]*/' | head -1
    done | sed 's|static/version||; s|/||' | sort | uniq -c | awk '{printf "%s×%s ", $2, $1}'
}

# A superseded release keeps the maintenance flag the next deploy set in it,
# because var/ is not shared. Proofs that serve from an old release set that
# flag aside and put it back, byte for byte, when they finish.
hold_maintenance() {
    docker exec "$PHP_CONTAINER" sh -c "[ ! -e '$1/var/.maintenance.flag' ] || mv '$1/var/.maintenance.flag' '$1/var/.maintenance.flag.zdt-held'"
}
release_maintenance() {
    docker exec "$PHP_CONTAINER" sh -c "[ ! -e '$1/var/.maintenance.flag.zdt-held' ] || mv '$1/var/.maintenance.flag.zdt-held' '$1/var/.maintenance.flag'"
}
