#!/usr/bin/env bash
# summary: two releases sharing one cache read each other's merged configuration
#
# P1-1. Runs on a site laid out the way this playbook deploys: releases/, a
# magento_current symlink, and env.php shared by symlink from shared/env.php.
# Copies the current release twice, as zdt_a and zdt_b, enables a module that
# declares one observer in zdt_b only, and asks each release in turn how many
# observers the event has.
#
# Falsifiers:
#   F11a  with env.php's shared id_prefix, the release read second sees its
#         own configuration rather than the one the first release cached
#   F11b  with the prefix removed from env.php (so each release derives one
#         from its own path), or with explicit different prefixes, the
#         interference does not stop
#
# Negative control: with the cache flushed before each read, zdt_a sees 0
# observers and zdt_b sees 1, so the two releases really are different.
#
# Changes the site: adds two release directories, edits the shared env.php and
# two release env.php links, and puts all of them back before it finishes.
#
# Environment overrides:
#   ZDT_SOURCE_RELEASE  the release to copy (default: the one magento_current
#                       points at)

# shellcheck source=/dev/null  # ZDT_PROOF_DIR is set by bin/zdt-proof at run time
source "$ZDT_PROOF_DIR/lib.sh"

OUT=$(outdir p1-1)
C_ROOT="$CONTAINER_MOUNT"
SHARED_ENV="$MAGENTO_SRC/shared/env.php"
SOURCE="${ZDT_SOURCE_RELEASE:-$(docker exec "$PHP_CONTAINER" readlink "$C_ROOT/magento_current")}"
READER="$C_ROOT/local.d/zdt-proof/php/p1-1-events.php"

[[ -f $SHARED_ENV ]] || { echo "p1-1: $MAGENTO_SRC is not laid out as releases with a shared env.php" >&2; exit 2; }

in_release() {
    local release="$1"
    shift
    docker exec -i -u www-data -w "$C_ROOT/releases/$release" "$PHP_CONTAINER" php -d memory_limit=-1 "$@"
}
observers() { in_release "$1" "$READER" | tee -a "$OUT/reads.txt" | sed -n 's/^observers=//p'; }
prefix() { in_release "$1" "$READER" | sed -n 's/^id_prefix=//p'; }
flush() { in_release zdt_a bin/magento cache:flush >/dev/null; }

cp "$SHARED_ENV" "$OUT/env.php.orig"
cleanup() {
    cp "$OUT/env.php.orig" "$SHARED_ENV"
    docker exec "$PHP_CONTAINER" rm -rf "$C_ROOT/releases/zdt_a" "$C_ROOT/releases/zdt_b"
    rm -f "$LAST_BODY"
}
trap cleanup EXIT

stage
step "Copying $SOURCE to releases/zdt_a and releases/zdt_b"
for r in zdt_a zdt_b; do
    docker exec "$PHP_CONTAINER" sh -c "rm -rf '$C_ROOT/releases/$r' && cp -a '$SOURCE' '$C_ROOT/releases/$r'"
done
docker exec "$PHP_CONTAINER" mkdir -p "$C_ROOT/releases/zdt_b/app/code/Kingletas"
docker cp "$HERE/module/cache-probe/Kingletas/ZdtCacheProbe" "$PHP_CONTAINER:$C_ROOT/releases/zdt_b/app/code/Kingletas/ZdtCacheProbe"
# shellcheck disable=SC2016  # PHP source: PHP expands these, not the shell
in_release zdt_b -r '
    $c = require "app/etc/config.php";
    $c["modules"]["Kingletas_ZdtCacheProbe"] = 1;
    file_put_contents("app/etc/config.php", "<?php\nreturn " . var_export($c, true) . ";\n");
'
docker exec "$PHP_CONTAINER" chown -R www-data:www-data "$C_ROOT/releases/zdt_b/app"

