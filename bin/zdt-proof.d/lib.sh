#!/usr/bin/env bash
#
# Shared helpers for the zdt-proof scripts. Sourced, never run.
#
# It works out which Kapelos site is active, where its tree is on the host,
# and which container runs its PHP, then gives each proof a small vocabulary:
# `mphp` runs PHP in the store, `magento` runs bin/magento, `sql` runs a query
# on the store's database, and `pass`/`fail` record a falsifier's outcome.
# The tally at the end decides the exit status, so a run with any FAIL exits 1.

set -euo pipefail

HERE="${ZDT_PROOF_DIR:?run proofs through bin/zdt-proof, which sets ZDT_PROOF_DIR}"

# Kapelos has no fixed place on a machine, so its checkout is named rather than
# guessed, and every Kapelos command runs from that checkout.
[[ -n ${KAPELOS_HOME:-} ]] || {
    echo "zdt-proof: KAPELOS_HOME is not set. Set it to your Kapelos checkout, for example:" >&2
    echo "  KAPELOS_HOME=/path/to/kapelos bin/zdt-proof ${0##*/}" | sed 's/\.sh$//' >&2
    exit 2
}
[[ -x $KAPELOS_HOME/bin/kapelos ]] || { echo "zdt-proof: KAPELOS_HOME=$KAPELOS_HOME has no bin/kapelos, so it is not a Kapelos checkout" >&2; exit 2; }
kapelos() { "$KAPELOS_HOME/bin/kapelos" "$@"; }

site="${ZDT_SITE:-$(kapelos sites | sed -n 's/^\* \([^ ]*\).*/\1/p')}"
[[ -n $site ]] || { echo "zdt-proof: no active Kapelos site" >&2; exit 2; }
envfile="$KAPELOS_HOME/etc/sites/$site.env"
[[ -f $envfile ]] || { echo "zdt-proof: no settings file for site $site at $envfile" >&2; exit 2; }

MAGENTO_SRC=$(sed -n 's/^MAGENTO_SRC=//p' "$envfile")
PROJECT=$(sed -n 's/^COMPOSE_PROJECT_NAME=//p' "$envfile")
PHP_CONTAINER="$PROJECT-php-1"
DB_CONTAINER="$PROJECT-db-1"

# Where the container sees the store: /app for a Kapelos store, somewhere else
# for a site whose compose overlay mounts it differently. Read from Docker
# rather than assumed.
# A site can be mounted at more than one place; a release layout's own symlink
# says which of them it was deployed to.
CONTAINER_MOUNT=""
for mount in $(docker inspect "$PHP_CONTAINER" -f '{{range .Mounts}}{{if eq .Source "'"$MAGENTO_SRC"'"}}{{.Destination}}{{"\n"}}{{end}}{{end}}' 2>/dev/null); do
    [[ -z $CONTAINER_MOUNT ]] && CONTAINER_MOUNT="$mount"
    if [[ $(docker exec "$PHP_CONTAINER" readlink "$mount/magento_current" 2>/dev/null) == "$mount"/* ]]; then
        CONTAINER_MOUNT="$mount"
        break
    fi
done
[[ -n $CONTAINER_MOUNT ]] || { echo "zdt-proof: $PHP_CONTAINER is not running or does not mount $MAGENTO_SRC" >&2; exit 2; }
ZDT_ROOT="${ZDT_ROOT:-$CONTAINER_MOUNT}"

# Host path of the Magento root, which differs from MAGENTO_SRC only for a
# store laid out as releases with ZDT_ROOT pointing into one.
HOST_ROOT="$MAGENTO_SRC${ZDT_ROOT#"$CONTAINER_MOUNT"}"

PASSES=0
FAILS=0

# Copy the payloads into the store, where the container can see them.
stage() {
    local dest="$HOST_ROOT/local.d/zdt-proof"
    mkdir -p "$dest/out"
    rsync -a --delete --exclude out "$HERE/php/" "$dest/php/"
    rsync -a --delete "$HERE/module/" "$dest/module/"
}

outdir() {
    local d="$HOST_ROOT/local.d/zdt-proof/out/$1"
    mkdir -p "$d"
    chmod 0777 "$d"
    echo "$d"
}

# ZDT_EXEC_USER runs PHP as a named user, for a site whose web server is not
# the container's default user (a site laid out as releases usually runs www-data).
EXEC_USER_ARGS=()
[[ -n ${ZDT_EXEC_USER:-} ]] && EXEC_USER_ARGS=(-u "$ZDT_EXEC_USER")
mphp() {
    docker exec -i "${EXEC_USER_ARGS[@]}" -w "$ZDT_ROOT" "$PHP_CONTAINER" php -d memory_limit=-1 -d display_errors=stderr "$@"
}

magento() {
    mphp bin/magento "$@"
}

# The database password is read inside the container, so it never reaches
# this shell's argument list or its output.
# shellcheck disable=SC2120  # the proofs call it with arguments
sql() {
    if [[ $# -gt 0 ]]; then
        sql <<<"$1"
        return
    fi
    docker exec -i "$DB_CONTAINER" sh -c 'mariadb -uroot -p"$MARIADB_ROOT_PASSWORD" "$MARIADB_DATABASE"'
}

step() { printf '\n== %s\n' "$*"; }
pass() { PASSES=$((PASSES + 1)); printf 'PASS  %s\n' "$*"; }
fail() { FAILS=$((FAILS + 1)); printf 'FAIL  %s\n' "$*"; }
note() { printf 'NOTE  %s\n' "$*"; }

finish() {
    printf '\n%s on site %s: %d passed, %d failed\n' "${0##*/}" "$site" "$PASSES" "$FAILS"
    [[ $FAILS -eq 0 ]]
}

