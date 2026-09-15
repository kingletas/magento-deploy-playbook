"""Tests for bin/audit-log: the chain holds, tampering is found, evidence is complete."""
from __future__ import annotations

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


if __name__ == "__main__":
    unittest.main()
