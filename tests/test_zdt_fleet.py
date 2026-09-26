"""Tests for bin/zdt-fleet: the replica gate and the checksum pair, offline.

No database exists here. A fake `mysql` client goes on PATH, answering from
canned replies keyed by host and SQL text, and recording every call so a test
can show what the tool asked the servers -- and, for refused runs, that it
asked nothing at all.
"""
from __future__ import annotations

import hashlib
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TOOL = ROOT / "bin" / "zdt-fleet"

FAKE_MYSQL = """#!/usr/bin/env bash
host="" ; sql="" ; db=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h) host="$2"; shift 2 ;;
        -e) sql="$2"; shift 2 ;;
        --database=*) db="${1#--database=}"; shift ;;
        *) shift ;;
    esac
done
printf '%s|%s|pwd=%s\\n' "$host" "$sql" "${MYSQL_PWD:-unset}" >> "$FAKE_CALLS"
key="${host}|${db}|${sql}"
file="$FAKE_DIR/$(printf '%s' "$key" | sha256sum | cut -d' ' -f1)"
if [[ -f $file ]]; then cat "$file"; exit 0; fi
echo "ERROR 1064 (42000): fake has no canned reply for [$sql] on $host" >&2
exit 1
"""

# MySQL 8.0.22+: Replica_... names, Seconds_Behind_Source.
MYSQL8_HEADERS = "\t".join([
    "Replica_IO_State", "Source_Host", "Replica_IO_Running", "Replica_SQL_Running",
    "Last_IO_Errno", "Last_IO_Error", "Last_SQL_Errno", "Last_SQL_Error",
    "Seconds_Behind_Source",
])
# MariaDB, any version, under either command: Slave_... and Seconds_Behind_Master.
MARIADB_HEADERS = MYSQL8_HEADERS.replace("Replica_", "Slave_").replace(
    "Seconds_Behind_Source", "Seconds_Behind_Master")


def status_row(io_running="Yes", sql_running="Yes", sql_errno="0", sql_error="",
               io_errno="0", lag="0"):
    return "\t".join(["", "primary.db", io_running, sql_running, io_errno, "",
                      sql_errno, sql_error, lag])


PRIMARY_SQL = {
    "SELECT @@binlog_format": "ROW\n",
    "SELECT COUNT(*) FROM catalog_product_entity": "1984\n",
    "SHOW BINARY LOGS": "binlog.000001\t106\nbinlog.000002\t384\n",
}


