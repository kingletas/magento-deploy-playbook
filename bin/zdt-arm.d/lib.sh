#!/usr/bin/env bash
#
# Shared helpers for the fleet arms of issue #5. Sourced, never run.
#
# The arms run things on a lab fleet from the control machine: they reach the
# nodes over ssh, drive the migration end to end on the admin node, generate a
# fixed traffic mix against every node, and print one PASS or FAIL line per
# falsifier so the transcript of the run is the evidence.
#
# Secrets never travel in argv. A remote script that carries one is piped to
# bash on the node over stdin, and the transcript prints only its label with
# the value replaced by ***; redact() does that replacement wherever a secret
# would otherwise appear. An exit trap restores env.php from the dated backups
# on every path it can reach; print_restores leaves the commands that cover
# the paths it cannot (SIGKILL, a power cut).
#
# Exit codes, as everywhere in this family: 0 pass; 1 the run failed (a FAIL
# line); 2 the run never happened (missing settings, declined plan, refused
# gate, failed snapshot).

# shellcheck disable=SC2034  # set by bin/zdt-arm before dispatching
ARM_DIR="${ARM_DIR:?run arms through bin/zdt-arm, which sets ARM_DIR}"

WRITTEN=0
PLAN_ONLY=0
ASSUME_YES=0
FAILS=0
PASSES=0
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
ARM_NAME="$(basename "$0" .sh)"
OUT="${ZDT_RUN_DIR:-local.d/zdt-arm/$RUN_ID-$ARM_NAME}"

DEFAULT_RATE=2
DEFAULT_DURATION=120
MAX_RATE=20
MAX_DURATION=600
LAG_WAIT_LIMIT=300   # falsifier 1: lag back to zero within five minutes

SECRET_VALUES=()
declare -A ENV_BACKED_UP=()
ENV_BACKUP_HOSTS=()
SNAPSHOT=""

die() { echo "zdt-arm/$ARM_NAME: $*" >&2; exit 2; }

falsifier() {
    local verdict="$1"; shift
    if [[ $verdict == PASS ]]; then PASSES=$((PASSES + 1)); else FAILS=$((FAILS + 1)); fi
    printf '%s  %s\n' "$verdict" "$*"
}

# ------------------------------------------------------------------ settings

