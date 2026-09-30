# Zero-downtime fleet run — `2026-09-30` — `Magento Open Source 2.4.8-p2`

**The runs met all three conditions, so this is a result.** Replication survived
every migration, and the flag let old code serve until the schema broke, naming
the renamed column. Falsifier 5 passes by its fixed test in every arm, and fails
in arms 1 to 3 when judged instead by the load balancer's own rotation. Taking
the migrating node out of the load balancer made the additive release serve every
customer request (0 of 310 refused). Maintenance mode was **not** the smaller
outage for the breaking release: the rollout refused 16 requests in 6 seconds,
maintenance mode 1,266 in 318.

| Falsifier | Verdict |
|---|---|
| 1. Replication survives a migration | PASS in every phase of every arm, on the one table the arms checksum (see its section) |
| 2. A replica read by Magento changes nothing the old servers serve | PASS as a control: nothing on Open Source reads the replica |
| 3. The flag lets old code serve until the schema breaks | PASS: no guard message across the additive release; the first old-server failure across the breaking release names `probe_value` |
| 4. Maintenance mode is the smaller outage for a breaking release | FAIL: the rollout was the smaller outage |
| 5. The health check never takes a refusing server out of rotation | PASS by the issue's test in every arm; FAIL by HAProxy's rotation in one phase of each of arms 1 to 3, PASS in the run with the migrating node taken out |

