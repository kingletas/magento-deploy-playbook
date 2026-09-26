#!/usr/bin/env bash
# summary: run P0-1, P0-2, P1-4 and P1-5 on a copy of a live release, then put the site back
#
# For a site laid out as releases, where the framework proofs must not touch
# the live release. Copies the current release to releases/zdt_fw, points
# magento_current at it, runs the four proofs against it as the web server's
# user, and whatever they report, flips back, reloads php-fpm, deletes the
# copy and the proofs' 'fixture' snapshot, and restores the snapshot named by
# ZDT_RESTORE_SNAPSHOT.
#
# Usage:
#   ZDT_SITE=acme-releases bin/zdt-proof framework-on-release
#
# Environment overrides:
#   ZDT_RESTORE_SNAPSHOT  snapshot taken before any change (default before-zdt);
#                         the run refuses to start without it
#   ZDT_EXEC_USER         the web server's user (default www-data)
#   ZDT_PROOFS            which proofs to run (default "p0-1 p0-2 p1-4 p1-5")

# shellcheck source=/dev/null  # ZDT_PROOF_DIR is set by bin/zdt-proof at run time
source "$ZDT_PROOF_DIR/lib.sh"
# shellcheck source=/dev/null  # ZDT_PROOF_DIR is set by bin/zdt-proof at run time
source "$ZDT_PROOF_DIR/release.sh"

SNAPSHOT="${ZDT_RESTORE_SNAPSHOT:-before-zdt}"
EXEC_USER="${ZDT_EXEC_USER:-www-data}"
PROOFS="${ZDT_PROOFS-p0-1 p0-2 p1-4 p1-5}"
ORIGINAL=$(current_release)
COPY="$RELEASES/zdt_fw"

snapshots=$(cd "$KAPELOS_HOME" && kapelos snapshot)
grep -q "^  $SNAPSHOT " <<<"$snapshots" || { echo "framework-on-release: no snapshot '$SNAPSHOT' to restore afterwards; take one first" >&2; exit 2; }
[[ $ORIGINAL != "$COPY" ]] || { echo "framework-on-release: magento_current already points at the copy; a previous run did not clean up" >&2; exit 2; }

# shellcheck disable=SC2317,SC2329  # run by the EXIT trap; shellcheck before 0.10 calls it unreachable
cleanup() {
    step "Putting the site back"
    flip "$ORIGINAL"
    reload_php
    docker exec "$PHP_CONTAINER" rm -rf "$COPY"
    (cd "$KAPELOS_HOME" && kapelos snapshot delete fixture -y >/dev/null 2>&1) || true
    (restore_snapshot "$SNAPSHOT") || echo "framework-on-release: restoring snapshot $SNAPSHOT FAILED; restore it by hand" >&2
    flush_cache || echo "framework-on-release: cache:flush from $ORIGINAL failed" >&2
    [[ $(current_release) == "$ORIGINAL" ]] && echo "magento_current: $ORIGINAL"
    rm -f "$LAST_BODY"
}
trap cleanup EXIT

step "Copying $ORIGINAL to $COPY"
docker exec "$PHP_CONTAINER" sh -c "rm -rf '$COPY' && cp -a '$ORIGINAL' '$COPY' && chmod -R a+rwX '$COPY/app' '$COPY/var' '$COPY/generated' '$COPY/pub/static' && mkdir -p '$COPY/local.d' && chmod 0777 '$COPY/local.d'"
flip "$COPY"
reload_php

status=0
for proof in $PROOFS; do
    step "Running $proof on $COPY as $EXEC_USER"
    ZDT_ROOT="$COPY" ZDT_EXEC_USER="$EXEC_USER" bash "$HERE/proofs/$proof.sh" || status=1
    mkdir -p "$MAGENTO_SRC/local.d/zdt-proof/out"
    rm -rf "$MAGENTO_SRC/local.d/zdt-proof/out/fw-$proof"
    cp -a "$MAGENTO_SRC/releases/zdt_fw/local.d/zdt-proof/out/$proof" "$MAGENTO_SRC/local.d/zdt-proof/out/fw-$proof" || echo "framework-on-release: could not keep the $proof artefacts" >&2
done
exit $status