require_env() {
    # None of the hosts has a default, so a missing one stops the arm BY NAME
    # rather than aiming at a guess. Paths every lab here uses the same way
    # have defaults; addresses and credentials never do.
    local missing=() v
    for v in ZDT_WEB_HOSTS ZDT_NEW_NODE ZDT_ADMIN_NODE ZDT_LB_URL ZDT_NODE_URLS \
             ZDT_RELEASE_TARBALL ZDT_LABEL_NEW ZDT_LABEL_OLD \
             ZDT_ENV_PHP ZDT_DB_HOST ZDT_DB_USER ZDT_DB_PASSWORD ZDT_DB_NAME; do
        [[ -n ${!v:-} ]] || missing+=("$v")
    done
    [[ ${#missing[@]} -eq 0 ]] \
        || die "set these first: ${missing[*]} (see bin/zdt-arm --help)"
    IFS=',' read -r -a WEB_HOSTS <<< "$ZDT_WEB_HOSTS"
    [[ ${#WEB_HOSTS[@]} -ge 3 ]] \
        || die "issue #5 needs at least three web hosts; ZDT_WEB_HOSTS lists ${#WEB_HOSTS[@]}"
    [[ ",$ZDT_WEB_HOSTS," == *",$ZDT_NEW_NODE,"* ]] \
        || die "ZDT_NEW_NODE ($ZDT_NEW_NODE) is not one of ZDT_WEB_HOSTS"
    IFS=',' read -r -a NODE_URLS <<< "$ZDT_NODE_URLS"
    [[ ${#NODE_URLS[@]} -eq ${#WEB_HOSTS[@]} ]] \
        || die "ZDT_NODE_URLS must name one URL per web host (${#WEB_HOSTS[@]} hosts, ${#NODE_URLS[@]} URLs)"
    RATE="${ZDT_RATE:-$DEFAULT_RATE}"
    DURATION="${ZDT_DURATION:-$DEFAULT_DURATION}"
    [[ $RATE =~ ^[0-9]+$ && $RATE -ge 1 ]] || die "ZDT_RATE must be a positive integer (default $DEFAULT_RATE)"
    [[ $DURATION =~ ^[0-9]+$ && $DURATION -ge 1 ]] || die "ZDT_DURATION must be a positive integer (default $DEFAULT_DURATION)"
    (( RATE <= MAX_RATE )) \
        || die "ZDT_RATE=$RATE exceeds the hard maximum $MAX_RATE/s per target: the lab machine runs other things too, keep it modest"
    (( DURATION <= MAX_DURATION )) \
        || die "ZDT_DURATION=$DURATION exceeds the hard maximum ${MAX_DURATION}s"
    ZDT_RELEASES_DIR="${ZDT_RELEASES_DIR:-/var/www/magento/releases}"
    ZDT_CURRENT_LINK="${ZDT_CURRENT_LINK:-/var/www/magento/current}"
    ZDT_SNAPSHOT_DIR="${ZDT_SNAPSHOT_DIR:-/var/www/magento/zdt-snapshots}"
    ZDT_TOUCHED_TABLES="${ZDT_TOUCHED_TABLES:-catalog_product_entity}"
    FLEET_BIN="${ZDT_FLEET_BIN:-$ARM_DIR/../zdt-fleet}"
    [[ -x $FLEET_BIN ]] || die "no executable bin/zdt-fleet at $FLEET_BIN (set ZDT_FLEET_BIN)"
    SECRET_VALUES+=("$ZDT_DB_PASSWORD")
}

parse_common_flags() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -n) PLAN_ONLY=1 ;;
            -y) ASSUME_YES=1 ;;
            *) die "unknown option '$1'; see bin/zdt-arm --help" ;;
        esac
        shift
    done
}

# ------------------------------------------------------------------ transcript

redact() {
    # Every registered secret's value becomes ***; so does anything after
    # -p/--password. The transcript must carry the command, never the secret.
    local text="$*" s
    for s in "${SECRET_VALUES[@]:-}"; do
        [[ -n $s ]] || continue
        text="${text//"$s"/***}"
    done
    printf '%s' "$text" | sed -E 's/(--password[= ]| -p)[^ ]*/\1***/g'
}

ssh_opts=(-o BatchMode=yes)   # host keys are checked, always: turning host
                              # key checking off is refused by
                              # bin/check-structure, and an unknown host
                              # stops the arm naming it (see _ssh_run).

_check_host_key_error() {
    # One place classifies ssh's own failure so an unknown host reads as
    # itself — named — and not as "the remote command failed".
    if grep -qi 'host key verification failed\|remote host identification has changed\|known hosts: none' "$1" 2>/dev/null; then
        rm -f "$1"
        die "unknown or changed host key for $2: the arm will not run without host key checking; accept the key in your known_hosts first"
    fi
}

remote_cmd() {
    # remote_cmd HOST CMD... -- echo the command (with any secret as ***),
    # run it. For short commands; anything carrying a secret goes through
    # remote_script instead so it never reaches argv.
    local host="$1"; shift
    local line
    line="$host: $(redact "$*")"
    # PLAN/RUN are transcript lines, not data: they go to stderr, so a
    # caller silencing the remote command's stdout cannot silence them.
    if [[ $PLAN_ONLY == 1 ]]; then printf 'PLAN  %s\n' "$line" >&2; return 0; fi
    printf 'RUN   %s\n' "$line" >&2
    local errf rc
    errf="$(mktemp "${TMPDIR:-/tmp}/zdt-arm-ssh.XXXXXX")"
    # shellcheck disable=SC2029  # client-side expansion is the point: the command runs there.
    ssh "${ssh_opts[@]}" "$host" "$@" 2>"$errf"
    rc=$?
    _check_host_key_error "$errf" "$host"
    [[ $rc -ne 0 ]] && cat "$errf" >&2 || true
    rm -f "$errf"
    [[ $rc -eq 0 ]] || return "$rc"
}

remote_script() {
    # remote_script HOST LABEL -- pipes the script body (given on this
    # function's stdin) to bash on the node, so the body — which may carry
    # the DB password or env.php contents — appears in no argv, no ps, no
    # history and no transcript: only the label is echoed, and redacted.
    local host="$1" label="$2"
    local line
    line="$host: $(redact "$label")"
    if [[ $PLAN_ONLY == 1 ]]; then printf 'PLAN  %s\n' "$line" >&2; return 0; fi
    printf 'RUN   %s\n' "$line" >&2
    local errf out rc
    errf="$(mktemp "${TMPDIR:-/tmp}/zdt-arm-ssh.XXXXXX")"
    out="$(mktemp "${TMPDIR:-/tmp}/zdt-arm-out.XXXXXX")"
    ssh "${ssh_opts[@]}" "$host" bash -s >"$out" 2>"$errf"
    rc=$?
    _check_host_key_error "$errf" "$host"
    [[ $rc -ne 0 ]] && cat "$errf" >&2 || true
    rm -f "$errf"
    cat "$out" || true
    rm -f "$out"
    [[ $rc -eq 0 ]] || return "$rc"
    WRITTEN=1
}

confirm_plan() {
    [[ $PLAN_ONLY == 1 || $ASSUME_YES == 1 ]] && return 0
    echo "The plan above is everything this run does; nothing has run yet," >&2
    echo "and the first RUN line is the first remote write." >&2
    local answer=""
    read -r answer || answer=""
    [[ $answer == y || $answer == Y ]] || die "plan declined; nothing ran"
}

# ------------------------------------------------------------- destructive core

snapshot_line() {
    # One labelled line for both the plan and the run, secret redacted.
    printf '%s\n' "$(redact "$ZDT_ADMIN_NODE: snapshot database $ZDT_DB_NAME (password $ZDT_DB_PASSWORD) to $1")"
}

snapshot_gate() {
    # A dated mysqldump on the admin node, before setup:upgrade. The password
    # is embedded inside a script piped over stdin (never argv, never echoed:
    # only the label is, redacted). A failed snapshot stops the arm BEFORE
    # the upgrade: no snapshot, no way back. The file lives on the admin node
    # under ZDT_SNAPSHOT_DIR, where restore-snapshot reads it from.
    local snap="$ZDT_SNAPSHOT_DIR/zdt-snapshot-$RUN_ID.sql.gz"
    if [[ $PLAN_ONLY == 1 ]]; then printf 'PLAN  %s\n' "$(snapshot_line "$snap")"; return 0; fi
    if ! remote_script "$ZDT_ADMIN_NODE" "snapshot database $ZDT_DB_NAME (password $ZDT_DB_PASSWORD) to $snap" >/dev/null <<REMOTE
set -euo pipefail
export MYSQL_PWD='$ZDT_DB_PASSWORD'
command -v mysqldump >/dev/null || { echo "no mysqldump on this node" >&2; exit 1; }
mkdir -p "$ZDT_SNAPSHOT_DIR"
mysqldump --single-transaction --routines --triggers --events \
    -h '$ZDT_DB_HOST' -u '$ZDT_DB_USER' --databases '$ZDT_DB_NAME' | gzip > "$snap"
REMOTE
    then
        die "the snapshot failed; refusing to run setup:upgrade without a way back"
    fi
    SNAPSHOT="$snap"
    WRITTEN=1
    echo "Restorable snapshot (on $ZDT_ADMIN_NODE): $snap"
    echo "Restore it with:  bin/zdt-arm restore-snapshot $snap -y"
}

restore_snapshot() {
    # restore_snapshot PATH — restore a snapshot file (a path on the admin
    # node, as printed by the arm) back onto the primary. Destructive: it
    # replaces the database, so it plans, and without -y it asks.
    [[ -n $1 && $1 == /* ]] || die "usage: bin/zdt-arm restore-snapshot /absolute/path/on/$ZDT_ADMIN_NODE [-y]"
    if [[ $PLAN_ONLY == 1 ]]; then
        printf 'PLAN  %s\n' "$(redact "$ZDT_ADMIN_NODE: restore database $ZDT_DB_NAME from $1 (password $ZDT_DB_PASSWORD)")"
        return 0
    fi
    if ! remote_script "$ZDT_ADMIN_NODE" "restore database $ZDT_DB_NAME from $1 (password $ZDT_DB_PASSWORD)" >/dev/null <<REMOTE
set -euo pipefail
export MYSQL_PWD='$ZDT_DB_PASSWORD'
[[ -f '$1' ]] || { echo "no snapshot at $1 on this node" >&2; exit 1; }
gunzip -c '$1' | mysql -h '$ZDT_DB_HOST' -u '$ZDT_DB_USER'
REMOTE
    then
        die "the restore failed; stop and fix by hand before re-running any arm"
    fi
}

place_new_release() {
    # One rsync and two links on the always-new node. The other nodes are
    # never touched here: at least one stays on the old code throughout, as
    # the issue requires.
    if [[ $PLAN_ONLY == 1 ]]; then
        printf 'PLAN  %s\n' "$ZDT_NEW_NODE: rsync $ZDT_RELEASE_TARBALL -> $ZDT_RELEASES_DIR/$ZDT_LABEL_NEW.tar.gz"
        printf 'PLAN  %s\n' "$ZDT_NEW_NODE: unpack and link release $ZDT_LABEL_NEW"
        return 0
    fi
    [[ -f $ZDT_RELEASE_TARBALL ]] || die "no release tarball at $ZDT_RELEASE_TARBALL on the control machine"
    rsync -a "$ZDT_RELEASE_TARBALL" "$ZDT_NEW_NODE:$ZDT_RELEASES_DIR/$ZDT_LABEL_NEW.tar.gz" \
        || die "the rsync to $ZDT_NEW_NODE failed"
    WRITTEN=1
    remote_script "$ZDT_NEW_NODE" "unpack and link release $ZDT_LABEL_NEW" >/dev/null <<REMOTE
set -euo pipefail
mkdir -p "$ZDT_RELEASES_DIR/$ZDT_LABEL_NEW"
tar -xzf "$ZDT_RELEASES_DIR/$ZDT_LABEL_NEW.tar.gz" -C "$ZDT_RELEASES_DIR/$ZDT_LABEL_NEW"
ln -sfn "$ZDT_RELEASES_DIR/$ZDT_LABEL_NEW" "$ZDT_CURRENT_LINK"
REMOTE
}

link_old_release() {
    # Between phases: put the always-new node back on the old release.
    remote_script "$ZDT_NEW_NODE" "link release $ZDT_LABEL_OLD back in" >/dev/null <<REMOTE
set -euo pipefail
ln -sfn "$ZDT_RELEASES_DIR/$ZDT_LABEL_OLD" "$ZDT_CURRENT_LINK"
REMOTE
}

run_setup_upgrade() {
    remote_script "$ZDT_ADMIN_NODE" "php bin/magento setup:upgrade --no-interaction" >/dev/null <<REMOTE
set -euo pipefail
cd "$ZDT_CURRENT_LINK"
php bin/magento setup:upgrade --no-interaction
REMOTE
}

# ------------------------------------------------------------------ env.php

env_backup() {
    # A dated copy of the node's env.php BEFORE its first edit. The trap
    # restores on the paths it can reach; backups plus the printed commands
    # are what survive SIGKILL and a power cut.
    local host="$1"
    [[ -n ${ENV_BACKED_UP[$host]:-} ]] && return 0
    remote_cmd "$host" cp -a "$ZDT_ENV_PHP" "$ZDT_ENV_PHP.bak-$RUN_ID" || return 1
    ENV_BACKED_UP["$host"]=1
    ENV_BACKUP_HOSTS+=("$host")
    WRITTEN=1
}

env_set() {
    # env_set HOST DOTTED.KEY.PATH JSON_VALUE -- edits the node's own env.php
    # with php (env.php IS php; sed on it is how stores get corrupted). The
    # dated backup always happens first, inside this function: nothing can
    # edit without it. The key path and value are not secrets (they are the
    # flag names and cache prefixes), so they go in the script body, which is
    # never echoed.
    local host="$1" keys="$2" json="$3"
    [[ -n ${ENV_BACKED_UP[$host]:-} ]] || env_backup "$host" || return 1
    if [[ $PLAN_ONLY == 1 ]]; then
        printf 'PLAN  %s\n' "$(redact "$host: set $keys to $json in $ZDT_ENV_PHP")"
        return 0
    fi
    remote_script "$host" "set $keys to $json in $ZDT_ENV_PHP" >/dev/null <<REMOTE
set -euo pipefail
php -r '
\$f = \$argv[1]; \$keys = explode(".", \$argv[2]); \$value = json_decode(\$argv[3], true);
\$env = include \$f;
\$ref = &\$env;
foreach (\$keys as \$k) { \$ref = &\$ref[\$k]; }
\$ref = \$value;
file_put_contents(\$f, "<?php\nreturn " . var_export(\$env, true) . ";\n");
' '$ZDT_ENV_PHP' '$keys' '$json'
REMOTE
}

print_restores() {
    echo
    echo "If the run was cut short in a way no trap could handle (kill -9, a"
    echo "power cut), put it back by running, on the control machine:"
    [[ -n $SNAPSHOT ]] && echo "  bin/zdt-arm restore-snapshot $SNAPSHOT -y"
    local h
    for h in "${ENV_BACKUP_HOSTS[@]:-}"; do
        [[ -n $h ]] || continue
        echo "  ssh -o BatchMode=yes $h cp -a $ZDT_ENV_PHP.bak-$RUN_ID $ZDT_ENV_PHP"
    done
}

restore_env_files() {
    [[ $WRITTEN -eq 0 ]] && return 0
    local h
    for h in "${ENV_BACKUP_HOSTS[@]:-}"; do
        [[ -n $h ]] || continue
        ssh "${ssh_opts[@]}" "$h" cp -a "$ZDT_ENV_PHP.bak-$RUN_ID" "$ZDT_ENV_PHP" >/dev/null 2>&1 || true
    done
}

# ------------------------------------------------------------------ replica

replica_gate() {
    # The PR1 gate, before anything. Its exit 2 means the check never
    # happened (2 back); its exit 1 means the replica is not live, and a run
    # from there does not count: reported as NOT RUN, exit 1.
    local out rc
    out=$("$FLEET_BIN" replica-check 2>&1)
    rc=$?
    if [[ $rc -eq 2 ]]; then
        printf '%s\n' "$out" >&2
        die "bin/zdt-fleet replica-check could not run; the arm does not start without it"
    fi
    if [[ $rc -ne 0 ]]; then
        echo "NOT RUN: the fleet missed condition 1 (a replica replicating continuously)." >&2
        printf '%s\n' "$out" >&2
        exit 1
    fi
    mkdir -p "$OUT"
    printf '%s\n' "$out" > "$OUT/replica-before.json"
}

replica_after() {
    # Falsifier 1, first half: the replica is still live after the migration,
    # its lag back to zero within five minutes, and — once the lag is zero —
    # the touched tables' checksums match.
    local out rc lag waited=0
    out=$("$FLEET_BIN" replica-check 2>&1)
    rc=$?
    [[ $rc -eq 2 ]] && { printf '%s\n' "$out" >&2; die "bin/zdt-fleet replica-check could not run after the migration"; }
    printf '%s\n' "$out" > "$OUT/replica-after.json"
    if [[ $rc -ne 0 ]]; then
        falsifier FAIL "falsifier 1: the replica stopped or errored during the migration"
        return 1
    fi
    lag=$(_lag_of "$out")
    while [[ $lag != 0 && $waited -lt $LAG_WAIT_LIMIT ]]; do
        sleep 5
        waited=$((waited + 5))
        out=$("$FLEET_BIN" replica-check 2>&1) || { falsifier FAIL "falsifier 1: the replica stopped or errored while catching up"; return 1; }
        printf '%s\n' "$out" > "$OUT/replica-after.json"
        lag=$(_lag_of "$out")
    done
    if [[ $lag != 0 ]]; then
        falsifier FAIL "falsifier 1: lag still $lag after ${LAG_WAIT_LIMIT}s (want 0 within five minutes)"
        return 1
    fi
    local tables=()
    IFS=',' read -r -a tables <<< "$ZDT_TOUCHED_TABLES"
    local sum rc2
    sum=$("$FLEET_BIN" table-checksums "${tables[@]}" 2>&1)
    rc2=$?
    printf '%s\n' "$sum" > "$OUT/checksums.txt"
    if [[ $rc2 -eq 0 ]]; then
        falsifier PASS "falsifier 1: replication survived the migration; lag back to 0 in ${waited}s; checksums of ${ZDT_TOUCHED_TABLES} match"
        return 0
    fi
    falsifier FAIL "falsifier 1: checksums differ after the lag reached zero (see $OUT/checksums.txt)"
    return 1
}

_lag_of() { printf '%s' "$1" | sed -n 's/.*"seconds_behind": *\([0-9]*\).*/\1/p'; }

# ------------------------------------------------------------------ traffic
#
# One line per request:  epoch  target  type  status  guard(0/1)
# guard is 1 when the body matched ZDT_GUARD_PATTERN, so a refused request
# names itself in the log. Targets: every web node's own URL — a refusing
# node is attributed to that node, not hidden behind the load balancer — plus
# the LB. The mix mirrors the request types the issue names (page, cart,
# REST, GraphQL, health check).

TRAFFIC_TYPES=(cms category product cart rest graphql health)

traffic_path() {
    case "$1" in
        cms) printf '/' ;;
        category) printf '/category.html' ;;
        product) printf '/product.html' ;;
        cart) printf '/cart' ;;
        rest) printf '/rest/V1/store/products' ;;
        graphql) printf '/graphql' ;;
        health) printf '/health_check.php' ;;
    esac
}

traffic_run() {
    # traffic_run -- RATE requests per second PER TARGET, stopped on its own
    # at DURATION seconds. Nothing can hold the arm longer: each generator
    # stops at its end time and every request carries curl --max-time, so a
    # stuck request costs at most 25s, not the run.
    mkdir -p "$OUT"
    # Append, never truncate: the two phases of one run share the run's
    # traffic.log, and the run directory is fresh per RUN_ID anyway.
    touch "$OUT/traffic.log"
    local targets=("${NODE_URLS[@]}" "$ZDT_LB_URL")
    local pids=() t
    for t in "${targets[@]}"; do
        traffic_one_target "$t" &
        pids+=($!)
    done
    wait "${pids[@]}" 2>/dev/null || true
    local n
    n=$(grep -c . "$OUT/traffic.log" 2>/dev/null || echo 0)
    echo "traffic: $n requests logged to $OUT/traffic.log" >&2
}

traffic_one_target() {
    local target="$1"
    local total=$((DURATION * RATE)) sent=0 end t type status
    end=$(( $(date +%s) + DURATION ))
    while (( sent < total )); do
        (( $(date +%s) >= end )) && break
        for (( t = 0; t < RATE && sent < total; t++ )); do
            type="${TRAFFIC_TYPES[$(( sent % ${#TRAFFIC_TYPES[@]} ))]}"
            send_one "$target" "$type" "$(traffic_path "$type")"
            sent=$((sent + 1))
        done
        sleep 1
    done
}

send_one() {
    # One request, one log line. The body sample is guard-checked then
    # dropped; the line is the evidence, the samples are not.
    local target="$1" type="$2" path="$3"
    local body status guard=0
    body=$(mktemp "${TMPDIR:-/tmp}/zdt-arm-body.XXXXXX")
    status=$(curl -s -o "$body" -w '%{http_code}' --max-time 25 "$target$path" 2>/dev/null) || status=000
    if [[ -n ${ZDT_GUARD_PATTERN:-} ]]; then
        if grep -Eq "$ZDT_GUARD_PATTERN" "$body" 2>/dev/null; then guard=1; fi
    fi
    printf '%s %s %s %s %s\n' "$(date +%s)" "${target#http://}" "$type" "${status:-000}" "$guard" >> "$OUT/traffic.log"
    rm -f "$body"
}

traffic_verdicts() {
    # Falsifier 5 from the log: health_check.php answered 200 on every target
    # that refused anything. The guard-message count is reported as a fact;
    # arms 3 and 4 judge the guard claims, arms 1 and 2 record them.
    local refused t bad=0
    refused=$(awk '$3 != "health" && $4 !~ /^2/' "$OUT/traffic.log" | awk '{print $2}' | sort -u)
    for t in $refused; do
        if awk -v t="$t" '$3 == "health" && $2 == t && $4 != "200"' "$OUT/traffic.log" | grep -q .; then
            falsifier FAIL "falsifier 5: $t refused requests and its health_check.php answered non-200"
            bad=1
        fi
    done
    [[ $bad -eq 0 ]] && falsifier PASS "falsifier 5: health_check.php answered 200 on every target that refused (targets that refused: ${refused:-none})"
    local guarded
    guarded=$(awk '$5 == 1' "$OUT/traffic.log" | wc -l | tr -d ' ')
    echo "traffic: $guarded responses matched ZDT_GUARD_PATTERN (see $OUT/traffic.log)"
}

# ------------------------------------------------------------------ the run

run_phase() {
    local label="$1" with_blue_green="$2"
    echo
    echo "== phase: $label =="
    local h pfx
    for h in "${WEB_HOSTS[@]}"; do
        if [[ $label == shared-* ]]; then
            env_set "$h" cache.frontend.default.backend_options.cache_prefix '"zdt-shared"'
            env_set "$h" cache.frontend.page_cache.backend_options.cache_prefix '"zdt-shared"'
        else
            pfx="old"
            [[ $h == "$ZDT_NEW_NODE" ]] && pfx="$ZDT_LABEL_NEW"
            env_set "$h" cache.frontend.default.backend_options.cache_prefix "\"zdt-$pfx\""
            env_set "$h" cache.frontend.page_cache.backend_options.cache_prefix "\"zdt-$pfx\""
        fi
        if [[ $with_blue_green == 1 && $h != "$ZDT_NEW_NODE" ]]; then
            env_set "$h" deployment.blue_green.enabled 'true'
        fi
    done
    [[ $PLAN_ONLY == 1 ]] && return 0

    snapshot_gate
    traffic_run &
    local traffic_pid=$!
    place_new_release
    run_setup_upgrade
    wait "$traffic_pid" 2>/dev/null || true
    traffic_verdicts
    replica_after
    restore_env_files
}

run_arms() {
    local with_blue_green="$1"
    if [[ $PLAN_ONLY == 1 ]]; then
        plan_all "$with_blue_green"
        return 0
    fi
    confirm_plan
    mkdir -p "$OUT"
    replica_gate
    run_phase "shared-prefix" "$with_blue_green"
    # Between the two phases, back to the start: the next phase repeats the
    # same migration under different cache settings.
    restore_snapshot "$SNAPSHOT"
    link_old_release
    run_phase "per-release-prefix" "$with_blue_green"
    echo
    echo "== summary: $PASSES pass, $FAILS fail =="
    print_restores
    [[ $FAILS -eq 0 ]] || exit 1
}

plan_all() {
    local with_blue_green="$1" h pfx
    echo "== plan (nothing runs) =="
    printf 'PLAN  control: bin/zdt-fleet replica-check (the gate; refuses a dead replica)\n'
    for h in "${WEB_HOSTS[@]}"; do
        printf 'PLAN  %s: cp -a %s %s.bak-%s\n' "$h" "$ZDT_ENV_PHP" "$ZDT_ENV_PHP" "$RUN_ID"
        printf 'PLAN  %s\n' "$h: set cache prefixes (shared, then per-release)"
        [[ $h == "$ZDT_NEW_NODE" ]] && printf 'PLAN  %s\n' "$h: rsync $ZDT_RELEASE_TARBALL -> $ZDT_RELEASES_DIR/$ZDT_LABEL_NEW.tar.gz" && printf 'PLAN  %s\n' "$h: unpack and link release $ZDT_LABEL_NEW" || true
        if [[ $with_blue_green == 1 && $h != "$ZDT_NEW_NODE" ]]; then
            printf 'PLAN  %s\n' "$h: set deployment.blue_green.enabled to true in $ZDT_ENV_PHP"
        fi
    done
    snapshot_line "$OUT/zdt-snapshot-$RUN_ID.sql.gz" | sed 's/^/PLAN  /'
    printf 'PLAN  control: traffic %ss at %s/s per target (%s web nodes + the load balancer)\n' "$DURATION" "$RATE" "${#WEB_HOSTS[@]}"
    printf 'PLAN  %s\n' "$ZDT_ADMIN_NODE: php bin/magento setup:upgrade --no-interaction"
    printf 'PLAN  control: bin/zdt-fleet replica-check + table-checksums (falsifier 1)\n'
    printf 'PLAN  control: restore env.php from the dated backups on every node\n'
}

arm_main() {
    require_env
    parse_common_flags "$@"
    trap 'restore_env_files' EXIT
    run_arms "${ARM_BLUE_GREEN:-0}"
}
