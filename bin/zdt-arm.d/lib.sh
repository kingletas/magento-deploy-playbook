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

TRAFFIC_LOG="$OUT/traffic.log"

DEFAULT_RATE=2
DEFAULT_DURATION=120
MAX_RATE=20
MAX_DURATION=600
LAG_WAIT_LIMIT=300   # falsifier 1: lag back to zero within five minutes

# ------------------------------------------------------------------ transcript
#
# Every line the arm prints goes through say(), so the run directory keeps the
# whole transcript — the plan, each RUN as it happens, each verdict and the
# banners — and the operator still sees the same text, on the same stream, at
# the same moment. Without this the PLAN/RUN lines went to stderr and nowhere
# else: the evidence existed only if the operator redirected it themselves.
#
# Empty until a run starts: `-n` prints the plan and keeps nothing, and a run
# directory is never created for a plan.
TRANSCRIPT=""
# Lines printed before the transcript exists — the plan phase. Kept so the
# confirmed plan is in the file the run leaves behind, and dropped when the run
# never starts (a plan, or a declined prompt), so a transcript is always the
# record of a run that happened.
PLAN_BUFFER=()

say() {
    # say STREAM LINE — STREAM is 1 (stdout) or 2 (stderr), exactly as the
    # call site printed before. The line reaches the transcript first (or the
    # plan buffer, while there is no transcript yet), so a line the operator
    # saw is a line the file kept.
    local stream="$1" line="$2"
    if [[ -n $TRANSCRIPT ]]; then
        printf '%s\n' "$line" >> "$TRANSCRIPT"
    else
        PLAN_BUFFER+=("$line")
    fi
    if [[ $stream == 2 ]]; then printf '%s\n' "$line" >&2; else printf '%s\n' "$line"; fi
}

plan() {
    # plan FORMAT [ARGS] — a plan line, formatted exactly as each call site
    # used to (the call sites were `printf 'PLAN ...' ...` to stdout). FORMAT
    # is a literal at every call site and the values travel as arguments, so
    # the format is never data.
    local line
    # shellcheck disable=SC2059  # the format is a literal at every call site.
    line="$(printf "$@")"
    say 1 "$line"
}

SECRET_VALUES=()
declare -A ENV_BACKED_UP=()
ENV_BACKUP_HOSTS=()
# Every maintenance flag this run raised, as `host|release`. var/ is not shared
# between releases, so which release carries the flag decides both what a node
# serves and what the trap and print_restores have to lift.
MAINT_FLAGS=()
MAINT_LINKED_HOSTS=()
# Set to 1 for a link that has to happen under the paper: the flag is then
# raised inside the new release before the link, so the page never drops while
# a node changes release. Read by link_release_on_hosts.
LINK_PAGE_UP=0
SNAPSHOT=""

die() { say 2 "zdt-arm/$ARM_NAME: $*"; exit 2; }

falsifier() {
    local verdict="$1"; shift
    if [[ $verdict == PASS ]]; then PASSES=$((PASSES + 1)); else FAILS=$((FAILS + 1)); fi
    say 1 "$verdict  $*"
}

transcript_open() {
    # The run's transcript, opened once the plan is CONFIRMED and before the
    # first remote write. The plan the operator just read is flushed into the
    # file first, so its PLAN lines are as much a part of the record as the
    # RUN lines — the docs' claim is "every PLAN/RUN line". Secret-free: a
    # line that could carry a secret goes through redact() at its call site,
    # and the rest carry labels only. `-n` and a declined prompt never reach
    # here, so those runs leave no file at all.
    mkdir -p "$OUT"
    TRANSCRIPT="$OUT/transcript.log"
    : > "$TRANSCRIPT"
    printf '%s\n' "== transcript: bin/zdt-arm $ARM_NAME, run $RUN_ID ==" >> "$TRANSCRIPT"
    if [[ ${#PLAN_BUFFER[@]} -gt 0 ]]; then
        printf '%s\n' "${PLAN_BUFFER[@]}" >> "$TRANSCRIPT"
    fi
    PLAN_BUFFER=()
}

# ------------------------------------------------------------ platform facts
#
# The results document issue #5 asks for opens with the platform: Magento
# edition and version, PHP, the database server and its version, the
# replication mode, the number of web servers. Nothing recorded any of it, so
# the header would come from the operator's memory rather than from the run.
# These are READ-ONLY facts about the lab, read once, after the plan is
# confirmed and before the first remote write, and written as facts to
# $OUT/platform.json. A fact that cannot be read is recorded as null with the
# reason and printed as a WARN line: the run goes on, and the document says
# "not recorded" rather than a guess.

json_string() {
    # json_string VALUE — a JSON string with the escapes JSON needs, or null
    # for an empty value (so a missing fact is null, never "").
    [[ -n $1 ]] || { printf 'null'; return; }
    printf '"%s"' "$(printf '%s' "$1" | tr -d '\n' | sed 's/\\/\\\\/g; s/"/\\"/g')"
}

record_platform_facts() {
    local replay="" probe="" phpv="" edition="" version="" cli="" pkgs="" dbserver=""
    # The replication mode is the fleet gate's own read of the primary, already
    # on disk: replica-before.json carries binlog_format. Taken from there
    # rather than asked again.
    if [[ -f $OUT/replica-before.json ]]; then
        replay=$(sed -n 's/.*"binlog_format": *"\([^"]*\)".*/\1/p' "$OUT/replica-before.json" | head -1)
    fi
    # One read-only script on the admin node: the PHP the store runs, the
    # release's own edition packages and Magento CLI line, and the database
    # server's version. The DB password travels inside the body, as the
    # snapshot's does, so it reaches no argv and no transcript line.
    probe=$(remote_script "$ZDT_ADMIN_NODE" "record the platform facts (read-only: php, Magento, database server)" <<REMOTE
set -uo pipefail
printf 'php_version=%s\n' "\$(php -r 'echo PHP_VERSION;' 2>/dev/null || echo '')"
rel="$ZDT_CURRENT_LINK"
pkg=""
if [[ -r "\$rel/composer.json" ]]; then
    pkg=\$(php -r '\$c = json_decode(file_get_contents(\$argv[1]), true); \$r = \$c["require"] ?? []; echo implode(",", array_intersect(array_keys(\$r), ["magento/product-community-edition", "mage-os/product-community-edition", "magento/product-enterprise-edition"]));' "\$rel/composer.json" 2>/dev/null || true)
fi
printf 'edition_packages=%s\n' "\$pkg"
cli=""
if [[ -x "\$rel/bin/magento" ]]; then cli=\$("\$rel/bin/magento" --version 2>/dev/null | head -1); fi
printf 'magento_cli=%s\n' "\$cli"
printf 'db_server=%s\n' "\$(MYSQL_PWD='$ZDT_DB_PASSWORD' mysql -h '$ZDT_DB_HOST' -u '$ZDT_DB_USER' -N -B -e 'SELECT VERSION();' 2>/dev/null || echo '')"
REMOTE
) || true
    phpv=$(printf '%s\n' "$probe" | sed -n 's/^php_version=//p' | head -1)
    pkgs=$(printf '%s\n' "$probe" | sed -n 's/^edition_packages=//p' | head -1)
    cli=$(printf '%s\n' "$probe" | sed -n 's/^magento_cli=//p' | head -1)
    dbserver=$(printf '%s\n' "$probe" | sed -n 's/^db_server=//p' | head -1)
    # The edition, named only when the packages identify exactly one. A release
    # carrying two, or none, records null and the raw list — a label guessed
    # here would put a platform in the document that the lab does not have.
    case "$pkgs" in
        *magento/product-community-edition*|*mage-os/product-community-edition*)
            edition="Open Source"; [[ $pkgs == *mage-os* ]] && edition="Mage-OS" ;;
        *magento/product-enterprise-edition*) edition="Commerce" ;;
    esac
    # The CLI line is "Magento CLI 2.4.8" (Mage-OS names itself likewise); its
    # last field is the version. Both are recorded, so the document can quote
    # the line it came from.
    case "$cli" in
        *CLI*) version="${cli##* }" ;;
    esac
    local reason=""
    [[ -n $phpv ]] || reason="the admin node did not answer 'php -r echo PHP_VERSION'"
    [[ -n $dbserver ]] || reason="${reason:+$reason; }the primary did not answer SELECT VERSION()"
    [[ -n $replay ]] || reason="${reason:+$reason; }replica-before.json carries no binlog_format"
    # A named-but-ambiguous list says something different from "no known
    # package at all", so the reason carries the ambiguity, not the default.
    [[ -n $edition ]] || reason="${reason:+$reason; }the release's composer.json did not name a known edition package"

    {
        printf '{\n'
        printf '  "arm": %s,\n' "$(json_string "$ARM_NAME")"
        printf '  "run_id": %s,\n' "$(json_string "$RUN_ID")"
        printf '  "web_node_count": %s,\n' "${#WEB_HOSTS[@]}"
        printf '  "web_nodes": %s,\n' "$(json_string "$ZDT_WEB_HOSTS")"
        printf '  "new_node": %s,\n' "$(json_string "$ZDT_NEW_NODE")"
        printf '  "replication_mode": %s,\n' "$(json_string "$replay")"
        printf '  "magento_edition": %s,\n' "$(json_string "$edition")"
        printf '  "magento_version": %s,\n' "$(json_string "$version")"
        printf '  "magento_cli": %s,\n' "$(json_string "$cli")"
        printf '  "edition_packages": %s,\n' "$(json_string "$pkgs")"
        printf '  "php_version": %s,\n' "$(json_string "$phpv")"
        printf '  "db_server": %s,\n' "$(json_string "$dbserver")"
        printf '  "release_old": %s,\n' "$(json_string "$ZDT_LABEL_OLD")"
        printf '  "release_new": %s,\n' "$(json_string "${ZDT_LABEL_NEW:-${ZDT_LABEL_BREAKING:-}}")"
        printf '  "not_recorded": %s\n' "$(json_string "$reason")"
        printf '}\n'
    } > "$OUT/platform.json"
    say 1 "platform: $OUT/platform.json (edition ${edition:-not recorded}, Magento ${version:-not recorded}, PHP ${phpv:-not recorded}, database ${dbserver:-not recorded}, replication ${replay:-not recorded}, ${#WEB_HOSTS[@]} web nodes)"
    [[ -z $reason ]] || say 1 "WARN  platform: not recorded — $reason"
}