# The fixture module lives in module/base; module/variants/<name> holds only
# the files a proof changes. Putting variants in place replaces the module in
# app/code with base plus each variant in the order given, so every state is reproducible from
# the payload and nothing depends on what the last proof left behind.
# shellcheck disable=SC2120  # the proofs call it with arguments
fixture_state() {
    local target="$HOST_ROOT/app/code/Kingletas/ZdtProof" variant
    mkdir -p "$target"
    rsync -a --delete "$HERE/module/base/Kingletas/ZdtProof/" "$target/"
    for variant in "$@"; do
        [[ -d $HERE/module/variants/$variant ]] || { echo "zdt-proof: no fixture variant $variant" >&2; exit 2; }
        rsync -a "$HERE/module/variants/$variant/" "$target/"
    done
    settle
}

# opcache.revalidate_freq is 2 in Kapelos, so a PHP file swapped less than two
# seconds before a request can still run as the old file. Every change to code
# or config.php waits this out.
settle() {
    sleep 3
}

# Install the fixture once and snapshot the store with it, so every proof can
# start from `kapelos snapshot restore fixture`.
ensure_fixture() {
    local status
    status=$(magento module:status Kingletas_ZdtProof 2>/dev/null || true)
    if grep -q 'Module is enabled' <<<"$status"; then
        return 0
    fi
    step "Installing the fixture module and saving snapshot 'fixture'"
    fixture_state
    local out
    # module:enable empties generated/code, which on a store with an optimised
    # classmap breaks every command after it, so the module is enabled in
    # config.php directly.
    # shellcheck disable=SC2016  # PHP source: PHP expands these, not the shell
    out=$(mphp -r '
        $c = require "app/etc/config.php";
        $c["modules"]["Kingletas_ZdtProof"] = 1;
        file_put_contents("app/etc/config.php", "<?php\nreturn " . var_export($c, true) . ";\n");
    ' 2>&1) || { echo "zdt-proof: enabling the fixture in config.php failed:" >&2; tail -15 <<<"$out" >&2; exit 1; }
    settle
    out=$(magento setup:upgrade --keep-generated 2>&1) || { echo "zdt-proof: setup:upgrade failed installing the fixture:" >&2; tail -15 <<<"$out" >&2; exit 1; }
    (cd "$KAPELOS_HOME" && kapelos snapshot save fixture -y >/dev/null 2>&1) || true
    (cd "$KAPELOS_HOME" && kapelos snapshot) | grep '^  fixture ' >/dev/null || { echo "zdt-proof: snapshot 'fixture' was not saved" >&2; exit 1; }
}

# Put the store back to the installed fixture: database and code both.
reset_fixture() {
    fixture_state
    restore_snapshot fixture
    magento cache:flush >/dev/null
}

# Kapelos restores the volumes and then resets caches with bin/magento from the
# site root, which a release layout does not have. So a restore is judged by
# whether the database volume came back, and the cache is flushed from the
# release by the caller.
restore_snapshot() {
    local out
    out=$(cd "$KAPELOS_HOME" && kapelos snapshot restore "$1" -y 2>&1) || true
    grep -q 'Restoring db-data' <<<"$out" || { echo "zdt-proof: restoring snapshot $1 failed:" >&2; tail -5 <<<"$out" >&2; exit 1; }
}

# GET or POST against the store and print only the status code; the body goes
# to $LAST_BODY so a proof can look inside it.
BASE_URL="${ZDT_BASE_URL:-$(sed -n 's/^MAGENTO_BASE_URL=//p' "$envfile")}"
BASE_URL="${BASE_URL%/}"
LAST_BODY=$(mktemp)
trap 'rm -f "$LAST_BODY"' EXIT
http() {
    curl -s -o "$LAST_BODY" -w '%{http_code}' --max-time 120 "$@"
}

# A unique query string, so Varnish can never answer a request from its cache
# and every check reaches PHP.
bust() {
    printf '%s%szdt=%s%s' "$1" "$([[ $1 == *\?* ]] && echo '&' || echo '?')" "$(date +%s%N)" "$RANDOM"
}

exception_lines() {
    wc -l <"$HOST_ROOT/var/log/exception.log" 2>/dev/null || echo 0
}
