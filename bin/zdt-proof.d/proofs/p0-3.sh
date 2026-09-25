#!/usr/bin/env bash
# summary: a narrowing ModifyColumn is non-destructive to Magento and still breaks data
#
# P0-3. Three column changes over rows that violate them: a varchar narrowed
# below the data, an int narrowed to smallint over a value too big for it, and
# NOT NULL added over a null. Each runs three ways:
#
#   magento   edit the fixture XML and run setup:upgrade, so the DDL goes
#             through Magento's own connection (which sets SQL_MODE='')
#   strict    the same ALTER from a client in the server's default SQL mode
#   empty     the same ALTER from a client after SET sql_mode='', which is what
#             isolates Magento's connection setting as the cause
#
# The client runs repeat on MySQL 8.0, from the host's own mysqld binary,
# started as this user in a throwaway directory under /tmp and removed at the
# end. AppArmor refuses that binary a data directory under $HOME.
#
# Falsifiers:
#   F3a  ModifyColumn::isOperationDestructive() is true at runtime
#   F3b  a violating change neither errors nor changes the data
#
# Each case is classified: fails at DDL time, corrupts silently, or no effect.
#
# Changes the store: seeds the fixture table, runs setup:upgrade three times,
# and restores snapshot 'fixture' between cases and at the end.
#
# Environment overrides:
#   ZDT_MYSQLD   the MySQL server binary (default /usr/sbin/mysqld); set it
#                empty to skip the MySQL 8.0 leg

# shellcheck source=/dev/null  # ZDT_PROOF_DIR is set by bin/zdt-proof at run time
source "$ZDT_PROOF_DIR/lib.sh"

OUT=$(outdir p0-3)
MYSQLD="${ZDT_MYSQLD-/usr/sbin/mysqld}"

stage
ensure_fixture

seed() {
    sql "DELETE FROM zdt_proof_item; INSERT INTO zdt_proof_item (sku, qty, note) VALUES ('long', 40000, 'this note is far longer than eight'), ('null', 1, NULL);"
}

table_rows() {
    sql "SELECT sku, qty, IFNULL(note, '<NULL>') AS note FROM zdt_proof_item ORDER BY sku" | tail -n +2 | tr '\t' ' ' | paste -sd'|'
}

step "F3a: how Magento classifies ModifyColumn at runtime"
mphp local.d/zdt-proof/php/p0-3-magento.php destructive | tee "$OUT/f3a.txt"
if grep -q '^modify_column_destructive=false' "$OUT/f3a.txt"; then
    pass "F3a ModifyColumn reports itself non-destructive"
else
    fail "F3a ModifyColumn reports itself destructive"
fi

declare -A VERDICT

for case in narrow-varchar narrow-int not-null; do
    step "$case through setup:upgrade"
    reset_fixture
    seed
    before=$(table_rows)
    fixture_state "$case"
    rm -f "$HOST_ROOT/var/log/dry-run-installation.log"
    magento setup:upgrade --dry-run=1 --keep-generated >/dev/null 2>&1 || true
    ddl=$(tr '\n' ' ' <"$HOST_ROOT/var/log/dry-run-installation.log" 2>/dev/null)
    echo "ddl: $ddl"
    if magento setup:upgrade --keep-generated >"$OUT/$case-upgrade.out" 2>&1; then
        after=$(table_rows)
        echo "before: $before"
        echo "after:  $after"
        if [[ $before == "$after" ]]; then
            VERDICT[$case/magento]="no effect"
        else
            VERDICT[$case/magento]="corrupts silently"
        fi
    else
        VERDICT[$case/magento]="fails at DDL time: $(grep -m1 -iE 'SQLSTATE|error' "$OUT/$case-upgrade.out" | cut -c1-160)"
    fi
    echo "verdict: ${VERDICT[$case/magento]}"
    if [[ $case == narrow-varchar && ${VERDICT[$case/magento]} == "corrupts silently" ]]; then
        step "narrow-varchar: a later write through Magento's connection"
        mphp local.d/zdt-proof/php/p0-3-magento.php write-long | tee "$OUT/narrow-varchar-write.txt"
    fi
done

reset_fixture

# The client-side statements for each case, as one script per case: create,
# seed, then the ALTER on its own line so its outcome can be read separately.
case_setup() {
    case "$1" in
        narrow-varchar) echo "DROP TABLE IF EXISTS zdt_p03; CREATE TABLE zdt_p03 (id INT PRIMARY KEY, note VARCHAR(255) NULL); INSERT INTO zdt_p03 VALUES (1, 'this note is far longer than eight'), (2, NULL);" ;;
        narrow-int) echo "DROP TABLE IF EXISTS zdt_p03; CREATE TABLE zdt_p03 (id INT PRIMARY KEY, qty INT NOT NULL); INSERT INTO zdt_p03 VALUES (1, 40000);" ;;
        not-null) echo "DROP TABLE IF EXISTS zdt_p03; CREATE TABLE zdt_p03 (id INT PRIMARY KEY, note VARCHAR(255) NULL); INSERT INTO zdt_p03 VALUES (1, 'kept'), (2, NULL);" ;;
    esac
}
case_alter() {
    case "$1" in
        narrow-varchar) echo "ALTER TABLE zdt_p03 MODIFY note VARCHAR(8) NULL;" ;;
        narrow-int) echo "ALTER TABLE zdt_p03 MODIFY qty SMALLINT NOT NULL;" ;;
        not-null) echo "ALTER TABLE zdt_p03 MODIFY note VARCHAR(255) NOT NULL;" ;;
    esac
}

