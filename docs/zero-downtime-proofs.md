# Zero-downtime proofs

**`bin/zdt-proof` runs eight proofs against a real Magento store and prints
the evidence for or against the assumptions a zero-downtime deploy rests on.**
Where it can, a proof puts the store into the failure first, on purpose, and
then applies the fix, so a quiet check later in the run means something. Every
expectation is a falsifier: a claim that would be wrong if its line said FAIL.
Two wrappers run four of the proofs on a store in production mode.

This page says what each proof claims, how it produces the failure and the fix,
and which PASS and FAIL lines it prints. It does not record results: those
belong to whoever ran the proof, on their store, at their Magento version. Run
them and keep the transcript.

## Contents

- [Running the proofs](#running-the-proofs)
- [Reading a run](#reading-a-run)
- [P0-1: two schema revisions diff into the release's DDL](#p0-1-two-schema-revisions-diff-into-the-releases-ddl)
- [P0-2: code ahead of the schema fails, a schema ahead of the code does not](#p0-2-code-ahead-of-the-schema-fails-a-schema-ahead-of-the-code-does-not)
- [P0-3: a narrowing column change is non-destructive to Magento and still breaks data](#p0-3-a-narrowing-column-change-is-non-destructive-to-magento-and-still-breaks-data)
- [P1-1: two releases sharing one cache read each other's configuration](#p1-1-two-releases-sharing-one-cache-read-each-others-configuration)
- [P1-2: static asset URLs from before a flip](#p1-2-static-asset-urls-from-before-a-flip)
- [P1-3: a php-fpm reload after a symlink flip](#p1-3-a-php-fpm-reload-after-a-symlink-flip)
- [P1-4: a substituted schema writer emits exactly the stock SQL](#p1-4-a-substituted-schema-writer-emits-exactly-the-stock-sql)
- [P1-5: a patch_list row written out of band marks a patch applied](#p1-5-a-patch_list-row-written-out-of-band-marks-a-patch-applied)
- [Running the framework proofs on a production store](#running-the-framework-proofs-on-a-production-store)
- [The fleet checks: `bin/zdt-fleet`](#the-fleet-checks-binzdt-fleet)
- [The fleet arms: `bin/zdt-arm`](#the-fleet-arms-binzdt-arm)

## Running the proofs

The proofs run against a store managed by
[Kapelos](https://github.com/kingletas/kapelos), which gives each site its own
containers, database and snapshots. The runner reads the site's settings file
from the Kapelos checkout, finds its PHP and database containers, copies its
PHP payloads and the fixture module into the store's tree under
`local.d/zdt-proof/`, and runs them in the store's PHP container.

```bash
export KAPELOS_HOME=/path/to/kapelos      # required; nothing is guessed
bin/zdt-proof list                        # every proof and what it shows
"$KAPELOS_HOME"/bin/kapelos snapshot save clean
bin/zdt-proof p0-2                        # one proof, against the active site
ZDT_SITE=acme bin/zdt-proof p1-5          # against a named site instead
```

**Never point a proof at a store holding real data.** They alter the schema,
create products and admin users, edit `app/etc/config.php` and `env.php`, and
restore Kapelos snapshots over the database. Use an empty or generated store.

What the host needs: bash, Docker, curl, rsync, python3 and GNU coreutils. The
store needs a working storefront at `MAGENTO_BASE_URL` and a MariaDB container
Kapelos manages.

The first proof that needs the fixture module installs it in `app/code`,
enables it in `config.php`, runs `setup:upgrade`, and saves a Kapelos snapshot
named `fixture`. The proofs that change the schema put the fixture back, code
and database, when they finish, and most do so before they start as well, so a
proof does not depend on what the one before it left.

Three proofs, P1-1, P1-2 and P1-3, need a site laid out the way this playbook
deploys: a `releases/` directory, a `magento_current` symlink into it, and
`shared/env.php` linked into each release. The rest run on an ordinary store.

| Variable | What it changes |
|---|---|
| `KAPELOS_HOME` | The Kapelos checkout. Required: a proof refuses to start without it, and says so |
| `ZDT_SITE` | The Kapelos site (default: the active one) |
| `ZDT_ROOT` | The Magento root inside the container, for a store laid out as releases (default: where the container mounts the site) |
| `ZDT_EXEC_USER` | Run PHP in the container as this user, for example `www-data` (default: the container's own user) |
| `ZDT_BASE_URL` | The storefront URL (default: `MAGENTO_BASE_URL` from the site's settings) |

Individual proofs take a few more, listed in their own sections and in the
header of each script in `bin/zdt-proof.d/proofs/`.

## Reading a run

Each proof prints `== step` headings as it goes, then one line per check:

- `PASS  <what held>`: the expectation on the line held.
- `FAIL  <what did not>`: it did not. The run exits 1 if any line failed.
- `NOTE  <what was seen>`: recorded, not judged. A NOTE is something the proof
  measures because it matters for the design, without claiming an answer.

The last line counts them: `p0-2.sh on site acme: <n> passed, <n> failed`.
Everything a proof collected along the way, such as response bodies, dry-run
SQL and diffs, is left in `<store>/local.d/zdt-proof/out/<proof>/`.

**A negative control runs before the check it protects.** Where a proof relies
on something staying quiet, it first makes that thing fire on purpose and
prints a PASS for it. If the control fails, the quiet result after it proves
nothing, and the proof says so.

Two FAIL lines report a hazard rather than a broken proof, and are described
where they occur: the setup_version check at the end of P0-2, and the first
F12a line in P1-2.

## P0-1: two schema revisions diff into the release's DDL

`bin/zdt-proof p0-1`

**The claim.** A deploy can work out the schema changes a release needs
from two revisions of the code's `db_schema.xml`, without a live database:
Magento's declared schema can be built with no connection, carried from one
process to another, diffed, and rendered as SQL that matches what
`setup:upgrade --dry-run=1` writes for the same change.

**Failure, then fix.** It writes a copy of `app/etc` whose database host
cannot resolve and which has no Redis cache, session or queue, standing in for
a CI job with no services. It builds the declared schema three ways: with the
store's database, with none, and with none but with the server version
supplied by a stand-in `SqlVersionProvider`. The stock build without a database
is recorded as a NOTE when it fails; the build with the version supplied is the
fix.

**Falsifiers.**

| ID | Would be wrong if | PASS line | FAIL line |
|---|---|---|---|
| F1a | building a declared schema needs a live connection | `with the server version supplied, the schema builds against an unresolvable host with no connection opened` | `the schema cannot be built without a database even with the version supplied` |
| F1a | the two builds differ | `both builds have <n> tables` | `table counts differ: ...` |
| F1b | a schema diffed against itself returns changes | `self-diff is empty` | `self-diff is not empty` |
| F1b | the diff cannot see a change at all (negative control: one column length altered) | `negative control: one altered column registers` | `negative control: the diff did not see an altered column` |
| F1c | the XML array cannot carry an old revision into another process | `the plain XML array round-trips through JSON with an empty diff` | `the JSON round trip does not diff empty` |
| F1c | `serialize()` cannot carry the Schema object | `serialize() round-trips the Schema object with an empty diff` | none: a failure here is a NOTE |
| F1d | the two-revision SQL differs from `setup:upgrade --dry-run=1` | `the two-revision SQL is the dry run's SQL, statement for statement` | `the two-revision SQL differs from the dry run` |
| F1d | a fresh install already dry-runs to statements | `a fresh install dry-runs to nothing, so the comparison has no noise` | none: the statements are subtracted and a NOTE says so |

F1d's ground truth is two dry runs, before and after the fixture gains a
`colour` column. The dry run's statements, less the baseline's, are compared
with the SQL the two-revision diff renders. F1e is recorded, not a falsifier:
whether rendering that SQL needs a connection, as NOTE lines. It fails only if
the no-database run never reached a diff.

`ZDT_SQL_VERSION_FIXED` is the version the stand-in reports (default `11.4.`).
The stand-in always answers as MariaDB, so set it to your MariaDB server's
major.minor and a trailing dot.

The copy of `app/etc` holds the store's credentials, so the proof deletes it
before restoring the `fixture` snapshot.

## P0-2: code ahead of the schema fails, a schema ahead of the code does not

`bin/zdt-proof p0-2`

**The claim.** The safe order for a release that adds a column is schema
first, code second: code that reads a column the database lacks fails, while
the previous release keeps working on a database that already has the new
column. It checks that with real requests, and checks that neither of
Magento's two request-blocking guards stops the old release.

**Failure, then fix.** The fixture module has a probe controller at
`/zdtproof/probe/index` that selects a fixed list of columns. The proof swaps
in a version that also selects `colour`, before the column exists, and
requests the probe. Then it reverts the code and requests it again. Next it
expands: adds the column and the code that reads it, and runs `setup:upgrade`.
Then it puts the old code back over the new schema, which is the moment in a
deploy when the old release is still serving and the database has moved on.

**Falsifiers.**

| ID | Would be wrong if | PASS line | FAIL line |
|---|---|---|---|
| control | the probe fails with nothing mismatched | `control: the probe answers 200 when code and schema agree` | `control: the probe answers <code> with nothing mismatched, ...` |
| F2a | code selecting a missing column does not fail | `code selecting a missing column answers <5xx> with Unknown column` | `code selecting a missing column answered <code>` |
| F2a fix | reverting the code does not recover | `fix: reverting the code brings the probe back to 200` | `fix: the probe still answers <code> after reverting` |
| expand | the new code cannot read the new column | `expanded: the new code reads the new column` | `expanded: probe answers <code>: ...` |
| F2b | with the database ahead, the home page fails | `home page 200 with the database ahead` | `home page answered <code> with the database ahead` |
| F2b | a product page fails | `product page 200 with the database ahead` | `product page answered <code> ...` |
| F2b | the old probe code fails | `the old probe code still reads its own columns` | `the old probe answered <code>` |
| F2b | an admin cannot log in | `admin login gets past the login form to <url> with the database ahead` | `admin login answered <code> (<title>)` |
| F2b | a guest cannot place an order through REST | `guest order <id> placed through REST with the database ahead` | `guest order failed: ...` |
| F2c control | `DbStatusValidator` cannot fire here (a `setup_version` bumped ahead of the database) | `negative control: a setup_version ahead of the database blocks the storefront (..., 'Please upgrade your database')` | `negative control: DbStatusValidator did not fire` |
| F2c | `DbStatusValidator` blocks the old release when only a column is ahead | `DbStatusValidator is quiet with the column ahead and versions equal` | `home answered <code> with only the column ahead` |
| F2c control | `ConfigChangeDetector` cannot fire here (an edited `config.php`) | `negative control: an edited config.php blocks the storefront (..., 'The configuration file has changed')` | `negative control: ConfigChangeDetector did not fire` |
| F2c | `ConfigChangeDetector` blocks the old release | `ConfigChangeDetector is quiet with the column ahead` | `home answered <code> after config.php was put back` |

The admin login uses `MAGENTO_ADMIN_USER`, `MAGENTO_ADMIN_PASSWORD` and
`MAGENTO_ADMIN_URI` from the site's settings. With no password there, it
creates a throwaway admin in the database the proof restores afterwards. The
password reaches curl through its config parser on stdin, never a command
line. The guest order uses flat-rate shipping and check/money order, so both
must be enabled.

It also records, as NOTE lines, what `setup:db:status` says while the database
is ahead, with the old release's whitelist and with the new whitelist left in
place, and which plugins sit on `FrontController` (F2d, in `f2d-di-info.txt`,
to be judged by reading each one).

**The last check reports a hazard.** It bumps the module's `setup_version`,
runs `setup:upgrade`, then puts the old code back and clears the config
cache. If the storefront answers "Please update your modules", the line is
`FAIL  database ahead is not harmless when a release bumps setup_version`.
That FAIL means the old code refuses to serve once the database records a
newer `setup_version`, which a column ahead does not cause. A NOTE before it
records whether the old code is checked at all while the config cache still
holds `db_is_up_to_date`.

`ZDT_PRODUCT_SKU` and `ZDT_PRODUCT_PATH` name an existing in-stock simple
product instead of creating `zdt-simple`, for a store where saving a product
through the API is slow.

## P0-3: a narrowing column change is non-destructive to Magento and still breaks data

`bin/zdt-proof p0-3`

**The claim.** Magento does not class a column change that narrows it as
destructive, so nothing in `setup:upgrade` stops it, yet over rows that do not
fit, the change either fails at DDL time or silently changes the data. The
proof finds out which, and whether Magento's own connection is the reason.

**Failure, then fix.** Three changes, each over rows that violate it:

- `narrow-varchar`: a `varchar(255)` narrowed to 8 over a longer value
- `narrow-int`: an `int` narrowed to `smallint` over 40000
- `not-null`: NOT NULL added over a null

Each runs three ways. Through Magento: edit the fixture's XML and run
`setup:upgrade`, so the DDL goes through Magento's connection, which sets
`SQL_MODE=''`. From a client in the server's default SQL mode (`strict`). From
a client after `SET sql_mode=''` (`empty`), which isolates Magento's
connection setting as the cause. The client runs repeat on MySQL 8.0, from the
host's own `mysqld` started in a throwaway directory under `/tmp` and removed
at the end. This proof has no fix step: it establishes the failure and
classifies it. The playbook's answer is the narrowing check in
[the setup:upgrade rehearsal](../README.md#rehearsing-setupupgrade), which stops
a narrowed column until it is accepted by name.

**Falsifiers.**

| ID | Would be wrong if | PASS line | FAIL line |
|---|---|---|---|
| F3a | `ModifyColumn::isOperationDestructive()` is true at runtime | `ModifyColumn reports itself non-destructive` | `ModifyColumn reports itself destructive` |
| F3b | a violating change neither errors nor changes the data | `<case> through Magento: <verdict>`, one per case | `<case>/<path>: a violating change had no effect`, for any path |

Each case and path gets a verdict, printed in a table and kept in
`verdicts.txt`: `fails at DDL time: <error>`, `corrupts silently (<before> ->
<after>)`, or `no effect`. When any path corrupts silently, a NOTE says a CI
gate cannot decide that change on its own. When `narrow-varchar` corrupts
through Magento, the proof also records what a later write through Magento's
connection stores, with its session SQL mode and warnings.

`ZDT_MYSQLD` is the MySQL server binary (default `/usr/sbin/mysqld`). Set it
empty to skip the MySQL 8.0 leg; a missing binary skips it with a NOTE.

## P1-1: two releases sharing one cache read each other's configuration

`bin/zdt-proof p1-1`, on a site laid out as releases.

**The claim.** Two releases that share `env.php`, and so share its cache
`id_prefix`, read each other's merged configuration from the cache, which the
proof shows with one event observer. During a deploy the old and new releases
both serve. Giving each release its own prefix stops it.

**Failure, then fix.** It copies the current release twice, as `zdt_a` and
`zdt_b`, and enables in `zdt_b` only a module declaring one observer on the
event `zdt_cache_probe`. It then asks each release how many observers that
event has, reading A then B and B then A with the cache flushed before each
pair. The failure is the shared prefix. The fixes are no `id_prefix` in
`env.php`, so each release derives one from its own path, and an explicit,
different prefix in each release's own `env.php`.

**Falsifiers.**

| ID | Would be wrong if | PASS line | FAIL line |
|---|---|---|---|
| control | the releases do not really differ | `control: read cold, zdt_a has 0 observers and zdt_b has 1` | `control: cold reads A=<n> B=<n>, ...` |
| F11a | with the shared prefix, the second release sees its own configuration | `warmed by A, B reads A's configuration: its own observer is missing` | `warmed by A, B still sees its own observer` |
| F11a | the same, the other way round | `warmed by B, A reads B's configuration: an observer whose class A does not have` | `warmed by B, A sees <n> observers` |
| F11b | derived prefixes are not per release | `derived prefixes differ per release (<a>, <b>)` | `derived prefixes are the same` |
| F11b | derived prefixes do not stop the interference | `with derived prefixes each release reads only its own configuration` | `derived prefixes still interfere` |
| F11b | explicit prefixes do not stop it | `with explicit different prefixes each release reads only its own configuration` | `explicit prefixes still interfere` |

It puts back the shared `env.php` and deletes both copies when it finishes,
whatever happened. `ZDT_SOURCE_RELEASE` names the release to copy (default:
the one `magento_current` points at).

## P1-2: static asset URLs from before a flip

`bin/zdt-proof p1-2`, on a site laid out as releases.

**The claim.** Which static asset URLs a page rendered by the old release
can still load once the symlink has flipped. Magento's nginx sample rewrites
`/static/version<N>/x` to `/static/x` before looking for the file, so the
version number alone cannot make a URL fail. What can is a file the new
release does not have.

**Failure, then fix.** It renders the storefront from an older release,
collects up to eight CSS and JS URLs from the page, and adds one for a
sentinel file placed only in the old release's `pub/static`. It flips to the
current release and requests them all again. The fix is the file present where
the new release serves from.

**Falsifiers.**

| ID | Would be wrong if | PASS line | FAIL line |
|---|---|---|---|
| control | the page does not carry the old version | `control: the page rendered from the old release carries version <n>` | `control: the page does not carry the old release's version` |
| control | the URLs fail even before the flip | `control: all <n> URLs answer 200 before the flip` | `control: <n> URLs fail before the flip` |
| F12a | an old-version asset URL still answers 200 after the flip | `<n> of <m> old-version asset URLs fail after the flip` | `every asset URL carrying the old version still answers 200 after the flip (...): the version number alone does not break them` |
| F12a | a file only the old release had still loads | `a file only the old release had answers 404 after the flip` | `the old-only file answers <code> after the flip` |
| F12b | with the file present in the new release, the old URL fails | `with the file present in the new release, the old-version URL answers 200` | `the old-version URL answers <code> with the file present` |

**The first F12a line reports a finding either way.** A FAIL there means the
old version number did not break any collected URL, so what breaks a page
mid-deploy is a missing file, which the sentinel then shows.

A superseded release keeps the maintenance flag the next deploy set in it,
because `var/` is not shared. The proof sets that flag aside while it serves
from the old release and puts it back byte for byte, removes both sentinels,
and flips back. `ZDT_OLD_RELEASE` names the release to render from (default:
the newest release other than the current one).

## P1-3: a php-fpm reload after a symlink flip

`bin/zdt-proof p1-3`, on a site laid out as releases.

**The claim.** After the `magento_current` symlink flips, php-fpm serves
the new release once it has been reloaded with USR2, the signal the playbook's
service task sends. The proof tests that with `opcache.validate_timestamps` as
the site has it and with it off, as production commonly runs.

**Failure, then fix.** It reads which release renders each response from the
static version in the page, 20 requests per reading, past Varnish. It flips
without reloading first, which is the negative control, then reloads, then
flips back and reloads again. It does this once per setting.

**Falsifiers.** `F13a` is the site's own setting, `F13b` is
`opcache.validate_timestamps=0`, set with an ini file the proof removes.

| ID | Would be wrong if | PASS line | FAIL line |
|---|---|---|---|
| F13a, F13b | the baseline is not the current release | none | `baseline: expected only <v>, saw ...` |
| F13a, F13b | without a reload, the new release serves at once | `negative control: without a reload the previous release still serves (...)` | none: a NOTE says the reload is not what makes the flip work here |
| F13a, F13b | after a flip and a reload, a request still renders the old release | `after the reload every request renders the flipped-to release` | `after the reload requests still render: ...` |
| F13a, F13b | flipping back does not return | `flipping back and reloading returns every request to the original release` | `after flipping back: ...` |

`ZDT_REQUESTS` sets the requests per reading (default 20), and
`ZDT_OLD_RELEASE` the release to flip to (default: the newest other one). The
proof sets the old release's maintenance flag aside and puts it back, and
flips back and reloads before it finishes.

## P1-4: a substituted schema writer emits exactly the stock SQL

`bin/zdt-proof p1-4`

**The claim.** A module can replace Magento's `DbSchemaWriterInterface`
with its own writer. It proves the seam rather than any particular writer: a
writer that records every statement and delegates the rest to the stock writer
reaches `OperationsExecutor` and changes nothing about the SQL, in a dry run
and in a real run.

**Failure, then fix.** It adds one column with the stock writer, in a dry run
and a real run, then again with the recording writer in place. The real-run
comparison reads MariaDB's general query log, switched on for one
`setup:upgrade` and off straight after. Indexers create and drop tables with
random suffixes during `setup:upgrade`, so real runs are compared with those
masked; the raw files are kept. The negative control is a writer that adds one
statement, which the same comparison must catch.

**Falsifiers.**

| ID | Would be wrong if | PASS line | FAIL line |
|---|---|---|---|
| F4a | a module's preference is not the writer in use | `dev:di:info resolves the interface to the recording writer` | `dev:di:info does not show the recording writer` |
| F4a | `OperationsExecutor` never calls it | `OperationsExecutor called the recording writer during setup:upgrade` | `the recording writer was never called` |
| F4b | the dry-run SQL differs from stock | `dry run: byte-identical to stock` | `dry run differs from stock` |
| F4b | the server receives different DDL | `real run: the server received identical DDL, temp-table suffixes masked` | `real run: the server received different DDL even with temp-table suffixes masked` |
| F4b control | the comparison cannot see an added statement | `negative control: the comparison catches an added statement` | `negative control: the comparison missed an added statement` |

## P1-5: a patch_list row written out of band marks a patch applied

`bin/zdt-proof p1-5`

**The claim.** Magento decides whether a data patch has run only from its
row in `patch_list`. So a row written out of band, with
`PatchHistory::fixPatch()`, marks a patch applied, and both `setup:db:status`
and `setup:upgrade` believe it.

**Failure, then fix.** It adds a data patch that inserts one marker row, and
shows it pending. It marks the patch applied before it has ever run, and
checks that status and upgrade both skip it. Then it removes the mark and
watches the patch run, so the row is shown to be what they actually read.

**Falsifiers.**

| ID | Would be wrong if | PASS line | FAIL line |
|---|---|---|---|
| control | the new patch is not seen as pending | `control: setup:db:status sees the new patch as pending` | `control: setup:db:status does not see the new patch` |
| F5a | with the row written, status reports the patch pending | `setup:db:status believes the mark` | `setup:db:status still reports: ...` |
| F5a | with the row written, `setup:upgrade` runs it | `setup:upgrade does not run a marked patch` | `setup:upgrade ran the marked patch anyway` |
| F5b | with the row removed, the patch is not pending | `with the row gone the patch is pending again` | `with the row gone status says: ...` |
| F5b | with the row removed, `setup:upgrade` does not run it | `setup:upgrade runs the patch once the row is gone, and records it again` | `the patch did not run after its row was removed` |

## Running the framework proofs on a production store

P0-1, P0-2, P1-4 and P1-5 install a fixture module, which a store in
production mode cannot see until `setup:di:compile` runs. Two wrappers run
those four without compiling, and put the store back whatever they report.
Both refuse to start without a Kapelos snapshot taken beforehand, named by
`ZDT_RESTORE_SNAPSHOT` (default `before-zdt`), and both take `ZDT_PROOFS` to
run a different list.

`bin/zdt-proof framework-dev-mode` copies `generated/` aside, removes the
compiled DI in `generated/metadata`, sets `MAGE_MODE` to developer in
`env.php`, and runs the proofs. Afterwards it puts back `generated/`,
`env.php` and `config.php` byte for byte, removes the fixture module, restores
the snapshot, and checks `pub/static` against a fingerprint taken before
anything changed. A lock stops a second run from starting while one is going.

`bin/zdt-proof framework-on-release` is for a site laid out as releases, where
the proofs must not touch the live release. It copies the current release to
`releases/zdt_fw`, points `magento_current` at the copy, and runs the proofs
against it as the web server's user (`ZDT_EXEC_USER`, default `www-data`).
Afterwards it flips back, reloads php-fpm, deletes the copy and the `fixture`
snapshot, and restores the named snapshot. Each proof's output is kept in the
site's `local.d/zdt-proof/out/fw-<proof>/`.

## The fleet checks: `bin/zdt-fleet`

`bin/zdt-proof` proves claims about one Magento install. The fleet arms of
issue #5 need something narrower first: a standing check that the shape a run
is performed on — a primary with a replica, replicating — is real, and the
facts the falsifiers judge against, recorded. `bin/zdt-fleet` is that check.
It deploys nothing and changes nothing; it verifies and records.

Connection details come from the environment, never from arguments, so no
password lands in a shell history or in a run transcript. The client is
`mysql`, which speaks to MariaDB servers too, and the password travels in
`MYSQL_PWD`, which keeps it out of `ps` output as well.

| Variable | Meaning |
|---|---|
| `ZDT_PRIMARY_HOST` / `ZDT_PRIMARY_PORT` / `ZDT_PRIMARY_USER` / `ZDT_PRIMARY_PASSWORD` | the primary's connection (port defaults to 3306) |
| `ZDT_PRIMARY_DATABASE` | required; where the tables live (`CHECKSUM TABLE` with no default database is error 1046) |
| `ZDT_REPLICA_HOST` / `ZDT_REPLICA_PORT` / `ZDT_REPLICA_USER` / `ZDT_REPLICA_PASSWORD` | the replica's connection (port defaults to 3306) |
| `ZDT_REPLICA_DATABASE` | required; as on the primary |

### `bin/zdt-fleet replica-check`

Asks the replica for its status and refuses to pass unless it is live: the IO
thread `Yes`, the SQL thread `Yes`, `Last_SQL_Errno` 0, and the lag a number
rather than `NULL`. Every failed condition prints with its value and the exit
is 1. Column names depend on the server: MySQL 8.0.22+ answers with
`Replica_…` and `Seconds_Behind_Source`; MariaDB keeps `Slave_…` and
`Seconds_Behind_Master` in every version, including under `SHOW REPLICA
STATUS`; and a server older than either only answers `SHOW SLAVE STATUS`, so
the older command is tried when the newer returns nothing. Both spellings are
read. The gate judges a *single-channel* replica: several status rows from
one server (MySQL multi-source) are refused with exit 2 rather than partially
read. Note that MariaDB answers `SHOW REPLICA STATUS` with only the default
connection — named channels appear only under `SHOW ALL SLAVES STATUS` — so a
MariaDB fleet with named multi-source channels is out of scope for this gate;
the lab fleet is single-source by design. When neither status command answers,
the refusal quotes each failed attempt's error, labelled with its command, so a
wrong password or an unreachable host reads as itself.

When the replica is live, it prints one JSON object on standard output:

```bash
ZDT_PRIMARY_HOST=primary.db ZDT_PRIMARY_USER=root ZDT_PRIMARY_PASSWORD=… \
ZDT_PRIMARY_DATABASE=magento \
ZDT_REPLICA_HOST=replica.db ZDT_REPLICA_USER=root ZDT_REPLICA_PASSWORD=… \
ZDT_REPLICA_DATABASE=magento \
bin/zdt-fleet replica-check
```

```json
{"timestamp": "2026-09-26T18:00:00Z", "binlog_format": "ROW", "catalogue_size": 1984, "binlog_bytes": 490, "seconds_behind": 0, "last_sql_errno": 0, "last_io_errno": 0, "last_sql_error": "", "last_io_error": ""}
```

A later arm takes this before and after a migration; the difference in
`binlog_bytes` is what the upgrade wrote, and `catalogue_size` is what a
checksum pair is judged against.

### `bin/zdt-fleet table-checksums TABLE…`

Runs `CHECKSUM TABLE` for each named table on both servers and prints one
line per table, `MATCH` or `DIFFER` with both values; exit 1 if any pair
differs. Falsifier 1 uses it once `seconds_behind` has returned to zero; a
differing checksum makes that falsifier false. A `NULL` checksum — what a
server answers for a table it does not have — never counts as a match, even
when both sides answer `NULL`: a typo'd or wrong-database table is a failure
of the check, not an agreement. A query that fails outright (unreachable
server, missing privileges) exits 2, the "the check never happened" code, so
it cannot masquerade as a DIFFER.

A caveat for the arms that subtract: `binlog_bytes` is the sum of the binary
log files that exist at the moment of the call. If a log is purged during the
migration (`PURGE BINARY LOGS`, `binlog_expire_logs_seconds`), "after minus
before" undercounts what the upgrade wrote and can even go negative. A run
that needs an exact figure should disable expiry for its window or account
for purges.

### Exit codes

0 is all good; 1 is a failed check — the fleet is not live, or a checksum
differs; 2 is the tool could not run at all: no settings, a bad name, no
client, or a query that failed outright (unreachable server, no privileges).
A run records them differently: 1 is a FAIL of a falsifier, 2 means
the run did not happen. On exit 2 stdout may hold partial output — a
`table-checksums` that dies on a later table has already printed its earlier
`MATCH` lines — so trust the exit code before parsing stdout.

The tests (`tests/test_zdt_fleet.py`, run by `make check`) use a fake `mysql`
client returning canned output.


## The fleet arms: `bin/zdt-arm`

`bin/zdt-fleet` checks and records; `bin/zdt-arm` runs things. It is the
runner for the fleet arms of [issue #5](https://github.com/kingletas/magento-deploy-playbook/issues/5),
built on the interface the maintainer approved: one command per step from the
control machine over ssh, the arms driving the migration end to end on the
admin node, a built-in traffic generator, and the cache prefixes and the
blue/green flag set and restored by the scripts themselves. Arms 1 and 2 are
here; arms 3 and 4 come in their own pull requests (arm 3 is in this build).

```bash
bin/zdt-arm list
bin/zdt-arm arm1 -n     # print the whole plan, run nothing
bin/zdt-arm arm1        # show the plan, then ask before the first remote write
bin/zdt-arm arm1 -y     # the same, without asking (for an operator who means it)
```

- **arm1** — the migration with `deployment/blue_green/enabled` off
  everywhere: first with one shared cache prefix, then a prefix per release,
  with traffic on every server throughout.
- **arm2** — the same run with `deployment/blue_green/enabled` set in the
  `env.php` of every server that stays on the old code.
- **arm3** — two code versions against one database with the flag on, across
  a release that changes the schema: first the additive **control**, then the
  breaking **evidence** (see *Arm 3* below).
- **restore-snapshot** — put a snapshot back on the primary. Destructive, so
  it plans and asks like the arms.

### How a run is kept safe

- `-n` prints the whole plan, every command in order, and runs nothing.
  Without `-y` the arm shows the plan and asks before its first remote write;
  with no terminal to answer, it stops rather than guessing (exit 2).
- Before `setup:upgrade` the arm takes a database snapshot on
  `ZDT_ADMIN_NODE`, prints the exact command that restores it, and refuses to
  go on if the snapshot fails.
- Before the first edit, every node's `env.php` is copied to a dated backup
  on its node, and the exact restore command is printed — because an exit
  trap restores on the paths it can reach, and not on `SIGKILL` or a power
  cut.
- The traffic generator has a default rate of 2 requests a second per target
  and a hard refusal above 20, and a default duration of 120 s with a hard
  maximum of 600: the lab machine runs other things too. The mix asks routes a
  stock store answers anonymously (home, `/checkout/cart/`,
  `/rest/V1/directory/currency`, a real GraphQL query, `pub/health_check.php`)
  plus the category and product pages you name in `ZDT_CATEGORY_PATH` and
  `ZDT_PRODUCT_PATH`. A target counts as refusing only on a 5xx, no answer at
  all, or a guard-pattern match; a 4xx is a fact in `traffic.log`, not a
  refusal — a route that goes missing mid-migration still shows there.
- Every remote command is echoed before it runs, and any secret in it is
  echoed as `***`. Commands that carry the database password run it embedded
  in a script piped over ssh stdin, so it is in no argv, no `ps`, no shell
  history — and never in the transcript.
- ssh runs with `BatchMode=yes` and normal host-key checking; an unknown
  host stops the arm with its name. Nothing here can turn host key checking
  off — `bin/check-structure` refuses it.
- The replica gate from `bin/zdt-fleet replica-check` runs before anything:
  a replica that is not live means the run is reported as NOT RUN, missing
  condition 1, and no node is touched.

### Arm 3: the crossing, and why its variables have no defaults

Arm 3 is the arm the issue turns on, and its two legs are not symmetric. The
**additive control** (`ZDT_RELEASE_ADDITIVE`) only adds: old servers with the
flag on must serve pages, REST and GraphQL without a guard message. Per the
issue, passing it alone proves nothing — a release with nothing to reconcile
passes by construction — but a guard message here disproves the flag's claim
on the cheapest possible release. The **breaking evidence**
(`ZDT_RELEASE_BREAKING`) renames or drops a column the old code reads. Old
servers must fail across it, the first failure's own words must name the
changed object, and the read path must not sail through with a 200: an old
server answering 200 across a schema it does not match fails the falsifier,
not the run's silence passing it.

The database is restored between the two legs (the same snapshot mechanism as
arms 1 and 2), so the breaking leg starts from exactly the state the control
started from. Response bodies of failing read requests and guard matches are
saved under the run directory (`evidence-<leg>/`), named with the time so the
chronologically first failure is unambiguous — the log line alone cannot show
that the failure *names the column*.

`ZDT_READ_PATH` and `ZDT_SCHEMA_OBJECT` have no defaults, and neither have
the two releases: the breaking change and the route that reads it belong to
the lab, and a guessed one would poison the evidence chain — the issue says
the results "must name the request that reads that column and show it was
sent to an old server". A missing one stops arm 3 by name (exit 2, nothing
runs). Falsifier 2 on these editions stays a control reported in the results
document: nothing on Open Source or Mage-OS reads the replica.

### Variables

The hosts have no defaults: a missing one stops the arm by name rather than
aiming at a guess. All values come from the environment, never from
arguments, so no password lands in a shell history or a transcript.

| Variable | Meaning |
|---|---|
| `ZDT_WEB_HOSTS` | comma-separated ssh names of the web nodes (at least three) |
| `ZDT_NEW_NODE` | the always-new node; one of `ZDT_WEB_HOSTS` |
| `ZDT_ADMIN_NODE` | the node that runs Magento's commands and the snapshot; must be `ZDT_NEW_NODE` — the migration runs from `current`, so a split between the two is refused, naming both |
| `ZDT_LB_URL` | the load balancer's base URL |
| `ZDT_NODE_URLS` | comma-separated per-node base URLs, same order as `ZDT_WEB_HOSTS`; traffic goes to each node directly, so a refusing node is attributed to that node |
| `ZDT_RELEASE_TARBALL` | the new release, a path on the control machine |
| `ZDT_LABEL_NEW` / `ZDT_LABEL_OLD` | release directory names under `ZDT_RELEASES_DIR`; `ZDT_LABEL_OLD` must already be deployed on every node |
| `ZDT_ENV_PHP` | each node's `env.php` path (they are edited by `php -r`, backed up first) |
| `ZDT_DB_HOST` / `ZDT_DB_USER` / `ZDT_DB_PASSWORD` / `ZDT_DB_NAME` | the primary's connection, for the snapshot |
| `ZDT_SNAPSHOT_DIR` | where the admin node keeps snapshots (default `/var/www/magento/zdt-snapshots`) |
| `ZDT_RATE` / `ZDT_DURATION` | traffic per target: requests/s (default 2, max 20) and seconds (default 120, max 600) |
| `ZDT_GUARD_PATTERN` | extended regex; a response body matching it is logged as a guard message |
| `ZDT_CATEGORY_PATH` / `ZDT_PRODUCT_PATH` | paths of a real category and a real product page (e.g. `/mens.html`, `/products/gt.html`). No default: a guessed path a stock store does not serve would record every target as refusing |
| `ZDT_TOUCHED_TABLES` | comma-separated tables to checksum once the lag reaches zero (default `catalog_product_entity`) |
| `ZDT_RELEASE_ADDITIVE` / `ZDT_LABEL_ADDITIVE` | arm 3 only: the additive control release (adds only) |
| `ZDT_RELEASE_BREAKING` / `ZDT_LABEL_BREAKING` | arm 3 only: the breaking release — renames or drops a column the old code reads |
| `ZDT_READ_PATH` | arm 3 only: a route that really reads that column or table |
| `ZDT_SCHEMA_OBJECT` | arm 3 only: the renamed or dropped name; the first old-server failure's body must contain it |
| `ZDT_RUN_DIR` | where the run's evidence lands (default `local.d/zdt-arm/<run>-<arm>/`) |
| `ZDT_FLEET_BIN` | path of `bin/zdt-fleet` (default beside `bin/zdt-arm`) |

The replica connection (`ZDT_PRIMARY_*` / `ZDT_REPLICA_*`) belongs to
`bin/zdt-fleet`, which the arms call as their gate.

### What the run leaves behind

The transcript (every `PLAN`/`RUN` line, secret-free), `traffic-<phase>.log`
— one per phase, so no verdict ever counts another phase's lines; each line
one request: epoch second, target, request type, status, guard flag —
`replica-before.json` and `replica-after.json` from the gate, , `evidence-<leg>/` (arm 3: the saved failure bodies),
and `checksums.txt`. `PASS`/`FAIL` lines for falsifier 1 (the replica survives
the migration: live after it, lag back to zero within five minutes, the
touched tables' checksums matching once the lag is zero) and falsifier 5
(the health check never takes a refusing server out of rotation). The guard
counts are recorded as facts for the results document; falsifiers 2, 3 and
4 belong to arms 3 and 4 and to Commerce runs, as issue #5 defines them.

### Exit codes

0 pass; 1 the run failed (a `FAIL` line); 2 the run never happened: missing
settings, a declined or unanswerable plan, a refused gate, a failed
snapshot. As with `bin/zdt-fleet`: 1 is a falsifier's FAIL, 2 means the run
did not happen.

The tests (`tests/test_zdt_arm.py`, run by `make check`) fake `ssh`, `curl`
and `rsync` beside the fake `mysql` client, so no lab and no live server is
touched: they show the plan runs nothing and names both phases and the
restore and relink between them, a declined prompt — shown the plan it asks
about — runs nothing, a failed snapshot, a failed release placement, a failed
`setup:upgrade` or a failed `env.php` edit stops the arm rather than letting
it report success, the backup precedes every edit and survives the
`env.php` symlink, the printed restores are right, the rate cap and the
duration stop hold, a 404 on one route is not read as a refusing target, and
the transcript never carries a password.
