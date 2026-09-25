#!/usr/bin/env bash
# summary: static asset URLs from before a flip stop resolving after it
#
# P1-2. On a site laid out as releases, renders the storefront from an older
# release, collects the static URLs the page carries, flips to the current
# release and requests the same URLs again.
#
# Magento's nginx sample rewrites /static/version<N>/x to /static/x before
# looking for the file, so the version number alone cannot make a URL fail.
# The proof separates the two things that could: an old version number, and a
# file the new release does not have. A sentinel file placed only in the old
# release's pub/static stands for the second.
#
# Falsifiers:
#   F12a  an asset URL carrying the old version still answers 200 after the flip
#   F12b  with the file present where the new release serves from, the old URL
#         does not answer 200
#
# Negative control: every collected URL, and the sentinel, answers 200 before
# the flip.
#
# Changes the site: flips magento_current, reloads php-fpm, writes and removes
# one sentinel file in each of two releases, and flips back before finishing.
#
# Environment overrides:
#   ZDT_OLD_RELEASE  the release to render from first (default: the newest
#                    release other than the current one)

# shellcheck source=/dev/null  # ZDT_PROOF_DIR is set by bin/zdt-proof at run time
source "$ZDT_PROOF_DIR/lib.sh"
# shellcheck source=/dev/null  # ZDT_PROOF_DIR is set by bin/zdt-proof at run time
source "$ZDT_PROOF_DIR/release.sh"

OUT=$(outdir p1-2)
ORIGINAL=$(current_release)
OLD="${ZDT_OLD_RELEASE:-$(docker exec "$PHP_CONTAINER" sh -c "ls -d $RELEASES/*/ | sed 's:/\$::' | grep -v '$ORIGINAL' | sort | tail -1")}"
SENTINEL_PATH="pub/static/zdt-sentinel-only-in-old.css"

cleanup() {
    docker exec "$PHP_CONTAINER" rm -f "$OLD/$SENTINEL_PATH" "$ORIGINAL/$SENTINEL_PATH"
    release_maintenance "$OLD"
    flip "$ORIGINAL"
    reload_php
    rm -f "$LAST_BODY"
}
trap cleanup EXIT

step "Releases"
echo "current: $ORIGINAL (version $(static_version "$ORIGINAL"))"
echo "old:     $OLD (version $(static_version "$OLD"))"

step "How the two releases' pub/static differ"
docker exec "$PHP_CONTAINER" sh -c "cd '$OLD/pub/static' && find . -type f ! -path './_cache/*' | sort" >"$OUT/old-files.txt"
docker exec "$PHP_CONTAINER" sh -c "cd '$ORIGINAL/pub/static' && find . -type f ! -path './_cache/*' | sort" >"$OUT/current-files.txt"
only_old=$(comm -23 "$OUT/old-files.txt" "$OUT/current-files.txt" | tee "$OUT/only-in-old.txt" | wc -l)
echo "files: old=$(wc -l <"$OUT/old-files.txt") current=$(wc -l <"$OUT/current-files.txt") only_in_old=$only_old"
echo "pub/static/_cache: $(docker exec "$PHP_CONTAINER" sh -c "readlink '$ORIGINAL/pub/static/_cache' || echo 'not a link'")"

step "Rendering from the old release"
docker exec "$PHP_CONTAINER" test -e "$OLD/var/.maintenance.flag" && note "the old release still carries the maintenance flag its successor's deploy set; held aside for this proof"
hold_maintenance "$OLD"
flip "$OLD"
reload_php
flush_cache
docker exec -u www-data "$PHP_CONTAINER" sh -c "echo '/* zdt */' > '$OLD/$SENTINEL_PATH'"
http "$(bust "$BASE_URL/")" >/dev/null
{ grep -o "$BASE_URL/static/version[0-9]*/[^\"' )]*\.\(css\|js\)" "$LAST_BODY" || true; } | sort -u | head -8 >"$OUT/urls.txt"
old_version=$(static_version "$OLD")
echo "$BASE_URL/static/version$old_version/zdt-sentinel-only-in-old.css" >>"$OUT/urls.txt"
cat "$OUT/urls.txt"
if grep -q "version$old_version/" "$OUT/urls.txt"; then
    pass "control: the page rendered from the old release carries version $old_version"
else
    fail "control: the page does not carry the old release's version"
fi

before_bad=0
while read -r url; do
    code=$(http "$url")
    [[ $code == 200 ]] || { before_bad=$((before_bad + 1)); echo "before flip $code $url"; }
done <"$OUT/urls.txt"
if [[ $before_bad == 0 ]]; then
    pass "control: all $(wc -l <"$OUT/urls.txt") URLs answer 200 before the flip"
else
    fail "control: $before_bad URLs fail before the flip"
fi

step "F12a: flip to the current release, request the same URLs"
flip "$ORIGINAL"
reload_php
flush_cache
assets_ok=0; assets_total=0
while read -r url; do
    code=$(http "$url")
    echo "after flip $code $url"
    if [[ $url == *zdt-sentinel* ]]; then
        sentinel_after=$code
    else
        assets_total=$((assets_total + 1))
        [[ $code == 200 ]] && assets_ok=$((assets_ok + 1))
    fi
done <"$OUT/urls.txt"
if [[ $assets_ok == "$assets_total" ]]; then
    fail "F12a every asset URL carrying the old version still answers 200 after the flip ($assets_ok of $assets_total): the version number alone does not break them"
else
    pass "F12a $((assets_total - assets_ok)) of $assets_total old-version asset URLs fail after the flip"
fi
if [[ $sentinel_after == 404 ]]; then
    pass "F12a a file only the old release had answers 404 after the flip"
else
    fail "F12a the old-only file answers $sentinel_after after the flip"
fi

step "F12b: the file present where the new release serves from"
docker exec -u www-data "$PHP_CONTAINER" sh -c "echo '/* zdt */' > '$ORIGINAL/$SENTINEL_PATH'"
code=$(http "$(tail -1 "$OUT/urls.txt")")
if [[ $code == 200 ]]; then
    pass "F12b with the file present in the new release, the old-version URL answers 200"
else
    fail "F12b the old-version URL answers $code with the file present"
fi

cleanup
trap - EXIT
[[ $(current_release) == "$ORIGINAL" ]] && note "magento_current restored to $ORIGINAL"
finish
