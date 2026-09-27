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
if [[ -n ${FAKE_SSH_RUN:-} ]]; then
    # Execute mode: run the received command/body locally, each host rooted
    # under $FAKE_SSH_RUN/<host>/ (paths under /srv/magento/ are rewritten
    # there), so a test can watch a backup, an edit and a restore touch real
    # files without any lab.
    root="$FAKE_SSH_RUN/$host"
    if [[ -n $body ]]; then
        mkdir -p "$root/current/app/etc"
        printf '%s\n' "$body" | sed "s|/srv/magento/|$root/|g" | bash -s; exit $?
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

FAKE_RSYNC = """#!/usr/bin/env bash
printf 'RSYNC|%s\\n' "$*" >> "$FAKE_SSH_CALLS"
exit 0
"""

FAKE_CURL = """#!/usr/bin/env bash
# Default 200. FAKE_CURL_DOWN: a target substring whose NON-health requests
# answer 503 with a guard message. FAKE_CURL_HEALTH_DOWN: a target whose
# health_check.php itself answers 503 — falsifier 5's failure mode.
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
[[ -n $out && -n $body ]] && printf '%s\\n' "$body" > "$out"
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
        ):
            fake = stubs / name
            fake.write_text(text)
            fake.chmod(0o755)
        self.calls_file = self.dir / "calls.log"
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
                "ZDT_NODE_URLS": "http://node1.example/,http://node2.example/,http://node3.example/",
                "ZDT_RELEASE_TARBALL": str(self.tarball),
                "ZDT_LABEL_NEW": "rel-new",
                "ZDT_LABEL_OLD": "rel-old",
                "ZDT_ENV_PHP": "/srv/magento/current/app/etc/env.php",
                "ZDT_DB_HOST": "primary.db",
                "ZDT_DB_USER": "dbu",
                "ZDT_DB_PASSWORD": "Sup3rSecretPw",
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
            "ZDT_NODE_URLS",
            "ZDT_RELEASE_TARBALL",
            "ZDT_LABEL_NEW",
            "ZDT_LABEL_OLD",
            "ZDT_ENV_PHP",
            "ZDT_DB_HOST",
            "ZDT_DB_USER",
            "ZDT_DB_PASSWORD",
            "ZDT_DB_NAME",
            "ZDT_SNAPSHOT_DIR",
            "ZDT_RATE",
            "ZDT_DURATION",
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

    def test_health_check_failure_on_a_refusing_node_is_a_falsifier_5_fail(
        self,
    ) -> None:
        # rate 7 x duration 1 sends one of each of the 7 request types to
        # every target, health included — the mix the issue names.
        result = self.run_arm(
            "arm1",
            "-y",
            ZDT_RATE="7",
            FAKE_CURL_DOWN="node2.example",
            FAKE_CURL_HEALTH_DOWN="node2.example",
        )
        self.assertEqual(result.returncode, 1)
        self.assertIn("FAIL  falsifier 5", result.stdout)
        # Guard messages are reported as facts, attributed per target.
        self.assertIn("matched ZDT_GUARD_PATTERN", result.stdout)

    def test_healthy_run_passes_falsifier_5_and_records_guard_facts(self) -> None:
        result = self.run_arm(
            "arm1", "-y", ZDT_RATE="7", FAKE_CURL_DOWN="node2.example"
        )
        self.assertEqual(result.returncode, 0, f"{result.stdout}{result.stderr}")
        self.assertIn("PASS  falsifier 5", result.stdout)
        self.assertIn("PASS  falsifier 1", result.stdout)
        # Two phases, two falsifiers each.
        self.assertIn("summary: 4 pass, 0 fail", result.stdout)

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
        # The maintenance leg's whole shape, in order, in the plan.
        self.assertEqual(transcript.count("maintenance:enable"), 3)  # every node
        self.assertIn("maintenance:disable", transcript)
        self.assertIn("restore database magento", transcript)
        self.assertIn("link release rel-old back in", transcript)
        self.assertEqual(transcript.count("setup:upgrade"), 2)
        self.assertNotIn("Sup3rSecretPw", transcript)

    def test_arm4_maintenance_leg_enables_every_node_then_disables(self) -> None:
        result = self.run_arm("arm4", "-y", FAKE_CURL_DOWN="node2.example")
        lines = [l for l in self.calls().splitlines() if l.startswith("SSH|")]
        enables = [i for i, l in enumerate(lines) if "maintenance:enable" in l]
        disables = [i for i, l in enumerate(lines) if "maintenance:disable" in l]
        # Three enables, one per web node, and they land only in the second
        # leg: before them sit exactly one snapshot+upgrade pair, and after
        # them comes the disable. The rollout leg never touches maintenance.
        self.assertEqual(len(enables), 3, f"expected 3 enables: {enables}")
        self.assertTrue(disables, "the maintenance leg must lift maintenance")
        upgrades = [i for i, l in enumerate(lines) if "setup:upgrade" in l]
        self.assertEqual(len(upgrades), 2)
        self.assertTrue(all(u < min(enables) for u in upgrades[:1]))
        self.assertTrue(all(u > max(enables) for u in upgrades[1:]))
        enabled_hosts = {l.split("|")[1] for l in lines if "maintenance:enable" in l}
        self.assertEqual(enabled_hosts, {"node1", "node2", "node3"})
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
            # Health rows never appear in the per-second shares: falsifier 5
            # judges the health check, not the customer-facing outage.
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

    def test_arm4_lists_and_help(self) -> None:
        listing = self.run_arm("list")
        self.assertIn("arm4", listing.stdout)
        help_text = self.run_arm("--help").stdout
        self.assertIn("arm4", help_text)


if __name__ == "__main__":
    unittest.main()
