# The ledger: every field a record carries

The audit log is one JSON object per line, appended by `bin/audit-log` and never rewritten. This page is the field reference: what every record carries, what each event adds, and what a reader may and may not assume.

The settings that turn it on are in the [README](../README.md#controls-approvals-and-the-audit-log). What the records are evidence of is in [compliance.md](compliance.md).

## Contents

- [The envelope every record carries](#the-envelope-every-record-carries)
- [Who did it](#who-did-it)
- [The events, and what each one adds](#the-events-and-what-each-one-adds)
- [A record, whole](#a-record-whole)
- [What a reader may assume](#what-a-reader-may-assume)
- [Adding a field](#adding-a-field)

## The envelope every record carries

Every line has these nine keys, whatever the event. The first five are the tool's and a record may not set them; the rest come from the deploy.

| Field | Type | What it is |
|---|---|---|
| `schema` | integer | The record format's version. `1` today |
| `seq` | integer | Its position in the file, from 1. A line whose `seq` is not its line number breaks the chain |
| `recorded_at` | string | When the record was written, UTC, `YYYY-MM-DDTHH:MM:SSZ`. **This is when the log was written, not when the step began** |
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

Eleven event names, in the order a deploy writes them. **One deploy writes at most ten**, because a backup either succeeds or fails, and a deploy that stops writes fewer. Each row's fields are in addition to the envelope.

| Event | Written when | Extra fields |
|---|---|---|
| `deploy.started` | the deploy begins, once the release id exists | `branch`, `reused_release`, `goes_live`, `playbook_commit` |
| `approval.verified` | a signed tag on the built commit checks out, and `approval.required` is on | `commit`, `tag`, `signer`, `signing_key` |
| `build.succeeded` | the release archive is built and checksummed | `commit`, `artefact_sha256`, `builder` |
| `cutover.started` | the hosts begin switching over | `maintenance_window`, `artefact_sha256` |
| `backup.succeeded` | the backup command exits 0 and names something | `backup_id`, `reason` |
| `backup.failed` | the backup command fails, and the deploy stops | `reason`, `error` |
| `maintenance.enabled` | the maintenance page goes up in the incoming release | none |
| `cutover.succeeded` | the new release is the one serving | `maintenance_window`, `setup_upgrade_ran`, `backup_id` |
| `warmup.completed` | the warm-up finishes, whatever it achieved | `requested`, `ok`, `percent` |
| `deploy.finished` | the playbook reaches its end | `outcome` |
| `deploy.verified` | `make verify` passes, which is a separate run | `outcome`, `upgrade_expected` |

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
| `outcome` | string | `success` on `deploy.finished`, `passed` on `deploy.verified` |
| `upgrade_expected` | boolean | What the verification was told to expect, so a reader knows which assertions ran |

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
