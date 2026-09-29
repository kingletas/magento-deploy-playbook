"""Tests for bin/zdt-arm: the fleet arms of issue #5, offline.

No lab exists here. Fake `ssh`, `curl` and `rsync` go on PATH; the replica
gate runs the real bin/zdt-fleet against the fake `mysql` client from
tests/test_zdt_fleet.py. Nothing connects to any server, and no test uses a
live one: the fakes record every call so a test can show what the arm did —
and, for refused runs, that it did nothing at all.
"""

from __future__ import annotations

import hashlib
import os
import re
import subprocess
import tempfile
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
RUNNER = ROOT / "bin" / "zdt-arm"

# The fake mysql from the fleet suite, reused verbatim for the gate.
import sys

sys.path.insert(0, str(ROOT / "tests"))
from test_zdt_fleet import FAKE_MYSQL, MYSQL8_HEADERS, status_row

FAKE_SSH = """#!/usr/bin/env bash
# Records host + command; a `bash -s` body is recorded too (newlines as ~).
# A rule file of `host|substring` lines fails a matching call, so a test can
# make exactly one step of the run fail.
host="" ; args=() ; skip=0
for a in "$@"; do
    if [[ $skip == 1 ]]; then skip=0; continue; fi
    if [[ $a == "-o" ]]; then skip=1; continue; fi
    if [[ -z $host ]]; then host="$a"; else args+=("$a"); fi
done
body=""
if [[ "${args[0]:-}" == bash && "${args[1]:-}" == "-s" ]]; then body=$(cat); fi
printf 'SSH|%s|%s|%s\\n' "$host" "${args[*]:-}" "$(printf '%s' "$body" | tr '\\n' '~')" >> "$FAKE_SSH_CALLS"
if [[ -n ${FAKE_MAINT_FLAGS:-} || -n ${FAKE_MAINT_EVENTS:-} ]]; then
    # Which release a maintenance command really touches. var/ is not shared
    # between releases, so the flag the fake raises has to sit in the release
    # the command runs in, and the `cd` in front of the command names it. A
    # `cd` to the current link (the control machine expands it before ssh)
    # means the release this host's link points at today, which the tracked
    # `ln -sfn` below says — that is what makes the fake catch a flag written
    # in one release and left behind, or read, in another.
    maint_all="${args[*]:-}${body}"
    current_link="${FAKE_ZDT_CURRENT_LINK:-/var/www/magento/current}"
    unquote() { printf '%s' "$1" | tr -d '"'; }
    maint_dir=$(printf '%s' "$maint_all" | awk '{for (i = 1; i < NF; i++) if ($i == "cd") { print $(i + 1); exit }}')
    maint_dir=$(unquote "$maint_dir")
    maint_label=""
    if [[ -n $maint_dir ]]; then
        if [[ $maint_dir == "$current_link" || $maint_dir == */current || $maint_dir == *'$ZDT_CURRENT_LINK'* ]]; then
            maint_label=$(cat "${FAKE_MAINT_CURRENT:-/nonexistent}/$host" 2>/dev/null || printf '%s' "${ZDT_LABEL_OLD:-}")
        else
            maint_label="${maint_dir##*/}"
        fi
    fi
fi
if [[ -n ${FAKE_MAINT_FLAGS:-} ]]; then
    # Flag-file mode (arm4): the flag lives INSIDE the release the command ran
    # in, exactly as Magento writes it.
    if [[ -n $maint_label ]]; then
        if printf '%s' "$maint_all" | grep -qF "maintenance:enable"; then
            mkdir -p "$FAKE_MAINT_FLAGS/$host"
            touch "$FAKE_MAINT_FLAGS/$host/$maint_label"
        fi
        if printf '%s' "$maint_all" | grep -qF "maintenance:disable"; then
            rm -f "$FAKE_MAINT_FLAGS/$host/$maint_label"
        fi
    fi
fi
if [[ -n ${FAKE_MAINT_FLAGS:-} || -n ${FAKE_MAINT_EVENTS:-} ]]; then
    # A link this call makes is this host's current release from now on. Done
    # AFTER the flag bookkeeping above, so a node's current release never
    # momentarily lacks the flag it should be serving behind: the release is
    # unpacked and its flag raised, and only then does `current` move — the
    # order the arm itself uses, which is the whole point of the fix.
    link_line=$(printf '%s' "$maint_all" | grep -oE 'ln -sfn [^ ]+ [^ ]+' | tail -1)
    if [[ -n $link_line && -n ${FAKE_MAINT_CURRENT:-} ]]; then
        # ln -sfn <release> <link>: the release is $3, the flag is $2.
        link_src=$(unquote "$(printf '%s' "$link_line" | awk '{print $3}')")
        mkdir -p "$FAKE_MAINT_CURRENT"
        printf '%s\\n' "${link_src##*/}" > "$FAKE_MAINT_CURRENT/$host"
    fi
fi
if [[ -n ${FAKE_SSH_SLEEP:-} ]]; then
    # Each ssh round-trip takes real time on a real fleet. Tests that judge
    # the traffic that lands *while* a step runs need the step to last longer
    # than a batch of requests, or the window is sub-second and the assertion
    # is vacuous.
    sleep "$FAKE_SSH_SLEEP"
fi
if [[ -n ${FAKE_MAINT_EVENTS:-} ]]; then
    for kw in "maintenance:enable" "maintenance:disable" "setup:upgrade"; do
        if printf '%s' "$maint_all" | grep -qF "$kw"; then
            printf '%s|%s|%s|%s\\n' "$(date +%s.%N)" "$host" "$kw" "$maint_label" >> "$FAKE_MAINT_EVENTS"
        fi
    done
fi
if [[ -n ${FAKE_SSH_RUN:-} ]]; then
    # Execute mode: run the received command/body locally, each host rooted
    # under $FAKE_SSH_RUN/<host>/ (paths under /srv/magento/ are rewritten
    # there), so a test can watch a backup, an edit and a restore touch real
    # files without any lab.
    root="$FAKE_SSH_RUN/$host"
    if [[ -n $body ]]; then
        mkdir -p "$root/current/app/etc"
        printf '%s\\n' "$body" | sed "s|/srv/magento/|$root/|g" | bash -s; exit $?
    fi
    cmd="${args[*]:-}"
    cmd="${cmd//\\/srv\\/magento\\//$root\\/}"
    bash -c "$cmd"; exit $?
fi
if [[ -n ${FAKE_SSH_FAIL:-} ]]; then
    while IFS= read -r rule; do
        [[ -z $rule ]] && continue
        rh="${rule%%|*}"; rs="${rule#*|}"
        if [[ $rh == "$host" ]] && printf '%s %s' "${args[*]:-}" "$body" | grep -qF "$rs"; then
            echo "fake ssh: $host fails on rule: $rs" >&2; exit 1
        fi
    done < "$FAKE_SSH_FAIL"
fi
exit 0
"""

FAKE_LB_DRAIN = """#!/usr/bin/env bash
# ZDT_LB_DRAIN's stand-in, logged beside the ssh calls so a test sees the
# order. FAKE_LB_DRAIN_FAIL names a state (maint or ready) that fails.
printf 'DRAIN|%s\\n' "$*" >> "$FAKE_SSH_CALLS"
[[ ${FAKE_LB_DRAIN_FAIL:-} == "$2" ]] && exit 1
exit 0
"""

FAKE_RSYNC = """#!/usr/bin/env bash
printf 'RSYNC|%s\\n' "$*" >> "$FAKE_SSH_CALLS"
exit 0
"""

