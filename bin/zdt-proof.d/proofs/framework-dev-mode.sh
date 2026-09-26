#!/usr/bin/env bash
# summary: run P0-1, P0-2, P1-4 and P1-5 on a production-mode store without compiling, then put it back
#
# A production-mode store runs from compiled DI in generated/, so a fixture
# module is invisible to it until setup:di:compile runs, which takes ten to
# twenty minutes and most of the machine. Instead this copies generated/ aside,
# removes the compiled DI in generated/metadata,
# sets MAGE_MODE to developer in env.php, runs the four proofs, and whatever
# they report puts back the original generated/, env.php and config.php byte
# for byte, removes the fixture module, restores the snapshot named by
# ZDT_RESTORE_SNAPSHOT, and checks pub/static against a fingerprint taken
# before anything changed.
#
# Usage:
#   ZDT_SITE=acme bin/zdt-proof framework-dev-mode
#
# Environment overrides:
#   ZDT_RESTORE_SNAPSHOT  snapshot taken before any change (default before-zdt);
#                         the run refuses to start without it
#   ZDT_PROOFS            which proofs to run (default "p0-1 p0-2 p1-4 p1-5")

# shellcheck source=/dev/null  # ZDT_PROOF_DIR is set by bin/zdt-proof at run time
source "$ZDT_PROOF_DIR/lib.sh"

SNAPSHOT="${ZDT_RESTORE_SNAPSHOT:-before-zdt}"
PROOFS="${ZDT_PROOFS-p0-1 p0-2 p1-4 p1-5}"
HELD="$HOST_ROOT/local.d/zdt-proof/held"
ENV_PHP="$HOST_ROOT/app/etc/env.php"
CONFIG_PHP="$HOST_ROOT/app/etc/config.php"

snapshots=$(cd "$KAPELOS_HOME" && kapelos snapshot)
grep -q "^  $SNAPSHOT " <<<"$snapshots" || { echo "framework-dev-mode: no snapshot '$SNAPSHOT' to restore afterwards; take one first" >&2; exit 2; }
[[ ! -e $HELD/generated ]] || { echo "framework-dev-mode: $HELD/generated exists, so a previous run did not put the store back; restore it by hand first" >&2; exit 2; }

static_fingerprint() { (cd "$HOST_ROOT/pub/static" && find . -type f -printf '%p %s\n' | sort | md5sum | cut -d' ' -f1); }

mkdir -p "$HELD"
# One run at a time: a second run's cleanup would put back files the first run
# is still using, and delete the copies the first run restores from.
exec 9>"$HOST_ROOT/local.d/zdt-proof/run.lock"
flock -n 9 || { echo "framework-dev-mode: another run holds $HOST_ROOT/local.d/zdt-proof/run.lock" >&2; exit 2; }
cp -a "$ENV_PHP" "$HELD/env.php"
cp -a "$CONFIG_PHP" "$HELD/config.php"
static_fingerprint >"$HELD/static.md5"
# The optimised Composer classmap names files in generated/code, so that tree
# stays; only the compiled DI in generated/metadata goes, which is what makes
# Magento wire objects the developer way. The copy is what gets put back.
cp -a "$HOST_ROOT/generated" "$HELD/generated"
rm -rf "$HOST_ROOT/generated/metadata"

# shellcheck disable=SC2317,SC2329  # run by the EXIT trap; shellcheck before 0.10 calls it unreachable
cleanup() {
    # Every step runs whatever the one before it did, and says so if it fails.
    set +e
    step "Putting the store back"
    rm -rf "$HOST_ROOT/app/code/Kingletas/ZdtProof"
    rmdir "$HOST_ROOT/app/code/Kingletas" 2>/dev/null
    if [[ -d $HELD/generated ]]; then
        rm -rf "$HOST_ROOT/generated" && mv "$HELD/generated" "$HOST_ROOT/generated" || echo "framework-dev-mode: putting generated/ back FAILED; the copy is in $HELD/generated" >&2
    else
        echo "framework-dev-mode: no held copy of generated/ to put back" >&2
    fi
    cp -a "$HELD/env.php" "$ENV_PHP" || echo "framework-dev-mode: restoring env.php FAILED" >&2
    cp -a "$HELD/config.php" "$CONFIG_PHP" || echo "framework-dev-mode: restoring config.php FAILED" >&2
    (cd "$KAPELOS_HOME" && kapelos snapshot delete fixture -y >/dev/null 2>&1)
    (restore_snapshot "$SNAPSHOT") || echo "framework-dev-mode: restoring snapshot $SNAPSHOT FAILED; restore it by hand" >&2
    docker exec "$PHP_CONTAINER" sh -c 'kill -USR2 1' 2>/dev/null
    magento cache:flush >/dev/null 2>&1 || echo "framework-dev-mode: cache:flush failed" >&2
    echo "mode: $(magento deploy:mode:show 2>&1 | head -1)"
    [[ $(static_fingerprint) == "$(cat "$HELD/static.md5" 2>/dev/null)" ]] && echo "pub/static: unchanged" || echo "framework-dev-mode: pub/static differs from before the run" >&2
    rm -f "$HELD/env.php" "$HELD/config.php" "$HELD/static.md5"
    rm -f "$LAST_BODY"
}

trap cleanup EXIT

# shellcheck disable=SC2016  # PHP source: PHP expands these, not the shell
mphp -r '
    $e = require $argv[1];
    $e["MAGE_MODE"] = "developer";
    file_put_contents($argv[1], "<?php\nreturn " . var_export($e, true) . ";\n");
' app/etc/env.php
settle
flushed=$(magento cache:flush 2>&1) || { echo "framework-dev-mode: cache:flush failed in developer mode:" >&2; tail -15 <<<"$flushed" >&2; exit 1; }
echo "mode for the run: $(magento deploy:mode:show 2>&1 | head -1)"

status=0
for proof in $PROOFS; do
    step "Running $proof in developer mode"
    bash "$HERE/proofs/$proof.sh" || status=1
done
exit $status
