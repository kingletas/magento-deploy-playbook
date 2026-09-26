#!/usr/bin/env bash
# summary: two revisions of db_schema.xml diff into the DDL the release needs
#
# P0-1. Builds Magento's declared Schema from XML, diffs it against itself and
# against an earlier revision, and compares the SQL that diff renders with what
# `setup:upgrade --dry-run=1` writes for the same change.
#
# Falsifiers:
#   F1a  building a declared Schema needs a live database connection
#   F1b  a schema diffed against a copy of itself returns changes (with a
#        negative control proving the diff can see a change at all)
#   F1c  neither the plain XML array nor serialize() carries an old revision
#        into another process intact
#   F1d  the two-revision SQL differs from setup:upgrade --dry-run=1
#   F1e  recorded, not a falsifier: whether rendering SQL needs a connection
#
# Changes the store: installs the fixture module, adds a column to its XML for
# the dry run, and restores snapshot 'fixture' when it finishes.
#
# Environment overrides:
#   ZDT_SQL_VERSION_FIXED  the version string the no-database run pretends the
#                          server is (default "11.4.", MariaDB 11.4). It always
#                          answers as MariaDB, so set it to your MariaDB
#                          server's major.minor and a trailing dot

# shellcheck source=/dev/null  # ZDT_PROOF_DIR is set by bin/zdt-proof at run time
source "$ZDT_PROOF_DIR/lib.sh"

FIXED_VERSION="${ZDT_SQL_VERSION_FIXED:-11.4.}"
OUT=$(outdir p0-1)
CONTAINER_OUT="$ZDT_ROOT/local.d/zdt-proof/out/p0-1"
SCRIPT=local.d/zdt-proof/php/p0-1-schema-diff.php

stage
ensure_fixture
fixture_state
magento cache:flush >/dev/null

# A copy of app/etc whose database host cannot resolve and which has no Redis
# cache or session, standing in for a CI job with no services at all.
step "Writing an app/etc with no reachable database"
mkdir -p "$OUT/etc-nodb"
rsync -a --exclude env.php "$HOST_ROOT/app/etc/" "$OUT/etc-nodb/"
# shellcheck disable=SC2016  # PHP source: PHP expands these, not the shell
mphp -r '
    $env = require "app/etc/env.php";
    $env["db"]["connection"]["default"]["host"] = "zdt-unreachable.invalid";
    unset($env["cache"], $env["session"], $env["queue"]);
    file_put_contents($argv[1], "<?php\nreturn " . var_export($env, true) . ";\n");
' "$CONTAINER_OUT/etc-nodb/env.php"

step "F1a: build the declared schema, with a database, then with none"
with_db=$(mphp $SCRIPT probe)
echo "$with_db"
nodb=$(docker exec -i "${EXEC_USER_ARGS[@]}" -w "$ZDT_ROOT" -e ZDT_CONFIG_DIR="$CONTAINER_OUT/etc-nodb" "$PHP_CONTAINER" php -d memory_limit=-1 $SCRIPT probe || true)
echo "$nodb"
fixed=$(docker exec -i "${EXEC_USER_ARGS[@]}" -w "$ZDT_ROOT" -e ZDT_CONFIG_DIR="$CONTAINER_OUT/etc-nodb" -e ZDT_SQL_VERSION="$FIXED_VERSION" "$PHP_CONTAINER" php -d memory_limit=-1 $SCRIPT probe || true)
echo "$fixed"
if grep -q '^connections=default' <<<"$with_db"; then
    note "stock build opens the default connection"
fi
if grep -q '^error=' <<<"$nodb"; then
    note "stock build fails with no database: $(sed -n 's/^error=//p' <<<"$nodb")"
elif ! grep -q '^tables=' <<<"$nodb"; then
    fail "F1a the stock no-database run died before building anything, so it answered nothing"
fi
if grep -q '^tables=' <<<"$fixed" && grep -qx 'connections=' <<<"$fixed"; then
    pass "F1a with the server version supplied, the schema builds against an unresolvable host with no connection opened"
else
    fail "F1a the schema cannot be built without a database even with the version supplied"
fi
tables_db=$(sed -n 's/^tables=//p' <<<"$with_db")
tables_fixed=$(sed -n 's/^tables=//p' <<<"$fixed")
if [[ $tables_db == "$tables_fixed" ]]; then
    pass "F1a both builds have $tables_db tables"
else
    fail "F1a table counts differ: $tables_db with a database, $tables_fixed without"
fi

step "F1b: diff a schema against itself, and prove the diff can see a change"
self=$(mphp $SCRIPT self-diff)
echo "$self"
if [[ $(sed -n 's/^self_changes=//p' <<<"$self") == 0 ]]; then
    pass "F1b self-diff is empty"
else
    fail "F1b self-diff is not empty"
