# Controls, and what they are evidence of

**No repository makes anything compliant.** HIPAA and SOC 2 apply to an
organisation and the systems it runs, and only an audit decides whether they are
met. What a deploy tool can do is implement some of the controls an auditor
tests, and produce the evidence they ask for. That is what this page maps, and
it says plainly where the line is.

Every control below has a file that implements it and a test that proves it,
listed so a reviewer can check the claim instead of believing it. The framework
references are our reading, not an auditor's finding.

## What the playbook controls

| Control | What it does | Where | Proved by |
|---|---|---|---|
| **Only approved code is built** | A release is built only if a tag on the commit is signed by a key in `approval.allowed_signers`, by someone who is not the deployer | `tasks/approval/verify.yml` | `tests/test-controls.yml`: a real repository with keys, refusing an unsigned tag, a stranger's key, the deployer's own signature, and a commit with no tag |
| **What was tested is what ships** | The builder records the archive's SHA-256, and each host refuses to unpack an archive that does not match | `tasks/packaging/archive.yml`, `tasks/deploy/verify-archive.yml` | `tests/test-controls.yml`: a changed archive is refused |
| **Every deploy is recorded, and the record can be checked** | Nine events per release, each chained to the one before, with the commit, artefact hash, approver, backup, who deployed and from where. `make audit-verify` re-checks every link | `bin/audit-log`, `tasks/audit/` | `tests/test_audit_log.py`: edits, deletions, reordering and a re-hashed forgery are all found; concurrent writers keep one chain |
| **Evidence without a spreadsheet** | `make evidence release=…` writes that release's records, its place in the chain, a summary and `SHA256SUMS` | `bin/audit-log evidence`, `audit.yml` | `tests/test_audit_log.py`, and every `make docker-test` run builds one |
| **Data is backed up before a risky change** | A configurable command must succeed, and name what it made, before maintenance goes on and the symlink flips | `tasks/backup/run.yml` | `tests/test-controls.yml`: a failing backup and a silent one both stop the deploy |
| **Changes are tested before release** | CI runs the gate and a six-container end-to-end deploy; the release workflow proves the tagged commit passes | `.github/workflows/`, `bin/check` | The workflows themselves |
| **Servers are authenticated** | Host key checking is on for the control node and for the builder's push; a structure check fails any attempt to turn it off | `ansible.cfg`, `tasks/deploy/upload.yml` | `bin/check-structure`, negative-tested |
| **Credentials stay out of logs** | Every task handling a token sets `no_log`, and a structure check fails one that does not. A plaintext secret in the committed defaults fails too | `handlers/main.yml`, `bin/check-structure` | `bin/check-structure`, negative-tested |
| **Least privilege at the edges** | Notifiers are off by default, secrets live in an Ansible Vault file, and the console ships launchable against nothing but the throwaway fleet | `group_vars/all/`, `.ordane.yml` | `tests/test-vars-contract.yml`, `bin/check-structure` |
| **A release can be undone** | Two releases stay on disk, the flip is a symlink, and the release being replaced is taken out of maintenance mode so rolling back to it serves the site | `tasks/release-outgoing-maintenance.yml`, `tasks/release-prune.yml` | `tests/test-outgoing-maintenance.yml`, `tests/test-release-prune.yml` |

## How that maps to the two frameworks

Approximate, and ours rather than an auditor's.

| Requirement | Controls above |
|---|---|
| HIPAA §164.312(b), audit controls | The audit log, and `make audit-verify` |
| HIPAA §164.312(c)(1), integrity | The artefact digest check |
| HIPAA §164.312(d)(e), authentication and transmission security | Host key checking, SSH throughout, secrets out of logs |
| HIPAA §164.308(a)(7), contingency plan | The backup gate. **The restore is yours**: nothing here tests one |
| HIPAA §164.316(b), six-year documentation | Forward the audit log to storage with that retention. The local chain shows tampering; it does not prevent it |
| SOC 2 CC8.1, change management | Approval, the digest, the test gate, and the per-release evidence |
| SOC 2 CC6.1/CC6.6, logical and network access | `no_log`, vaulted secrets, host keys, notifiers off by default |
| SOC 2 CC7.2, monitoring | The deployment events, and `deploy.verified` recorded only when verification passes |
| SOC 2 A1.2, availability | The backup gate, the rollback path, the maintenance window only when a release needs one |

## What it does not cover

- **Anything about the application.** Whether patient data reaches the Magento
  database, how it is encrypted at rest, who can read it, and what the store
  logs are all outside a deploy tool.
- **Access reviews, onboarding and offboarding, training, risk assessments,
  vendor management, business associate agreements, incident response.** These
  are most of an audit and none of them live here.
- **Encryption at rest** for releases, archives, backups or the audit log.
- **Proof that a backup restores.** The gate proves a command succeeded and
  named something. Only a restore test proves the backup is usable.
- **Time.** Records carry the control node's clock. An auditor who cares about
  ordering will want a trusted time source.
- **A key change mid-session.** Ansible reuses one authenticated SSH connection
  per host for a while, so a host key that changes during a run is not rechecked
  until that connection closes. The next run catches it.
- **Anyone with root on the control node.** They can replace the whole audit log.
  Forwarding each record off the machine is what makes that visible.

## Getting the evidence

```bash
make audit-verify environment=staging
make evidence environment=staging release=20260915_1789512159_staging
```

The bundle lands in `local.d/evidence/<env>/<release>/` and holds `audit.jsonl`
(that release's records), `chain.txt` (its place in the full log and the head
hash), `summary.md` (a page a reviewer can read) and `SHA256SUMS`.

`local.d/` is gitignored on purpose: evidence describes real systems and does
not belong in a public repository.
