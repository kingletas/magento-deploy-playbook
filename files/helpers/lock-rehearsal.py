#!/usr/bin/env python3
"""Rehearses a release's setup:upgrade against a private copy of the database's
shape, and reports what each schema statement would lock in production.

    lock-rehearsal.py --release DIR --dump FILE --stats FILE --image IMAGE --out FILE

Run on the builder, which has the built release, PHP and Docker.

  --release  the built release. It is copied first, because setup:upgrade
             rewrites app/etc/config.php
  --dump     production's schema, with the rows of the tables setup:upgrade
             reads to decide what to do (setup_module, patch_list, the stores,
             the EAV metadata, core_config_data). magento-db-snapshot.php
             writes it
  --stats    production's row counts and sizes per table, server version and
             default row format, as JSON, from the same helper
  --image    the MariaDB image to rehearse on. Its major.minor must match
             production's, or the answer is about another server and the
             rehearsal refuses
  --out      where the JSON report goes

How it works. setup:upgrade is a reconciler: it runs whatever the live
database needs, including statements no dry run shows, such as grid and index
tables rebuilt and mview triggers recreated. So the release's real
setup:upgrade runs against the copy with the general log on, and every schema
statement it sent is kept, in order. The copy is then loaded again and each
statement replayed, asking the server first for ALGORITHM=INSTANT, then
NOCOPY, then INPLACE with LOCK=NONE. The first it accepts is the statement's
class; none means a table copy that blocks writes. That answer comes from the
same server version, not from a table in a document.

Each statement is then sized with production's row count and bytes for its
table. No seconds are given: how fast a server rebuilds a table depends on
disk and load that a rehearsal does not have.

What it cannot see, and says so in the report: data patches and recurring
scripts run against tables that are empty here, so their cost is not
measured, only their names and statement counts; and a class on the copy is
the best case, because production's table may carry instant changes already
made that make the next one a rebuild.
"""
import argparse
import json
import os
import re
import secrets
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

SCHEMA_STATEMENT = re.compile(r"^\s*(ALTER|CREATE|DROP|RENAME|TRUNCATE)\b", re.IGNORECASE)
DATA_STATEMENT = re.compile(r"^\s*(INSERT|UPDATE|DELETE|REPLACE)\b", re.IGNORECASE)
ALTER_TABLE = re.compile(r"^\s*ALTER\s+TABLE\s+(`[^`]+`|\S+)\s+(.*)$", re.IGNORECASE | re.DOTALL)
TABLE_OF = re.compile(
    r"^\s*(?:ALTER\s+TABLE|CREATE\s+(?:TEMPORARY\s+)?TABLE(?:\s+IF\s+NOT\s+EXISTS)?|DROP\s+TABLE(?:\s+IF\s+EXISTS)?"
    r"|TRUNCATE(?:\s+TABLE)?|RENAME\s+TABLE)\s+(`[^`]+`|\S+)", re.IGNORECASE)
TRIGGER_ON = re.compile(r"\bON\s+(`[^`]+`|\S+)\s+FOR\s+EACH\s+ROW", re.IGNORECASE)
DATA_TABLE = re.compile(
    r"^\s*(?:INSERT\s+(?:IGNORE\s+)?INTO|REPLACE\s+INTO|UPDATE(?:\s+IGNORE)?|DELETE\s+FROM)\s+(`[^`]+`|[^\s(]+)", re.IGNORECASE)
DEFINER = re.compile(rb"DEFINER\s*=\s*(`[^`]*`|'[^']*'|\S+)@(`[^`]*`|'[^']*'|\S+)")
DATABASE = "rehearsal"


def unquote(name):
    name = name.strip().rstrip(";")
    if "." in name and not name.startswith("`"):
        name = name.split(".")[-1]
    return name.replace("`", "").split(".")[-1]


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