fi
if [[ $(sed -n 's/^control_changes=//p' <<<"$self") -ge 1 ]]; then
    pass "F1b negative control: one altered column registers"
else
    fail "F1b negative control: the diff did not see an altered column"
fi

step "F1c: carry the old revision into a second process"
rm -f "$OUT/tables.json" "$OUT/schema.ser"
mphp $SCRIPT dump "$CONTAINER_OUT" | tee "$OUT/dump.txt"
rt=$(mphp $SCRIPT roundtrip "$CONTAINER_OUT")
echo "$rt"
if [[ $(sed -n 's/^json_roundtrip_changes=//p' <<<"$rt") == 0 ]]; then
    pass "F1c the plain XML array round-trips through JSON with an empty diff"
else
    fail "F1c the JSON round trip does not diff empty"
fi
if grep -q '^serialize_roundtrip_changes=0$' <<<"$rt"; then
    pass "F1c serialize() round-trips the Schema object with an empty diff"
else
    note "serialize() route: $(grep -h "^serialize" "$OUT/dump.txt" - <<<"$rt" | tr '\n' ' ')"
fi

step "F1d: ground truth from setup:upgrade --dry-run=1, before and after adding a column"
rm -f "$HOST_ROOT/var/log/dry-run-installation.log"
magento setup:upgrade --dry-run=1 --keep-generated >"$OUT/dry-run-baseline.out" 2>&1 || note "baseline dry run exited non-zero, see dry-run-baseline.out"
cp "$HOST_ROOT/var/log/dry-run-installation.log" "$OUT/dry-run-baseline.sql" 2>/dev/null || : >"$OUT/dry-run-baseline.sql"

fixture_state add-column
magento cache:flush >/dev/null
rm -f "$HOST_ROOT/var/log/dry-run-installation.log"
magento setup:upgrade --dry-run=1 --keep-generated >"$OUT/dry-run.out" 2>&1 || note "dry run exited non-zero, see dry-run.out"
cp "$HOST_ROOT/var/log/dry-run-installation.log" "$OUT/dry-run.sql" 2>/dev/null || : >"$OUT/dry-run.sql"

step "F1d: the two-revision diff, old XML against new XML"
two=$(mphp $SCRIPT diff "$CONTAINER_OUT" || true)
echo "$two" | tee "$OUT/diff.txt"

compare=$(python3 - "$OUT" <<'PY'
import re, sys, pathlib
out = pathlib.Path(sys.argv[1])
def statements(name):
    text = (out / name).read_text() if (out / name).exists() else ""
    return [re.sub(r"\s+", " ", s).strip() for s in text.split("\n\n") if s.strip()]
base, dry, two = statements("dry-run-baseline.sql"), statements("dry-run.sql"), statements("two-revision.sql")
release = [s for s in dry if s not in base]
print(f"baseline={len(base)} dry_run={len(dry)} dry_run_minus_baseline={len(release)} two_revision={len(two)}")
print("match=" + ("yes" if release == two and two else "no"))
for s in release: print("dry  " + s)
for s in two: print("two  " + s)
PY
)
echo "$compare" | tee "$OUT/compare.txt"
if grep -q '^match=yes' <<<"$compare"; then
    pass "F1d the two-revision SQL is the dry run's SQL, statement for statement"
else
    fail "F1d the two-revision SQL differs from the dry run"
fi
if [[ $(sed -n 's/^baseline=\([0-9]*\).*/\1/p' <<<"$compare") == 0 ]]; then
    pass "F1d a fresh install dry-runs to nothing, so the comparison has no noise"
else
    note "a fresh install already dry-runs to statements; they were subtracted"
fi

step "F1e: rendering SQL from the diff, with and without a database"
grep '^connections_' <<<"$two" || true
nodb_sql=$(docker exec -i "${EXEC_USER_ARGS[@]}" -w "$ZDT_ROOT" -e ZDT_CONFIG_DIR="$CONTAINER_OUT/etc-nodb" -e ZDT_SQL_VERSION="$FIXED_VERSION" "$PHP_CONTAINER" php -d memory_limit=-1 $SCRIPT diff "$CONTAINER_OUT" || true)
echo "$nodb_sql" | tee "$OUT/diff-nodb.txt"
if grep -q '^error=' <<<"$nodb_sql"; then
    note "F1e the stock OperationsExecutor cannot render SQL without a connection: $(sed -n 's/^error=//p' <<<"$nodb_sql")"
elif grep -q '^connections_after_sql=' <<<"$nodb_sql"; then
    note "F1e SQL rendered with no database; connections opened: $(sed -n 's/^connections_after_sql=//p' <<<"$nodb_sql")"
else
    fail "F1e the no-database run did not get as far as a diff, so it answered nothing; see diff-nodb.txt"
fi

# The no-database app/etc copy still holds the store's credentials.
rm -rf "$OUT/etc-nodb"

step "Restoring snapshot 'fixture'"
reset_fixture
finish
