# The ledger: every field a record carries

The audit log is one JSON object per line, appended by `bin/audit-log` and never rewritten. This page is the field reference: what every record carries, what each event adds, and what a reader may and may not assume.

The settings that turn it on are in the [README](../README.md#controls-approvals-and-the-audit-log). What the records are evidence of is in [compliance.md](compliance.md).

## Contents

- [The envelope every record carries](#the-envelope-every-record-carries)
- [Who did it](#who-did-it)
- [The events, and what each one adds](#the-events-and-what-each-one-adds)
- [How long each phase took](#how-long-each-phase-took)
- [A record, whole](#a-record-whole)
- [What a reader may assume](#what-a-reader-may-assume)
- [Adding a field](#adding-a-field)

## The envelope every record carries

Every line has these nine keys, whatever the event. The first five are the tool's and a record may not set them; the rest come from the deploy.

| Field | Type | What it is |
|---|---|---|
| `schema` | integer | The record format's version. `1` today |
| `seq` | integer | Its position in the file, from 1. A line whose `seq` is not its line number breaks the chain |
| `recorded_at` | string | When the record was written, UTC, `YYYY-MM-DDTHH:MM:SSZ`. **This is when the log was written, not when the step began**, which is why a phase has a record at its start and another at its end. See [How long each phase took](#how-long-each-phase-took) |
| `prev_hash` | string | The previous record's `hash`. Sixty-four zeros on the first record |
| `hash` | string | SHA-256 of this record's canonical JSON with `hash` left out: keys sorted, no spaces, UTF-8 |
| `event` | string | Which step this is. The table below lists them |
| `env_name` | string | The environment, from the inventory's `env_name` |
| `release` | string | The release identifier, e.g. `20260915_1789512159_staging`. Empty on a record written before one exists |
| `actor` | object | Who ran the step. See below |

**`schema`, `seq`, `recorded_at`, `prev_hash` and `hash` are reserved.** `bin/audit-log append` refuses a record that sets any of them, so a caller cannot backdate a record or choose its place in the chain.

## Who did it

`actor` is resolved once per play by `tasks/audit/actor.yml`, on the control node.

| Field | Where it comes from |
|---|---|
| `git_email` | `git config user.email` on the control node |
| `os_user` | `$USER` on the control node |
| `remote_user` | the `ansible_user` the deploy connects to the hosts as |
| `control_host` | `hostname` of the control node |

**None of it is proof of identity.** The deployer sets their own git config, and this records what the machine said rather than what an identity provider checked. The signature on an approval is the one field nobody can forge: that is the control, and this is the trail.

## The events, and what each one adds

The event names, in the order a deploy writes them, then the one only `make rollback` writes. **No deploy writes all of them**, because a backup either succeeds or fails, a release either passes its health check or is rolled back, a release with no database work takes no window, and a deploy that stops writes fewer. Each row's fields are in addition to the envelope.

| Event | Written when | Extra fields |
|---|---|---|
| `deploy.started` | the deploy begins, once the release id exists | `branch`, `reused_release`, `goes_live`, `playbook_commit` |
| `approval.verified` | a signed tag on the built commit checks out, and `approval.required` is on | `commit`, `tag`, `signer`, `signing_key` |
| `build.started` | the build play begins on the builder, before the checkout is synced | none |
| `build.succeeded` | the release archive is built and checksummed | `commit`, `artefact_sha256`, `builder` |
| `upload.started` | the web hosts begin receiving the archive | none |
| `upload.succeeded` | every web host that began the deploy has the release unpacked | none |
| `cutover.started` | the hosts begin switching over | `maintenance_window`, `artefact_sha256`, `magento_host` |
| `forecast.completed` | the `setup:upgrade` rehearsal ran, which it does only when `lock_forecast.enabled` is on and the release has database work | `finished`, `statements`, `blocking`, `narrowing`, `patches` |
| `backup.succeeded` | the backup command exits 0 and names something | `backup_id`, `reason` |
| `backup.failed` | the backup command fails, and the deploy stops | `reason`, `error` |
| `maintenance.enabled` | the maintenance page goes up in the incoming release | none |
| `upgrade.started` | the cache is flushed on the new release and `setup:upgrade` is about to run | `magento_host` |
| `upgrade.succeeded` | `setup:upgrade` returned without an error | `magento_host` |
| `maintenance.disabled` | `maint:disable` has run on every web host, in a deploy that opened a window | none |
| `upgrade.failed` | `setup:upgrade` failed after the cutover; the site stays in maintenance and the lock is released | `error`, `magento_host`, `backup_id` |
| `health.failed` | an app host did not answer 2xx on a health check path after the cutover | `hosts`, `paths`, `rollback` |
| `rollback.refused` | the release being rolled back to does not fit the database, so it was not put back | `from_release`, `to_release`, `reasons`, and `backup_id` after a deploy |
| `deploy.rolled_back` | the release before is live again, after a failed health check or by `make rollback` | `from_release`, `to_release`, `trigger`, `recovered`, `notes` |
| `cutover.succeeded` | the new release is the one serving and passed its health check | `maintenance_window`, `setup_upgrade_ran`, `backup_id` |
| `warmup.completed` | the warm-up finishes, whatever it achieved | `requested`, `ok`, `percent` |
| `deploy.finished` | the playbook reaches its end | `outcome` |
| `deploy.failed` | the deploy stopped and no success is recorded: a web host it began with dropped out (`phase` upload, before-cutover, before-switch, switch or after-switch, with `lost_hosts`); no host could run Magento's commands (`phase: magento-host`, with what each answered in `tried`); a step after the switch failed (`phase: after-switch`, with `step`, `magento_host` and `error`); or any other step stopped it before anything went live (`phase` preflight, build, upload or before-switch, with `step` and `error`), unless that step recorded its own failure | `phase`, and `lost_hosts`, `tried` or `step`, `magento_host`, `error` |
| `deploy.verified` | `make verify` passes, which is a separate run | `outcome`, `upgrade_expected` |
| `rollback.started` | `make rollback` has chosen the release to go back to | `from_release`, `to_release`, `has_mark` |

`deploy.finished` carries `outcome: rolled_back` when the health check failed and the release before was put back. A `rollback.refused` from `make rollback` is also written by it, and `deploy.rolled_back` names `trigger: manual`.

What each extra field means:

| Field | Type | Meaning |
|---|---|---|
| `branch` | string | The branch the build checked out |
| `reused_release` | boolean | The deploy reused a release already built rather than building one |
| `goes_live` | boolean | False for a build-and-upload that never flips the symlink |
| `playbook_commit` | string | The commit of *this playbook* that ran the deploy. Empty when the checkout is not a git repository |
| `commit` | string | The commit of the *store* that was approved, and built |
| `tag`, `signer`, `signing_key` | string | The approval tag, the email its signature verified as, and the key's fingerprint |
| `artefact_sha256` | string | The release archive's checksum. It appears on the build and again at cutover, so a reader can tell whether the archive that went live is the one that was built |
| `builder` | string | The host that built it |
| `maintenance_window` | boolean | Whether this release needed one. **On `cutover.started` this is a decision, not an observation**: the window is taken later, and `maintenance.enabled` is the record that it actually went up |
| `backup_id` | string | The last line the backup command printed, which is the dump or snapshot's name |
| `reason` | string | The `backup.run` setting that asked for it: `window` or `always` |
| `error` | string | Why the backup failed, truncated to 500 characters |
| `setup_upgrade_ran` | boolean | Whether `setup:upgrade` ran inside the window |
| `requested`, `ok` | integer | Pages the warm-up asked for, and pages that answered |
| `percent` | number | `ok` as a percentage of `requested` |
| `outcome` | string | `success` or `rolled_back` on `deploy.finished`, `passed` on `deploy.verified` |
| `finished` | boolean | Whether the `setup:upgrade` rehearsal ran to the end. When it did not, its other fields are empty |
| `statements` | integer | Schema statements the rehearsed `setup:upgrade` sent, triggers included |
| `blocking` | list | Tables a statement would rebuild with a copy that blocks writes, over `lock_forecast.stop_on_rows` |
| `narrowing` | list | Columns a statement would make smaller or stricter, as `table.column: old to new` |
| `patches` | list | Data patches the rehearsal applied. Their cost is not measured: they ran on empty tables |
| `hosts`, `paths` | list | The app hosts that failed the health check, and the paths it requested |
| `rollback` | string | `health.rollback` when the check failed: `auto` or `never` |
| `from_release`, `to_release` | string | The release that was live, and the one a rollback went, or would have gone, back to |
| `reasons` | list | Why the rollback guard refused, one sentence each |
| `trigger` | string | `health_check` for an automatic rollback, `manual` for `make rollback` |
| `recovered` | boolean | Whether the release put back passed the health check |
| `notes` | list | What a rollback leaves as it is: recurring setup scripts only the newer release has, and configuration written since |
| `has_mark` | boolean | Whether the release being gone back to recorded the database it went live with. Without one, the guard compares patches by class name, which also lists patches of modules removed long ago |
| `upgrade_expected` | boolean | What the verification was told to expect, so a reader knows which assertions ran |

## How long each phase took

**A phase is the stretch from the record that opens it to the first record after it that closes it**, so a deploy's timings come from its own records and nothing else:

| Phase | Opens with | Closes with |
|---|---|---|
| deploy | `deploy.started` | `deploy.finished`, or `deploy.failed` |
| build | `build.started` | `build.succeeded` |
| upload | `upload.started` | `upload.succeeded` |
| cutover | `cutover.started` | `cutover.succeeded` |
| setup:upgrade | `upgrade.started` | `upgrade.succeeded`, or `upgrade.failed` |
| maintenance | `maintenance.enabled` | `maintenance.disabled` |

**The maintenance phase is the store's downtime**: the page goes up before the switch and `maintenance.disabled` is written only once every web host is out of it.

```bash
bin/audit-log phases --path ~/.local/state/magento-deploy-playbook/staging.audit.jsonl --release 20260915_1789512159_staging
```

```text
release 20260915_1789512159_staging
phase          started               ended                 seconds
deploy         2026-09-15T02:00:00Z  2026-09-15T02:02:58Z  178
build          2026-09-15T02:00:02Z  2026-09-15T02:01:37Z  95
upload         2026-09-15T02:01:38Z  2026-09-15T02:01:58Z  20
cutover        2026-09-15T02:02:01Z  2026-09-15T02:02:49Z  48
setup:upgrade  2026-09-15T02:02:07Z  2026-09-15T02:02:38Z  31
maintenance    2026-09-15T02:02:05Z  2026-09-15T02:02:43Z  38
```

`--json` prints the same as one object, for another program. `make evidence` puts the table in the release's `summary.md`, with the window's length on its own row.

What the numbers are, and are not:

- **They are when each record was written on the control node, to the second.** A phase shorter than a second reads 0, and the control node's clock is the only clock.
- **A phase with a start and no end was not closed**: the deploy stopped inside it, or, for maintenance, the store was left in maintenance, as after a failed `setup:upgrade`. The table says `not closed`.
- **A phase with nothing recorded did not happen in that deploy**, or the deploy ran on a playbook from before these events existed. A release with no database work has no `setup:upgrade` and no maintenance phase.
- **A release deployed twice is timed by its last run**: the records from its last `deploy.started` on.
- **One kind of downtime is not in it.** When a failed release cannot be rolled back, the playbook puts the store in maintenance on purpose and records `rollback.refused`, not `maintenance.enabled`. That outage ends when a person ends it, and no record says when.

## A record, whole

```json
{"actor":{"control_host":"ops-laptop","git_email":"alex@example.com","os_user":"alex","remote_user":"deploy"},"artefact_sha256":"9b1e4c7a2f6d8e03b5a9c1d7e4f2a6b80c3d5e7f9a1b2c4d6e8f0a2b4c6d8e0f","builder":"builder1","commit":"3f9c2a71d4e8b0561a2c9e7f40b3d18e6a5c2f90","env_name":"staging","event":"build.succeeded","hash":"d3d332b194c2eb5dd95dad5d1c74eec83eaf934a619c27981810eaec875750c9","prev_hash":"ee19da99442cf88be3bc7c4b50e429e0f03c66969fbf2d42d697134c669b50cf","recorded_at":"2026-09-17T17:33:36Z","release":"20260917_1789650000_staging","schema":1,"seq":3}
```

Keys are written sorted, because the hash is computed over the canonical form. Do not reformat a line: pretty-printing it changes nothing about the hash, which is computed from the parsed record, but it does break `seq`-per-line and the chain check reads the file by lines.

Reading it by hand:

```bash
jq -r '[.seq, .event, .recorded_at, .actor.git_email] | @tsv' ~/.local/state/magento-deploy-playbook/staging.audit.jsonl
```

## What a reader may assume

- **An absent field is not a zero.** `maintenance.enabled` missing means the page never went up; a missing `backup_id` means no backup was taken. Neither means the step failed.
- **`maintenance.enabled` with no `maintenance.disabled` after it in the same deploy** means that deploy did not take the page down again, or that it ran on a playbook from before `maintenance.disabled` existed. A `cutover.succeeded` after it tells the two apart.
- **An absent event is not a failure either.** Approval, backup and the warm-up are per-environment settings, so their records are missing wherever they are off.
- **A deploy is the records between one `deploy.started` and the next.** `deploy.verified` is written by a separate run and can arrive much later, or never.
- **Order is the file's order.** `recorded_at` has one-second resolution and several records can share a second, so read `seq` rather than sorting by time.
- **A record with no `deploy.started` before it belongs to no deploy.** The warm-up suite writes such records on its own.
- **Fields are added, not removed.** A reader should ignore a field it does not know, and `schema` changes if that stops being true.

## Adding a field

A field goes in the `audit_detail` mapping where the event is recorded, and nowhere else:

```yaml
- name: "Audit: record the cutover"
  ansible.builtin.include_tasks: tasks/audit/record.yml
  vars:
    audit_event: cutover.succeeded
    audit_detail:
      maintenance_window: "{{ upgrade_needed | bool }}"
```

Three things to hold to when you add one:

1. **Never record a secret.** These records are forwarded, copied into evidence bundles and read by people who were not there. A password or a token in `audit_detail` is in the chain for good, because rewriting the file is exactly what the chain refuses.
2. **Record what happened, not what was configured.** A setting is already in the inventory; the record's job is the fact.
3. **Add to this table in the same change.** A field nothing documents is a field the next reader has to find by grepping the playbook, which is how this page came to be written.