class Server:
    """A throwaway MariaDB in Docker, reached through `docker exec`."""

    def __init__(self, image, row_format):
        self.name = "lock-rehearsal-" + secrets.token_hex(4)
        self.port = free_port()
        self.password = secrets.token_hex(16)
        subprocess.run(
            ["docker", "run", "-d", "--rm", "--name", self.name,
             "-p", f"127.0.0.1:{self.port}:3306",
             "-e", f"MARIADB_ROOT_PASSWORD={self.password}",
             "--memory", "2g", "--cpus", "2",
             image,
             "--general-log=1", "--log-output=TABLE",
             f"--innodb-default-row-format={row_format}",
             "--sql-mode=", "--max-allowed-packet=256M"],
            check=True, stdout=subprocess.DEVNULL)
        deadline = time.time() + 120
        while time.time() < deadline:
            if self.sql("SELECT 1", check=False).returncode == 0:
                return
            time.sleep(1)
        self.stop()
        raise SystemExit("the rehearsal database did not start within 120 seconds")

    # Over TCP: the image's entrypoint first runs a temporary server with
    # networking off, which answers on the socket and then shuts down.
    def client(self):
        return ["docker", "exec", "-i", self.name, "mariadb", "-uroot", f"-p{self.password}",
                "--protocol=TCP", "-h127.0.0.1"]

    def sql(self, statement, database=None, check=True):
        cmd = self.client() + ["--batch", "--skip-column-names", "--raw"]
        if database:
            cmd.append(database)
        return subprocess.run(cmd, input=statement, text=True, capture_output=True, check=check)

    def load(self, dump):
        """Loads the dump, without the DEFINER clauses naming production's users."""
        self.sql(f"DROP DATABASE IF EXISTS {DATABASE}; CREATE DATABASE {DATABASE}")
        with open(dump, "rb") as source:
            text = DEFINER.sub(b"", source.read())
        result = subprocess.run(self.client() + [DATABASE], input=text, capture_output=True, check=False)
        if result.returncode:
            raise SystemExit("the dump did not load: " + result.stderr.decode(errors="replace")[-2000:])

    def version(self):
        return self.sql("SELECT VERSION()").stdout.strip()

    def stop(self):
        subprocess.run(["docker", "rm", "-f", self.name], capture_output=True, check=False)


class SearchStandIn:
    """Answers setup:upgrade's search engine check, which only needs a reply."""

    class Handler(BaseHTTPRequestHandler):
        def _reply(self):
            body = json.dumps({"version": {"number": "2.19.0", "distribution": "opensearch"},
                               "tagline": "rehearsal"}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            if self.command != "HEAD":
                self.wfile.write(body)

        do_GET = do_HEAD = do_POST = do_PUT = _reply

        def log_message(self, format, *args):
            pass

    def __init__(self):
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), self.Handler)
        self.port = self.server.server_address[1]
        threading.Thread(target=self.server.serve_forever, daemon=True).start()


def env_php(server, cache_dir):
    """An env.php for the copy: the rehearsal database, file caches, a throwaway key."""
    return f"""<?php
return [
    'backend' => ['frontName' => 'admin'],
    'crypt' => ['key' => '{secrets.token_hex(16)}'],
    'db' => ['table_prefix' => '', 'connection' => ['default' => [
        'host' => '127.0.0.1:{server.port}', 'dbname' => '{DATABASE}',
        'username' => 'root', 'password' => '{server.password}',
        'model' => 'mysql4', 'engine' => 'innodb', 'initStatements' => 'SET NAMES utf8mb4;',
        'active' => '1', 'driver_options' => [1014 => false]]]],
    'resource' => ['default_setup' => ['connection' => 'default']],
    'x-frame-options' => 'SAMEORIGIN',
    'MAGE_MODE' => 'production',
    'session' => ['save' => 'files'],
    'cache' => ['frontend' => [
        'default' => ['backend' => 'Cm_Cache_Backend_File', 'backend_options' => ['cache_dir' => '{cache_dir}/default']],
        'page_cache' => ['backend' => 'Cm_Cache_Backend_File', 'backend_options' => ['cache_dir' => '{cache_dir}/page']]]],
    'install' => ['date' => 'Thu, 01 Jan 2026 00:00:00 +0000'],
];
"""


def copy_release(release, into):
    """The release without its static content and media, which setup:upgrade never reads."""
    skip = {os.path.join(release, "pub", "static"), os.path.join(release, "pub", "media"),
            os.path.join(release, "var")}

    def ignore(directory, names):
        return [n for n in names if os.path.join(directory, n) in skip]

    shutil.copytree(release, into, symlinks=True, ignore=ignore)
    for link in ("app/etc/env.php",):
        path = os.path.join(into, link)
        if os.path.islink(path) or os.path.exists(path):
            os.unlink(path)
    os.makedirs(os.path.join(into, "var"), exist_ok=True)