# ------------------------------------------------------------------ settings

require_env() {
    # None of the hosts has a default, so a missing one stops the arm BY NAME
    # rather than aiming at a guess. Paths every lab here uses the same way
    # have defaults; addresses and credentials never do.
    local missing=() v
    # Arm 3 places two releases (the additive control, then the breaking
    # one), so it asks for those instead of the single ZDT_RELEASE_TARBALL /
    # ZDT_LABEL_NEW pair the other arms place.
    local release_vars=(ZDT_RELEASE_TARBALL ZDT_LABEL_NEW)
    if [[ ${ARM_CROSSING:-0} == 1 ]]; then release_vars=(); fi
    if [[ ${ARM_OUTAGE:-0} == 1 ]]; then release_vars=(); fi
    for v in ZDT_WEB_HOSTS ZDT_NEW_NODE ZDT_ADMIN_NODE ZDT_LB_URL ZDT_NODE_URLS \
             "${release_vars[@]}" ZDT_LABEL_OLD \
             ZDT_ENV_PHP ZDT_DB_HOST ZDT_DB_USER ZDT_DB_PASSWORD ZDT_DB_NAME; do
        [[ -n ${!v:-} ]] || missing+=("$v")
    done
    [[ ${#missing[@]} -eq 0 ]] \
        || die "set these first: ${missing[*]} (see bin/zdt-arm --help)"
    if [[ ${ARM_CROSSING:-0} == 1 ]]; then crossing_require; fi
    if [[ ${ARM_OUTAGE:-0} == 1 ]]; then outage_require; fi
    IFS=',' read -r -a WEB_HOSTS <<< "$ZDT_WEB_HOSTS"
    [[ ${#WEB_HOSTS[@]} -ge 3 ]] \
        || die "issue #5 needs at least three web hosts; ZDT_WEB_HOSTS lists ${#WEB_HOSTS[@]}"
    [[ ",$ZDT_WEB_HOSTS," == *",$ZDT_NEW_NODE,"* ]] \
        || die "ZDT_NEW_NODE ($ZDT_NEW_NODE) is not one of ZDT_WEB_HOSTS"
    # setup:upgrade runs on ZDT_ADMIN_NODE from $ZDT_CURRENT_LINK, and the
    # new release is only ever placed on ZDT_NEW_NODE. Splitting the two
    # would run the migration on the old release's code — no migration, both
    # arms reporting on a run that never happened — so refuse, naming both.
    [[ "$ZDT_ADMIN_NODE" == "$ZDT_NEW_NODE" ]] \
        || die "ZDT_ADMIN_NODE ($ZDT_ADMIN_NODE) must be ZDT_NEW_NODE ($ZDT_NEW_NODE): the migration runs on the node that carries the new release"
    local missing_paths=()
    [[ -n ${ZDT_CATEGORY_PATH:-} ]] || missing_paths+=(ZDT_CATEGORY_PATH)
    [[ -n ${ZDT_PRODUCT_PATH:-} ]] || missing_paths+=(ZDT_PRODUCT_PATH)
    [[ ${#missing_paths[@]} -eq 0 ]] \
        || die "set ${missing_paths[*]} to a real category/product page's path: a guessed URL a stock store does not serve would record every target as refusing"
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

crossing_require() {
    # Arm 3's own settings, refused by name when missing: the two releases it
    # crosses (additive control, then breaking), the route that reads the
    # schema object the breaking release renames or drops, and the object's
    # name. Falsifier 3's PASS must name that object in the first failure, so
    # a guessed one would poison the evidence: no default, refusal instead.
    local missing_c=() cv
    for cv in ZDT_RELEASE_ADDITIVE ZDT_LABEL_ADDITIVE ZDT_RELEASE_BREAKING \
              ZDT_LABEL_BREAKING ZDT_READ_PATH ZDT_SCHEMA_OBJECT; do
        [[ -n ${!cv:-} ]] || missing_c+=("$cv")
    done
    [[ ${#missing_c[@]} -eq 0 ]] \
        || die "arm 3 needs these too: ${missing_c[*]} (see bin/zdt-arm --help)"
}

outage_require() {
    # Arm 4's own settings: the BREAKING release whose rollout it measures,
    # twice — once live, once behind maintenance mode. Like arm 3's, it has
    # no defaults: measuring the outage of the wrong release would answer a
    # question nobody asked, so a missing one stops arm 4 by name.
    local missing_o=() ov
    for ov in ZDT_RELEASE_BREAKING ZDT_LABEL_BREAKING; do
        [[ -n ${!ov:-} ]] || missing_o+=("$ov")
    done
    [[ ${#missing_o[@]} -eq 0 ]] \
        || die "arm 4 needs these too: ${missing_o[*]} (see bin/zdt-arm --help)"
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
    if [[ $PLAN_ONLY == 1 ]]; then say 2 "PLAN  $line"; return 0; fi
    say 2 "RUN   $line"
    local errf rc
    errf="$(mktemp "${TMPDIR:-/tmp}/zdt-arm-ssh.XXXXXX")"
    # shellcheck disable=SC2029  # client-side expansion is the point: the command runs there.
    ssh "${ssh_opts[@]}" "$host" "$@" 2>"$errf"
    rc=$?
    _check_host_key_error "$errf" "$host"
    if [[ $rc -ne 0 ]]; then cat "$errf" >&2; fi
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
    if [[ $PLAN_ONLY == 1 ]]; then say 2 "PLAN  $line"; return 0; fi
    say 2 "RUN   $line"
    local errf out rc
    errf="$(mktemp "${TMPDIR:-/tmp}/zdt-arm-ssh.XXXXXX")"
    out="$(mktemp "${TMPDIR:-/tmp}/zdt-arm-out.XXXXXX")"
    ssh "${ssh_opts[@]}" "$host" bash -s >"$out" 2>"$errf"
    rc=$?
    _check_host_key_error "$errf" "$host"
    if [[ $rc -ne 0 ]]; then cat "$errf" >&2; fi
    rm -f "$errf"
    cat "$out" || true
    rm -f "$out"
    [[ $rc -eq 0 ]] || return "$rc"
    WRITTEN=1
}

confirm_plan() {
    [[ $PLAN_ONLY == 1 || $ASSUME_YES == 1 ]] && return 0
    say 2 "The plan above is everything this run does; nothing has run yet,"
    say 2 "and the first RUN line is the first remote write."
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
    if [[ $PLAN_ONLY == 1 ]]; then say 1 "PLAN  $(snapshot_line "$snap")"; return 0; fi
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
    say 1 "Restorable snapshot (on $ZDT_ADMIN_NODE): $snap"
    say 1 "Restore it with:  bin/zdt-arm restore-snapshot $snap -y"
}

restore_snapshot() {
    # restore_snapshot PATH — restore a snapshot file (a path on the admin
    # node, as printed by the arm) back onto the primary. Destructive: it
    # replaces the database, so it plans, and without -y it asks.
    [[ -n $1 && $1 == /* ]] || die "usage: bin/zdt-arm restore-snapshot /absolute/path/on/$ZDT_ADMIN_NODE [-y]"
    if [[ $PLAN_ONLY == 1 ]]; then
        say 1 "PLAN  $(redact "$ZDT_ADMIN_NODE: restore database $ZDT_DB_NAME from $1 (password $ZDT_DB_PASSWORD)")"
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
    # place_new_release [TARBALL LABEL] -- one rsync and two links on the
    # always-new node; defaults to the single release the non-crossing arms
    # place. The other nodes are never touched here: at least one stays on
    # the old code throughout, as the issue requires. Arm 4's maintenance leg
    # does not come through here: it links every web node (this one included)
    # through link_release_on_hosts, which raises the maintenance flag inside
    # the new release before the link.
    local tarball="${1:-$ZDT_RELEASE_TARBALL}" label="${2:-$ZDT_LABEL_NEW}"
    if [[ $PLAN_ONLY == 1 ]]; then
        say 1 "PLAN  $ZDT_NEW_NODE: rsync $tarball -> $ZDT_RELEASES_DIR/$label.tar.gz"
        say 1 "PLAN  $ZDT_NEW_NODE: unpack and link release $label"
        return 0
    fi
    [[ -f $tarball ]] || die "no release tarball at $tarball on the control machine"
    rsync -a "$tarball" "$ZDT_NEW_NODE:$ZDT_RELEASES_DIR/$label.tar.gz" \
        || die "the rsync to $ZDT_NEW_NODE failed"
    WRITTEN=1
    remote_script "$ZDT_NEW_NODE" "unpack and link release $label" >/dev/null <<REMOTE
set -euo pipefail
mkdir -p "$ZDT_RELEASES_DIR/$label"
tar -xzf "$ZDT_RELEASES_DIR/$label.tar.gz" -C "$ZDT_RELEASES_DIR/$label"
ln -sfn "$ZDT_RELEASES_DIR/$label" "$ZDT_CURRENT_LINK"
REMOTE
}

link_old_release() {
    # Between phases: put the always-new node back on the release named
    # (default: the old one).
    local label="${1:-$ZDT_LABEL_OLD}"
    remote_script "$ZDT_NEW_NODE" "link release $label back in" >/dev/null <<REMOTE
set -euo pipefail
ln -sfn "$ZDT_RELEASES_DIR/$label" "$ZDT_CURRENT_LINK"
REMOTE
}

link_release_on_hosts() {
    # link_release_on_hosts TARBALL LABEL HOST... — place_new_release's shape
    # (rsync, unpack, link) on every named host. Arm 4's maintenance leg uses
    # it: the page must come down on a fleet actually running the new release.
    # Each host that gets linked is remembered, so the relink after the leg
    # (and the exit trap on a failed leg) puts every node back on old code.
    #
    # With LINK_PAGE_UP=1 the flag is raised inside the release being linked,
    # BEFORE the link: var/ is not shared between releases, so linking first
    # would drop the page on that node before the migration ran. The flag's
    # release is remembered, so the trap lifts it in the release that holds
    # it.
    local tarball="$1" label="$2"
    shift 2
    local h
    for h in "$@"; do
        [[ -f $tarball ]] || die "no release tarball at $tarball on the control machine"
        rsync -a "$tarball" "$h:$ZDT_RELEASES_DIR/$label.tar.gz" || return 1
        if [[ ${LINK_PAGE_UP:-0} == 1 ]]; then
            if ! remote_script "$h" "unpack release $label on $h, enable maintenance in it, link it" >/dev/null <<REMOTE
set -euo pipefail
mkdir -p "$ZDT_RELEASES_DIR/$label"
tar -xzf "$ZDT_RELEASES_DIR/$label.tar.gz" -C "$ZDT_RELEASES_DIR/$label"
cd "$ZDT_RELEASES_DIR/$label" && php bin/magento maintenance:enable
ln -sfn "$ZDT_RELEASES_DIR/$label" "$ZDT_CURRENT_LINK"
REMOTE
            then return 1; fi
            MAINT_FLAGS+=("$h|$label")
        else
            if ! remote_script "$h" "unpack and link release $label on $h" >/dev/null <<REMOTE
set -euo pipefail
mkdir -p "$ZDT_RELEASES_DIR/$label"
tar -xzf "$ZDT_RELEASES_DIR/$label.tar.gz" -C "$ZDT_RELEASES_DIR/$label"
ln -sfn "$ZDT_RELEASES_DIR/$label" "$ZDT_CURRENT_LINK"
REMOTE
            then return 1; fi
        fi
        MAINT_LINKED_HOSTS+=("$h")
    done
}

relink_linked_hosts_old() {
    # After the maintenance leg's traffic stops: every linked node back on
    # ZDT_LABEL_OLD, so the lab is left as it was found. Never while traffic
    # still runs: old code against the migrated schema would add the rollout
    # leg's failures on top of the window just measured. A relink that fails
    # prints the exact command — the measurement itself is already done.
    #
    # The maintenance flag lives in a release, not on the host, so the relink
    # has to take it off the release the node is going BACK to as well: a
    # superseded release keeps the flag the previous deploy set in it, and
    # repointing at it would serve the maintenance page from the lab the run
    # was supposed to leave as it found it.
    [[ ${#MAINT_LINKED_HOSTS[@]} -eq 0 ]] && return 0
    local h
    for h in "${MAINT_LINKED_HOSTS[@]}"; do
        [[ -n $h ]] || continue
        # shellcheck disable=SC2029  # client-side expansion is the point.
        # `&&`, not `;`: ssh reports the LAST command's status, so with `;` a
        # failed `maintenance:disable` would still look like a successful
        # relink — the node would be handed back behind the page, its flag
        # dropped from the tracking, and the operator told nothing.
        if ssh "${ssh_opts[@]}" "$h" "cd $ZDT_RELEASES_DIR/$ZDT_LABEL_OLD && php bin/magento maintenance:disable && ln -sfn $ZDT_RELEASES_DIR/$ZDT_LABEL_OLD $ZDT_CURRENT_LINK" >/dev/null 2>&1; then
            maint_flags_drop_host "$h"
        else
            say 2 "zdt-arm/$ARM_NAME: could not relink $h to $ZDT_LABEL_OLD; run: ssh -o BatchMode=yes $h 'cd $ZDT_RELEASES_DIR/$ZDT_LABEL_OLD && php bin/magento maintenance:disable && ln -sfn $ZDT_RELEASES_DIR/$ZDT_LABEL_OLD $ZDT_CURRENT_LINK'"
        fi
    done
    MAINT_LINKED_HOSTS=()
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
    # cp -L: env.php is deployed as a symlink to the shared copy, so a
    # dereference-free cp -a would "back up" a second symlink to the very
    # file the run edits — and the restore would put the edited bytes back,
    # losing the original on every node. The backup holds contents.
    remote_cmd "$host" cp -L --preserve=mode,ownership,timestamps "$ZDT_ENV_PHP" "$ZDT_ENV_PHP.bak-$RUN_ID" || return 1
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
        say 1 "PLAN  $(redact "$host: set $keys to $json in $ZDT_ENV_PHP")"
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
    say 1 ""
    say 1 "If the run was cut short in a way no trap could handle (kill -9, a"
    say 1 "power cut), put it back by running, on the control machine:"
    # `[[ -z … ]] ||` rather than `[[ -n … ]] &&`: with `&&` an empty SNAPSHOT
    # would leave the function with status 1, which `set -e` reads as a failure
    # in the middle of printing the restores.
    [[ -z $SNAPSHOT ]] || say 1 "  bin/zdt-arm restore-snapshot $SNAPSHOT -y"
    local spec h rel
    # One line per flag actually raised, naming the release that holds it:
    # `cd $ZDT_CURRENT_LINK` would disable whatever release the node happens
    # to point at, which after a relink is not the one carrying the flag.
    for spec in "${MAINT_FLAGS[@]:-}"; do
        [[ -n $spec ]] || continue
        h="${spec%%|*}"; rel="${spec##*|}"
        say 1 "  ssh -o BatchMode=yes $h 'cd $ZDT_RELEASES_DIR/$rel && php bin/magento maintenance:disable'"
    done
    for h in "${MAINT_LINKED_HOSTS[@]:-}"; do
        [[ -n $h ]] || continue
        say 1 "  ssh -o BatchMode=yes $h 'cd $ZDT_RELEASES_DIR/$ZDT_LABEL_OLD && php bin/magento maintenance:disable && ln -sfn $ZDT_RELEASES_DIR/$ZDT_LABEL_OLD $ZDT_CURRENT_LINK'"
    done
    for h in "${ENV_BACKUP_HOSTS[@]:-}"; do
        [[ -n $h ]] || continue
        say 1 "  ssh -o BatchMode=yes $h cp --preserve=mode,ownership,timestamps $ZDT_ENV_PHP.bak-$RUN_ID $ZDT_ENV_PHP"
    done
}

restore_env_files() {
    [[ $WRITTEN -eq 0 ]] && return 0
    local h
    for h in "${ENV_BACKUP_HOSTS[@]:-}"; do
        [[ -n $h ]] || continue
        # Plain cp: the dated backup is a real file (cp -L made it one);
        # following the destination symlink writes the original bytes back
        # into the shared copy — where env.php points.
        ssh "${ssh_opts[@]}" "$h" cp --preserve=mode,ownership,timestamps "$ZDT_ENV_PHP.bak-$RUN_ID" "$ZDT_ENV_PHP" >/dev/null 2>&1 || true
    done
}

# ------------------------------------------------------------- maintenance mode
#
# A maintenance flag is `var/.maintenance.flag`, and `var/` is NOT shared
# between releases here: the flag lives inside the release that wrote it. So
# every flag this run raises is recorded as `host|release` and lifted by path.
# `cd $ZDT_CURRENT_LINK` is never used to lift one: after a link or a relink
# `current` points at a different release than the flag's, so that would
# either leave the page up or clear nothing.

maint_flag_drop() {
    # maint_flag_drop `host|release` — that flag is off; stop tracking it.
    local spec="$1" f keep=()
    for f in "${MAINT_FLAGS[@]:-}"; do
        [[ -n $f && $f != "$spec" ]] || continue
        keep+=("$f")
    done
    if [[ ${#keep[@]} -eq 0 ]]; then MAINT_FLAGS=(); else MAINT_FLAGS=("${keep[@]}"); fi
}

maint_flags_drop_host() {
    # maint_flags_drop_host HOST — every flag on that host is off. Used after
    # a relink, which clears the old release's flag by path.
    local host="$1" f keep=()
    for f in "${MAINT_FLAGS[@]:-}"; do
        [[ -n $f && ${f%%|*} != "$host" ]] || continue
        keep+=("$f")
    done
    if [[ ${#keep[@]} -eq 0 ]]; then MAINT_FLAGS=(); else MAINT_FLAGS=("${keep[@]}"); fi
}

maintenance_enable() {
    # maintenance_enable HOST RELEASE — the stock way in, run in the named
    # release by path. The host|release pair is remembered so the trap and
    # print_restores lift exactly that flag, wherever `current` points later.
    local host="$1" rel="$2"
    remote_cmd "$host" "cd $ZDT_RELEASES_DIR/$rel && php bin/magento maintenance:enable" \
        || return 1
    MAINT_FLAGS+=("$host|$rel")
    WRITTEN=1
}

maintenance_disable() {
    # maintenance_disable HOST RELEASE — lift the flag in that release only.
    local host="$1" rel="$2"
    remote_cmd "$host" "cd $ZDT_RELEASES_DIR/$rel && php bin/magento maintenance:disable" || true
    maint_flag_drop "$host|$rel"
}

restore_maintenance() {
    # The trap's half: every flag still up, lifted in the release that holds
    # it — the old release the page went up in at the start of the leg, and
    # the new release each node was linked under. A no-op when the run's own
    # disables already covered them, as on a clean leg.
    [[ ${#MAINT_FLAGS[@]} -eq 0 ]] && return 0
    local spec h rel
    for spec in "${MAINT_FLAGS[@]}"; do
        [[ -n $spec ]] || continue
        h="${spec%%|*}"; rel="${spec##*|}"
        # shellcheck disable=SC2029  # client-side expansion is the point: the path is the control machine's view.
        ssh "${ssh_opts[@]}" "$h" "cd $ZDT_RELEASES_DIR/$rel && php bin/magento maintenance:disable" >/dev/null 2>&1 || true
    done
    MAINT_FLAGS=()
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
        say 2 "$out"
        die "bin/zdt-fleet replica-check could not run; the arm does not start without it"
    fi
    if [[ $rc -ne 0 ]]; then
        say 2 "NOT RUN: the fleet missed condition 1 (a replica replicating continuously)."
        say 2 "$out"
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
    [[ $rc -eq 2 ]] && { say 2 "$out"; die "bin/zdt-fleet replica-check could not run after the migration"; }
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
# Arm 3's crossing adds a request that reads the named schema object, added
# in arm_main (ARM_CROSSING is set after this file is sourced). The lab sets
# ZDT_READ_PATH to a route that really reads it (the issue: "the results must
# name the request that reads that column and show it was sent to an old
# server"); with no crossing run, the mix stays as the issue's request types.

traffic_path() {
    case "$1" in
        cms) printf '/' ;;
        category) printf '%s' "$ZDT_CATEGORY_PATH" ;;
        product) printf '%s' "$ZDT_PRODUCT_PATH" ;;
        cart) printf '/checkout/cart/' ;;
        rest) printf '/rest/V1/directory/currency' ;;
        # Braces percent-encoded: curl's URL globbing would eat them.
        graphql) printf '/graphql?query=%%7BstoreConfig%%7Bstore_code%%7D%%7D' ;;
        health) printf '/health_check.php' ;;
        read) printf '%s' "$ZDT_READ_PATH" ;;
    esac
}

traffic_run() {
    # traffic_run -- RATE requests per second PER TARGET, stopped on its own
    # at DURATION seconds. Nothing can hold the arm longer: each generator
    # stops at its end time and every request carries curl --max-time, so a
    # stuck request costs at most 25s, not the run.
    mkdir -p "$OUT"
    # Append, never truncate: a phase's log belongs to that phase alone
    # (TRAFFIC_LOG), and the run directory is fresh per RUN_ID anyway.
    touch "$TRAFFIC_LOG"
    local targets=("${NODE_URLS[@]}" "$ZDT_LB_URL")
    local pids=() t
    for t in "${targets[@]}"; do
        traffic_one_target "$t" &
        pids+=($!)
    done
    wait "${pids[@]}" 2>/dev/null || true
    local n
    n=$(grep -c . "$TRAFFIC_LOG" 2>/dev/null || echo 0)
    say 2 "traffic: $n requests logged to $TRAFFIC_LOG"
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

save_evidence() {
    # Keep the response body as evidence: falsifier 3 must check that the
    # first failure on an old server names the schema object that changed,
    # and the log line alone cannot show that. Names carry time, pid, target,
    # type and status so nothing overwrites; a body without the words stays
    # there too — its absence from the grep is itself evidence.
    local target="$1" type="$2" status="$3" body="$4" name
    [[ -n ${EVIDENCE_DIR:-} ]] || return 0
    mkdir -p "$EVIDENCE_DIR"
    # Trailing slashes stripped: "http://node2.example/" would otherwise make
    # the copy destination end in /, where cp silently goes wrong.
    name="${target#http://}"; name="${name%/}"
    cp "$body" "$EVIDENCE_DIR/${type}-${status}-$(date +%s%N)-${BASHPID:-$$}-${name}" 2>/dev/null || true
}

send_one() {
    # One request, one log line, through TRAFFIC_LOG (one log per phase, so a
    # later verdict never counts the earlier phase's lines). A body that
    # tripped the guard is copied to $EVIDENCE_DIR when that is set: falsifier
    # 3 needs the first failure's own words, to check they name the schema
    # object. Otherwise the body sample is guard-checked then dropped.
    local target="$1" type="$2" path="$3"
    local body status guard=0
    body=$(mktemp "${TMPDIR:-/tmp}/zdt-arm-body.XXXXXX")
    status=$(curl -s -o "$body" -w '%{http_code}' --max-time 25 "$target$path" 2>/dev/null) || status=000
    if [[ -n ${ZDT_GUARD_PATTERN:-} ]]; then
        if grep -Eq "$ZDT_GUARD_PATTERN" "$body" 2>/dev/null; then
            guard=1
            save_evidence "$target" "$type" "$status" "$body"
        fi
    fi
    # Falsifier 3 reads a failed read request's own words even when no guard
    # pattern was set to catch it: a schema error is not a guard message.
    if [[ $type == read && $status != 200 ]]; then
        save_evidence "$target" "$type" "$status" "$body"
    fi
    printf '%s %s %s %s %s\n' "$(date +%s)" "${target#http://}" "$type" "${status:-000}" "$guard" >> "$TRAFFIC_LOG"
    rm -f "$body"
}

traffic_verdicts() {
    # Falsifier 5 from the log: health_check.php answered 200 on every target
    # that refused anything. The guard-message count is reported as a fact;
    # arms 3 and 4 judge the guard claims, arms 1 and 2 record them.
    # "Refused" means the server was not serving: 5xx, no answer at all, or
    # a guard message. A 4xx is a fact for the log, not a refusal — a route
    # that goes missing mid-migration still shows there.
    local refused t bad=0
    refused=$(awk '$3 != "health" && ($4 ~ /^5/ || $4 == "000" || $5 == 1)' "$TRAFFIC_LOG" | awk '{print $2}' | sort -u)
    for t in $refused; do
        if awk -v t="$t" '$3 == "health" && $2 == t && $4 != "200"' "$TRAFFIC_LOG" | grep -q .; then
            falsifier FAIL "falsifier 5: $t refused requests and its health_check.php answered non-200"
            bad=1
        fi
    done
    [[ $bad -eq 0 ]] && falsifier PASS "falsifier 5: health_check.php answered 200 on every target that refused (targets that refused: ${refused:-none})"
    local guarded
    guarded=$(awk '$5 == 1' "$TRAFFIC_LOG" | wc -l | tr -d ' ')
    say 1 "traffic: $guarded responses matched ZDT_GUARD_PATTERN (see $TRAFFIC_LOG)"
}

# ------------------------------------------------------------------ the run

run_phase() {
    local label="$1" with_blue_green="$2"
    TRAFFIC_LOG="$OUT/traffic-$label.log"
    say 1 ""
    say 1 "== phase: $label =="
    local h pfx
    for h in "${WEB_HOSTS[@]}"; do
        if [[ $label == shared-* ]]; then
            # id_prefix IS the cache prefix Magento reads (the P1-1 proof
            # edits and reads back this key); backend_options.cache_prefix is
            # a key Magento ignores.
            env_set "$h" cache.frontend.default.id_prefix '"zdt-shared"' \
                || die "the env.php edit on $h failed before the migration; the arm stops here"
            env_set "$h" cache.frontend.page_cache.id_prefix '"zdt-shared"' \
                || die "the env.php edit on $h failed before the migration; the arm stops here"
        else
            pfx="old"
            [[ $h == "$ZDT_NEW_NODE" ]] && pfx="$ZDT_LABEL_NEW"
            env_set "$h" cache.frontend.default.id_prefix "\"zdt-$pfx\"" \
                || die "the env.php edit on $h failed before the migration; the arm stops here"
            env_set "$h" cache.frontend.page_cache.id_prefix "\"zdt-$pfx\"" \
                || die "the env.php edit on $h failed before the migration; the arm stops here"
        fi
        if [[ $with_blue_green == 1 && $h != "$ZDT_NEW_NODE" ]]; then
            env_set "$h" deployment.blue_green.enabled 'true' \
                || die "the env.php edit on $h failed before the migration; the arm stops here"
        fi
    done
    [[ $PLAN_ONLY == 1 ]] && return 0

    snapshot_gate
    traffic_run &
    local traffic_pid=$!
    if ! place_new_release; then
        kill "$traffic_pid" 2>/dev/null || true
        die "the new release did not land on $ZDT_NEW_NODE; the migration did not happen"
    fi
    if ! run_setup_upgrade; then
        kill "$traffic_pid" 2>/dev/null || true
        die "setup:upgrade failed on $ZDT_ADMIN_NODE; the migration did not happen"
    fi
    wait "$traffic_pid" 2>/dev/null || true
    traffic_verdicts
    replica_after
    restore_env_files
}

run_arms() {
    local with_blue_green="$1"
    # The plan is printed either way: -n stops there, otherwise the operator
    # confirms the plan visible above the prompt, never one unseen.
    plan_all "$with_blue_green"
    [[ $PLAN_ONLY == 1 ]] && return 0
    confirm_plan
    transcript_open
    replica_gate
    record_platform_facts
    run_phase "shared-prefix" "$with_blue_green"
    # Between the two phases, back to the start: the next phase repeats the
    # same migration under different cache settings.
    restore_snapshot "$SNAPSHOT"
    link_old_release "$ZDT_LABEL_OLD" || die "could not relink $ZDT_NEW_NODE to $ZDT_LABEL_OLD; check that node by hand before re-running an arm"
    run_phase "per-release-prefix" "$with_blue_green"
    say 1 ""
    say 1 "== summary: $PASSES pass, $FAILS fail =="
    print_restores
    [[ $FAILS -eq 0 ]] || exit 1
}

plan_phase() {
    # One phase's plan lines, in the order run_phase does them.
    local label="$1" with_blue_green="$2" h pfx
    plan 'PLAN  == phase: %s ==\n' "$label"
    for h in "${WEB_HOSTS[@]}"; do
        plan 'PLAN  %s: cp -L --preserve=mode,ownership,timestamps %s %s.bak-%s\n' "$h" "$ZDT_ENV_PHP" "$ZDT_ENV_PHP" "$RUN_ID"
        if [[ $label == shared-* ]]; then
            plan 'PLAN  %s\n' "$h: set cache prefixes (id_prefix) to zdt-shared in $ZDT_ENV_PHP"
        else
            pfx="old"
            [[ $h == "$ZDT_NEW_NODE" ]] && pfx="$ZDT_LABEL_NEW"
            plan 'PLAN  %s\n' "$h: set cache prefixes (id_prefix) to zdt-$pfx in $ZDT_ENV_PHP"
        fi
        if [[ $with_blue_green == 1 && $h != "$ZDT_NEW_NODE" ]]; then
            plan 'PLAN  %s\n' "$h: set deployment.blue_green.enabled to true in $ZDT_ENV_PHP"
        fi
    done
    plan 'PLAN  %s\n' "$ZDT_NEW_NODE: rsync $ZDT_RELEASE_TARBALL -> $ZDT_RELEASES_DIR/$ZDT_LABEL_NEW.tar.gz"
    plan 'PLAN  %s\n' "$ZDT_NEW_NODE: unpack and link release $ZDT_LABEL_NEW"
    say 1 "$(snapshot_line "$ZDT_SNAPSHOT_DIR/zdt-snapshot-$RUN_ID.sql.gz" | sed 's/^/PLAN  /')"
    plan 'PLAN  control: traffic %ss at %s/s per target (%s web nodes + the load balancer)\n' "$DURATION" "$RATE" "${#WEB_HOSTS[@]}"
    plan 'PLAN  %s\n' "$ZDT_ADMIN_NODE: php bin/magento setup:upgrade --no-interaction"
    plan 'PLAN  control: bin/zdt-fleet replica-check + table-checksums (falsifier 1)\n'
}

plan_all() {
    # The whole run, in the order run_arms does it — both phases AND the
    # destructive steps between them (restore over the primary, relink), so
    # what -y would do is fully reviewable from the plan alone.
    local with_blue_green="$1"
    say 1 "== plan (nothing runs) =="
    plan 'PLAN  control: bin/zdt-fleet replica-check (the gate; it stops a run whose replica is not live)\n'
    plan_phase "shared-prefix" "$with_blue_green"
    plan 'PLAN  %s\n' "$(redact "$ZDT_ADMIN_NODE: restore database $ZDT_DB_NAME from $ZDT_SNAPSHOT_DIR/zdt-snapshot-$RUN_ID.sql.gz (password $ZDT_DB_PASSWORD)")"
    plan 'PLAN  %s\n' "$ZDT_NEW_NODE: link release $ZDT_LABEL_OLD back in"
    plan_phase "per-release-prefix" "$with_blue_green"
    plan 'PLAN  control: restore env.php from the dated backups on every node\n'
}

# --------------------------------------------------- arm 3: crossing releases

crossing_old_targets() {
    # The nodes that stay on the old code: every node URL but the new node's.
    # Falsifier 3 is judged on these alone — the new node is expected to
    # match the schema after the upgrade.
    local i new_url=""
    for i in "${!WEB_HOSTS[@]}"; do
        [[ ${WEB_HOSTS[$i]} == "$ZDT_NEW_NODE" ]] && new_url="${NODE_URLS[$i]#http://}"
    done
    local t
    for t in "${NODE_URLS[@]}"; do
        [[ ${t#http://} == "$new_url" ]] && continue
        printf '%s\n' "${t#http://}"
    done
}

crossing_phase() {
    # One crossing: old code serving while this release's migration runs
    # against the primary, with the flag ON on the old servers. The label
    # says which release (additive control / breaking evidence).
    local label="$1" tarball="$2" rel="$3"
    TRAFFIC_LOG="$OUT/traffic-$label.log"
    EVIDENCE_DIR="$OUT/evidence-$label"
    say 1 ""
    say 1 "== crossing: $label ($rel) =="
    local h pfx
    for h in "${WEB_HOSTS[@]}"; do
        pfx="old"
        [[ $h == "$ZDT_NEW_NODE" ]] && pfx="$rel"
        env_set "$h" cache.frontend.default.id_prefix "\"zdt-$pfx\"" \
            || die "the env.php edit on $h failed before the crossing; the arm stops here"
        env_set "$h" cache.frontend.page_cache.id_prefix "\"zdt-$pfx\"" \
            || die "the env.php edit on $h failed before the crossing; the arm stops here"
        if [[ $h != "$ZDT_NEW_NODE" ]]; then
            # Arm 3 is defined with the flag ON: this is where falsifier 3
            # tests the claim that it lets old code serve until the schema
            # breaks.
            env_set "$h" deployment.blue_green.enabled 'true' \
                || die "the env.php edit on $h failed before the crossing; the arm stops here"
        fi
    done
    [[ $PLAN_ONLY == 1 ]] && return 0

    snapshot_gate
    traffic_run &
    local traffic_pid=$!
    if ! place_new_release "$tarball" "$rel"; then
        kill "$traffic_pid" 2>/dev/null || true
        die "the release did not land on $ZDT_NEW_NODE; the crossing did not happen"
    fi
    if ! run_setup_upgrade; then
        kill "$traffic_pid" 2>/dev/null || true
        die "setup:upgrade failed on $ZDT_ADMIN_NODE; the crossing did not happen"
    fi
    wait "$traffic_pid" 2>/dev/null || true
    traffic_verdicts
    replica_after
    if [[ $label == breaking-* ]]; then
        falsifier3_breaking
    else
        falsifier3_control
    fi
    restore_env_files
}

falsifier3_control() {
    # Control leg: across the ADDITIVE release, old servers with the flag on
    # must serve pages, REST and GraphQL without a guard message. Per the
    # issue, passing this alone is not evidence of anything — the breaking
    # leg below is the evidence — but a guard message here disproves the
    # flag's claim on the cheapest possible release.
    local old_t guarded=0 t
    old_t=$(crossing_old_targets)
    for t in $old_t; do
        local n
        n=$(awk -v t="$t" '$2 == t && $3 != "health" && $5 == 1' "$TRAFFIC_LOG" | wc -l | tr -d ' ')
        guarded=$((guarded + n))
    done
    if [[ $guarded -gt 0 ]]; then
        falsifier FAIL "falsifier 3 (control): $guarded guarded responses on old servers across the additive release with the flag on"
        return 1
    fi
    falsifier PASS "falsifier 3 (control): no guard message on any old server across the additive release (a control; not the evidence)"
}

falsifier3_breaking() {
    # Evidence leg: across the BREAKING release, the first failure on an old
    # server must name $ZDT_SCHEMA_OBJECT, and the read path must not sail
    # through. Both come from this phase's own log and saved bodies.
    local old_t read_failed=0 served_ok=0 t
    old_t=$(crossing_old_targets)
    for t in $old_t; do
        local n m
        n=$(awk -v t="$t" '$2 == t && $3 == "read" && ($4 ~ /^[45]/ || $4 == "000" || $5 == 1)' "$TRAFFIC_LOG" | wc -l | tr -d ' ')
        m=$(awk -v t="$t" '$2 == t && $3 == "read" && $4 == "200"' "$TRAFFIC_LOG" | wc -l | tr -d ' ')
        read_failed=$((read_failed + n))
        served_ok=$((served_ok + m))
    done
    local guarded=0
    for t in $old_t; do
        local g
        g=$(awk -v t="$t" '$2 == t && $3 != "health" && $5 == 1' "$TRAFFIC_LOG" | wc -l | tr -d ' ')
        guarded=$((guarded + g))
    done
    if [[ $guarded -gt 0 ]]; then
        falsifier FAIL "falsifier 3: $guarded guarded responses on old servers across the breaking release with the flag on — the flag did not silence the guard"
        return 1
    fi
    if [[ $read_failed -eq 0 ]]; then
        falsifier FAIL "falsifier 3: no old server failed the read path across the breaking release (old read requests answered 200: $served_ok) — either the release does not break what $ZDT_READ_PATH reads, or old servers served a schema they do not match"
        return 1
    fi
    # The first failure's own words must name the schema object. Names carry
    # the epoch in nanoseconds, so the chronological first is a numeric sort
    # on field 3. Only the old servers count: a body saved from the new node
    # (new code before setup:upgrade) or from the load balancer is not an
    # old-server failure, so an evidence file only qualifies when its name
    # ends in -<old target>, with the target stripped the way save_evidence
    # strips it (no http://, no trailing slash — the log keeps the slash and
    # the file name drops it).
    local first="" first_node="" hit="" f t suffix
    for f in $(find "$EVIDENCE_DIR" -maxdepth 1 -type f -name 'read-*' -printf '%f\n' 2>/dev/null | sort -t- -k3,3n); do
        for t in $old_t; do
            suffix="${t#http://}"; suffix="${suffix%/}"
            if [[ $f == *"-$suffix" ]]; then
                first="$f"; first_node="$suffix"
                break
            fi
        done
        [[ -n $first ]] && break
    done
    if [[ -n $first ]]; then
        if grep -qi "$ZDT_SCHEMA_OBJECT" "$EVIDENCE_DIR/$first"; then
            hit="$EVIDENCE_DIR/$first"
        fi
    fi
    if [[ -z $hit ]]; then
        falsifier FAIL "falsifier 3: the first old-server failure does not name $ZDT_SCHEMA_OBJECT (first old-server body: ${first:-none saved}; see $EVIDENCE_DIR)"
        return 1
    fi
    falsifier PASS "falsifier 3: across the breaking release the first old-server failure on $first_node names $ZDT_SCHEMA_OBJECT ($hit; the read path is $ZDT_READ_PATH)"
}

run_crossing() {
    # Arm 3's shape: control first, then the evidence, with the database
    # restored between them so the breaking crossing starts from the same
    # state. One phase each; the flag is on the old servers throughout.
    plan_all_crossing
    [[ $PLAN_ONLY == 1 ]] && return 0
    confirm_plan
    transcript_open
    replica_gate
    record_platform_facts
    crossing_phase "additive-control" "$ZDT_RELEASE_ADDITIVE" "$ZDT_LABEL_ADDITIVE"
    restore_snapshot "$SNAPSHOT"
    link_old_release "$ZDT_LABEL_OLD" || die "could not relink $ZDT_NEW_NODE to $ZDT_LABEL_OLD; check that node by hand before re-running the arm"
    crossing_phase "breaking-evidence" "$ZDT_RELEASE_BREAKING" "$ZDT_LABEL_BREAKING"
    say 1 ""
    say 1 "== summary: $PASSES pass, $FAILS fail =="
    print_restores
    [[ $FAILS -eq 0 ]] || exit 1
}

plan_phase_crossing() {
    local label="$1" tarball="$2" rel="$3" h pfx
    plan 'PLAN  == crossing: %s (%s) ==\n' "$label" "$rel"
    for h in "${WEB_HOSTS[@]}"; do
        plan 'PLAN  %s: cp -L --preserve=mode,ownership,timestamps %s %s.bak-%s\n' "$h" "$ZDT_ENV_PHP" "$ZDT_ENV_PHP" "$RUN_ID"
        pfx="old"
        [[ $h == "$ZDT_NEW_NODE" ]] && pfx="$rel"
        plan 'PLAN  %s\n' "$h: set cache prefixes (id_prefix) to zdt-$pfx and deployment.blue_green.enabled to true (old nodes only) in $ZDT_ENV_PHP"
    done
    plan 'PLAN  %s\n' "$ZDT_NEW_NODE: rsync $tarball -> $ZDT_RELEASES_DIR/$rel.tar.gz"
    plan 'PLAN  %s\n' "$ZDT_NEW_NODE: unpack and link release $rel"
    say 1 "$(snapshot_line "$ZDT_SNAPSHOT_DIR/zdt-snapshot-$RUN_ID.sql.gz" | sed 's/^/PLAN  /')"
    plan 'PLAN  control: traffic %ss at %s/s per target, including the read path %s (%s web nodes + the load balancer)\n' "$DURATION" "$RATE" "$ZDT_READ_PATH" "${#WEB_HOSTS[@]}"
    plan 'PLAN  %s\n' "$ZDT_ADMIN_NODE: php bin/magento setup:upgrade --no-interaction"
    plan 'PLAN  control: bin/zdt-fleet replica-check + table-checksums (falsifier 1); saved failure bodies under %s/evidence-%s/ (falsifier 3)\n' "$OUT" "$label"
}

plan_all_crossing() {
    say 1 "== plan (nothing runs) =="
    plan 'PLAN  control: bin/zdt-fleet replica-check (the gate; it stops a run whose replica is not live)\n'
    plan_phase_crossing "additive-control" "$ZDT_RELEASE_ADDITIVE" "$ZDT_LABEL_ADDITIVE"
    plan 'PLAN  %s\n' "$(redact "$ZDT_ADMIN_NODE: restore database $ZDT_DB_NAME from $ZDT_SNAPSHOT_DIR/zdt-snapshot-$RUN_ID.sql.gz (password $ZDT_DB_PASSWORD)")"
    plan 'PLAN  %s\n' "$ZDT_NEW_NODE: link release $ZDT_LABEL_OLD back in"
    plan_phase_crossing "breaking-evidence" "$ZDT_RELEASE_BREAKING" "$ZDT_LABEL_BREAKING"
    plan 'PLAN  control: restore env.php from the dated backups on every node\n'
}

# ---------------------------------------------------------------- outage (arm 4)
#
# Arm 4 measures the outage of the breaking release two ways, second by
# second: the rollout (no maintenance mode, old servers serving while the
# migration runs) and the same rollout behind maintenance mode. A request
# counts as failed when it was refused: 5xx, no answer at all, or a guard
# match — the maintenance page IS a 503, so the mode's own outage is counted
# the same way. Per second and request type the report carries the share
# that failed ("what the customer sees" every second of the rollout); the
# verdict compares the two legs on totals: failed requests, and seconds in
# which something failed (the outage's length).

# One rule, used by the verdict, the TOTAL line and the per-second table: a
# request failed when it was REFUSED — 5xx, no answer at all, or a guard
# match. Health is excluded (falsifier 5 judges it) and a 4xx is a fact for
# the log, not a refusal, exactly as traffic_verdicts defines it.
outage_is_fail() { awk '$3 != "health" && ($4 ~ /^5/ || $4 == "000" || $5 == 1)'; }

summarize_outage() {
    # summarize_outage LOG REPORT LABEL — writes REPORT: per second and
    # request type the share of requests that failed ("what the customer
    # sees" second by second; health excluded — falsifier 5 judges it), then
    # one TOTAL line. Echoes "failed=<n> seconds=<n>": the failed requests,
    # and the distinct seconds in which at least one failed (the outage's
    # length, not the run's).
    local log="$1" report="$2" label="$3"
    {
        printf '== %s: per second and type, failed/total (0 means all served) ==\n' "$label"
        awk '
            $3 != "health" {
                total[$1 " " $3]++
                if ($4 ~ /^5/ || $4 == "000" || $5 == 1) fail[$1 " " $3]++
            }
            END { for (k in total) printf "%s %d/%d\n", k, fail[k], total[k] }
        ' "$log" | sort -n
        printf 'TOTAL %s\n' "$(outage_is_fail < "$log" | wc -l | tr -d ' ')"
    } > "$report"
    local failed seconds
    failed=$(outage_is_fail < "$log" | wc -l | tr -d ' ')
    seconds=$(outage_is_fail < "$log" | cut -d' ' -f1 | sort -u | wc -l | tr -d ' ')
    printf 'failed=%s seconds=%s\n' "$failed" "$seconds"
}

falsifier4_verdict() {
    # Falsifier 4: the rollout must fail MORE requests, and for MORE seconds,
    # than the same release behind maintenance mode. Fewer or shorter means
    # the statement is false — a FAIL, per the issue's "false if".
    if (( $1 > $3 && $2 > $4 )); then
        falsifier PASS "falsifier 4: the rollout failed $1 requests in $2 seconds; maintenance mode failed $3 in $4 — maintenance is the smaller outage"
        return
    fi
    falsifier FAIL "falsifier 4: the rollout failed $1 requests in $2 seconds; maintenance mode failed $3 in $4 — maintenance was NOT the smaller outage (want the rollout strictly worse on both)"
}

outage_phase() {
    # outage_phase LABEL TARBALL REL [MAINT] — one leg. With MAINT the leg is
    # a real maintenance deploy: the page goes up on every node before
    # anything moves, the breaking release is linked on every web node under
    # the page BEFORE the migration (the flag is raised inside the release
    # being linked, so `current` never points at a release without one), and
    # the page comes down on every node in the same step after it — the
    # outage maintenance mode actually buys, measured on a fleet that ends
    # the window serving the new release. The linked nodes go back to the old
    # release only after traffic stops, or the rollout leg's failures (old
    # code on the migrated schema) would be added on top of the window just
    # measured. Without MAINT the window is exactly what a live rollout is.
    local label="$1" tarball="$2" rel="$3" maint="${4:-}"
    TRAFFIC_LOG="$OUT/traffic-$label.log"
    EVIDENCE_DIR="$OUT/evidence-$label"
    say 1 ""
    say 1 "== outage: $label ($rel) =="
    [[ $PLAN_ONLY == 1 ]] && return 0

    snapshot_gate
    traffic_run &
    local traffic_pid=$!
    if [[ $maint == maint ]]; then
        # The page goes up on every node, in the release `current` points at
        # today (ZDT_LABEL_OLD), before anything moves; a failed enable stops
        # the leg, and the exit trap lifts it on the nodes that already went
        # under. Each node is then linked under its own page — the breaking
        # release is unpacked with the flag already raised in it — and only
        # then does the migration run. Linking first would drop the page
        # before the migration: a flag lives inside the release that wrote
        # it, and `var/` is not shared.
        local h
        for h in "${WEB_HOSTS[@]}"; do
            if ! maintenance_enable "$h" "$ZDT_LABEL_OLD"; then
                kill "$traffic_pid" 2>/dev/null || true
                die "maintenance:enable failed on $h; the maintenance leg did not happen"
            fi
        done
        LINK_PAGE_UP=1
        if ! link_release_on_hosts "$tarball" "$rel" "${WEB_HOSTS[@]}"; then
            LINK_PAGE_UP=0
            kill "$traffic_pid" 2>/dev/null || true
            die "maintenance: link to $rel failed; the maintenance leg did not happen"
        fi
        LINK_PAGE_UP=0
    elif ! place_new_release "$tarball" "$rel"; then
        kill "$traffic_pid" 2>/dev/null || true
        die "the release did not land on $ZDT_NEW_NODE; the rollout did not happen"
    fi
    if ! run_setup_upgrade; then
        kill "$traffic_pid" 2>/dev/null || true
        die "setup:upgrade failed on $ZDT_ADMIN_NODE; the rollout did not happen"
    fi
    if [[ $maint == maint ]]; then
        # The page comes down on every node it went up on, in one step, right
        # after the migration: the fleet is serving the new release the
        # moment the outage ends. Each flag is lifted in the release that
        # carries it — the new release here; the old release's flag is
        # cleared by path as part of the relink, before `current` points at
        # it again. The exit trap covers every path here that die() takes, so
        # no node is left behind the page.
        local spec
        for spec in "${MAINT_FLAGS[@]:-}"; do
            [[ -n $spec ]] || continue
            [[ ${spec##*|} == "$rel" ]] || continue
            maintenance_disable "${spec%%|*}" "${spec##*|}"
        done
    fi
    wait "$traffic_pid" 2>/dev/null || true
    if [[ $maint == maint ]]; then
        relink_linked_hosts_old
    fi
    traffic_verdicts
    replica_after
}

run_outage() {
    # Arm 4's shape: the rollout leg first, then the database back to its
    # exact pre-run state, then the same rollout behind maintenance mode.
    # Falsifier 4 compares the two legs; falsifier 5 is judged on each.
    plan_all_outage
    [[ $PLAN_ONLY == 1 ]] && return 0
    confirm_plan
    transcript_open
    replica_gate
    record_platform_facts
    outage_phase "rollout" "$ZDT_RELEASE_BREAKING" "$ZDT_LABEL_BREAKING"
    restore_snapshot "$SNAPSHOT"
    link_old_release "$ZDT_LABEL_OLD" || die "could not relink $ZDT_NEW_NODE to $ZDT_LABEL_OLD; check that node by hand before re-running the arm"
    outage_phase "maintenance" "$ZDT_RELEASE_BREAKING" "$ZDT_LABEL_BREAKING" maint
    local r m rf rs mf ms
    r=$(summarize_outage "$OUT/traffic-rollout.log" "$OUT/outage-report-rollout.txt" "rollout")
    m=$(summarize_outage "$OUT/traffic-maintenance.log" "$OUT/outage-report-maintenance.txt" "maintenance")
    rf="${r#failed=}"; rf="${rf%% *}"
    rs="${r##*seconds=}"
    mf="${m#failed=}"; mf="${mf%% *}"
    ms="${m##*seconds=}"
    falsifier4_verdict "$rf" "$rs" "$mf" "$ms"
    say 1 "outage: rollout failed $rf requests in $rs seconds; maintenance mode failed $mf in $ms (per-second shares: $OUT/outage-report-rollout.txt, $OUT/outage-report-maintenance.txt)"
    say 1 ""
    say 1 "== summary: $PASSES pass, $FAILS fail =="
    print_restores
    [[ $FAILS -eq 0 ]] || exit 1
}

plan_phase_outage() {
    local label="$1" tarball="$2" rel="$3" maint="${4:-}" h
    plan 'PLAN  == outage: %s (%s) ==\n' "$label" "$rel"
    if [[ $maint == maint ]]; then
        for h in "${WEB_HOSTS[@]}"; do
            plan 'PLAN  %s\n' "$h: php bin/magento maintenance:enable in $ZDT_RELEASES_DIR/$ZDT_LABEL_OLD (before anything moves)"
        done
        for h in "${WEB_HOSTS[@]}"; do
            plan 'PLAN  %s\n' "$h: rsync $tarball -> $ZDT_RELEASES_DIR/$rel.tar.gz, unpack release $rel, php bin/magento maintenance:enable in $ZDT_RELEASES_DIR/$rel, link it (under the page, before the migration)"
        done
    else
        plan 'PLAN  %s\n' "$ZDT_NEW_NODE: rsync $tarball -> $ZDT_RELEASES_DIR/$rel.tar.gz"
        plan 'PLAN  %s\n' "$ZDT_NEW_NODE: unpack and link release $rel"
    fi
    say 1 "$(snapshot_line "$ZDT_SNAPSHOT_DIR/zdt-snapshot-$RUN_ID.sql.gz" | sed 's/^/PLAN  /')"
    plan 'PLAN  control: traffic %ss at %s/s per target (%s web nodes + the load balancer)\n' "$DURATION" "$RATE" "${#WEB_HOSTS[@]}"
    plan 'PLAN  %s\n' "$ZDT_ADMIN_NODE: php bin/magento setup:upgrade --no-interaction"
    if [[ $maint == maint ]]; then
        for h in "${WEB_HOSTS[@]}"; do
            plan 'PLAN  %s\n' "$h: php bin/magento maintenance:disable in $ZDT_RELEASES_DIR/$rel (after the migration, on every node, in one step)"
        done
        for h in "${WEB_HOSTS[@]}"; do
            plan 'PLAN  %s\n' "$h: php bin/magento maintenance:disable in $ZDT_RELEASES_DIR/$ZDT_LABEL_OLD, then link release $ZDT_LABEL_OLD back in (after the traffic window)"
        done
    fi
    plan 'PLAN  control: bin/zdt-fleet replica-check + table-checksums (falsifier 1)\n'
}

plan_all_outage() {
    say 1 "== plan (nothing runs) =="
    plan 'PLAN  control: bin/zdt-fleet replica-check (the gate; it stops a run whose replica is not live)\n'
    plan_phase_outage "rollout" "$ZDT_RELEASE_BREAKING" "$ZDT_LABEL_BREAKING"
    plan 'PLAN  %s\n' "$(redact "$ZDT_ADMIN_NODE: restore database $ZDT_DB_NAME from $ZDT_SNAPSHOT_DIR/zdt-snapshot-$RUN_ID.sql.gz (password $ZDT_DB_PASSWORD)")"
    plan 'PLAN  %s\n' "$ZDT_NEW_NODE: link release $ZDT_LABEL_OLD back in"
    plan_phase_outage "maintenance" "$ZDT_RELEASE_BREAKING" "$ZDT_LABEL_BREAKING" maint
    plan 'PLAN  control: every maintenance flag raised by the run, lifted in the release that holds it; env.php restored from the dated backups\n'
}

arm_main() {
    require_env
    parse_common_flags "$@"
    trap 'restore_env_files; restore_maintenance; relink_linked_hosts_old' EXIT
    if [[ ${ARM_CROSSING:-0} == 1 ]]; then
        TRAFFIC_TYPES+=(read)
        run_crossing
        return
    fi
    if [[ ${ARM_OUTAGE:-0} == 1 ]]; then
        run_outage
        return
    fi
    run_arms "${ARM_BLUE_GREEN:-0}"
}