class ZdtFleetTest(unittest.TestCase):
    def setUp(self) -> None:
        # Under local.d/, not the system temp: some sandboxes mount /tmp
        # noexec, and a fake client that will not run reads as a dead replica.
        # local.d/ is this playbook's gitignored place for disposable output.
        work = ROOT / "local.d" / "test-zdt-fleet"
        work.mkdir(parents=True, exist_ok=True)
        self.tmp = tempfile.TemporaryDirectory(dir=work)
        self.dir = Path(self.tmp.name)
        self.fake_dir = self.dir / "canned"
        self.fake_dir.mkdir()
        self.calls = self.dir / "calls.log"
        stubs = self.dir / "stubs"
        stubs.mkdir()
        fake = stubs / "mysql"
        fake.write_text(FAKE_MYSQL)
        fake.chmod(0o755)
        # Nothing outside the fake may answer: drop any real mysql from PATH.
        self.env = {k: v for k, v in os.environ.items()
                    if not k.startswith("ZDT_")}
        self.env["PATH"] = f"{stubs}{os.pathsep}{os.environ['PATH']}"
        self.env["FAKE_DIR"] = str(self.fake_dir)
        self.env["FAKE_CALLS"] = str(self.calls)
        self.env.update({
            "ZDT_PRIMARY_HOST": "primary.db", "ZDT_PRIMARY_USER": "u1",
            "ZDT_PRIMARY_PASSWORD": "secret1", "ZDT_PRIMARY_DATABASE": "magento",
            "ZDT_REPLICA_HOST": "replica.db", "ZDT_REPLICA_USER": "u2",
            "ZDT_REPLICA_PASSWORD": "secret2", "ZDT_REPLICA_DATABASE": "magento",
        })
        for sql, out in PRIMARY_SQL.items():
            self.canned("primary.db", sql, out)

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def canned(self, host: str, sql: str, output: str, db: str = "magento") -> None:
        name = hashlib.sha256(f"{host}|{db}|{sql}".encode()).hexdigest()
        (self.fake_dir / name).write_text(output)

    def remove_canned(self, host: str, sql: str, db: str = "magento") -> None:
        name = hashlib.sha256(f"{host}|{db}|{sql}".encode()).hexdigest()
        (self.fake_dir / name).unlink()

    def run_tool(self, *argv: str, **extra_env: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run([str(TOOL), *argv], env={**self.env, **extra_env},
                              capture_output=True, text=True, timeout=60, check=False)

    # ----------------------------------------------------------- replica-check

    def test_healthy_mysql8_replica_passes_and_records_the_facts(self) -> None:
        self.canned("replica.db", "SHOW REPLICA STATUS",
                    MYSQL8_HEADERS + "\n" + status_row(lag="3") + "\n")
        result = self.run_tool("replica-check")
        self.assertEqual(result.returncode, 0, result.stderr)
        facts = json.loads(result.stdout)
        self.assertEqual(facts["binlog_format"], "ROW")
        self.assertEqual(facts["catalogue_size"], 1984)
        self.assertEqual(facts["binlog_bytes"], 490)
        self.assertEqual(facts["seconds_behind"], 3)
        self.assertRegex(facts["timestamp"], r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$")

    def test_healthy_mariadb_replica_passes_under_either_command_name(self) -> None:
        # MariaDB answers SHOW REPLICA STATUS with the old column names.
        self.canned("replica.db", "SHOW REPLICA STATUS",
                    MARIADB_HEADERS + "\n" + status_row(lag="0") + "\n")
        result = self.run_tool("replica-check")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["seconds_behind"], 0)

    def test_an_old_server_answered_only_by_slave_status_still_passes(self) -> None:
        # Pre-8.0.22 MySQL (pre-10.5.1 MariaDB): SHOW REPLICA STATUS errors and
        # only SHOW SLAVE STATUS answers, with the old names.
        self.canned("replica.db", "SHOW SLAVE STATUS",
                    MARIADB_HEADERS + "\n" + status_row(lag="12") + "\n")
        result = self.run_tool("replica-check")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["seconds_behind"], 12)
        calls = self.calls.read_text()
        self.assertIn("SHOW REPLICA STATUS", calls)
        self.assertIn("SHOW SLAVE STATUS", calls)

    def _expect_dead(self, headers: str, row: str, named: str) -> None:
        self.canned("replica.db", "SHOW REPLICA STATUS", headers + "\n" + row + "\n")
        result = self.run_tool("replica-check")
        self.assertEqual(result.returncode, 1, f"{named}: {result.stdout}{result.stderr}")
        self.assertIn(named, result.stderr)

    def test_io_thread_not_running_fails_and_names_itself(self) -> None:
        self._expect_dead(MYSQL8_HEADERS, status_row(io_running="Connecting"),
                          "Replica_IO_Running")

    def test_sql_thread_not_running_fails_and_names_itself(self) -> None:
        self._expect_dead(MYSQL8_HEADERS, status_row(sql_running="No"),
                          "Replica_SQL_Running")

    def test_a_nonzero_last_sql_errno_fails_and_names_itself(self) -> None:
        self._expect_dead(MYSQL8_HEADERS, status_row(sql_errno="1032", sql_error="Can't find row"),
                          "Last_SQL_Errno")

    def test_null_lag_fails_and_names_itself(self) -> None:
        self._expect_dead(MYSQL8_HEADERS, status_row(lag="NULL"),
                          "Seconds_Behind_Source")

    def test_mariadb_failures_name_the_slave_columns(self) -> None:
        self._expect_dead(MARIADB_HEADERS, status_row(io_running="No"),
                          "Slave_IO_Running")

    def test_a_dead_replica_is_stated_as_not_live(self) -> None:
        self.canned("replica.db", "SHOW REPLICA STATUS",
                    MYSQL8_HEADERS + "\n" + status_row(sql_running="No", sql_errno="1062") + "\n")
        result = self.run_tool("replica-check")
        self.assertEqual(result.returncode, 1)
        self.assertIn("replica is NOT live", result.stderr)

    def test_a_server_answering_neither_status_command_is_refused(self) -> None:
        # No canned reply for either command: not a replica at all -> exit 2,
        # the "the check never happened" code, not the "fleet is wrong" code.
        result = self.run_tool("replica-check")
        self.assertEqual(result.returncode, 2)
        self.assertIn("neither SHOW REPLICA STATUS nor SHOW SLAVE STATUS", result.stderr)

    def test_missing_connection_settings_refuse_before_any_call(self) -> None:
        env = {k: v for k, v in self.env.items() if not k.startswith("ZDT_REPLICA")}
        result = subprocess.run([str(TOOL), "replica-check"], env=env,
                                capture_output=True, text=True, timeout=60, check=False)
        self.assertEqual(result.returncode, 2)
        self.assertIn("ZDT_REPLICA_HOST", result.stderr)
        self.assertFalse(self.calls.exists(), "a refused run reached no server")

    def test_the_password_travels_in_the_environment_never_the_arguments(self) -> None:
        self.canned("replica.db", "SHOW REPLICA STATUS",
                    MYSQL8_HEADERS + "\n" + status_row() + "\n")
        self.run_tool("replica-check")
        calls = self.calls.read_text()
        # Every call carries the password only as MYSQL_PWD=; the argv
        # records (host|sql) hold no secret.
        self.assertIn("pwd=secret2", calls)
        for line in calls.splitlines():
            argv_part = line.split("|", 2)[0:2]
            self.assertNotIn("secret", "|".join(argv_part))

    # --------------------------------------------------------- table-checksums

    def test_matching_checksums_pass_on_every_table(self) -> None:
        for table in ("catalog_product_entity", "catalog_category_product"):
            self.canned("primary.db", f"CHECKSUM TABLE {table}", f"magento.{table}\t111222\n")
            self.canned("replica.db", f"CHECKSUM TABLE {table}", f"magento.{table}\t111222\n")
        result = self.run_tool("table-checksums", "catalog_product_entity",
                               "catalog_category_product")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.count("MATCH"), 2)
        self.assertNotIn("DIFFER", result.stdout)

    def test_a_differing_checksum_is_reported_and_fails(self) -> None:
        table = "catalog_product_entity"
        self.canned("primary.db", f"CHECKSUM TABLE {table}", f"magento.{table}\t111222\n")
        self.canned("replica.db", f"CHECKSUM TABLE {table}", f"magento.{table}\t999888\n")
        result = self.run_tool("table-checksums", table)
        self.assertEqual(result.returncode, 1)
        self.assertIn(f"DIFFER {table} primary=111222 replica=999888", result.stdout)

    def test_a_missing_checksum_on_one_side_is_a_differ(self) -> None:
        # The replica lacks the table the migration touched. A real server
        # does not error on CHECKSUM TABLE for a missing table: it answers the
        # row with a NULL checksum.
        table = "zdt_marker"
        self.canned("primary.db", f"CHECKSUM TABLE {table}", f"magento.{table}\t55\n")
        self.canned("replica.db", f"CHECKSUM TABLE {table}", f"magento.{table}\tNULL\n")
        result = self.run_tool("table-checksums", table)
        self.assertEqual(result.returncode, 1)
        self.assertIn(f"DIFFER {table} primary=55 replica=NULL", result.stdout)

    def test_a_table_missing_on_both_sides_is_a_differ_not_a_match(self) -> None:
        # NULL == NULL must never read as MATCH: a typo'd name or the wrong
        # database is missing on both servers and CHECKSUM TABLE answers NULL
        # on both. That is a DIFFER (the fleet's tables are not what was
        # named), never a green light.
        table = "nosuch"
        self.canned("primary.db", f"CHECKSUM TABLE {table}", f"magento.{table}\tNULL\n")
        self.canned("replica.db", f"CHECKSUM TABLE {table}", f"magento.{table}\tNULL\n")
        result = self.run_tool("table-checksums", table)
        self.assertEqual(result.returncode, 1)
        self.assertIn(f"DIFFER {table} primary=NULL replica=NULL", result.stdout)

    def test_a_failed_query_in_table_checksums_is_exit_2_not_differ(self) -> None:
        # No canned reply means the client fails: the replica never answered,
        # so this is "the check never happened" (2), not "the fleet is wrong"
        # (1).
        table = "t"
        self.canned("primary.db", f"CHECKSUM TABLE {table}", f"magento.{table}\t7\n")
        # deliberately no canned reply on replica.db
        result = self.run_tool("table-checksums", table)
        self.assertEqual(result.returncode, 2, f"{result.stdout}{result.stderr}")
        self.assertIn("replica query failed on replica.db", result.stderr)

    def test_a_failed_primary_query_in_replica_check_is_exit_2(self) -> None:
        # Live replica, but the primary cannot answer SHOW BINARY LOGS: a
        # zero binlog_bytes would read as "the upgrade wrote nothing", so the
        # whole check refuses instead of printing facts it never gathered.
        self.canned("replica.db", "SHOW REPLICA STATUS",
                    MYSQL8_HEADERS + "\n" + status_row() + "\n")
        self.remove_canned("primary.db", "SHOW BINARY LOGS")
        result = self.run_tool("replica-check")
        self.assertEqual(result.returncode, 2, f"{result.stdout}{result.stderr}")
        self.assertIn("primary query failed on primary.db: SHOW BINARY LOGS", result.stderr)
        self.assertNotIn("binlog_bytes", result.stdout)

    def test_checksums_without_a_database_configured_are_refused(self) -> None:
        # CHECKSUM TABLE with no default database is error 1046; the tool must
        # refuse (2) before reaching the servers, not smuggle a DIFFER.
        table = "catalog_product_entity"
        self.canned("primary.db", f"CHECKSUM TABLE {table}", f"magento.{table}\t1\n", db="")
        self.canned("replica.db", f"CHECKSUM TABLE {table}", f"magento.{table}\t1\n", db="")
        result = self.run_tool("table-checksums", table,
                               ZDT_PRIMARY_DATABASE="", ZDT_REPLICA_DATABASE="")
        self.assertEqual(result.returncode, 2)
        self.assertIn("ZDT_PRIMARY_DATABASE", result.stderr)

    def test_the_database_reaches_the_client(self) -> None:
        # --database must be on the wire: with --no-defaults, a server without
        # a default database answers CHECKSUM TABLE with error 1046.
        self.canned("replica.db", "SHOW REPLICA STATUS",
                    MYSQL8_HEADERS + "\n" + status_row() + "\n")
        self.run_tool("replica-check")
        # replica-check's own queries ran; the checksum path proves the flag:
        table = "catalog_product_entity"
        self.canned("primary.db", f"CHECKSUM TABLE {table}", f"magento.{table}\t42\n")
        self.canned("replica.db", f"CHECKSUM TABLE {table}", f"magento.{table}\t42\n")
        result = self.run_tool("table-checksums", table)
        self.assertEqual(result.returncode, 0, f"{result.stdout}{result.stderr}")

    def test_multi_source_replication_is_refused(self) -> None:
        # Two status rows (two channels): reading only the first would let a
        # dead second channel pass the gate. Refuse with exit 2.
        rows = (MYSQL8_HEADERS + "\n" + status_row() + "\n"
                + status_row(io_running="No") + "\n")
        self.canned("replica.db", "SHOW REPLICA STATUS", rows)
        result = self.run_tool("replica-check")
        self.assertEqual(result.returncode, 2, f"{result.stdout}{result.stderr}")
        self.assertIn("multi-source", result.stderr)

    def test_no_arguments_exits_2_not_help_0(self) -> None:
        # A script calling the gate with no arguments must not read its
        # usage text as success.
        result = subprocess.run([str(TOOL)], env=self.env,
                                capture_output=True, text=True, timeout=60, check=False)
        self.assertEqual(result.returncode, 2)

    def test_explicit_help_exits_0(self) -> None:
        result = self.run_tool("--help")
        self.assertEqual(result.returncode, 0)
        self.assertIn("replica-check", result.stdout)


    def test_a_table_name_is_never_a_query(self) -> None:
        for name in ("catalog; DROP TABLE x", "a b", "-h"):
            with self.subTest(name=name):
                result = self.run_tool("table-checksums", name)
                self.assertEqual(result.returncode, 2)

    def test_no_tables_named_is_refused(self) -> None:
        result = self.run_tool("table-checksums")
        self.assertEqual(result.returncode, 2)

    def test_unknown_subcommand_is_refused(self) -> None:
        result = self.run_tool("deploy")
        self.assertEqual(result.returncode, 2)
        self.assertIn("not a subcommand", result.stderr)


if __name__ == "__main__":
    unittest.main()
