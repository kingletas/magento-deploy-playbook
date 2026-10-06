"""Tests for bin/audit-log: the chain holds, tampering is found, evidence is complete, phases are timed."""
from __future__ import annotations

import datetime as dt
import hashlib
import importlib.machinery
import importlib.util
import io
import json
import multiprocessing
import sys
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
from unittest import mock

TOOL = Path(__file__).resolve().parent.parent / "bin" / "audit-log"
_loader = importlib.machinery.SourceFileLoader("audit_log", str(TOOL))
_spec = importlib.util.spec_from_loader("audit_log", _loader)
audit = importlib.util.module_from_spec(_spec)
_loader.exec_module(audit)


def _append_many(path: str, count: int) -> None:
    for i in range(count):
        audit.append(Path(path), {"event": "parallel", "n": i}, "")


def run_cli(*argv: str, stdin: str = "") -> tuple[int, str, str]:
    out, err = io.StringIO(), io.StringIO()
    old_stdin = sys.stdin
    sys.stdin = io.StringIO(stdin)
    try:
        with redirect_stdout(out), redirect_stderr(err):
            code = audit.main(list(argv))
    finally:
        sys.stdin = old_stdin
    return code, out.getvalue(), err.getvalue()


class AuditLogTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.path = Path(self.tmp.name) / "audit.jsonl"

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def write_release(self, release: str = "r1") -> None:
        for event, extra in [
            ("deploy.started", {"actor": {"git_email": "deployer@example.invalid", "os_user": "ci",
                                          "control_host": "runner"}, "env_name": "staging"}),
            ("approval.verified", {"signer": "approver@example.invalid", "tag": "approved/r1"}),
            ("build.succeeded", {"commit": "abc123", "artefact_sha256": "f" * 64}),
            ("deploy.finished", {"outcome": "success"}),
        ]:
            audit.append(self.path, {"event": event, "release": release, **extra}, "")

    def lines(self) -> list[str]:
        return self.path.read_text().splitlines(keepends=True)

    def assert_broken_at(self, line: int) -> None:
        with self.assertRaises(audit.ChainError) as caught:
            audit.read_chain(self.path)
        self.assertEqual(caught.exception.line, line)

    def test_an_appended_chain_verifies(self) -> None:
        self.write_release()
        chain = audit.read_chain(self.path)
        self.assertEqual([r["seq"] for r in chain], [1, 2, 3, 4])
        self.assertEqual(chain[0]["prev_hash"], audit.GENESIS)
        self.assertEqual(chain[1]["prev_hash"], chain[0]["hash"])
        self.assertEqual(oct(self.path.stat().st_mode & 0o777), "0o600")

    def test_an_edited_field_is_found(self) -> None:
        self.write_release()
        lines = self.lines()
        lines[1] = lines[1].replace("approver@example.invalid", "deployer@example.invalid")
        self.path.write_text("".join(lines))
        self.assert_broken_at(2)

    def test_a_removed_line_is_found(self) -> None:
        self.write_release()
        lines = self.lines()
        del lines[1]
        self.path.write_text("".join(lines))
        self.assert_broken_at(2)

    def test_reordered_lines_are_found(self) -> None:
        self.write_release()
        lines = self.lines()
        lines[1], lines[2] = lines[2], lines[1]
        self.path.write_text("".join(lines))
        self.assert_broken_at(2)

    def test_a_rehashed_forgery_still_breaks_the_next_link(self) -> None:
        self.write_release()
        records = [json.loads(line) for line in self.lines()]
        records[1]["signer"] = "deployer@example.invalid"
        records[1]["hash"] = audit.record_hash(records[1])
        self.path.write_text("".join(json.dumps(r, sort_keys=True) + "\n" for r in records))
        self.assert_broken_at(3)

    def test_a_record_cannot_set_the_chain_fields(self) -> None:
        with self.assertRaises(ValueError):
            audit.append(self.path, {"event": "x", "prev_hash": audit.GENESIS}, "")

    def test_append_refuses_to_extend_a_broken_chain(self) -> None:
        self.write_release()
        self.path.write_text(self.path.read_text().replace("abc123", "def456"))
        code, _, err = run_cli("append", "--path", str(self.path), stdin='{"event": "late"}')
        self.assertEqual(code, 2)
        self.assertIn("chain broken", err)
        self.assertEqual(len(self.lines()), 4)

    def test_concurrent_writers_keep_one_chain(self) -> None:
        workers = [multiprocessing.Process(target=_append_many, args=(str(self.path), 25)) for _ in range(4)]
        for worker in workers:
            worker.start()
        for worker in workers:
            worker.join()
        self.assertEqual(len(audit.read_chain(self.path)), 100)

    def test_verify_reports_both_outcomes(self) -> None:
        self.write_release()
        code, out, _ = run_cli("verify", "--path", str(self.path))
        self.assertEqual(code, 0)
        self.assertIn("4 records, chain intact", out)
        self.path.write_text(self.path.read_text().replace("staging", "production"))
        code, _, err = run_cli("verify", "--path", str(self.path))
        self.assertEqual(code, 2)
        self.assertIn("line 1", err)

    def test_forward_receives_the_record_and_its_failure_is_reported(self) -> None:
        sink = Path(self.tmp.name) / "sink.jsonl"
        forward = f"{sys.executable} -c \"import sys; open({str(sink)!r}, 'a').write(sys.stdin.read())\""
        code, out, _ = run_cli("append", "--path", str(self.path), "--forward", forward, stdin='{"event": "x"}')
        self.assertEqual(code, 0)
        self.assertEqual(json.loads(sink.read_text())["hash"], out.strip())
        code, _, err = run_cli("append", "--path", str(self.path), "--forward", "false", stdin='{"event": "y"}')
        self.assertEqual(code, 1)
        self.assertIn("audit-log append", err)

    def test_evidence_holds_the_release_and_checks_itself(self) -> None:
        self.write_release("r1")
        self.write_release("r2")
        out = Path(self.tmp.name) / "evidence"
        code, _, _ = run_cli("evidence", "--path", str(self.path), "--release", "r1", "--out", str(out))
        self.assertEqual(code, 0)
        records = [json.loads(line) for line in (out / "audit.jsonl").read_text().splitlines()]
        self.assertEqual({r["release"] for r in records}, {"r1"})
        self.assertEqual(len(records), 4)
        summary = (out / "summary.md").read_text()
        self.assertIn("approver@example.invalid", summary)
        self.assertIn("f" * 64, summary)
        for line in (out / "SHA256SUMS").read_text().splitlines():
            digest, name = line.split("  ")
            self.assertEqual(hashlib.sha256((out / name).read_bytes()).hexdigest(), digest)

    def test_evidence_refuses_a_broken_chain_and_an_unknown_release(self) -> None:
        self.write_release("r1")
        out = Path(self.tmp.name) / "evidence"
        code, _, _ = run_cli("evidence", "--path", str(self.path), "--release", "nope", "--out", str(out))
        self.assertEqual(code, 1)
        self.path.write_text(self.path.read_text().replace("abc123", "000000"))
        code, _, _ = run_cli("evidence", "--path", str(self.path), "--release", "r1", "--out", str(out))
        self.assertEqual(code, 2)
        self.assertFalse((out / "audit.jsonl").exists())