def point_search_at(server, port):
    server.sql(
        f"UPDATE core_config_data SET value = '127.0.0.1' WHERE path LIKE 'catalog/search/%server_hostname';"
        f"UPDATE core_config_data SET value = '{port}' WHERE path LIKE 'catalog/search/%server_port';"
        f"UPDATE core_config_data SET value = '0' WHERE path LIKE 'catalog/search/%enable_auth';",
        DATABASE)


def logged_statements(server):
    rows = server.sql(
        "SELECT REPLACE(REPLACE(CONVERT(argument USING utf8mb4), '\\\\', '\\\\\\\\'), '\\n', '\\\\n') "
        "FROM mysql.general_log WHERE command_type = 'Query' ORDER BY event_time",
        check=True).stdout
    statements = []
    for line in rows.splitlines():
        statements.append(line.replace("\\n", "\n").replace("\\\\", "\\"))
    return statements


def columns(server, table):
    out = server.sql(
        "SELECT COLUMN_NAME, COLUMN_TYPE, IS_NULLABLE FROM information_schema.COLUMNS "
        f"WHERE TABLE_SCHEMA = '{DATABASE}' AND TABLE_NAME = '{table}'").stdout
    return {c: (t, n) for c, t, n in (line.split("\t") for line in out.splitlines() if line)}


TYPE_RANK = {"tinyint": 1, "smallint": 2, "mediumint": 3, "int": 4, "bigint": 5,
             "char": 1, "varchar": 2, "tinytext": 3, "text": 4, "mediumtext": 5, "longtext": 6,
             "float": 1, "double": 2}
SIZED = re.compile(r"^(\w+)(?:\((\d+)(?:,(\d+))?\))?")


def narrowings(before, after):
    """Columns an ALTER made smaller, stricter or a different type: data can be cut."""
    found = []
    for name, (old_type, old_null) in before.items():
        if name not in after:
            continue
        new_type, new_null = after[name]
        if old_null == "YES" and new_null == "NO":
            found.append(f"{name}: NULL to NOT NULL")
        if old_type == new_type:
            continue
        o, n = SIZED.match(old_type), SIZED.match(new_type)
        if not o or not n:
            found.append(f"{name}: {old_type} to {new_type}, a change of type")
            continue
        o_base, n_base = o.group(1).lower(), n.group(1).lower()
        o_len, n_len = int(o.group(2) or 0), int(n.group(2) or 0)
        o_scale, n_scale = int(o.group(3) or 0), int(n.group(3) or 0)
        unsigned_lost = "unsigned" in old_type and "unsigned" not in new_type
        if o_base == n_base:
            if n_len < o_len or n_scale < o_scale or unsigned_lost:
                found.append(f"{name}: {old_type} to {new_type}")
        elif o_base in TYPE_RANK and n_base in TYPE_RANK and TYPE_RANK[n_base] < TYPE_RANK[o_base]:
            found.append(f"{name}: {old_type} to {new_type}")
        elif o_base not in TYPE_RANK or n_base not in TYPE_RANK:
            found.append(f"{name}: {old_type} to {new_type}, a change of type")
    return found


def classify(server, statement):
    """Replays one statement on the copy and returns its class and any error."""
    match = ALTER_TABLE.match(statement)
    if match:
        table, rest = match.group(1), match.group(2).rstrip().rstrip(";")
        for algorithm, lock, klass in (("INSTANT", None, "instant"), ("NOCOPY", None, "nocopy"),
                                       ("INPLACE", "NONE", "inplace")):
            clause = f"ALGORITHM={algorithm}" + (f", LOCK={lock}" if lock else "")
            if server.sql(f"ALTER TABLE {table} {clause}, {rest}", DATABASE, check=False).returncode == 0:
                return klass, None
        result = server.sql(statement, DATABASE, check=False)
        return "copy", (result.stderr.strip() or None) if result.returncode else None
    kind = statement.split(None, 2)
    head = " ".join(kind[:2]).upper() if len(kind) > 1 else statement.upper()
    klass = ("trigger" if "TRIGGER" in head else
             "new table" if head.startswith(("CREATE TABLE", "CREATE TEMPORARY")) else
             "drop table" if head.startswith("DROP TABLE") else
             "other")
    result = server.sql(statement, DATABASE, check=False)
    return klass, (result.stderr.strip() or None) if result.returncode else None


def table_of(statement):
    trigger = TRIGGER_ON.search(statement)
    if trigger:
        return unquote(trigger.group(1))
    match = TABLE_OF.match(statement)
    return unquote(match.group(1)) if match else None


