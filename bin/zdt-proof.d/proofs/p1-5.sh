#!/usr/bin/env bash
# summary: a patch_list row written out of band marks a data patch applied
#
# P1-5. Adds a data patch that inserts a marker row, marks it applied through
# PatchHistory::fixPatch() before it has ever run, and watches whether
# setup:db:status and setup:upgrade believe the mark. Then removes the mark and
# watches the patch run, so the row is shown to be what they actually read.
#
# Falsifiers:
#   F5a  with the row written, setup:db:status reports the patch pending, or
#        setup:upgrade runs it
#   F5b  with the row removed, setup:upgrade does not run it
#
# Changes the store: adds the patch, writes and removes a patch_list row, runs
# setup:upgrade twice, and restores snapshot 'fixture' when it finishes.

# shellcheck source=/dev/null  # ZDT_PROOF_DIR is set by bin/zdt-proof at run time
source "$ZDT_PROOF_DIR/lib.sh"

OUT=$(outdir p1-5)
PATCH='Kingletas\ZdtProof\Setup\Patch\Data\ZdtMarkerPatch'

stage
ensure_fixture
reset_fixture

markers() { sql "SELECT COUNT(*) FROM zdt_proof_item WHERE sku = 'patch-applied'" | tail -1; }
history_rows() { sql "SELECT COUNT(*) FROM patch_list WHERE patch_name = '${PATCH//\\/\\\\}'" | tail -1; }
db_status() { { magento setup:db:status 2>&1 || true; } | tr '\n' ' '; }

step "Control: the patch on disk and unmarked is pending"
fixture_state patch-marker
magento cache:flush >/dev/null
status=$(db_status)
echo "status: $status"
if grep -q "Data patches are not up to date" <<<"$status"; then
    pass "control: setup:db:status sees the new patch as pending"
else
    fail "control: setup:db:status does not see the new patch ($status)"
fi

step "F5a: mark it applied out of band"
mphp local.d/zdt-proof/php/p1-5-patch.php mark
echo "patch_list rows: $(history_rows)"
status=$(db_status)
echo "status: $status"
if grep -q "All modules are up to date" <<<"$status"; then
    pass "F5a setup:db:status believes the mark"
else
    fail "F5a setup:db:status still reports: $status"
fi
magento setup:upgrade --keep-generated >"$OUT/upgrade-marked.out" 2>&1 || fail "setup:upgrade failed with the patch marked"
echo "marker rows after setup:upgrade: $(markers)"
if [[ $(markers) == 0 ]]; then
    pass "F5a setup:upgrade does not run a marked patch"
else
    fail "F5a setup:upgrade ran the marked patch anyway"
fi

step "F5b: remove the mark, and the patch runs"
mphp local.d/zdt-proof/php/p1-5-patch.php unmark
status=$(db_status)
echo "status: $status"
if grep -q "Data patches are not up to date" <<<"$status"; then
    pass "F5b with the row gone the patch is pending again"
else
    fail "F5b with the row gone status says: $status"
fi
magento setup:upgrade --keep-generated >"$OUT/upgrade-unmarked.out" 2>&1 || fail "setup:upgrade failed with the mark removed"
echo "marker rows after setup:upgrade: $(markers)  patch_list rows: $(history_rows)"
if [[ $(markers) == 1 ]]; then
    pass "F5b setup:upgrade runs the patch once the row is gone, and records it again"
else
    fail "F5b the patch did not run after its row was removed"
fi

step "Restoring snapshot 'fixture'"
reset_fixture
finish
