#!/usr/bin/env bash
# summary: a substituted DbSchemaWriterInterface emits exactly the stock SQL
#
# P1-4. No writer of ours exists yet, so this proves the seam rather than the
# tool: a preference for DbSchemaWriterInterface that records every statement
# and then delegates to the stock writer must reach OperationsExecutor and must
# change nothing about the SQL, in dry-run mode and when it really runs.
#
# Falsifiers:
#   F4a  a module's preference is not the writer OperationsExecutor receives
#   F4b  the pass-through writer's SQL differs from the stock writer's for the
#        same change. Negative control: a writer that adds one statement must
#        be caught by the same comparison
#
# The real-run comparison reads MariaDB's general query log, switched on for
# the length of one setup:upgrade and off again straight after.
#
# Changes the store: adds a column through setup:upgrade twice, toggles the
# server's general log, and restores snapshot 'fixture' between runs and at
# the end.

# shellcheck source=/dev/null  # ZDT_PROOF_DIR is set by bin/zdt-proof at run time
source "$ZDT_PROOF_DIR/lib.sh"

OUT=$(outdir p1-4)
DRYLOG="$HOST_ROOT/var/log/dry-run-installation.log"
RECORDED="$HOST_ROOT/var/zdt-recorded.sql"

stage
ensure_fixture

dry_run() {
    rm -f "$DRYLOG" "$RECORDED"
    docker exec -i "${EXEC_USER_ARGS[@]}" -w "$ZDT_ROOT" -e ZDT_WRITER_MUTATE="${MUTATE:-}" "$PHP_CONTAINER" \
        php -d memory_limit=-1 bin/magento setup:upgrade --dry-run=1 --keep-generated >/dev/null 2>&1 || true
    cp "$DRYLOG" "$1" 2>/dev/null || : >"$1"
}

# Every DDL statement the server received during one real setup:upgrade.
real_run() {
    sql "TRUNCATE mysql.general_log; SET GLOBAL log_output='TABLE'; SET GLOBAL general_log=ON;"
    magento setup:upgrade --keep-generated >/dev/null 2>&1 || fail "setup:upgrade failed during a real run"
    sql "SET GLOBAL general_log=OFF;"
    sql "SELECT argument FROM mysql.general_log WHERE command_type='Query' AND (argument LIKE 'ALTER TABLE%' OR argument LIKE 'CREATE TABLE%' OR argument LIKE 'DROP TABLE%') ORDER BY event_time" |
        tail -n +2 | sed 's/[[:space:]]\+/ /g' >"$1"
}

same() { cmp -s "$1" "$2"; }

# Indexers run inside setup:upgrade and create and drop tables with random
# suffixes, so real runs are compared with those masked. The raw files are kept.
# shellcheck disable=SC2016  # PHP source: PHP expands these, not the shell
mask_random() { sed -E 's/__temp[0-9a-f]+/__temp/g; s/(`?[a-z_]+)[0-9a-f]{8}`/\1<random>`/g' "$1"; }
same_masked() {
    cmp -s <(mask_random "$1") <(mask_random "$2")
}

step "Stock writer: dry run and real run of one added column"
reset_fixture
fixture_state add-column
dry_run "$OUT/stock-dry.sql"
real_run "$OUT/stock-real.sql"
echo "stock dry: $(tr '\n' ' ' <"$OUT/stock-dry.sql")"
echo "stock real: $(tr '\n' ' ' <"$OUT/stock-real.sql")"
[[ -s $OUT/stock-dry.sql && -s $OUT/stock-real.sql ]] || fail "the stock runs produced no SQL, so there is nothing to compare"

step "F4a: the preference reaches OperationsExecutor"
reset_fixture
fixture_state add-column recording-writer
magento cache:flush >/dev/null
magento dev:di:info 'Magento\Framework\Setup\Declaration\Schema\Db\DbSchemaWriterInterface' >"$OUT/di-info.txt" 2>&1 || true
grep -m1 'Preference' "$OUT/di-info.txt" || true
dry_run "$OUT/recording-dry.sql"
if grep -q 'RecordingSchemaWriter' "$OUT/di-info.txt"; then
    pass "F4a dev:di:info resolves the interface to the recording writer"
else
    fail "F4a dev:di:info does not show the recording writer"
fi
if [[ -s $RECORDED ]]; then
    pass "F4a OperationsExecutor called the recording writer during setup:upgrade"
else
    fail "F4a the recording writer was never called"
fi
cp "$RECORDED" "$OUT/recorded-dry.txt" 2>/dev/null || true

step "F4b: same SQL through the recording writer"
if same "$OUT/stock-dry.sql" "$OUT/recording-dry.sql"; then
    pass "F4b dry run: byte-identical to stock"
else
    fail "F4b dry run differs from stock"
fi
real_run "$OUT/recording-real.sql"
echo "recording real: $(tr '\n' ' ' <"$OUT/recording-real.sql")"
echo "real-run statements: stock=$(wc -l <"$OUT/stock-real.sql") recording=$(wc -l <"$OUT/recording-real.sql")"
if same "$OUT/stock-real.sql" "$OUT/recording-real.sql"; then
    note "F4b real runs identical byte for byte"
else
    note "F4b real runs differ before masking temp-table suffixes"
fi
if same_masked "$OUT/stock-real.sql" "$OUT/recording-real.sql"; then
    pass "F4b real run: the server received identical DDL, temp-table suffixes masked"
else
    fail "F4b real run: the server received different DDL even with temp-table suffixes masked"
fi

step "F4b negative control: a writer that adds one statement is caught"
reset_fixture
fixture_state add-column recording-writer
magento cache:flush >/dev/null
MUTATE=1 dry_run "$OUT/mutated-dry.sql"
if same "$OUT/stock-dry.sql" "$OUT/mutated-dry.sql"; then
    fail "F4b negative control: the comparison missed an added statement"
else
    pass "F4b negative control: the comparison catches an added statement"
fi

step "Restoring snapshot 'fixture'"
reset_fixture
finish