class Clock(dt.datetime):
    """A datetime whose now() is whatever the test last set, so records land seconds apart on purpose."""

    moment = dt.datetime(2026, 1, 14, 2, 0, 0, tzinfo=dt.timezone.utc)

    @classmethod
    def now(cls, tz=None):
        return cls.moment


class PhaseTimesTest(unittest.TestCase):
    """How long each phase took, and how long the store was down, read from the records alone."""

    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.path = Path(self.tmp.name) / "audit.jsonl"
        patcher = mock.patch.object(audit.dt, "datetime", Clock)
        patcher.start()
        self.addCleanup(patcher.stop)
        self.addCleanup(self.tmp.cleanup)
        Clock.moment = dt.datetime(2026, 1, 14, 2, 0, 0, tzinfo=dt.timezone.utc)

    def record(self, event: str, after: int = 0, release: str = "r1", **extra) -> None:
        """One record, written `after` seconds past the one before it."""
        Clock.moment += dt.timedelta(seconds=after)
        audit.append(self.path, {"event": event, "release": release, **extra}, "")

    def deploy_with_a_window(self, release: str = "r1") -> None:
        for event, after in [
            ("deploy.started", 0), ("build.started", 2), ("build.succeeded", 95),
            ("upload.started", 1), ("upload.succeeded", 20), ("cutover.started", 3),
            ("maintenance.enabled", 4), ("upgrade.started", 2), ("upgrade.succeeded", 31),
            ("maintenance.disabled", 5), ("cutover.succeeded", 6), ("deploy.finished", 9),
        ]:
            self.record(event, after, release)

    def spans(self, release: str = "r1") -> dict[str, dict]:
        code, out, _ = run_cli("phases", "--path", str(self.path), "--release", release, "--json")
        self.assertEqual(code, 0)
        return {span["phase"]: span for span in json.loads(out)["phases"]}

    def test_every_phase_has_a_start_an_end_and_the_seconds_between(self) -> None:
        self.deploy_with_a_window()
        spans = self.spans()
        self.assertEqual(
            {name: span["seconds"] for name, span in spans.items()},
            {"deploy": 178, "build": 95, "upload": 20, "cutover": 48, "setup:upgrade": 31, "maintenance": 38},
        )
        self.assertEqual(spans["build"]["started"], "2026-01-14T02:00:02Z")
        self.assertEqual(spans["build"]["ended"], "2026-01-14T02:01:37Z")

    def test_downtime_is_from_maintenance_enabled_to_maintenance_disabled(self) -> None:
        self.deploy_with_a_window()
        window = self.spans()["maintenance"]
        self.assertEqual((window["seconds"], window["ended_by"]), (38, "maintenance.disabled"))

    def test_a_deploy_with_no_window_has_no_maintenance_phase(self) -> None:
        for event in ["deploy.started", "build.started", "build.succeeded", "cutover.started",
                      "cutover.succeeded", "deploy.finished"]:
            self.record(event, 5)
        spans = self.spans()
        self.assertIsNone(spans["maintenance"]["started"])
        self.assertIsNone(spans["setup:upgrade"]["started"])
        self.assertEqual(spans["cutover"]["seconds"], 5)

    def test_a_failed_setup_upgrade_ends_its_phase_and_leaves_the_window_open(self) -> None:
        for event, after in [("deploy.started", 0), ("cutover.started", 5), ("maintenance.enabled", 2),
                             ("upgrade.started", 1), ("upgrade.failed", 40)]:
            self.record(event, after)
        spans = self.spans()
        self.assertEqual((spans["setup:upgrade"]["seconds"], spans["setup:upgrade"]["ended_by"]), (40, "upgrade.failed"))
        self.assertEqual(spans["maintenance"]["started"], "2026-01-14T02:00:07Z")
        self.assertIsNone(spans["maintenance"]["ended"])
        self.assertIsNone(spans["maintenance"]["seconds"])
        self.assertIsNone(spans["cutover"]["ended"])

    def test_a_deploy_that_stops_is_timed_to_where_it_stopped(self) -> None:
        for event, after in [("deploy.started", 0), ("build.started", 1), ("deploy.failed", 30)]:
            self.record(event, after)
        spans = self.spans()
        self.assertEqual((spans["deploy"]["seconds"], spans["deploy"]["ended_by"]), (31, "deploy.failed"))
        self.assertIsNone(spans["build"]["ended"])

    def test_a_release_deployed_twice_is_timed_by_its_last_run(self) -> None:
        self.deploy_with_a_window()
        self.record("deploy.started", 600)
        self.record("cutover.started", 10)
        self.record("cutover.succeeded", 7)
        self.record("deploy.finished", 3)
        spans = self.spans()
        self.assertEqual(spans["deploy"]["seconds"], 20)
        self.assertEqual(spans["cutover"]["seconds"], 7)
        self.assertIsNone(spans["maintenance"]["started"])

    def test_only_the_release_asked_for_is_read(self) -> None:
        self.deploy_with_a_window("r1")
        self.record("deploy.started", 100, "r2")
        self.record("deploy.finished", 11, "r2")
        self.assertEqual(self.spans("r2")["deploy"]["seconds"], 11)
        self.assertEqual(self.spans("r1")["deploy"]["seconds"], 178)

    def test_a_log_written_before_these_events_existed_still_reads(self) -> None:
        for event, after in [("deploy.started", 0), ("build.succeeded", 90), ("cutover.started", 20),
                             ("maintenance.enabled", 3), ("cutover.succeeded", 45), ("deploy.finished", 8)]:
            self.record(event, after)
        spans = self.spans()
        self.assertEqual(spans["deploy"]["seconds"], 166)
        self.assertEqual(spans["cutover"]["seconds"], 48)
        self.assertIsNone(spans["build"]["started"])
        self.assertIsNone(spans["upload"]["started"])
        self.assertIsNone(spans["maintenance"]["ended"])
        out = Path(self.tmp.name) / "evidence"
        code, _, _ = run_cli("evidence", "--path", str(self.path), "--release", "r1", "--out", str(out))
        self.assertEqual(code, 0)
        self.assertIn("| Maintenance window | yes, from 2026-01-14T02:01:53Z; its end was not recorded |",
                      (out / "summary.md").read_text())

    def test_the_table_says_what_was_not_recorded_and_what_was_not_closed(self) -> None:
        for event, after in [("deploy.started", 0), ("cutover.started", 5), ("maintenance.enabled", 2)]:
            self.record(event, after)
        code, out, _ = run_cli("phases", "--path", str(self.path), "--release", "r1")
        self.assertEqual(code, 0)
        lines = out.splitlines()
        self.assertEqual(lines[0], "release r1")
        self.assertIn("build          not recorded", lines)
        self.assertTrue(any(line.startswith("maintenance    2026-01-14T02:00:07Z") and "not closed" in line
                            for line in lines))

    def test_the_summary_gives_the_window_in_seconds_and_a_row_for_each_phase(self) -> None:
        self.deploy_with_a_window()
        out = Path(self.tmp.name) / "evidence"
        code, _, _ = run_cli("evidence", "--path", str(self.path), "--release", "r1", "--out", str(out))
        self.assertEqual(code, 0)
        summary = (out / "summary.md").read_text()
        self.assertIn("| Maintenance window | yes, 38 s, from 2026-01-14T02:02:05Z to 2026-01-14T02:02:43Z |", summary)
        self.assertIn("| setup:upgrade | 2026-01-14T02:02:07Z | 2026-01-14T02:02:38Z | 31 |", summary)
        self.assertIn("| deploy | 2026-01-14T02:00:00Z | 2026-01-14T02:02:58Z | 178 |", summary)

    def test_a_window_nothing_closed_says_the_store_may_still_be_down(self) -> None:
        for event, after in [("deploy.started", 0), ("maintenance.enabled", 9), ("upgrade.failed", 30)]:
            self.record(event, after)
        out = Path(self.tmp.name) / "evidence"
        run_cli("evidence", "--path", str(self.path), "--release", "r1", "--out", str(out))
        self.assertIn("no end is recorded: the store may still be in maintenance", (out / "summary.md").read_text())

    def test_phases_refuses_an_unknown_release_and_a_broken_chain(self) -> None:
        self.deploy_with_a_window()
        code, _, err = run_cli("phases", "--path", str(self.path), "--release", "nope")
        self.assertEqual(code, 1)
        self.assertIn("no records for release 'nope'", err)
        self.path.write_text(self.path.read_text().replace("upgrade.started", "upgrade.begun"))
        code, _, err = run_cli("phases", "--path", str(self.path), "--release", "r1")
        self.assertEqual(code, 2)
        self.assertIn("chain broken", err)


if __name__ == "__main__":
    unittest.main()
