# Zero-downtime fleet run — `<YYYY-MM-DD>` — `<platform>`

**NOT A RESULT.** This file is the template for a results document, committed so
the document that follows a lab run has a shape and nothing in it has to be
invented while the run is fresh. Copy it to

```
docs/results/<YYYY-MM-DD>-<platform>.md
```

— one document per run, named by its date and the platform it ran on — and fill
every placeholder from the raw output the run left behind.

**What makes a document a result:** a run meets all three conditions of validity
below, every falsifier is judged from output the run produced (never from
memory, never from the scripts' intent), and the raw output it was judged from
is attached or linked unedited. A run that missed a condition is reported as
**NOT RUN**, naming the condition it missed — not silently dropped, and not
filled in from a run that did meet it.

Every arm of issue
[#5](https://github.com/kingletas/magento-deploy-playbook/issues/5) has the same
shape, so the sections below are the same five falsifiers for every platform.

## How to use this template

- A value comes from the run's own files under `ZDT_RUN_DIR`
  (`local.d/zdt-arm/<run>-<arm>/` by default): `platform.json` for the header,
  `transcript.log` for what happened, `replica-before.json` /
  `replica-after.json` for replication, `checksums.txt` for the touched tables,
  `traffic-<phase>.log` for the requests, `evidence-<leg>/` for the failing
  bodies, `outage-report-<leg>.txt` for the per-second outage.
- Quote the deciding line **verbatim**, with the file it came from. A verdict
  without the line it rests on proves nothing to a reader.
- Where the run answered a fact with `null`, the document says what could not be
  read and why — the reason is in `not_recorded` — rather than guessing it.
- Where this document and whoever ran the lab read the same output differently,
  say so out loud in the section it concerns and give the line both readings
  rest on.
- Nothing here is run automatically. A document is filled after a lab run, by
  reading the run's output next to this shape.

## Conditions of validity

A run counts only if it meets all three. A run that misses any of them is
reported as not run, with the condition it missed.

| # | Condition | How the run shows it |
|---|---|---|
| 1 | At least two databases: a primary and at least one replica, replicating continuously throughout | `bin/zdt-fleet replica-check` passing before anything, `replica-before.json` and `replica-after.json` |
| 2 | Three or more web servers sharing one Valkey (or Redis) | `web_node_count` and `web_nodes` in `platform.json`; the shared cache named with the server that runs it |
| 3 | Every arm claiming zero downtime crosses a schema-changing release; an additive-only release is a control and can never be the evidence for a pass | the release labels in `platform.json`, and the arm-3 / arm-4 release the run was given |

- Conditions met: `<yes/no>`
- Condition missed, if any: `<condition N — what the run shows was missing>` — the
  run is then reported as **NOT RUN**, with the arms that did not happen named
  below.

## Platform facts

From `platform.json` in the run directory. A field the lab did not answer is
`null` there, with the reason in `not_recorded`; the document says so instead of
a value.

| Fact | Value |
|---|---|
| Platform and version | `<magento_edition>` `<magento_version>` (`edition_packages`: `<edition_packages>`; `<magento_cli>`) |
| PHP | `<php_version>` |
| Database server and version | `<db_server>` |
| Replication mode | `<replication_mode>` (`binlog_format`) |
| Web servers | `<web_node_count>` (`web_nodes`) |
| Cached, shared | `<cache server and version>` |
| Search | `<OpenSearch version>` |
| Load balancer | `<what it is>` |
| Not recorded | `<not_recorded, verbatim, or "nothing">` |

## What was run

- **Controller commit:** `<git rev-parse HEAD on the control machine>` — the
  scripts a repeat run has to start from.
- **Run directory per arm:** `<ZDT_RUN_DIR>` for each arm that ran.
- **Commands, verbatim, in the order they ran:**

```bash
<the environment the operator set (variables only -- never a password)>
<every command, exactly as typed, including the ones that refused>
```

- **Arms that ran:** `<list>` — arms 1, 2 (migration with the flag off, shared
  then per-release cache prefixes; then the flag on the old servers), 3 (the
  crossing: additive control, then the breaking evidence), 4 (the outage:
  rollout, then maintenance mode). Each with its own run directory.

## Falsifier 1 — replication survives a migration

*The replica keeps applying changes through `setup:upgrade` and every data
patch: no SQL thread stop, no error 1032 or 1062, and its lag back to zero
within five minutes of the upgrade finishing. Once the lag is zero, a checksum
of every table the upgrade touched matches between primary and replica. Record
`binlog_format`, the catalogue size and the bytes of binary log the upgrade
wrote.*

- **Judged by:** every arm that ran — it checks the replica after each of its
  phases, so its `PASS`/`FAIL` line appears once per phase in the arm's
  `transcript.log`, with `replica-before.json`, `replica-after.json` and
  `checksums.txt` beside it.
- **Verdict:** `NOT RUN — <condition missed>`
- **Deciding line:** `<quoted verbatim, with the file it came from>`
- **Binary log the upgrade wrote:** `<after minus before in binlog_bytes>`
  against a catalogue of `<catalogue_size>` rows; `binlog_format` `<value>`.
  Purges during the window (`PURGE BINARY LOGS`, `binlog_expire_logs_seconds`)
  make this figure an undercount — `<whether any ran>`.
- **Lag after the upgrade:** `<seconds and how it was measured>`

## Falsifier 2 — a replica read by Magento changes nothing the old servers serve

*On Commerce with the replica as Magento's read connection, arm 1 fails the same
request types as it did on one database. On Open Source and Mage-OS nothing
reads the replica, so there it is a control expected to pass, and is reported as
such.*

- **Judged by:** `<arm and its run directory>`
- **Edition this run was on:** `<Open Source / Mage-OS / Commerce>`
- **Anything on this side reads the replica:** `<no — a db/slave_connection in
  env.php is accepted and never read / yes: ResourceConnections, configured as
  <what>>`
- **Verdict:** `NOT RUN — <condition missed>`
- **Deciding line:** `<quoted verbatim>`
- **If this edition reads the replica:** the request types that failed, per
  type, including a read meeting the replica's older schema while it lagged —
  `<list, or "not applicable on this edition">`

## Falsifier 3 — the flag lets old code serve until the schema breaks

*In arm 3, with the flag on, old servers serve pages, REST and GraphQL across the
additive control release without a guard message; that alone is not a pass.
Across the breaking release, the first failure names the column or table that
changed. The results must name the request that reads that column and show it
was sent to an old server.*

- **Judged by:** arm 3 — the control leg's and the breaking leg's `PASS`/`FAIL`
  lines, `traffic-<leg>.log`, the failing bodies in `evidence-<leg>/`.
- **Additive control — verdict:** `NOT RUN — <condition missed>`
- **Additive control — deciding line:** `<quoted verbatim>`
- **Breaking release:** `<ZDT_LABEL_BREAKING>` — renames or drops
  `<ZDT_SCHEMA_OBJECT>`
- **Read path sent to an old server:** `<ZDT_READ_PATH>`
- **Breaking evidence — verdict:** `NOT RUN — <condition missed>`
- **Breaking evidence — deciding line:** `<the first old-server failure's own
  words, quoted verbatim, with the node it came from and the file it was saved
  to>`
- **A guard message appeared with the flag on:** `<no / yes — and then which arm,
  which request, which node>`

## Falsifier 4 — maintenance mode is the smaller outage for a breaking release

*Under arm 4, a rollout of the breaking release fails a larger share of
requests, for longer, than the same release behind maintenance mode.*

- **Judged by:** arm 4 — the `PASS`/`FAIL` line in its `transcript.log`,
  `traffic-rollout.log` and `traffic-maintenance.log`, and the per-second
  shares in `outage-report-rollout.txt` / `outage-report-maintenance.txt`.
- **Release rolled out:** `<ZDT_LABEL_BREAKING>`; the database restored between
  the two legs: `<how it is shown that both started from one state>`
- **Verdict:** `NOT RUN — <condition missed>`
- **Deciding line:** `<quoted verbatim>`
- **Rollout:** failed `<n>` requests in `<s>` seconds
- **Maintenance mode:** failed `<n>` requests in `<s>` seconds
- **Per request type, worst second of each leg:** `<page, cart, REST, GraphQL
  -- the share that failed, and what the customer saw>`

## Falsifier 5 — the health check never takes a refusing server out of rotation

*`pub/health_check.php` answers 200 on every server that refuses pages, in every
arm.*

- **Judged by:** every arm, on every phase it ran — the `health` lines in
  `traffic-<phase>.log` next to the targets of the same phase that refused.
- **Verdict per arm and phase:** `NOT RUN — <condition missed>`
- **Deciding line:** `<quoted verbatim, per arm>` — note that an arm whose no
  target refused prints `targets that refused: none`, which is a pass over an
  empty set and says nothing about a refusing server.

## What could not be run

Plainly, one line each, with the reason: `<arm or falsifier — the reason, and
the condition it missed if that is why>`. A run that missed a condition of
validity belongs here as well as in the conditions table above.

## Raw output

- `<link or attachment>` — unedited, one per arm.
- Nothing in it is edited for presentation: a run's `transcript.log`, its
  `platform.json`, its traffic logs and its outage reports are the evidence, and
  a summary that does not match them is the summary that is wrong.
