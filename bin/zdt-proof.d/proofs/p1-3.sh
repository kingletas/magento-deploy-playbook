#!/usr/bin/env bash
# summary: a php-fpm reload after a symlink flip serves the new release
#
# P1-3. On a site laid out as releases, flips magento_current between two
# releases and reads which release the storefront renders from, by the static
# version in the page. First without reloading php-fpm, which is the negative
# control, then after the USR2 reload the playbook's service task sends. Runs
# twice: with opcache.validate_timestamps as the site has it, and with it off,
# as production runs.
#
# Falsifiers:
#   F13a  after a flip and a reload, a request still renders the old release
#   F13b  the same, with opcache.validate_timestamps=0
#
# Negative control: after a flip without a reload, the old release is still
# what serves. If the new one serves at once, the reload was never what made
# the flip work, and that is reported rather than worked around.
#
# Changes the site: flips magento_current, reloads php-fpm, adds and removes an
# ini file in the PHP container, holds the old release's maintenance flag
# aside, and puts all of it back before finishing.
#
# Environment overrides:
#   ZDT_OLD_RELEASE  the release to flip to (default: the newest other one)
#   ZDT_REQUESTS     requests per reading (default 20)

# shellcheck source=/dev/null  # ZDT_PROOF_DIR is set by bin/zdt-proof at run time
source "$ZDT_PROOF_DIR/lib.sh"
# shellcheck source=/dev/null  # ZDT_PROOF_DIR is set by bin/zdt-proof at run time
source "$ZDT_PROOF_DIR/release.sh"

OUT=$(outdir p1-3)
REQUESTS="${ZDT_REQUESTS:-20}"
ORIGINAL=$(current_release)
OLD="${ZDT_OLD_RELEASE:-$(docker exec "$PHP_CONTAINER" sh -c "ls -d $RELEASES/*/ | sed 's:/\$::' | grep -v '$ORIGINAL' | sort | tail -1")}"
V_CUR=$(static_version "$ORIGINAL")
V_OLD=$(static_version "$OLD")
INI=/usr/local/etc/php/conf.d/zz-zdt-proof.ini

cleanup() {
    docker exec "$PHP_CONTAINER" rm -f "$INI"
    release_maintenance "$OLD"
    flip "$ORIGINAL"
    reload_php
    rm -f "$LAST_BODY"
}
trap cleanup EXIT

echo "current $ORIGINAL renders version $V_CUR"
echo "other   $OLD renders version $V_OLD"
echo "php-fpm workers: $(docker exec "$PHP_CONTAINER" sh -c "grep -rh '^pm' /usr/local/etc/php-fpm.d/ | tr '\n' ' '")"
hold_maintenance "$OLD"

# $1 label, $2 falsifier id.
run_setting() {
    local label="$1" id="$2" seen
    step "$label: baseline on the current release"
    flip "$ORIGINAL"; reload_php; flush_cache
    seen=$(marker "$REQUESTS"); echo "seen: $seen"
    [[ $seen == "$V_CUR×$REQUESTS " ]] || fail "$id baseline: expected only $V_CUR, saw $seen"

    step "$label: flip to the other release, no reload"
    flip "$OLD"; flush_cache
    sleep 3
    seen=$(marker "$REQUESTS"); echo "seen: $seen" | tee -a "$OUT/$id-no-reload.txt"
    if [[ $seen == *"$V_CUR×"* ]]; then
        pass "$id negative control: without a reload the previous release still serves ($seen)"
    else
        note "$id without a reload the new release served at once ($seen): the reload is not what makes the flip work here"
    fi

    step "$label: reload"
    reload_php; flush_cache
    seen=$(marker "$REQUESTS"); echo "seen: $seen" | tee -a "$OUT/$id-reload.txt"
    if [[ $seen == "$V_OLD×$REQUESTS " ]]; then
        pass "$id after the reload every request renders the flipped-to release"
    else
        fail "$id after the reload requests still render: $seen"
    fi

    step "$label: flip back, reload"
    flip "$ORIGINAL"; reload_php; flush_cache
    seen=$(marker "$REQUESTS"); echo "seen: $seen"
    if [[ $seen == "$V_CUR×$REQUESTS " ]]; then
        pass "$id flipping back and reloading returns every request to the original release"
    else
        fail "$id after flipping back: $seen"
    fi
}

step "Settings as the site has them"
docker exec "$PHP_CONTAINER" php -i | grep -E '^(opcache.validate_timestamps|realpath_cache_ttl) '
run_setting "validate_timestamps=on" F13a

step "Production setting: opcache.validate_timestamps=0"
docker exec "$PHP_CONTAINER" sh -c "printf 'opcache.validate_timestamps=0\n' > '$INI'"
reload_php
docker exec "$PHP_CONTAINER" php -i | grep -E '^opcache.validate_timestamps '
run_setting "validate_timestamps=off" F13b

step "Restoring"
cleanup
trap - EXIT
[[ $(current_release) == "$ORIGINAL" ]] && note "magento_current restored to $ORIGINAL"
finish