Five runs, all from one commit and one fleet. The runner is `bin/zdt-arm` at
`6ad93c6`, merged to `main` as `b3688ae`. The raw output of each run is kept
out of this repository, unedited, in one archive published with the write-up of
these runs (see [Raw output](#raw-output)). Every path this document cites, such
as `final-arm1-20260930T001430Z/transcript.log`, is a path inside that archive.

## Conditions of validity

| # | Condition | How the run shows it |
|---|---|---|
| 1 | At least two databases, replicating throughout | A MariaDB 11.4 primary with one replica following it by GTID. Each arm ran `bin/zdt-fleet replica-check` as its gate before anything, and `replica-before.json` in every run reads `"seconds_behind": 0, "last_sql_errno": 0, "last_io_errno": 0` |
| 2 | Three or more web servers sharing one Valkey | `"web_node_count": 3`, `"web_nodes": "web1,web2,web3"` in every `platform.json`; one `valkey/valkey:8` container is every node's cache and session store |
| 3 | Every arm claiming zero downtime crosses a schema-changing release | Arms 1 and 2 cross `r0` to `r1`, which adds the table `lab_zdt_probe`. Arm 3 crosses `r2-additive` (adds a column, the control) and `r2-breaking` (renames `probe_value`, the evidence). Arm 4 rolls out `r2-breaking` |

- Conditions met: **yes**
- Condition missed: none

## Platform facts

From `platform.json` (every run's is the same, bar the arm and releases).

| Fact | Value |
|---|---|
| Platform and version | Open Source `2.4.8-p2` (`edition_packages`: `magento/product-community-edition`; `Magento CLI 2.4.8-p2`) |
| PHP | `8.4.26` |
| Database server and version | `11.4.13-MariaDB-ubu2404-log` |
| Replication mode | GTID, `binlog_format` `ROW` |
| Web servers | 3 (`web1,web2,web3`); `web1` always carries the new release |
| Cache, shared | `valkey/valkey:8`, one container |
| Search | `opensearchproject/opensearch:2.19.6` |
| Load balancer | `haproxy:3.2.24-alpine`, round robin, `option httpchk GET /health_check.php`, `inter 2s fall 3 rise 2` |
| Not recorded | nothing (`"not_recorded": null`) |

**The lab is one host running containers, with limits that shape the numbers.**
Each web node has 1.0 CPU and 1,250 MB of memory, and runs PHP-FPM with
`pm.max_children = 6` and `memory_limit = 2G`. `setup:upgrade` runs inside `web1`,
beside its PHP-FPM. The kernel killed nothing for memory in any web container
across the five runs (`oom_kill 0` in each container's `memory.events`, before
and after). But `web1` reached its memory limit 46,683 times during these runs,
against about 7,300 for each of the other two, so it ran under memory pressure
while it migrated. A host with more room may stall less than this one.

## What was run

- **Controller commit:** `6ad93c6`. The control container's copy of the
  repository was not a git checkout, so it was made from `git archive 6ad93c6`,
  and all 233 tracked regular files were compared by SHA-256 with the commit
  before the runs; they matched. `b3688ae`, the merge on `main`, differs from it
  only in `lab/zdt-fleet/bin/replica-seed` and one warning line in the arm's
  node-return step.
- **Run directories:** `final-arm1-20260930T001430Z`,
  `final-arm2-20260930T003945Z`, `final-arm3-20260930T010445Z`,
  `final-arm3-20260930T013054Z` (the migrating node taken out, below) and
  `final-arm4-20260930T015838Z`.
- **Arms that ran:** 1, 2, 3 and 4, each once, and arm 3 a second time with
  `ZDT_LB_DRAIN` set.

**The second arm-3 run is not one of the issue's arms.** It takes the migrating
node out of the load balancer before its release lands, and puts it back once it
answers 200 on its home page and `health_check.php`. It answers whether the
failures arms 1 to 3 show come from that node serving new code before the schema
matches. HAProxy counts a node put into maintenance as taken out, so falsifier 5
leaves out that window, and the transcript says so.

Every arm ran in the control container, with the lab's `lab.env`, and its
settings from the environment (no password in any argument):

```bash
lab/zdt-fleet/bin/with-secrets bin/zdt-arm arm1 -y
lab/zdt-fleet/bin/with-secrets bin/zdt-arm arm2 -y
ZDT_LABEL_OLD=r1 lab/zdt-fleet/bin/with-secrets bin/zdt-arm arm3 -y
ZDT_LABEL_OLD=r1 ZDT_LB_DRAIN=lab/zdt-fleet/bin/lb-state lab/zdt-fleet/bin/with-secrets bin/zdt-arm arm3 -y
ZDT_LABEL_OLD=r1 lab/zdt-fleet/bin/with-secrets bin/zdt-arm arm4 -y
```

Each run had `ZDT_RUN_DIR=/runs/final-<arm>-<UTC time>`. Before each, the fleet was
put back to that arm's starting point:

```bash
lab/zdt-fleet/bin/with-secrets bin/zdt-arm restore-snapshot /var/www/magento/zdt-snapshots/<snapshot> -y
# on each web node: re-extract the release from its tarball if its pub/static/deployed_version.txt is missing, then
ln -sfn /var/www/magento/releases/<r0 or r1> /var/www/magento/current && zdtfleet-fpm-reload
# on web1
php bin/magento cache:flush
lab/zdt-fleet/bin/with-secrets bin/zdt-fleet replica-check   # repeated until "seconds_behind": 0
```

Arms 1 and 2 started from an `r0` snapshot with every node on `r0`. Arm 3, both
runs, and arm 4 started from an `r1` snapshot with every node on `r1`. After each
reset, every web node and the load balancer answered 200 on `/`.

## Falsifier 1 — replication survives a migration

- **Judged by:** every arm, once per phase, in its `transcript.log`.
- **Verdict:** **PASS** in all ten phases.
- **Deciding line**, the same in each phase (`final-arm1-20260930T001430Z/transcript.log`):
  `PASS  falsifier 1: replication survived the migration; lag back to 0 in 0s; checksums of catalog_product_entity match`
- **Checksums:** `MATCH  catalog_product_entity primary=3438696010 replica=3438696010`
  (`final-arm1-20260930T001430Z/checksums.txt`).
- **Lag after the upgrade:** 0 seconds when first read after each migration, by
  `bin/zdt-fleet replica-check`.
- **Binary log the upgrade wrote:** not recorded. `replica-before.json` is read
  before the first phase and `replica-after.json` after the last, with a snapshot
  restore between them, so their difference is not one upgrade's binlog. Catalogue
  size at each run's start: 1,200 rows, `binlog_format` `ROW`.

> [!WARNING]
> **What this falsifier did not check.** The arms checksum `ZDT_TOUCHED_TABLES`, which defaulted to
> `catalog_product_entity`. The table these releases change, `lab_zdt_probe`, was
> not checksummed. The replica's SQL and IO threads reported no error in any phase,
> but a checksum of `lab_zdt_probe` after the rename is the stronger evidence, and
> this run does not have it.

## Falsifier 2 — a replica read by Magento changes nothing the old servers serve

- **Edition this run was on:** Open Source.
- **Anything on this side reads the replica:** no. `env.php` declares no
  `db/slave_connection`, and on Open Source one would be accepted and never read.
- **Verdict:** **PASS as a control.** Nothing reads the replica, so it cannot
  change what the old servers serve. This is the expected result on Open Source,
  not evidence about Commerce.

## Falsifier 3 — the flag lets old code serve until the schema breaks

- **Judged by:** arm 3's two runs, the control and the breaking leg of each.
- **Additive control — verdict:** **PASS** in both runs.
- **Additive control — deciding line** (`final-arm3-20260930T010445Z/transcript.log`):
  `PASS  falsifier 3 (control): no guard message on any old server across the additive release (a control; not the evidence)`
- **Breaking release:** `r2-breaking` renames `probe_value` in `lab_zdt_probe`.
- **Read path sent to an old server:** `/zdtprobe/read`, which selects that column.
- **Breaking evidence — verdict:** **PASS** in both runs.
- **Breaking evidence — deciding line** (`final-arm3-20260930T013054Z/transcript.log`):
  `PASS  falsifier 3: across the breaking release the first old-server failure on web2 names probe_value (/runs/final-arm3-20260930T013054Z/evidence-breaking-evidence/read-500-1790732853716960052-198017-web2; the read path is /zdtprobe/read)`
- **The failure's own words** (`evidence-breaking-evidence/read-500-1790732853716960052-198017-web2`):
  `SQLSTATE[42S22]: Column not found: 1054 Unknown column 'lab_zdt_probe.probe_value' in 'SELECT'`
- **A guard message appeared with the flag on:** no, in any arm.

## Falsifier 4 — maintenance mode is the smaller outage for a breaking release

- **Judged by:** arm 4, `final-arm4-20260930T015838Z`.
- **Release rolled out:** `r2-breaking`. The database was restored from the run's
  own snapshot between the two legs, so both started from one state.
- **Verdict:** **FAIL.** The claim is disproved: the rollout was the smaller outage.
- **Deciding line** (`transcript.log`):
  `FAIL  falsifier 4: the rollout failed 16 requests in 6 seconds; maintenance mode failed 1266 in 318 — maintenance was NOT the smaller outage (want the rollout strictly worse on both)`
- **Rollout:** failed 16 requests (15 answered 500, 1 no answer) in 6 seconds.
- **Maintenance mode:** failed 1,266 requests (1,265 answered 503, 1 no answer) in 318 seconds.
- **By request type:** in the rollout, pages, categories, products and the cart
  failed, each in full in its worst second, and REST and GraphQL never failed.
  Under maintenance mode every type failed, 1,266 of the leg's 1,524 requests, or
  83%, as the maintenance page intends. The per-second shares are in
  `outage-report-rollout.txt` and `outage-report-maintenance.txt`.

This lab's breaking release reads its column from one route, so the rollout's
outage is small. A release whose changed column sits on more routes breaks more
of them.

## Falsifier 5 — the health check never takes a refusing server out of rotation

**This falsifier is reported two ways, because the runner judges it differently
from the issue.** The issue's test, fixed before any run: `health_check.php`
answers 200 on every server that refuses pages. During these runs, the runner
judged it from HAProxy's own count of the times it took each node out of rotation
(its stats page, read before and after each phase). That change was made after
earlier runs had been seen, so both readings are given, and the issue's own test
is the one that decides the verdict.

- **By the issue's test:** **PASS** in every phase of every arm. No refusing
  node's `health_check.php` answered anything but 200: the `health` lines of every
  `traffic-<phase>.log` hold no other status.
- **By HAProxy's rotation:** FAIL in the heavier phase of arms 1 to 3. HAProxy took
  `web1` out once for 20 s (arm 1, `per-release-prefix`), 20 s (arm 2,
  `per-release-prefix`) and 8 s (arm 3, `breaking-evidence`), on checks that took
  longer than 2 s while `web1` migrated. The runner's own probe waits 25 s and got
  200 each time. PASS in the other phases, in arm 4, and in both legs of the run
  with the migrating node taken out.
- **Deciding line, HAProxy** (`final-arm1-20260930T001430Z/transcript.log`):
  `FAIL  falsifier 5: HAProxy took web1 out of rotation 1 time(s), 20s out in all, while it refused requests`

**What refused, and why.** The old servers refused nothing in arms 1 and 2 or in
arm 3's additive leg. Every refusal there was `web1`, the node carrying the new
release, answering *Please upgrade your database* between the moment it served
the new code and the moment `setup:upgrade` finished. Through the load balancer,
that reached customers:

| Run and phase | Refused through the load balancer |
|---|---|
| Arm 1, per-release prefix | 13 of 172 |
| Arm 2, per-release prefix | 13 of 136 |
| Arm 3, additive control, `web1` in rotation | 12 of 179 |
| Arm 3, additive control, `web1` taken out while it migrates | **0 of 310** |

## What could not be run

- **Mage-OS 3.x:** not run. This lab was built on Open Source only.
- **Adobe Commerce, and falsifier 2 with the replica as Magento's read connection:**
  not run. We hold no Commerce licence.
- **A checksum of `lab_zdt_probe` for falsifier 1:** not taken; see that section.

## Raw output

- **Archive:** `zdt-fleet-2026-09-30-open-source.tar.gz`, published with the write-up of these runs on
  kingletas.com. SHA-256
  `07061f5b4254e090e6da3af3ff5d25cdd4aea7ed73567897f1cc10502bb55421`;
  check a download with `sha256sum` before reading it.
- **Contents:** one directory per run, under `zdt-fleet-2026-09-30-open-source/`:
  `transcript.log`, `platform.json`, `replica-before.json`, `replica-after.json`,
  `checksums.txt`, each phase's `traffic-<phase>.log` with HAProxy's readings
  (`.lb-before`, `.lb-after`, and for the second arm-3 run `.lb-drain-start` and
  `.lb-drain-end`), arm 3's `evidence-<leg>/` and arm 4's `outage-report-<leg>.txt`.
- Nothing in it is edited. Passwords appear only as `***`, as the runner writes them.