# $1 engine label, $2 mode (strict|empty), $3 case, $4... the client command.
client_case() {
    local engine="$1" mode="$2" case="$3" before after result
    shift 3
    local mode_sql=""
    [[ $mode == empty ]] && mode_sql="SET SESSION sql_mode='';"
    "$@" <<<"$(case_setup "$case")" >/dev/null
    before=$("$@" <<<"SELECT * FROM zdt_p03 ORDER BY id;" | tail -n +2 | tr '\t' ' ' | paste -sd'|')
    if result=$("$@" <<<"$mode_sql $(case_alter "$case") SHOW WARNINGS;" 2>&1); then
        after=$("$@" <<<"SELECT * FROM zdt_p03 ORDER BY id;" | tail -n +2 | tr '\t' ' ' | paste -sd'|')
        if [[ $before == "$after" ]]; then
            VERDICT[$case/$engine-$mode]="no effect"
        else
            VERDICT[$case/$engine-$mode]="corrupts silently ($before -> $after)"
        fi
    else
        VERDICT[$case/$engine-$mode]="fails at DDL time: $(grep -m1 ERROR <<<"$result" | cut -c1-140)"
    fi
    printf '%-15s %-14s %-6s %s\n' "$case" "$engine" "$mode" "${VERDICT[$case/$engine-$mode]}"
}

step "The same ALTERs from a client, on MariaDB"
echo "server sql_mode: $(sql 'SELECT @@GLOBAL.sql_mode' | tail -1)"
for case in narrow-varchar narrow-int not-null; do
    for mode in strict empty; do
        client_case mariadb "$mode" "$case" sql
    done
done
sql "DROP TABLE IF EXISTS zdt_p03;"

MYSQL_DIR=""
stop_mysql() {
    if [[ -n $MYSQL_DIR && -f $MYSQL_DIR/pid ]]; then
        kill "$(cat "$MYSQL_DIR/pid")" 2>/dev/null || true
        for _ in $(seq 1 30); do [[ -S $MYSQL_DIR/sock ]] || break; sleep 1; done
    fi
    [[ -n $MYSQL_DIR ]] && rm -rf "$MYSQL_DIR"
    rm -f "$LAST_BODY"
}
trap stop_mysql EXIT

if [[ -n $MYSQLD && -x $MYSQLD ]]; then
    step "The same ALTERs on MySQL 8.0"
    MYSQL_DIR=$(mktemp -d /tmp/zdt-mysql8.XXXXXX)
    "$MYSQLD" --no-defaults --initialize-insecure --datadir="$MYSQL_DIR/data" --user="$(id -un)" >"$MYSQL_DIR/init.log" 2>&1
    "$MYSQLD" --no-defaults --datadir="$MYSQL_DIR/data" --socket="$MYSQL_DIR/sock" --pid-file="$MYSQL_DIR/pid" \
        --skip-networking --mysqlx=OFF --log-error="$MYSQL_DIR/error.log" --user="$(id -un)" &
    for _ in $(seq 1 60); do [[ -S $MYSQL_DIR/sock ]] && break; sleep 1; done
    if [[ -S $MYSQL_DIR/sock ]]; then
        my() { command mysql --no-defaults -uroot -S "$MYSQL_DIR/sock" -D zdt; }
        command mysql --no-defaults -uroot -S "$MYSQL_DIR/sock" -e "CREATE DATABASE zdt"
        echo "server: $(my <<<'SELECT VERSION(), @@GLOBAL.sql_mode' | tail -1)"
        for case in narrow-varchar narrow-int not-null; do
            for mode in strict empty; do
                client_case mysql8 "$mode" "$case" my
            done
        done
    else
        fail "MySQL 8.0 did not start; see $MYSQL_DIR/error.log"
        cp "$MYSQL_DIR/error.log" "$OUT/mysql8-error.log" 2>/dev/null || true
    fi
else
    note "MySQL 8.0 leg skipped: no server binary at ${MYSQLD:-<empty>}"
fi

step "Verdicts"
for key in $(printf '%s\n' "${!VERDICT[@]}" | sort); do
    printf '%-32s %s\n' "$key" "${VERDICT[$key]}"
done | tee "$OUT/verdicts.txt"

silent=0
for key in "${!VERDICT[@]}"; do
    [[ ${VERDICT[$key]} == "no effect" ]] && fail "F3b $key: a violating change had no effect"
    [[ ${VERDICT[$key]} == corrupts* ]] && silent=1
done
[[ $silent == 1 ]] && note "at least one path corrupts silently, so the CI gate's middle bucket cannot be automatic"
for case in narrow-varchar narrow-int not-null; do
    [[ ${VERDICT[$case/magento]} != "no effect" ]] && pass "F3b $case through Magento: ${VERDICT[$case/magento]}"
done

finish