def main():
    parser = argparse.ArgumentParser(description="Rehearse setup:upgrade and classify its locks.")
    for flag in ("--release", "--dump", "--stats", "--image", "--out"):
        parser.add_argument(flag, required=True)
    args = parser.parse_args()

    with open(args.stats) as handle:
        stats = json.load(handle)
    work = tempfile.mkdtemp(prefix="lock-rehearsal-")
    server = None
    try:
        server = Server(args.image, stats.get("row_format", "dynamic"))
        rehearsal_version = server.version()
        want = ".".join(stats["version"].split(".")[:2])
        have = ".".join(rehearsal_version.split(".")[:2])
        if want != have:
            raise SystemExit(f"production runs {stats['version']} and {args.image} is {rehearsal_version}; "
                             f"the rehearsal must run on {want}")

        server.load(args.dump)
        search = SearchStandIn()
        point_search_at(server, search.port)
        before_patches = set(server.sql("SELECT patch_name FROM patch_list", DATABASE).stdout.split())

        release = os.path.join(work, "release")
        copy_release(args.release, release)
        cache_dir = os.path.join(work, "cache")
        with open(os.path.join(release, "app/etc/env.php"), "w") as handle:
            handle.write(env_php(server, cache_dir))

        server.sql("TRUNCATE mysql.general_log")
        started = time.time()
        upgrade = subprocess.run(
            ["php", "bin/magento", "setup:upgrade", "--keep-generated", "--no-interaction"],
            cwd=release, capture_output=True, text=True, check=False)
        upgrade_seconds = round(time.time() - started, 1)
        statements = [s for s in logged_statements(server)
                      if "general_log" not in s and "information_schema" not in s.lower()]
        applied = sorted(set(server.sql("SELECT patch_name FROM patch_list", DATABASE).stdout.split())
                         - before_patches)

        schema = [s for s in statements if SCHEMA_STATEMENT.match(s)
                  and not re.match(r"^\s*(CREATE|DROP)\s+TEMPORARY", s, re.IGNORECASE)]
        data = [s for s in statements if DATA_STATEMENT.match(s)]
        data_by_table = {}
        for statement in data:
            match = DATA_TABLE.match(statement)
            name = unquote(match.group(1)) if match else "?"
            data_by_table[name] = data_by_table.get(name, 0) + 1

        # Replay on a fresh copy, one statement at a time, asking for the cheapest algorithm.
        server.load(args.dump)
        tables = stats.get("tables", {})
        report_statements = []
        for statement in schema:
            table = table_of(statement)
            before = columns(server, table) if table and ALTER_TABLE.match(statement) else {}
            klass, error = classify(server, statement)
            after = columns(server, table) if before else {}
            size = tables.get(table or "", {})
            report_statements.append({
                "statement": statement if len(statement) <= 2000 else statement[:2000] + "...",
                "table": table,
                "class": klass,
                "rows": size.get("rows"),
                "bytes": size.get("bytes"),
                "narrowing": [f"{table}.{change}" for change in narrowings(before, after)],
                "error": error,
            })

        report = {
            "production_version": stats["version"],
            "rehearsal_version": rehearsal_version,
            "row_format": stats.get("row_format"),
            "upgrade_exit": upgrade.returncode,
            "upgrade_output_tail": upgrade.stdout[-4000:] + upgrade.stderr[-4000:],
            "upgrade_seconds_on_empty_tables": upgrade_seconds,
            "statements": report_statements,
            "patches_applied": applied,
            "data_statements": len(data),
            "data_statements_by_table": dict(sorted(data_by_table.items(), key=lambda kv: -kv[1])),
            "blind_spots": [
                ("Data patches and recurring scripts ran on tables that are empty here, so what they cost "
                 "on production's rows is not measured; only their names and statement counts are."),
                ("A class is the best case: production's table may already carry instant changes, or a "
                 "row format or FULLTEXT index the copy does not, that turn the next change into a rebuild."),
                ("Triggers take a metadata lock on their table, which waits for every open transaction on "
                 "it; how long depends on production's traffic, not on the table's size."),
            ],
        }
        with open(args.out, "w") as handle:
            json.dump(report, handle, indent=1)
        return 0 if upgrade.returncode == 0 else 3
    finally:
        if server:
            server.stop()
        shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