FAKE_CURL = """#!/usr/bin/env bash
# Default 200. FAKE_CURL_DOWN: a target substring whose NON-health requests
# answer 503 with a guard message. FAKE_CURL_HEALTH_DOWN: a target whose
# health_check.php itself answers 503.
#
# ZDT_LB_STATS_URL answers HAProxy's stats CSV. Every read counts, and each
# server named in FAKE_LB_TAKEN_OUT has been taken out once more per read, 5 s
# each, so a phase's two reads show it taken out once. FAKE_LB_BACKWARDS
# counts down instead (HAProxy restarted), FAKE_LB_SERVERS replaces the
# server list, and FAKE_LB_STATS_DOWN makes the page answer 503.
out="" ; url=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -o) out="$2"; shift 2 ;;
        -w) shift 2 ;;
        --max-time) shift 2 ;;
        -s) shift ;;
        *) url="$1"; shift ;;
    esac
done
printf 'CURL|%s\\n' "$url" >> "$FAKE_CURL_CALLS"
if [[ -n ${ZDT_LB_STATS_URL:-} && $url == "$ZDT_LB_STATS_URL" ]]; then
    if [[ -n ${FAKE_LB_STATS_DOWN:-} ]]; then echo 503; exit 0; fi
    reads="$FAKE_DIR/lb-stats-reads"
    n=$(( $(cat "$reads" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$reads"
    {
        echo "# pxname,svname,qcur,status,chkdown,downtime,type,"
        echo "stats,FRONTEND,0,OPEN,,,0,"
        IFS=',' read -r -a servers <<< "${FAKE_LB_SERVERS:-node1,node2,node3}"
        for sv in "${servers[@]}"; do
            downs=0
            [[ ,${FAKE_LB_TAKEN_OUT:-}, == *",$sv,"* ]] && downs=$n
            [[ ,${FAKE_LB_BACKWARDS:-}, == *",$sv,"* ]] && downs=$(( 100 - n ))
            echo "web,$sv,0,UP,$downs,$(( downs * 5 )),2,"
        done
        echo "web,BACKEND,0,UP,0,0,1,"
    } > "${out:-/dev/stdout}"
    echo 200
    exit 0
fi
# How many ssh calls had been logged when this request STARTED. Read
# here, before the response is decided: the answer reflects the flags as
# they were then, so a request that started before an enable and was
# answered after it belongs to the window before the page went up.
curl_pos=$(wc -l < "${FAKE_SSH_CALLS:-/dev/null}" 2>/dev/null | tr -d ' ')
code=200 ; body=""
if [[ -n ${FAKE_CURL_DOWN:-} && $url == *"$FAKE_CURL_DOWN"* && $url != *health_check* ]]; then
    code=503; body="Please refresh the page and try again"
fi
if [[ -n ${FAKE_CURL_HEALTH_DOWN:-} && $url == *"$FAKE_CURL_HEALTH_DOWN"* && $url == *health_check* ]]; then
    code=503
fi
if [[ -n ${FAKE_CURL_NOTFOUND:-} && $url == *"$FAKE_CURL_NOTFOUND"* && $url != *health_check* ]]; then
    code=404
fi
if [[ -n ${FAKE_CURL_BREAK_READ:-} && $url == *"$FAKE_CURL_BREAK_READ"* && $url == *"$ZDT_READ_PATH"* ]]; then
    code=503; body="${FAKE_CURL_BREAK_BODY:-SQLSTATE[42S22]: Column not found: 1054 Unknown column 'gift_registry_id' in 'field list'}"
fi
if [[ -n ${FAKE_CURL_BREAK_READ2:-} && $url == *"$FAKE_CURL_BREAK_READ2"* && $url == *"$ZDT_READ_PATH"* ]]; then
    code=503; body="${FAKE_CURL_BREAK_BODY2:-SQLSTATE[HY000]: unrelated}"
fi
if [[ -n ${FAKE_MAINT_FLAGS:-} ]]; then
    # Flag-file mode (arm4): a host answers the maintenance page while the
    # release its `current` link resolves to carries the flag — the flag is
    # per release, so which release `current` points at is what decides.
    fh="${url#http://}"; fh="${fh%%/*}"; fh="${fh%%:*}"; fh="${fh%%.example}"
    cur=$(cat "${FAKE_MAINT_CURRENT:-/nonexistent}/$fh" 2>/dev/null || printf '%s' "${ZDT_LABEL_OLD:-}")
    if [[ -n $cur && -e "$FAKE_MAINT_FLAGS/$fh/$cur" && $url != *health_check* ]]; then
        code=503; body="Please refresh the page and try again"
    fi
fi
if [[ -n ${FAKE_CURL_INDEXED:-} ]]; then
    # Which ssh call this request belongs to: the fake ssh appends exactly one
    # line per call, so the count is a position in the run — a position, not a
    # wall-clock second, which is what lets a test judge the traffic of a
    # window ("while the page was up") without flaking on a loaded runner.
    printf '%s %s %s\n' "${curl_pos:-?}" "$url" "$code" >> "$FAKE_CURL_INDEXED"
fi
[[ -n $out && -n $body ]] && printf '%s\n' "$body" > "$out"
echo "$code"
"""


