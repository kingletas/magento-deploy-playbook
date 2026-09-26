"""Tests for bin/zdt-proof: it lists every proof, and refuses to start without a Kapelos to run against."""
from __future__ import annotations

import os
import re
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
RUNNER = ROOT / "bin" / "zdt-proof"
PAYLOADS = ROOT / "bin" / "zdt-proof.d"
PROOFS = sorted(p.stem for p in (PAYLOADS / "proofs").glob("*.sh"))

# Stands in for docker and kapelos, recording every call so a test can show
# that a refused run reached neither.
STUB = """#!/usr/bin/env bash
echo "$(basename "$0") $*" >>"$ZDT_TEST_CALLS"
if [[ $(basename "$0") == kapelos && ${1:-} == sites ]]; then
    echo "* acme  running"
    exit 0
fi
exit 1
"""


class ZdtProofTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)
        self.calls = self.dir / "calls.log"
        stubs = self.dir / "stubs"
        stubs.mkdir()
        self.write_stub(stubs / "docker")
        self.write_stub(stubs / "kapelos")
        self.env = {k: v for k, v in os.environ.items()
                    if k != "KAPELOS_HOME" and not k.startswith("ZDT_")}
        self.env["PATH"] = f"{stubs}{os.pathsep}{os.environ['PATH']}"
        self.env["ZDT_TEST_CALLS"] = str(self.calls)

    def tearDown(self) -> None:
        self.tmp.cleanup()

    @staticmethod
    def write_stub(path: Path) -> None:
        path.write_text(STUB)
        path.chmod(0o755)

    def run_runner(self, *argv: str, **env: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run([str(RUNNER), *argv], env={**self.env, **env},
                              capture_output=True, text=True, timeout=60, check=False)

    def fake_kapelos(self) -> Path:
        """A directory shaped like a Kapelos checkout, with one site whose container is not running."""
        home = self.dir / "kapelos"
        (home / "bin").mkdir(parents=True)
        (home / "etc" / "sites").mkdir(parents=True)
        self.write_stub(home / "bin" / "kapelos")
        (home / "etc" / "sites" / "acme.env").write_text(
            "MAGENTO_SRC=/srv/acme\nCOMPOSE_PROJECT_NAME=acme\nMAGENTO_BASE_URL=https://acme.example/\n")
        return home

    def test_list_names_every_proof_with_its_summary(self) -> None:
        result = self.run_runner("list")
        self.assertEqual(result.returncode, 0, result.stderr)
        listed = dict(re.match(r"(\S+)\s+(.*)", line).groups() for line in result.stdout.splitlines())
        self.assertEqual(sorted(listed), PROOFS)
        self.assertGreaterEqual(len(PROOFS), 10)
        for name, summary in listed.items():
            self.assertTrue(summary.strip(), f"{name} has no '# summary:' line")

    def test_every_proof_refuses_without_kapelos_home_and_touches_nothing(self) -> None:
        for proof in PROOFS:
            with self.subTest(proof=proof):
                result = self.run_runner(proof)
                self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
                self.assertIn("KAPELOS_HOME is not set", result.stderr)
                self.assertIn(f"bin/zdt-proof {proof}", result.stderr)
        self.assertFalse(self.calls.exists(), "a refused run called docker or kapelos")

    def test_a_directory_that_is_not_kapelos_is_refused(self) -> None:
        result = self.run_runner("p0-1", KAPELOS_HOME=str(self.dir / "empty"))
        self.assertEqual(result.returncode, 2)
        self.assertIn("is not a Kapelos checkout", result.stderr)
        self.assertFalse(self.calls.exists(), "a refused run called docker or kapelos")

    def test_a_configured_kapelos_gets_past_the_refusal_to_the_store(self) -> None:
        # The quiet side of the refusal: with KAPELOS_HOME set, the run asks
        # Kapelos for the active site and stops only because no container runs.
        result = self.run_runner("p0-1", KAPELOS_HOME=str(self.fake_kapelos()))
        self.assertEqual(result.returncode, 2)
        self.assertNotIn("KAPELOS_HOME", result.stderr)
        self.assertIn("acme-php-1 is not running or does not mount /srv/acme", result.stderr)
        calls = self.calls.read_text().splitlines()
        self.assertIn("kapelos sites", calls)
        self.assertTrue(any(c.startswith("docker inspect acme-php-1") for c in calls), calls)

    def test_a_proof_name_is_never_a_path(self) -> None:
        for name in ("../lib", "proofs/p0-1", "/etc/passwd"):
            with self.subTest(name=name):
                result = self.run_runner(name)
                self.assertEqual(result.returncode, 2)
                self.assertIn("is not a proof name", result.stderr)

    def test_an_unknown_proof_is_refused(self) -> None:
        result = self.run_runner("p9-9")
        self.assertEqual(result.returncode, 2)
        self.assertIn("no proof named p9-9", result.stderr)

    def test_no_file_names_a_home_directory(self) -> None:
        home_path = re.compile(r"\$HOME/|~/|/home/|/Users/")
        for path in [RUNNER, *sorted(p for p in PAYLOADS.rglob("*") if p.is_file())]:
            with self.subTest(path=str(path.relative_to(ROOT))):
                self.assertIsNone(home_path.search(path.read_text()))


if __name__ == "__main__":
    unittest.main()