# $1 label. Reads A then B, and B then A, with one flush before each pair.
cross_reads() {
    local label="$1" ab_a ab_b ba_b ba_a
    flush; ab_a=$(observers zdt_a); ab_b=$(observers zdt_b)
    flush; ba_b=$(observers zdt_b); ba_a=$(observers zdt_a)
    echo "$label: A then B -> A=$ab_a B=$ab_b | B then A -> B=$ba_b A=$ba_a"
    CROSS="$ab_a $ab_b $ba_b $ba_a"
}

step "Negative control: each release read cold"
flush; cold_a=$(observers zdt_a)
flush; cold_b=$(observers zdt_b)
echo "cold: A=$cold_a B=$cold_b"
if [[ $cold_a == 0 && $cold_b == 1 ]]; then
    pass "control: read cold, zdt_a has 0 observers and zdt_b has 1"
else
    fail "control: cold reads A=$cold_a B=$cold_b, so the releases do not differ as intended"
fi

step "F11a: shared env.php, one id_prefix"
echo "prefixes: A=$(prefix zdt_a) B=$(prefix zdt_b)"
cross_reads shared
read -r ab_a ab_b ba_b ba_a <<<"$CROSS"
if [[ $ab_b == 0 ]]; then
    pass "F11a warmed by A, B reads A's configuration: its own observer is missing"
else
    fail "F11a warmed by A, B still sees its own observer ($ab_b)"
fi
if [[ $ba_a == 1 ]]; then
    pass "F11a warmed by B, A reads B's configuration: an observer whose class A does not have"
else
    fail "F11a warmed by B, A sees $ba_a observers"
fi

step "F11b: no id_prefix in env.php, so each release derives its own"
# shellcheck disable=SC2016  # PHP source: PHP expands these, not the shell
in_release zdt_a -r '
    $e = require $argv[1];
    foreach ($e["cache"]["frontend"] as $k => $f) { unset($e["cache"]["frontend"][$k]["id_prefix"]); }
    file_put_contents($argv[1], "<?php\nreturn " . var_export($e, true) . ";\n");
' "$C_ROOT/shared/env.php"
sleep 3
pa=$(prefix zdt_a); pb=$(prefix zdt_b)
echo "prefixes: A=$pa B=$pb"
if [[ -n $pa && $pa != "$pb" ]]; then
    pass "F11b derived prefixes differ per release ($pa, $pb)"
else
    fail "F11b derived prefixes are the same ($pa, $pb)"
fi
cross_reads derived
read -r ab_a ab_b ba_b ba_a <<<"$CROSS"
if [[ "$ab_a$ab_b$ba_b$ba_a" == 0110 ]]; then
    pass "F11b with derived prefixes each release reads only its own configuration"
else
    fail "F11b derived prefixes still interfere ($CROSS)"
fi

step "F11b: explicit different prefixes, one env.php per release"
cp "$OUT/env.php.orig" "$SHARED_ENV"
for r in zdt_a zdt_b; do
    # shellcheck disable=SC2016  # PHP source: PHP expands these, not the shell
    in_release "$r" -r '
        $e = require "app/etc/env.php";
        foreach ($e["cache"]["frontend"] as $k => $f) { $e["cache"]["frontend"][$k]["id_prefix"] = $argv[1]; }
        unlink("app/etc/env.php");
        file_put_contents("app/etc/env.php", "<?php\nreturn " . var_export($e, true) . ";\n");
    ' "${r}_"
done
sleep 3
echo "prefixes: A=$(prefix zdt_a) B=$(prefix zdt_b)"
cross_reads explicit
read -r ab_a ab_b ba_b ba_a <<<"$CROSS"
if [[ "$ab_a$ab_b$ba_b$ba_a" == 0110 ]]; then
    pass "F11b with explicit different prefixes each release reads only its own configuration"
else
    fail "F11b explicit prefixes still interfere ($CROSS)"
fi

step "Cleaning up"
flush
cleanup
trap - EXIT
[[ $(docker exec "$PHP_CONTAINER" readlink "$C_ROOT/magento_current") == "$SOURCE" ]] && note "magento_current untouched: $SOURCE"
finish