class ZdtArmTest(unittest.TestCase):
    def setUp(self) -> None:
        # Under local.d/, not /tmp: some sandboxes mount /tmp noexec and a
        # fake client that will not run reads as a dead lab.
        work = ROOT / "local.d" / "test-zdt-arm"
        work.mkdir(parents=True, exist_ok=True)
        self.tmp = tempfile.TemporaryDirectory(dir=work)
        self.dir = Path(self.tmp.name)
        self.fake_dir = self.dir / "canned"
        self.fake_dir.mkdir()
        stubs = self.dir / "stubs"
        stubs.mkdir()
        for name, text in (
            ("mysql", FAKE_MYSQL),
            ("ssh", FAKE_SSH),
            ("rsync", FAKE_RSYNC),
            ("curl", FAKE_CURL),
            ("lb-drain", FAKE_LB_DRAIN),
        ):
            fake = stubs / name
            fake.write_text(text)
            fake.chmod(0o755)
        self.calls_file = self.dir / "calls.log"
        self.lb_drain = str(stubs / "lb-drain")
        self.curl_calls = self.dir / "curl.log"
        self.tarball = self.dir / "release-new.tgz"
        self.tarball.write_text(
            "not really a tarball; the node unpacks it, the fake does not\n"
        )
        self.env = {k: v for k, v in os.environ.items() if not k.startswith("ZDT_")}
        self.env["PATH"] = f"{stubs}{os.pathsep}{os.environ['PATH']}"
        self.env.update(
            {
                "FAKE_DIR": str(self.fake_dir),
                "FAKE_CALLS": str(self.dir / "mysql-calls.log"),
                "FAKE_SSH_CALLS": str(self.calls_file),
                "FAKE_CURL_CALLS": str(self.curl_calls),
                "ZDT_PRIMARY_HOST": "primary.db",
                "ZDT_PRIMARY_USER": "u1",
                "ZDT_PRIMARY_PASSWORD": "pw1",
                "ZDT_PRIMARY_DATABASE": "magento",
                "ZDT_REPLICA_HOST": "replica.db",
                "ZDT_REPLICA_USER": "u2",
                "ZDT_REPLICA_PASSWORD": "pw2",
                "ZDT_REPLICA_DATABASE": "magento",
                "ZDT_WEB_HOSTS": "node1,node2,node3",
                "ZDT_NEW_NODE": "node1",
                "ZDT_ADMIN_NODE": "node1",
                "ZDT_LB_URL": "http://lb.example/",
                "ZDT_LB_STATS_URL": "http://lb.example:8404/stats;csv",
                "ZDT_NODE_URLS": "http://node1.example/,http://node2.example/,http://node3.example/",
                "ZDT_RELEASE_TARBALL": str(self.tarball),
                "ZDT_LABEL_NEW": "rel-new",
                "ZDT_LABEL_OLD": "rel-old",
                "ZDT_ENV_PHP": "/srv/magento/current/app/etc/env.php",
                "ZDT_FPM_RELOAD": "fpm-reload-cmd",
                "ZDT_DB_HOST": "primary.db",
                "ZDT_DB_USER": "dbu",
                "ZDT_DB_PASSWORD": "Sup3rSecretPw",  # pragma: allowlist secret (invented for the tests)
                "ZDT_DB_NAME": "magento",
                "ZDT_GUARD_PATTERN": "Please refresh",
                "ZDT_CATEGORY_PATH": "/mens.html",
                "ZDT_PRODUCT_PATH": "/products/gt.html",
                "ZDT_RELEASE_ADDITIVE": str(self.tarball),
                "ZDT_LABEL_ADDITIVE": "rel-add",
                "ZDT_RELEASE_BREAKING": str(self.tarball),
                "ZDT_LABEL_BREAKING": "rel-break",
                "ZDT_READ_PATH": "/products/gt.html",
                "ZDT_SCHEMA_OBJECT": "gift_registry_id",
                "ZDT_DURATION": "1",
                "ZDT_RATE": "1",
                "ZDT_TRAFFIC_TAIL": "0",
                "ZDT_RUN_DIR": str(self.dir / "run"),
            }
        )
        # A live replica for the gate, and matching checksums for falsifier 1.
        self.canned(
            "replica.db",
            "SHOW REPLICA STATUS",
            MYSQL8_HEADERS + "\n" + status_row(lag="0") + "\n",
        )
        for host in ("primary.db", "replica.db"):
            self.canned(
                host,
                "CHECKSUM TABLE catalog_product_entity",
                "magento.catalog_product_entity\t4242\n",
            )
        self.canned("primary.db", "SELECT @@binlog_format", "ROW\n")
        self.canned("primary.db", "SELECT COUNT(*) FROM catalog_product_entity", "10\n")
        self.canned("primary.db", "SHOW BINARY LOGS", "binlog.000001\t100\n")

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def canned(self, host: str, sql: str, output: str, db: str = "magento") -> None:
        name = hashlib.sha256(f"{host}|{db}|{sql}".encode()).hexdigest()
        (self.fake_dir / name).write_text(output)

    def run_arm(self, *argv: str, stdin="", **extra_env: str):
        # stdin=DEVNULL models "no terminal": read gets EOF at once.
        if stdin is None:
            return subprocess.run(
                [str(RUNNER), *argv],
                env={**self.env, **extra_env},
                stdin=subprocess.DEVNULL,
                capture_output=True,
                text=True,
                timeout=120,
                check=False,
            )
        return subprocess.run(
            [str(RUNNER), *argv],
            env={**self.env, **extra_env},
            input=stdin,
            capture_output=True,
            text=True,
            timeout=120,
            check=False,
        )

    def calls(self) -> str:
        return self.calls_file.read_text() if self.calls_file.exists() else ""

    # ------------------------------------------------------------------ runner

    def test_no_arguments_is_exit_2_not_help_0(self) -> None:
        result = self.run_arm()
        self.assertEqual(result.returncode, 2)

    def test_help_lists_every_documented_variable_and_exits_0(self) -> None:
        result = self.run_arm("--help")
        self.assertEqual(result.returncode, 0)
        for var in (
            "ZDT_WEB_HOSTS",
            "ZDT_NEW_NODE",
            "ZDT_ADMIN_NODE",
            "ZDT_LB_URL",
            "ZDT_LB_STATS_URL",
            "ZDT_LB_DRAIN",
            "ZDT_NODE_URLS",
            "ZDT_RELEASE_TARBALL",
            "ZDT_LABEL_NEW",
            "ZDT_LABEL_OLD",
            "ZDT_ENV_PHP",
            "ZDT_FPM_RELOAD",
            "ZDT_DB_HOST",
            "ZDT_DB_USER",
            "ZDT_DB_PASSWORD",
            "ZDT_DB_NAME",
            "ZDT_SNAPSHOT_DIR",
            "ZDT_RATE",
            "ZDT_DURATION",
            "ZDT_TRAFFIC_TAIL",
            "ZDT_GUARD_PATTERN",
            "ZDT_CATEGORY_PATH",
            "ZDT_PRODUCT_PATH",
            "ZDT_TOUCHED_TABLES",
            "ZDT_RUN_DIR",
            "ZDT_FLEET_BIN",
        ):
            self.assertIn(var, result.stdout)

    def test_list_shows_the_arms(self) -> None:
        result = self.run_arm("list")
        self.assertEqual(result.returncode, 0)
        self.assertIn("arm1", result.stdout)
        self.assertIn("arm2", result.stdout)
        self.assertIn("restore-snapshot", result.stdout)

    def test_unknown_arm_is_refused(self) -> None:
        result = self.run_arm("arm9")
        self.assertEqual(result.returncode, 2)

    # ---------------------------------------------------------------- settings

    def test_missing_host_stops_the_arm_by_name_and_reaches_nothing(self) -> None:
        env = {k: v for k, v in self.env.items() if k != "ZDT_NEW_NODE"}
        result = subprocess.run(
            [str(RUNNER), "arm1", "-y"],
            env=env,
            input="",
            capture_output=True,
            text=True,
            timeout=60,
            check=False,
        )
        self.assertEqual(result.returncode, 2)
        self.assertIn("ZDT_NEW_NODE", result.stderr)
        self.assertEqual(self.calls(), "")

    def test_rate_above_the_maximum_is_refused(self) -> None:
        result = self.run_arm("arm1", "-y", ZDT_RATE="21")
        self.assertEqual(result.returncode, 2)
        self.assertIn("maximum", result.stderr)
        self.assertEqual(self.calls(), "")

    def test_duration_above_the_maximum_is_refused(self) -> None:
        result = self.run_arm("arm1", "-y", ZDT_DURATION="601")
        self.assertEqual(result.returncode, 2)
        self.assertIn("maximum", result.stderr)

    def test_admin_node_split_from_new_node_is_refused(self) -> None:
        # setup:upgrade runs on the admin node from current; the new release
        # only lands on the new node. Split = the migration would run on the
        # old code, so refuse, naming both variables, and touch nothing.
        result = self.run_arm("arm1", "-y", ZDT_ADMIN_NODE="node2")
        self.assertEqual(result.returncode, 2)
        self.assertIn("ZDT_ADMIN_NODE", result.stderr)
        self.assertIn("ZDT_NEW_NODE", result.stderr)
        self.assertEqual(self.calls(), "")

    def test_missing_traffic_paths_are_refused(self) -> None:
        env = {
            k: v
            for k, v in self.env.items()
            if k not in ("ZDT_CATEGORY_PATH", "ZDT_PRODUCT_PATH")
        }
        result = subprocess.run(
            [str(RUNNER), "arm1", "-y"],
            env=env,
            input="",
            capture_output=True,
            text=True,
            timeout=60,
            check=False,
        )
        self.assertEqual(result.returncode, 2)
        self.assertIn("ZDT_CATEGORY_PATH", result.stderr)
        self.assertIn("ZDT_PRODUCT_PATH", result.stderr)
        self.assertEqual(self.calls(), "")

    def test_fewer_than_three_hosts_is_refused(self) -> None:
        result = self.run_arm(
            "arm1",
            "-y",
            ZDT_WEB_HOSTS="node1,node2",
            ZDT_NODE_URLS="http://node1/,http://node2/",
        )
        self.assertEqual(result.returncode, 2)
        self.assertIn("three web hosts", result.stderr)

    # ------------------------------------------------------------------- -n / -y

    def test_plan_runs_nothing_and_shows_the_whole_plan(self) -> None:
        result = self.run_arm("arm1", "-n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.calls(), "", "-n must reach no server")
        self.assertFalse(self.curl_calls.exists(), "-n must send no traffic")
        transcript = result.stdout + result.stderr
        self.assertIn("PLAN", transcript)
        self.assertNotIn("RUN ", transcript)
        # The plan must name every destructive step in run order — both
        # phases and the restore and relink between them — so what -y would
        # do is fully reviewable without running it.
        self.assertIn("phase: shared-prefix", transcript)
        self.assertIn("phase: per-release-prefix", transcript)
        self.assertIn("restore database magento", transcript)
        self.assertIn("link release rel-old back in", transcript)
        self.assertIn("/var/www/magento/zdt-snapshots/zdt-snapshot-", transcript)
        self.assertIn("snapshot database magento", transcript)
        self.assertEqual(transcript.count("setup:upgrade"), 2)
        self.assertIn(
            "cp -L --preserve=mode,ownership,timestamps "
            "/srv/magento/current/app/etc/env.php",
            transcript,
        )
        self.assertIn("replica-check", transcript)
        # The key Magento reads is id_prefix; backend_options is ignored.
        self.assertIn("id_prefix", transcript)
        self.assertNotIn("backend_options", transcript)
        # A cache prefix is the start of every cache id, and Magento refuses
        # an id with a hyphen in it; the new release's label has one.
        self.assertIn("id_prefix) to zdt_shared_ in", transcript)
        self.assertIn("id_prefix) to zdt_rel_new_ in", transcript)
        self.assertNotRegex(transcript, r"id_prefix\) to \S*-")
        # Every node reloads PHP-FPM after its env.php edit, in both phases.
        self.assertEqual(transcript.count("fpm-reload-cmd (so PHP-FPM reads the edited env.php)"), 6)
        self.assertIn("restore env.php from the dated backups on every node, and fpm-reload-cmd on each", transcript)

    def test_every_node_reloads_php_fpm_before_the_migration_and_after_the_restore(self) -> None:
        # OPcache never rechecks a file, so an env.php edit that is not
        # followed by a reload leaves the node on the settings the arm
        # started with, and the phase measures nothing it claims.
        result = self.run_arm("arm1", "-y")
        self.assertEqual(result.returncode, 0, f"{result.stdout}{result.stderr}")
        lines = self.calls().splitlines()
        upgrade = next(i for i, line in enumerate(lines) if "setup:upgrade" in line)
        for node in ("node1", "node2", "node3"):
            reloads = [i for i, line in enumerate(lines) if line.startswith(f"SSH|{node}|") and "fpm-reload-cmd" in line]
            # Two phases, each after the edit and after the restore, and once
            # more after the exit trap's own restore.
            self.assertEqual(len(reloads), 5, f"{node} reloads: {reloads}")
            self.assertLess(reloads[0], upgrade, f"{node} must serve the phase's settings before the migration")

    def test_declined_prompt_runs_nothing(self) -> None:
        result = self.run_arm("arm1", stdin="n\n")
        self.assertEqual(result.returncode, 2)
        self.assertIn("plan declined", result.stderr)
        # The prompt says "the plan above" — so the plan must be above it.
        transcript = result.stdout + result.stderr
        self.assertIn("PLAN", transcript)
        self.assertIn("setup:upgrade", transcript)
        self.assertEqual(self.calls(), "", "a declined plan reaches no server")

    def test_no_terminal_is_a_refusal_not_a_guess(self) -> None:
        # stdin closed: nobody could answer. The run never happened (2), it
        # did not fail and it certainly did not run.
        result = self.run_arm("arm1", stdin=None)
        self.assertEqual(result.returncode, 2)
        self.assertEqual(self.calls(), "")

    # ------------------------------------------------------------- secrets

    def test_transcript_carries_the_commands_never_the_password(self) -> None:
        result = self.run_arm("arm1", "-y")
        transcript = result.stdout + result.stderr
        self.assertNotIn("Sup3rSecretPw", transcript)
        self.assertIn("***", transcript)
        self.assertIn("snapshot database magento", transcript)
        # The password travels embedded in a remote script body (the design:
        # the body goes over ssh stdin, never argv). The guarantee the test
        # checks: no argv field and no transcript line ever carries it; the
        # body does, and that body is never echoed.
        self.assertIn("mysqldump", self.calls())
        # A restore must also remove what the migration created, or the next
        # phase finds the new table already there.
        self.assertIn("--add-drop-database", self.calls())
        for line in self.calls().splitlines():
            if line.startswith("SSH|"):
                argv_field = "|".join(line.split("|")[0:3])
                self.assertNotIn(
                    "Sup3rSecretPw",
                    argv_field,
                    "the password must never reach ssh argv",
                )
            elif line.startswith("RSYNC|"):
                self.assertNotIn("Sup3rSecretPw", line)

    # ------------------------------------------------------------- snapshot

    def test_failed_snapshot_stops_before_setup_upgrade(self) -> None:
        failfile = self.dir / "ssh-fail"
        failfile.write_text("node1|mysqldump\n")
        result = self.run_arm("arm1", "-y", FAKE_SSH_FAIL=str(failfile))
        self.assertEqual(result.returncode, 2, f"{result.stdout}{result.stderr}")
        self.assertIn("refusing to run setup:upgrade", result.stderr)
        calls = self.calls()
        self.assertIn("mysqldump", calls)  # the snapshot was attempted
        self.assertNotIn("setup:upgrade", calls)  # and stopped before this
        # The dated backups already happened — env edits precede the snapshot
        # — but no upgrade and no traffic: the run never happened.
        self.assertFalse(self.curl_calls.exists())

    def _assert_arm_dies_on(self, rule: str) -> None:
        # A step of the destructive core failing must stop the arm (2) with
        # no PASS line: an arm that exits 0 after setup:upgrade never ran is
        # worse than one that stops.
        failfile = self.dir / "ssh-fail"
        failfile.write_text(rule + "\n")
        result = self.run_arm("arm1", "-y", FAKE_SSH_FAIL=str(failfile))
        self.assertNotEqual(result.returncode, 0, f"{rule}: {result.stdout}")
        self.assertNotIn("PASS", result.stdout, f"{rule}: a PASS line after a dead step")

    def test_the_migration_keeps_the_releases_compiled_code(self) -> None:
        # The playbook's deploy runs setup:upgrade with --keep-generated; a plain
        # one deletes generated/ and pub/static/ in production mode, so the new
        # node would fail on the arm's command rather than on the deploy.
        result = self.run_arm("arm1", "-y")
        self.assertEqual(result.returncode, 0, f"{result.stdout}{result.stderr}")
        upgrades = [line for line in self.calls().splitlines() if "bin/magento setup:upgrade" in line]
        self.assertEqual(len(upgrades), 2, "one migration per phase")
        for line in upgrades:
            self.assertIn("setup:upgrade --keep-generated --no-interaction", line)

    def test_failed_setup_upgrade_stops_the_arm(self) -> None:
        self._assert_arm_dies_on("node1|bin/magento setup:upgrade")

    def test_failed_release_placement_stops_the_arm(self) -> None:
        self._assert_arm_dies_on("node1|tar -xzf")  # the unpack step

    def test_failed_env_edit_on_an_old_node_stops_the_arm(self) -> None:
        self._assert_arm_dies_on("node2|id_prefix")

    # ------------------------------------------------------------ env backups

    def test_backup_happens_before_any_edit_on_every_node(self) -> None:
        result = self.run_arm("arm1", "-y")
        self.assertEqual(result.returncode, 0, f"{result.stdout}{result.stderr}")
        lines = [line for line in self.calls().splitlines() if line.startswith("SSH|")]
        # backend_options.cache_prefix is a key Magento ignores; the prefix
        # lives in id_prefix (the P1-1 proof reads it back from there).
        for line in lines:
            self.assertNotIn("backend_options", line)
        for node in ("node1", "node2", "node3"):
            host_lines = [l for l in lines if l.startswith(f"SSH|{node}|")]
            backs = [
                i for i, l in enumerate(host_lines) if "cp -L " in l and ".bak-" in l
            ]
            edits = [
                i
                for i, l in enumerate(host_lines)
                if "id_prefix" in l and "cp -L" not in l
            ]
            self.assertTrue(
                edits, f"{node}: no cache-prefix edit on id_prefix"
            )
            self.assertTrue(backs, f"{node}: no dated env.php backup")
            self.assertTrue(edits, f"{node}: env.php was never edited")
            self.assertLess(
                min(backs), min(edits), f"{node}: env.php was edited before its backup"
            )

    def test_printed_restore_commands_are_correct(self) -> None:
        result = self.run_arm("arm1", "-y")
        transcript = result.stdout + result.stderr
        for node in ("node1", "node2", "node3"):
            pattern = (
                rf"ssh -o BatchMode=yes {node} cp --preserve=mode,ownership,timestamps "
                rf"/srv/magento/current/app/etc/env\.php\.bak-\d{{8}}T\d{{6}}Z "
                rf"/srv/magento/current/app/etc/env\.php"
            )
            self.assertRegex(transcript, pattern)
        snap = re.search(r"bin/zdt-arm restore-snapshot (\S+)", transcript)
        self.assertIsNotNone(snap, "the snapshot restore command must be printed too")
        self.assertIn("zdt-snapshot-", snap.group(1))

    def test_env_backup_and_restore_survive_the_env_php_symlink(self) -> None:
        # env.php is deployed as a symlink to the shared copy. A backup that
        # copies the symlink instead of its contents loses the original on
        # every node: the edit changes what both names point to, and the
        # restore would put the edited bytes back. The arm's own primitives
        # — backup, set, restore — run against real files here (the fake
        # ssh executes what it receives under a per-host root); afterwards
        # the shared file's bytes must match the original, and the dated
        # backup on disk must hold the original bytes too.
        import shutil

        php = shutil.which("php")
        if php is None:
            self.skipTest("needs php on PATH")
        # The fake's execute mode roots each host at $FAKE_SSH_RUN/<host>/,
        # so the tree it will edit lives there.
        node = self.dir / "hosts" / "host"
        etc = node / "current" / "app" / "etc"
        shared = node / "shared"
        etc.mkdir(parents=True)
        shared.mkdir()
        original = (
            "<?php\nreturn ['cache' => ['frontend' => ['default' => "
            "['backend' => 'file', 'id_prefix' => 'orig']]]];\n"
        )
        shared_file = shared / "env.php"
        shared_file.write_text(original)
        (etc / "env.php").symlink_to(shared_file)
        snippet = (
            'ARM_DIR="' + str(ROOT / "bin" / "zdt-arm.d") + '"; '
            'source "$ARM_DIR/lib.sh"; '
            'env_backup host && '
            'env_set host cache.frontend.default.id_prefix "\\"zdt-edited\\"" && '
            'restore_env_files'
        )
        env = dict(self.env)
        env["FAKE_SSH_RUN"] = str(self.dir / "hosts")
        ran = subprocess.run(
            ["bash", "-c", snippet],
            env=env,
            capture_output=True,
            text=True,
            timeout=60,
            check=False,
        )
        self.assertEqual(ran.returncode, 0, f"{ran.stdout}{ran.stderr}")
        backed_up = sorted((etc).glob("env.php.bak-*"))
        self.assertEqual(len(backed_up), 1, "no dated backup was made")
        self.assertTrue(backed_up[0].is_file() and not backed_up[0].is_symlink(),
            "the backup must be a real file, not a second symlink")
        self.assertEqual(backed_up[0].read_text(), original,
            "the backup lost the original bytes")
        self.assertEqual(shared_file.read_text(), original,
            "the shared env.php's bytes changed through backup/edit/restore")

    def test_blue_green_flag_is_set_on_old_servers_only(self) -> None:
        result = self.run_arm("arm2", "-y")
        self.assertEqual(result.returncode, 0, f"{result.stdout}{result.stderr}")
        lines = self.calls().splitlines()
        new_blue = [
            l for l in lines if l.startswith("SSH|node1|") and "blue_green" in l
        ]
        old_blue = [
            l for l in lines if l.startswith("SSH|node2|") and "blue_green" in l
        ]
        old_blue += [
            l for l in lines if l.startswith("SSH|node3|") and "blue_green" in l
        ]
        self.assertEqual(new_blue, [], "the always-new node must not take the flag")
        self.assertTrue(old_blue, "the old servers must take the flag in arm 2")
        # arm 1 must NOT set it anywhere.
        self.calls_file.unlink()
        result = self.run_arm("arm1", "-y")
        self.assertEqual(result.returncode, 0, f"{result.stdout}{result.stderr}")
        self.assertNotIn("blue_green", self.calls())

    # ---------------------------------------------------------------- traffic

    def test_generator_stops_at_the_duration(self) -> None:
        start = time.monotonic()
        result = self.run_arm("arm1", "-y")
        elapsed = time.monotonic() - start
        self.assertEqual(result.returncode, 0, f"{result.stdout}{result.stderr}")
        logs = [
            (self.dir / "run" / f"traffic-{phase}.log").read_text().splitlines()
            for phase in ("shared-prefix", "per-release-prefix")
        ]
        # duration 1s at 1/s over 3 nodes + the LB, one phase: exactly 4.
        # The generator sends total = duration * rate per target and no more,
        # and each phase's verdict counts its own log alone.
        for log in logs:
            self.assertEqual(len(log), 4, "the generator must stop at the duration")
        self.assertLess(elapsed, 30, "a short run must finish at once")

    def test_traffic_outlasts_a_migration_slower_than_the_duration(self) -> None:
        # A fixed window stopped before a slow migration did, and arm 3's
        # evidence leg then saw no old server after the change. Every fake ssh
        # round-trip takes a second here, so the migration ends well past the
        # one-second duration; traffic must still be running after it.
        events = self.dir / "maint-events"
        result = self.run_arm(
            "arm1", "-y", FAKE_SSH_SLEEP="1", ZDT_TRAFFIC_TAIL="1",
            FAKE_MAINT_EVENTS=str(events),
        )
        self.assertEqual(result.returncode, 0, f"{result.stdout}{result.stderr}")
        upgrades = [float(line.split("|")[0]) for line in events.read_text().splitlines()
                    if "|setup:upgrade|" in line]
        self.assertEqual(len(upgrades), 2, "one migration per phase")
        log = (self.dir / "run" / "traffic-shared-prefix.log").read_text().splitlines()
        last = max(int(line.split()[0]) for line in log)
        # The fake records the upgrade when its one-second call ends; the old
        # fixed window had stopped a second or more before that.
        self.assertGreaterEqual(last, int(upgrades[0]),
                                "traffic stopped before the migration was over")

    def test_a_bad_traffic_tail_is_refused(self) -> None:
        for value in ("abc", "601"):
            result = self.run_arm("arm1", "-y", ZDT_TRAFFIC_TAIL=value)
            self.assertEqual(result.returncode, 2, value)
            self.assertIn("ZDT_TRAFFIC_TAIL", result.stderr)
            self.assertEqual(self.calls(), "", f"{value}: refused before any server")

    def test_traffic_asks_for_the_configured_paths(self) -> None:
        result = self.run_arm("arm1", "-y", ZDT_RATE="7")
        self.assertEqual(result.returncode, 0, f"{result.stdout}{result.stderr}")
        curl = self.curl_calls.read_text()
        for path in ("/mens.html", "/products/gt.html", "/checkout/cart/",
                     "/rest/V1/directory/currency", "/graphql?query=",
                     "/health_check.php"):
            self.assertIn(path, curl, f"the mix never asked for {path}")

    def test_a_missing_route_404_is_not_a_refusal(self) -> None:
        # A route answering 404 mid-migration is a fact for traffic.log, not
        # a server refusing: the target must not be listed as refusing.
        result = self.run_arm(
            "arm1", "-y", ZDT_RATE="7", FAKE_CURL_NOTFOUND="/mens.html"
        )
        self.assertEqual(result.returncode, 0, f"{result.stdout}{result.stderr}")
        self.assertIn("PASS  falsifier 5", result.stdout)
        refused_line = [
            l for l in result.stdout.splitlines() if "targets that refused" in l
        ]
        self.assertTrue(refused_line)
        self.assertIn("targets that refused: none", refused_line[0])
        # The 404 is still recorded: it is in each phase's log, as a fact.
        log = (self.dir / "run" / "traffic-shared-prefix.log").read_text()
        self.assertIn(" 404 ", log)

    def test_refusing_node_taken_out_by_haproxy_is_a_falsifier_5_fail(self) -> None:
        # rate 7 x duration 1 sends one of each of the 7 request types to
        # every target, health included: the mix the issue names.
        result = self.run_arm(
            "arm1",
            "-y",
            ZDT_RATE="7",
            FAKE_CURL_DOWN="node2.example",
            FAKE_LB_TAKEN_OUT="node2",
        )
        self.assertEqual(result.returncode, 1)
        self.assertIn(
            "FAIL  falsifier 5: HAProxy took node2 out of rotation 1 time(s), 5s out in all",
            result.stdout,
        )
        # Guard messages are reported as facts, attributed per target.
        self.assertIn("matched ZDT_GUARD_PATTERN", result.stdout)

    def test_a_failed_health_probe_alone_is_not_a_falsifier_5_fail(self) -> None:
        # Our own probe of health_check.php failing is not the node leaving
        # rotation: only HAProxy's count decides, and here it took nothing out.
        result = self.run_arm(
            "arm1",
            "-y",
            ZDT_RATE="7",
            FAKE_CURL_DOWN="node2.example",
            FAKE_CURL_HEALTH_DOWN="node2.example",
        )
        self.assertEqual(result.returncode, 0, f"{result.stdout}{result.stderr}")
        self.assertIn("PASS  falsifier 5", result.stdout)
        self.assertIn("HAProxy took out of rotation this phase: none", result.stdout)

    def test_a_node_taken_out_that_refused_nothing_passes_and_is_listed(self) -> None:
        result = self.run_arm(
            "arm1", "-y", ZDT_RATE="7", FAKE_CURL_DOWN="node2.example", FAKE_LB_TAKEN_OUT="node3"
        )
        self.assertEqual(result.returncode, 0, f"{result.stdout}{result.stderr}")
        self.assertIn("PASS  falsifier 5", result.stdout)
        self.assertIn("HAProxy took out of rotation this phase: node3 1x 5s", result.stdout)

    def test_unanswered_haproxy_stats_stop_the_arm_before_its_traffic(self) -> None:
        result = self.run_arm("arm1", "-y", FAKE_LB_STATS_DOWN="1")
        self.assertEqual(result.returncode, 2)
        self.assertIn("ZDT_LB_STATS_URL", result.stderr)
        sent = self.curl_calls.read_text() if self.curl_calls.exists() else ""
        self.assertNotIn("health_check", sent, "no traffic may start without the stats")

    def test_haproxy_without_a_web_host_stops_the_arm_by_name(self) -> None:
        result = self.run_arm("arm1", "-y", FAKE_LB_SERVERS="node1,node2")
        self.assertEqual(result.returncode, 2)
        self.assertIn("HAProxy has no server named node3", result.stderr)

    def test_haproxy_counts_going_backwards_are_not_judged(self) -> None:
        result = self.run_arm("arm1", "-y", FAKE_LB_BACKWARDS="node2")
        self.assertEqual(result.returncode, 1)
        self.assertIn("FAIL  falsifier 5: not judged", result.stdout)
        self.assertIn("went backwards for node2", result.stdout)

    def test_missing_haproxy_stats_url_is_refused_by_name(self) -> None:
        env = {k: v for k, v in self.env.items() if k != "ZDT_LB_STATS_URL"}
        result = subprocess.run(
            [str(RUNNER), "arm1", "-y"],
            env=env,
            input="",
            capture_output=True,
            text=True,
            timeout=60,
            check=False,
        )
        self.assertEqual(result.returncode, 2)
        self.assertIn("ZDT_LB_STATS_URL", result.stderr)
        self.assertEqual(self.calls(), "")

    def test_healthy_run_passes_falsifier_5_and_records_guard_facts(self) -> None:
        result = self.run_arm(
            "arm1", "-y", ZDT_RATE="7", FAKE_CURL_DOWN="node2.example"
        )
        self.assertEqual(result.returncode, 0, f"{result.stdout}{result.stderr}")
        self.assertIn("PASS  falsifier 5", result.stdout)
        self.assertIn("PASS  falsifier 1", result.stdout)
        # Two phases, two falsifiers each.
        self.assertIn("summary: 4 pass, 0 fail", result.stdout)

    # ------------------------------------------------------ taking a node out

    def _drain_order(self) -> list[str]:
        # The run's steps that matter here, in order: the node out, its
        # release unpacked, the migration, the node back in.
        steps = []
        for line in self.calls().splitlines():
            if line.startswith("DRAIN|"):
                steps.append(line.removeprefix("DRAIN|"))
            elif line.startswith("SSH|node1|") and "tar -xzf" in line:
                steps.append("unpack")
            elif line.startswith("SSH|node1|") and "setup:upgrade" in line:
                steps.append("upgrade")
        return steps

    def test_without_lb_drain_no_node_leaves_the_load_balancer(self) -> None:
        result = self.run_arm("arm1", "-y")
        self.assertEqual(result.returncode, 0, f"{result.stdout}{result.stderr}")
        self.assertNotIn("DRAIN|", self.calls())

    def test_lb_drain_takes_the_new_node_out_before_its_release_and_back_after(self) -> None:
        result = self.run_arm("arm1", "-y", ZDT_LB_DRAIN=self.lb_drain)
        self.assertEqual(result.returncode, 0, f"{result.stdout}{result.stderr}")
        phase = ["node1 maint", "unpack", "upgrade", "node1 ready"]
        self.assertEqual(self._drain_order(), phase + phase)

    def test_lb_drain_covers_both_crossings_of_arm3(self) -> None:
        result = self.run_arm("arm3", "-y", ZDT_LB_DRAIN=self.lb_drain)
        self.assertIn("summary:", result.stdout, f"{result.stdout}{result.stderr}")
        phase = ["node1 maint", "unpack", "upgrade", "node1 ready"]
        self.assertEqual(self._drain_order(), phase + phase)

    def test_a_failed_upgrade_still_puts_the_node_back(self) -> None:
        failfile = self.dir / "ssh-fail"
        failfile.write_text("node1|bin/magento setup:upgrade\n")
        result = self.run_arm(
            "arm1", "-y", ZDT_LB_DRAIN=self.lb_drain, FAKE_SSH_FAIL=str(failfile)
        )
        self.assertEqual(result.returncode, 2)
        drains = [s for s in self._drain_order() if s.startswith("node1 ")]
        self.assertEqual(drains, ["node1 maint", "node1 ready"])

    def test_a_node_that_will_not_leave_stops_the_arm_before_its_release(self) -> None:
        result = self.run_arm(
            "arm1", "-y", ZDT_LB_DRAIN=self.lb_drain, FAKE_LB_DRAIN_FAIL="maint"
        )
        self.assertEqual(result.returncode, 2)
        self.assertIn("could not be taken out of the load balancer", result.stderr)
        self.assertNotIn("unpack", self._drain_order())

    def test_plan_names_the_take_out_and_the_return_only_when_set(self) -> None:
        plain = self.run_arm("arm1", "-n")
        self.assertNotIn("maint (out of the load balancer", plain.stdout)
        drained = self.run_arm("arm1", "-n", ZDT_LB_DRAIN=self.lb_drain)
        self.assertIn(f"{self.lb_drain} node1 maint (out of the load balancer", drained.stdout)
        self.assertIn(f"{self.lb_drain} node1 ready, once it answers 200", drained.stdout)
        self.assertNotIn("DRAIN|", self.calls(), "-n must take nothing out")

    # ------------------------------------------------------------- replica gate

    def test_dead_replica_is_reported_as_not_run(self) -> None:
        bad = (
            MYSQL8_HEADERS
            + "\n"
            + status_row(sql_running="No", sql_errno="1032")
            + "\n"
        )
        self.canned("replica.db", "SHOW REPLICA STATUS", bad)
        result = self.run_arm("arm1", "-y")
        self.assertEqual(result.returncode, 1)
        self.assertIn("NOT RUN", result.stdout + result.stderr)
        self.assertIn("condition 1", result.stdout + result.stderr)
        self.assertEqual(self.calls(), "", "a refused gate reaches no node")

    # ---------------------------------------------------------- restore-snapshot

    def test_restore_snapshot_plans_redacted_and_runs_with_y(self) -> None:
        snap = "/srv/zdt-snapshots/zdt-snapshot-x.sql.gz"
        planned = self.run_arm("restore-snapshot", snap, "-n")
        self.assertEqual(planned.returncode, 0, planned.stderr)
        self.assertIn("restore database magento", planned.stdout)
        self.assertNotIn("Sup3rSecretPw", planned.stdout)
        self.assertIn("***", planned.stdout)
        self.assertEqual(self.calls(), "")
        ran = self.run_arm("restore-snapshot", snap, "-y")
        self.assertEqual(ran.returncode, 0, f"{ran.stdout}{ran.stderr}")
        self.assertIn("gunzip", self.calls())
        ran_transcript = ran.stdout + ran.stderr
        self.assertNotIn("Sup3rSecretPw", ran_transcript)
        self.assertIn("***", ran_transcript)

    def test_restore_snapshot_refuses_a_relative_path(self) -> None:
        result = self.run_arm("restore-snapshot", "oops.sql.gz", "-y")
        self.assertEqual(result.returncode, 2)


    # ------------------------------------------------------------------ arm 3

    def test_help_lists_the_arm3_variables(self) -> None:
        result = self.run_arm("--help")
        for var in (
            "ZDT_RELEASE_ADDITIVE",
            "ZDT_LABEL_ADDITIVE",
            "ZDT_RELEASE_BREAKING",
            "ZDT_LABEL_BREAKING",
            "ZDT_READ_PATH",
            "ZDT_SCHEMA_OBJECT",
        ):
            self.assertIn(var, result.stdout)

    def test_list_shows_arm3(self) -> None:
        result = self.run_arm("list")
        self.assertIn("arm3", result.stdout)

    def test_arm3_missing_crossing_variables_refused_by_name(self) -> None:
        env = {
            k: v
            for k, v in self.env.items()
            if k not in ("ZDT_READ_PATH", "ZDT_SCHEMA_OBJECT")
        }
        result = subprocess.run(
            [str(RUNNER), "arm3", "-y"],
            env=env,
            input="",
            capture_output=True,
            text=True,
            timeout=60,
            check=False,
        )
        self.assertEqual(result.returncode, 2)
        self.assertIn("ZDT_READ_PATH", result.stderr)
        self.assertIn("ZDT_SCHEMA_OBJECT", result.stderr)
        self.assertEqual(self.calls(), "")

    def test_arm3_arm1_and_arm2_ignore_the_crossing_variables(self) -> None:
        # Dropping arm 3's variables must not disturb the other arms: they
        # never ask for them.
        env = {
            k: v
            for k, v in self.env.items()
            if k
            not in (
                "ZDT_RELEASE_ADDITIVE",
                "ZDT_LABEL_ADDITIVE",
                "ZDT_RELEASE_BREAKING",
                "ZDT_LABEL_BREAKING",
                "ZDT_READ_PATH",
                "ZDT_SCHEMA_OBJECT",
            )
        }
        result = subprocess.run(
            [str(RUNNER), "arm1", "-y"],
            env=env,
            input="",
            capture_output=True,
            text=True,
            timeout=120,
            check=False,
        )
        self.assertEqual(result.returncode, 0, f"{result.stdout}{result.stderr}")

    def test_arm3_plan_shows_both_crossings_and_runs_nothing(self) -> None:
        result = self.run_arm("arm3", "-n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.calls(), "", "-n must reach no server")
        self.assertFalse(self.curl_calls.exists(), "-n must send no traffic")
        transcript = result.stdout + result.stderr
        self.assertIn("crossing: additive-control (rel-add)", transcript)
        self.assertIn("crossing: breaking-evidence (rel-break)", transcript)
        self.assertIn("restore database magento", transcript)
        self.assertIn("link release rel-old back in", transcript)
        self.assertIn("/var/www/magento/zdt-snapshots/zdt-snapshot-", transcript)
        self.assertEqual(transcript.count("setup:upgrade"), 2)
        self.assertIn("/products/gt.html", transcript)  # the named read path
        self.assertIn("id_prefix", transcript)
        self.assertNotIn("backend_options", transcript)
        self.assertNotIn("Sup3rSecretPw", transcript)

    def test_arm3_breaking_failure_naming_the_object_passes_falsifier_3(self) -> None:
        # node2's read path fails across both crossings naming the object.
        # Control: node2 is an old server, so the control must FAIL there too
        # — but only on the guard-message rule; a 503 without the guard text
        # is not a control failure. Then the breaking leg's first saved
        # failure names gift_registry_id: falsifier 3 PASSes on evidence.
        result = self.run_arm(
            "arm3", "-y", ZDT_RATE="8",
            FAKE_CURL_BREAK_READ="node2.example",
        )
        self.assertIn("PASS  falsifier 3 (control)", result.stdout)
        self.assertIn("PASS  falsifier 3:", result.stdout)
        self.assertIn("names gift_registry_id", result.stdout)
        self.assertEqual(result.returncode, 0, f"{result.stdout}{result.stderr}")

    def test_arm3_first_failure_not_naming_the_object_fails(self) -> None:
        result = self.run_arm(
            "arm3", "-y", ZDT_RATE="8",
            FAKE_CURL_BREAK_READ="node2.example",
            FAKE_CURL_BREAK_BODY="SQLSTATE[42S02]: Base table not found: 1146",
        )
        self.assertIn("FAIL  falsifier 3:", result.stdout)
        self.assertIn("does not name gift_registry_id", result.stdout)
        self.assertEqual(result.returncode, 1)

    def test_arm3_old_servers_passing_across_the_breaking_release_fail(self) -> None:
        # Nothing fails on the read path: either the release does not break
        # what the read path reads, or old servers served a schema they do
        # not match. Either way falsifier 3 FAILS — it never passes by
        # silence.
        result = self.run_arm("arm3", "-y", ZDT_RATE="8")
        self.assertIn("FAIL  falsifier 3:", result.stdout)
        self.assertEqual(result.returncode, 1)

    def test_arm3_guard_message_on_an_old_server_fails_both_legs(self) -> None:
        # The flag is ON in arm 3: a guard message across either crossing
        # disproves falsifier 3's claim about the flag.
        result = self.run_arm(
            "arm3", "-y", ZDT_RATE="8",
            FAKE_CURL_BREAK_READ="node2.example",
            FAKE_CURL_BREAK_BODY="Please refresh the page",
        )
        self.assertIn("FAIL  falsifier 3 (control)", result.stdout)
        self.assertIn("FAIL  falsifier 3:", result.stdout)
        self.assertEqual(result.returncode, 1)

    def test_arm3_guard_on_the_new_node_does_not_blame_old_servers(self) -> None:
        # place_new_release links the breaking code on the new node BEFORE
        # setup:upgrade, so for that window the new node can answer the guard
        # message with the flag off. Falsifier 3 counts old servers only: the
        # guard rule fires on node1 (the new node), the read failure on node2,
        # and both legs must still PASS.
        result = self.run_arm(
            "arm3", "-y", ZDT_RATE="8",
            FAKE_CURL_DOWN="node1.example",
            FAKE_CURL_BREAK_READ="node2.example",
        )
        self.assertIn("PASS  falsifier 3 (control)", result.stdout)
        self.assertIn("PASS  falsifier 3:", result.stdout)
        self.assertIn("names gift_registry_id", result.stdout)
        self.assertNotIn("FAIL  falsifier 3", result.stdout)
        self.assertEqual(result.returncode, 0, f"{result.stdout}{result.stderr}")

    def test_arm3_first_failure_counts_only_old_server_bodies(self) -> None:
        # The load balancer's read failure lands too, with a body that does
        # not name the object. The verdict is the old servers' first failure,
        # not whichever body finished first: node2's body names the object,
        # so falsifier 3 PASSes and names node2.example as the source.
        result = self.run_arm(
            "arm3", "-y", ZDT_RATE="8",
            FAKE_CURL_BREAK_READ="node2.example",
            FAKE_CURL_BREAK_READ2="lb.example",
            FAKE_CURL_BREAK_BODY2="SQLSTATE[HY000]: unrelated",
        )
        self.assertIn("PASS  falsifier 3:", result.stdout)
        self.assertIn("first old-server failure on node2.example names gift_registry_id", result.stdout)
        self.assertEqual(result.returncode, 0, f"{result.stdout}{result.stderr}")

    def test_arm3_saves_the_first_failures_body_as_evidence(self) -> None:
        result = self.run_arm(
            "arm3", "-y", ZDT_RATE="8",
            FAKE_CURL_BREAK_READ="node2.example",
        )
        self.assertEqual(result.returncode, 0, f"{result.stdout}{result.stderr}")
        evidence = self.dir / "run" / "evidence-breaking-evidence"
        bodies = sorted(evidence.iterdir())
        self.assertTrue(bodies, "no failure bodies saved for the breaking leg")
        self.assertTrue(
            any("gift_registry_id" in b.read_text() for b in bodies),
            "no saved body names the schema object",
        )

    def test_arm3_sets_the_flag_on_old_servers_only(self) -> None:
        self.run_arm("arm3", "-y")
        lines = [l for l in self.calls().splitlines() if l.startswith("SSH|")]
        for node in ("node2", "node3"):
            self.assertTrue(
                any(l.startswith(f"SSH|{node}|") and "blue_green" in l for l in lines),
                f"{node}: arm 3 must set the flag on the old servers",
            )
        self.assertEqual(
            [l for l in lines if l.startswith("SSH|node1|") and "blue_green" in l],
            [],
            "the always-new node must not take the flag",
        )

    # ------------------------------------------------------------------ arm 4

    def test_arm4_missing_release_refused_by_name(self) -> None:
        env = {
            k: v
            for k, v in self.env.items()
            if k not in ("ZDT_RELEASE_BREAKING", "ZDT_LABEL_BREAKING")
        }
        result = subprocess.run(
            [str(RUNNER), "arm4", "-y"],
            env=env,
            input="",
            capture_output=True,
            text=True,
            timeout=60,
            check=False,
        )
        self.assertEqual(result.returncode, 2)
        self.assertIn("ZDT_RELEASE_BREAKING", result.stderr)
        self.assertIn("ZDT_LABEL_BREAKING", result.stderr)
        self.assertEqual(self.calls(), "")

    def test_arm4_plan_shows_both_legs_and_runs_nothing(self) -> None:
        result = self.run_arm("arm4", "-n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.calls(), "", "-n must reach no server")
        self.assertFalse(self.curl_calls.exists(), "-n must send no traffic")
        transcript = result.stdout + result.stderr
        self.assertIn("outage: rollout (rel-break)", transcript)
        self.assertIn("outage: maintenance (rel-break)", transcript)
        # The maintenance leg's whole shape: the page goes up in the release
        # `current` points at today (rel-old), then each node is linked to the
        # breaking release with the flag already raised inside it — two
        # enables per node — and both flags are printed as lifted.
        self.assertEqual(transcript.count("maintenance:enable"), 6)  # 3 nodes × 2
        self.assertEqual(transcript.count("maintenance:disable"), 6)  # rel-break + rel-old
        self.assertIn(
            "maintenance:enable in /var/www/magento/releases/rel-old", transcript
        )
        self.assertIn("maintenance:disable in /var/www/magento/releases/rel-break", transcript)
        self.assertIn("restore database magento", transcript)
        self.assertIn("link release rel-old back in", transcript)
        self.assertEqual(transcript.count("setup:upgrade"), 2)
        self.assertNotIn("Sup3rSecretPw", transcript)

    def test_arm4_maintenance_leg_enables_every_node_then_disables(self) -> None:
        result = self.run_arm("arm4", "-y", FAKE_CURL_DOWN="node2.example")
        lines = [l for l in self.calls().splitlines() if l.startswith("SSH|")]
        # Two enables per node, in this order: the run's own, in the release
        # `current` points at, then the one that rides along with the link
        # into the breaking release. Every one of them lands in the
        # maintenance leg: the rollout leg never touches maintenance.
        for node in ("node1", "node2", "node3"):
            own = [i for i, l in enumerate(lines) if l.startswith(f"SSH|{node}|") and "maintenance:enable" in l]
            self.assertEqual(len(own), 2, f"{node}: want 2 enables, got {own}")
            self.assertIn("releases/rel-old", lines[own[0]], f"{node}: the first enable is the old release's")
            self.assertNotIn("rel-break", lines[own[0]], f"{node}: the first enable is the old release's")
        upgrades = [i for i, l in enumerate(lines) if "setup:upgrade" in l]
        self.assertEqual(len(upgrades), 2)
        first_maint_enable = min(
            i for i, l in enumerate(lines) if "maintenance:enable" in l and "rel-old" in l
        )
        self.assertTrue(
            all(u < first_maint_enable for u in upgrades[:1]),
            "the rollout leg's upgrade comes before any maintenance",
        )
        disables = [l for l in lines if "maintenance:disable" in l]
        self.assertTrue(disables, "the maintenance leg must lift maintenance")
        self.assertTrue(
            any("rel-break" in l for l in disables), "the new release's flag must be lifted"
        )
        self.assertTrue(
            any("rel-old" in l for l in disables), "the old release's flag must be lifted too"
        )
        self.assertEqual(result.returncode, 1, result.stdout)  # see below

    def test_arm4_verdict_compares_the_two_legs(self) -> None:
        # Both legs run the same fake failure (node2 down), so both fail the
        # same share: the rollout is NOT strictly worse, and falsifier 4
        # FAILS rather than passing by equality. The comparison itself is
        # pinned exactly by test_arm4_verdict_math below.
        result = self.run_arm("arm4", "-y", FAKE_CURL_DOWN="node2.example")
        self.assertIn("FAIL  falsifier 4:", result.stdout)
        self.assertIn("rollout failed", result.stdout)
        self.assertIn("outage-report-rollout.txt", result.stdout)
        for leg in ("rollout", "maintenance"):
            report = self.dir / "run" / f"outage-report-{leg}.txt"
            self.assertTrue(report.exists(), f"no report for {leg}")
            text = report.read_text()
            self.assertIn("TOTAL", text)
            # Health rows never appear in the per-second shares: no customer
            # asks for the health check.
            self.assertNotIn(" health ", text)

    def test_arm4_verdict_math(self) -> None:
        # The comparison, unit-level: strictly more requests AND strictly more
        # seconds is a PASS; anything else is the falsifier's FAIL, per the
        # issue's "false if".
        snippet = (
            'ARM_DIR="' + str(ROOT / "bin" / "zdt-arm.d") + '"; '
            'source "$ARM_DIR/lib.sh" 2>/dev/null || true; '
            'falsifier4_verdict 4 2 1 1; falsifier4_verdict 4 2 4 1; '
            'falsifier4_verdict 4 2 3 2; falsifier4_verdict 5 3 4 3'
        )
        ran = subprocess.run(
            ["bash", "-c", snippet],
            capture_output=True,
            text=True,
            timeout=30,
            check=False,
        )
        out = ran.stdout
        self.assertEqual(out.count("PASS  falsifier 4"), 1)
        self.assertEqual(out.count("FAIL  falsifier 4"), 3)

    def test_arm4_restores_maintenance_after_a_failed_step(self) -> None:
        # Mid-maintenance-leg failure: the trap must still lift maintenance
        # on every node it had enabled — a store left behind the maintenance
        # page by a failed proof run is worse than the failed run. Here the
        # enable on node3 fails, after node1 and node2 went under.
        failfile = self.dir / "ssh-fail"
        failfile.write_text("node3|maintenance:enable\n")
        result = self.run_arm("arm4", "-y", FAKE_SSH_FAIL=str(failfile))
        self.assertNotEqual(result.returncode, 0)
        lines = [l for l in self.calls().splitlines() if l.startswith("SSH|")]
        disabled = [l for l in lines if "maintenance:disable" in l]
        # The fake records a call before its fail rule bites, so node3's
        # failed enable is in the log; what matters is that every node that
        # went under maintenance comes out, and nothing else is touched.
        self.assertEqual(
            {l.split("|")[1] for l in disabled}, {"node1", "node2"},
            "a failed maintenance leg must still lift maintenance everywhere it went in",
        )

    def test_arm4_maintenance_leg_lifts_every_node_after_the_upgrade(self) -> None:
        # Blocker (Ed's flag-file test, second round): the flag lives INSIDE
        # the release that wrote it, and var/ is not shared between releases.
        # The fake ssh therefore keys the flag by the release the command runs
        # in ($FAKE_MAINT_FLAGS/<host>/<label>) and tracks each host's
        # `current` from the last `ln -sfn` it saw; the fake curl answers 503
        # while the release `current` resolves to carries the flag.
        #
        # The window is judged in ssh-call positions, not wall-clock seconds:
        # the fake curl records how many ssh calls had been logged when it
        # answered, so "while the page was up" is exact and cannot flake on a
        # loaded runner. On the code before this round the flag was raised in
        # the old release and then left behind when the link moved `current`
        # to the new one, so both (a) and (b) below fail there.
        flags = self.dir / "maint-flags"
        flags.mkdir()
        current = self.dir / "maint-current"
        events = self.dir / "maint-events"
        indexed = self.dir / "curl-indexed"
        result = self.run_arm(
            "arm4", "-y",
            FAKE_MAINT_FLAGS=str(flags), FAKE_MAINT_CURRENT=str(current),
            FAKE_MAINT_EVENTS=str(events), FAKE_CURL_INDEXED=str(indexed),
            # Every ssh round-trip takes real time, so the window between the
            # first enable and the migration holds many requests: without it
            # the window is one or two requests per node and the assertion
            # has no teeth. A batch of RATE requests carries one of every
            # request type, so each second of the window holds a non-health
            # request on every node.
            FAKE_SSH_SLEEP="0.8",
            ZDT_DURATION="12", ZDT_RATE="5",
        )
        lines = [l for l in self.calls().splitlines() if l.startswith("SSH|")]
        # Position of each maintenance call, as the fake curl counts them.
        def call_pos(host: str, needle: str, which: str = "one") -> int:
            hits = [
                i + 1 for i, l in enumerate(lines)
                if l.startswith(f"SSH|{host}|") and needle in l
            ]
            if which == "one":
                self.assertEqual(len(hits), 1, f"{host}: want exactly one call with {needle!r}")
                return hits[0]
            # The maintenance leg is the second of the two legs, so its calls
            # are the last of each kind (setup:upgrade runs once per leg).
            self.assertTrue(hits, f"{host}: no call with {needle!r}")
            return hits[-1]

        node_rel = "releases/rel-old"
        new_rel = "releases/rel-break"
        # (a) From the last node's enable (the fleet-wide start of the page)
        # until the migration, every non-health request to a web node came
        # back as the maintenance page: the page is up across the link into
        # the breaking release, and nothing serves while it is meant to be
        # behind it. Positions, not seconds, are what the assertion compares,
        # so a loaded runner cannot flake it.
        enables = {
            h: call_pos(h, f"cd /var/www/magento/{node_rel} && php bin/magento maintenance:enable")
            for h in ("node1", "node2", "node3")
        }
        fleet_page_up = max(enables.values())
        # setup:upgrade runs on the admin node only, so the migration is one
        # call for the fleet.
        migration = call_pos("node1", "setup:upgrade", "last")
        judged = 0
        for row in indexed.read_text().splitlines():
            pos, url, code = row.split(" ")[:3]
            if not pos.isdigit():
                continue
            host = url.split("/")[2].split(":")[0].removesuffix(".example")
            if host not in enables or "health_check" in url or url.startswith("http://lb."):
                continue
            if not (fleet_page_up < int(pos) <= migration):
                continue
            judged += 1
            self.assertTrue(
                code.startswith("5"),
                f"{host} answered {code} for {url} while the page was up"
                f" (ssh call {pos}, page up at {fleet_page_up}, migration at {migration})",
            )
        self.assertGreater(judged, 3, "too few requests landed in the page window")
        # (b) No flag survives the run, in any release on any host — the old
        # release's own flag included: the relink points `current` back at
        # it, so leaving it there would hand the lab back behind the page.
        left = [str(p.relative_to(flags)) for p in flags.rglob("*") if p.is_file()]
        self.assertEqual(left, [], "a maintenance flag survived the run")
        # The ordering, from the ssh call log rather than wall-clock
        # timestamps — the steadier form. After the migration, each node's
        # page comes down in the NEW release and the relink then clears the
        # OLD release's flag before pointing `current` back at it: a relink
        # that repointed first would serve the page from the release the flag
        # was still sitting in.
        # The needle carries the `&&` the relink uses: with `;` a failed
        # `maintenance:disable` would still report success and this ordering
        # would hold over a node handed back behind the page.
        for node in ("node1", "node2", "node3"):
            down = call_pos(node, f"cd /var/www/magento/{new_rel} && php bin/magento maintenance:disable")
            relink = call_pos(node, f"cd /var/www/magento/{node_rel} && php bin/magento maintenance:disable && ln -sfn")
            self.assertLess(migration, down, f"{node}: the page comes down after the migration")
            self.assertLess(down, relink, f"{node}: the page comes down before the relink")
        self.assertEqual(result.returncode in (0, 1), True, result.stdout)

    def test_arm4_summarise_counts_only_refusals(self) -> None:
        # Blocker 2 (Ed's unit test): one rule for the table, the TOTAL and
        # the verdict — health excluded, 4xx not a refusal. Hand-written log:
        # one health 503, one cart 404, one cart 503 => exactly one failure
        # in one second, and the report's TOTAL agrees with its own rows.
        log = self.dir / "log.txt"
        log.write_text(
            "100 node1 health 503 0\n"
            "100 node2 cart 404 0\n"
            "101 node2 cart 503 0\n"
        )
        report = self.dir / "report.txt"
        snippet = (
            'ARM_DIR="' + str(ROOT / "bin" / "zdt-arm.d") + '"; '
            'source "$ARM_DIR/lib.sh" 2>/dev/null || true; '
            f'summarize_outage "{log}" "{report}" test'
        )
        ran = subprocess.run(
            ["bash", "-c", snippet], capture_output=True, text=True, timeout=30, check=False
        )
        self.assertIn("failed=1 seconds=1", ran.stdout)
        lines = report.read_text().splitlines()
        self.assertEqual(lines[-1], "TOTAL 1")
        # The per-type rows use the same rule: only the 503 is a failure...
        self.assertIn("101 cart 1/1", lines)
        # ...the 404 is a fact for the log, not a refusal.
        self.assertIn("100 cart 0/1", lines)

    def test_arm4_lists_and_help(self) -> None:
        listing = self.run_arm("list")
        self.assertIn("arm4", listing.stdout)
        help_text = self.run_arm("--help").stdout
        self.assertIn("arm4", help_text)


if __name__ == "__main__":
    unittest.main()
