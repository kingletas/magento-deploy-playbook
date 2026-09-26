# magento-deploy-playbook

[![CI](https://github.com/kingletas/magento-deploy-playbook/actions/workflows/ci.yml/badge.svg)](https://github.com/kingletas/magento-deploy-playbook/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

An Ansible playbook that builds a Magento 2 release on a builder host, pushes
it to a fleet of web hosts, deploys Magento onto it, flips the `current`
symlink and prunes what it replaced.

One run, one release, with a build lock so two people cannot cut the same
environment at once. Every step that can fail silently has an assertion in
front of it, and there's a throwaway Docker fleet so you can watch the whole
thing run end to end without owning any servers.

```bash
make help                          # every target, every environment
make check                         # everything verifiable without a host
make docker-test                   # full end-to-end run, seven containers
make docker-demo                   # the same, building real Magento from GitHub
make deploy environment=staging    # a real deploy, once you have one
```

Or without `make` at all:

```bash
ansible-playbook -i inventory/staging deployment.yml
```

`inventory/example/` is the template you copy to make `staging`. It ships with
placeholder hosts under `example.com`, and the playbook refuses to run against
them rather than failing seven times over at the SSH layer.

## Try it in five minutes

No servers needed, no credentials, nothing to configure.

```bash
make docker-test
```

That builds seven throwaway containers -- a builder, three app nodes, an admin
host, a cron host and varnish -- stands up a bare git repository as the release
source, runs the whole deploy against them, and then asserts on what it left
behind. Nothing is stubbed at the Ansible layer: every assert, gate,
`run_once`, `delegate_to` and handler runs for real.

### ...or with real Magento

```bash
make docker-demo
```

The same run, except the release is a shallow clone of **Magento Open Source**
from GitHub rather than the few-KB fixture. So the archive, the rsync fan-out
to five hosts and the symlink cutover all move a real 435 MB release. The
repository is public, so there's nothing to authenticate.

Point it at your own instead:

```bash
make docker-demo DEMO_REPO=https://github.com/you/store.git DEMO_BRANCH=main
```

Then look around inside the fleet:

```bash
bin/docker-suite shell web1
ls -la /var/www/html/                      # releases/, archives/, the symlink
readlink -f /var/www/html/magento_current  # what is live
```

The shallow clone is deliberate: the build doesn't need the history, and a
full clone of Magento is a long wait. The changelog step then has no merge base
to work from, so it falls back to a message saying so -- which is the behaviour
it is written to have, not a failure. Drop `git_depth` to get a real changelog.

[docker/README.md](docker/README.md) has what is faked inside the containers
and what isn't.

## Contents

- [Setup](#setup)
- [Environments](#environments)
- [Controls, approvals and the audit log](#controls-approvals-and-the-audit-log)
- [Warming the storefront](#warming-the-storefront)
- [Which host runs Magento's commands](#which-host-runs-magentos-commands)
- [After the cutover: the health check and rollback](#after-the-cutover-the-health-check-and-rollback)
- [Rehearsing setup:upgrade](#rehearsing-setupupgrade)
- [Proving the zero-downtime assumptions](#proving-the-zero-downtime-assumptions)
- [Building only what changed](#building-only-what-changed)
- [Bundling the JavaScript](#bundling-the-javascript)
- [Running it from a console](#running-it-from-a-console)
- [The one rule: inventory vars vs playbook vars](#the-one-rule-inventory-vars-vs-playbook-vars)
- [Running a deploy](#running-a-deploy)
- [Layout](#layout)
- [What the checks cover, and what they don't](#what-the-checks-cover-and-what-they-dont)
- [Adding an environment](#adding-an-environment)
- [Scope](#scope)
- [What this doesn't do](#what-this-doesnt-do)
- [Known limitations](#known-limitations)

## Setup

```bash
make venv          # python virtualenv from requirements.txt
make collections   # community.general + ansible.posix
make check         # prove the install works
```

Everything is here and tracked: the inventories, the settings and the release
payloads. There's no `.env` to source, no submodule to initialise and nothing
to export.

**Credentials.** `group_vars/all/notifications.yml` ships in plain text with
placeholder values, and every notifier that would use one is off by default, so
the playbook runs out of the box with no secrets at all. Once you put real
tokens in it:

```bash
ansible-vault encrypt group_vars/all/notifications.yml
```

then uncomment `vault_password_file` in `ansible.cfg` and put the password in
`.vault-pass`, which is gitignored. The offline suites decrypt through
`include_vars`, so they keep working either way.

## Environments

An environment is a directory under `inventory/`. That directory is *both* the
hosts and the settings:

```text
inventory/
    example/   hosts  group_vars/all.yml     the template -- copy this one
    docker/    hosts  group_vars/all.yml     the local container fleet
    test/      hosts  group_vars/all.yml     the offline suites
```

Anything named `inventory/local-<name>/` is gitignored, for an environment whose
hosts and addresses are nobody else's business. An inventory has to live under
`inventory/` for Ansible to find it, so `local.d/` cannot hold one.

`ansible-playbook -i inventory/<name> deployment.yml` takes the directory, and
`make deploy environment=<name>` takes its name. Adding an environment is
copying `inventory/example/` -- the template -- and editing two files;
`make check` then tells you if you forgot a key or invented one.

All three declare **the same seventeen keys**, and `make check` fails if one of
them forgets a key or invents one:

| Key | What it decides |
|---|---|
| `env_name` | Names the release (`<env_name>_latest`) and the DORA event |
| `suffix` | Names the release directory and **scopes the prune** |
| `branch_name` | The branch `tasks/packaging/git.yml` checks out |
| `php_version` | The FPM service name, and is checked against `php_minimum_version` |
| `profile` | The text in the Slack message and the PagerDuty description |
| `deployment_complete` | Whether the `current` symlink is repointed |
| `git_repo` | Where the release is cloned from |
| `warmup` | Whether and how the storefront is warmed once maintenance is off. See [Warming the storefront](#warming-the-storefront) |
| `health` | What each app host must serve after the cutover, and whether a failure puts the previous release back. See [After the cutover](#after-the-cutover-the-health-check-and-rollback) |
| `lock_forecast` | Whether a release's `setup:upgrade` is rehearsed first, and how much it may lock. See [Rehearsing setup:upgrade](#rehearsing-setupupgrade) |
| `audit` | Where the deploy's audit log is written, whether it is forwarded, and whether a record that fails stops the deploy |
| `approval` | Whether a release needs a signed approval, and whose signatures count |
| `backup` | Whether a backup runs before the cutover, what command takes it, and how long it may take |
| `kill_php` | Whether PHP is killed before the cutover |
| `archive_min_bytes` | The floor the built tarball must exceed |
| `release_disk_min_bytes` | Free space each host must have **before** the deploy starts |
| `notify_via_slack` | Whether a deploy posts to Slack |

Three of those deserve their own note.

**`deployment_complete` is the footgun this layout exists to close.** When it is
false, a deploy runs green and never repoints the symlink -- nothing goes live,
and the tasks that `chdir` into `releases.current` then fail with "Unable to
change directory". `tasks/release-preflight.yml` asserts the key is *defined* --
`is defined` rather than a truth test, because `false` is a legitimate value
(build without cutover) and *absent* isn't.

**`release_disk_min_bytes` is an estimate, and the check tells you the real
number.** Running out of space mid-deploy fails in the worst available place. A
web host filling up during `tasks/deploy/unarchive.yml` leaves a partial release
and stops the run with the fleet in a mixed state and the site in maintenance
mode.

So it's checked up front, on every host that will hold a release, before the
lock is taken or anything is created. The failure says so, and it's safe to
retry. `varnish` is skipped deliberately: nothing is ever written to it, so
failing there would block a deploy for an unrelated reason.

The 8 GB default for stage and dev covers one release tree plus its tarball with
headroom, but it's an estimate rather than a measurement. The assertion's
success message reports actual free space on every passing host, so one green
deploy gives you the numbers to set it from.

**`suffix` is an environment-slot identifier, not a branch derivation.** It is a
literal. Deriving it from `branch_name` would give every branch its own prune
scope, and releases from other branches would then never be pruned.

## Controls, approvals and the audit log

A deploy here records what it did, refuses code nobody approved, and can take a
backup before it touches anything. All three are per environment and off or
empty until you set them:

```yaml
audit:
  path: ~/.local/state/magento-deploy-playbook/staging.audit.jsonl
  forward: ""          # a command that receives each record on stdin
  required: true       # a record that cannot be written stops the deploy

approval:
  required: true
  allowed_signers: /etc/magento-deploy/allowed_signers
  tag_pattern: "approved/*"

backup:
  run: window          # never | window | always
  command: /usr/local/bin/snapshot-magento-database
  timeout: 3600
```

**The audit log is append-only and hash-chained.** Each record carries the SHA-256
of the one before it, so an edited, removed or reordered line breaks every hash
after it:

```bash
make audit-verify environment=staging
make evidence environment=staging release=20260915_1789512159_staging
```

A release's evidence bundle holds its records, its place in the chain, a summary
and `SHA256SUMS`. The chain shows tampering; it cannot prevent it, so set
`forward` to something that ships each record somewhere nobody here can rewrite.

**An approval is a signed git tag.** Someone other than the deployer signs a tag
on the commit with an SSH key listed in `allowed_signers`, and the build refuses
to start without one:

```bash
git tag -s approved/2026-09-15 -m "reviewed" <commit>   # with gpg.format=ssh
```

The deployer is whoever `git config user.email` names on the control node, which
they set themselves. The signature is the control; the deployer check only stops
a release being approved by the person shipping it.

**The backup runs before maintenance goes on and before the symlink moves**, on
the host that runs Magento's commands. Its last line of output is recorded as the backup's name,
and a backup that fails or names nothing stops the deploy with the old release
still serving.

**Every field a record carries is in [docs/ledger.md](docs/ledger.md)**: the
envelope, the actor, and what each of the eleven events adds. What all of this is
evidence of, and what it is not, is in [docs/compliance.md](docs/compliance.md).

## Warming the storefront

A deploy flushes Magento's cache and bans its pages in Varnish, so the first
visitors after it build every page from scratch. The warm-up requests pages
first, from the machine running Ansible, as soon as maintenance mode is off:

```yaml
warmup:
  enabled: true
  base_url: https://stage.example.com/
  paths:                  # warmed first, in this order
    - /
    - /customer/account/login/
  sitemap: sitemap.xml    # "" for none; an index is followed one level
  limit: 200              # most URLs requested, after duplicates are removed
  concurrency: 8          # requests at a time, 1 to 64
  timeout: 30             # seconds per request
  fail_below: 0           # % that must answer 2xx; 0 only reports
```

It requests the paths, then the sitemap's URLs, stopping at `limit`. Only URLs
on `base_url`'s host are requested: a path has to start with a single `/`, and
sitemap entries for any other host are skipped. Every setting is checked before
the build starts, because by the time the warm-up runs the release is live.

The run prints how many URLs answered 2xx and lists the first 20 that did not.
**It never fails the deploy unless you set `fail_below`**, and even then the
check runs last, after the prune and the lock release, and rolls nothing back:
the release is already serving. Use it as an alarm for a storefront that came up
broken.

**It warms after traffic arrives, not before.** When there is no maintenance
window there is no moment before customers reach the new release, and during a
window Magento's maintenance page blocks the warm-up's requests too. Warming a
node before it takes traffic needs a rolling deploy, which this playbook does
not do.

## Which host runs Magento's commands

**One host runs every Magento command in a deploy**: the status checks, the
backup, the rehearsal, the cache flush, `setup:upgrade` and the indexer reset.
It is chosen before anything goes live, from `magento_hosts` in the inventory,
which is the admin group when an environment does not set it:

```yaml
magento_hosts: [admin1, web1]   # admin1 first; web1 only when admin1 cannot
```

A host is chosen when it is still in the deploy and its `setup:db:status`
answers, which means it can run `bin/magento` against the database. The first
that does is used, and the deploy says when it passed over one. When none can,
the deploy stops there: nothing has gone live, maintenance is off, the build lock
is released, and `deploy.failed` records `phase: magento-host` with what each
host answered.

**A web host that drops out stops the deploy** wherever it happens: before the
cutover, during the upload, before and during the switch, and after it. The
record names the host and the phase, and no success is written.

**Every step after the switch has a decided response.** By then every web host
serves the new release, so when the cache flush, the Varnish ban,
`maint:disable` or the indexer reset fails, the deploy stops rather than guess:
it records `deploy.failed` with `phase: after-switch`, the step and the error,
releases the build lock, and prints the steps left to run by hand, with whether
`make rollback` is still possible. A step that runs on every web host fails once
for all of them, so no host carries on alone. `setup:upgrade` keeps its own
response, described below.

## After the cutover: the health check and rollback

Once the new release is live and maintenance is off, every app host requests
each path in `health.paths` from its own web server, at `health.url`, with
`health.host` as the Host header. That bypasses Varnish and any load
balancer, so a cached page cannot answer for a broken release. A path passes
only on a 2xx.

```yaml
health:
  enabled: true
  url: http://127.0.0.1/
  host: stage.example.com
  paths:
    - /
    - /customer/section/load/?sections=cart
  timeout: 10
  attempts: 3
  delay: 5
  rollback: auto      # auto | never
```

**Storefront paths, not `pub/health_check.php`.** That script checks the
database and the cache answer, but never passes through the front controller,
so a server whose code and database disagree answers 200 there while refusing
every page. So does a server in maintenance mode. The cart section is never
cached and reads the database.

**When a path fails, the release the deploy replaced goes back, if it can.**
Moving the symlink undoes the code, not the database, so a guard decides first:

1. **The older release's own `setup:db:status` must pass** against the live
   database. It runs the same version check Magento's front controller makes on
   every page, so a failure means the older code would answer every page with a
   500. That is what happens once a deploy's `setup:upgrade` records a newer
   module version. An exit 2 can also be a column the new release only widened,
   which is harmless; the refusal says so.
2. **No data patch may have run since the older release went live.** Each
   deploy records the highest `patch_list` id its release went live with, and
   anything above it is data the older code has never seen and a rollback
   cannot undo.
3. **No NOT NULL column without a default may exist that the older release
   does not declare**, in a table it does, because its INSERTs leave that
   column out.
4. **No unique or foreign key may have been added since it went live**, on a
   table it declares, because its writes know nothing of it. Keys are compared
   by their columns, against the list each release records when it goes live;
   a release with no such record is compared with what it declares, which also
   names keys that predate it.

It also reports what goes back regardless: recurring setup scripts only the
newer release has, and configuration written since.

**What the automatic rollback covers is a release that went live and does not
serve pages.** It does not cover `setup:upgrade` failing part way: then the
database may be half migrated, a code rollback is the wrong answer, and the
deploy stops with the site in maintenance, releases the build lock, records
`upgrade.failed` and prints the way back: restore the backup, or fix the cause
and run `setup:upgrade` again.

**When the guard refuses, the live release goes into maintenance** and the
deploy stops, naming the backup it took. A maintenance page tells a customer to
come back; a failing page does not, and a rollback onto a newer database would
fail every page instead of some.

The status commands run with a private file cache, so the older release's code
cannot write its configuration into the cache the live release reads. A Magento
too old to allow that refuses the automatic rollback rather than risk it.

### Rolling back by hand

```bash
make rollback environment=staging                      # the release before the live one
make rollback environment=staging release=<name>       # a named release
```

The same guard decides. Each refusal can be overridden, and only by naming
exactly what it listed, so nobody waves a refusal through without reading it:

| The guard refused because | Override |
|---|---|
| The older release's `setup:db:status` exited 2 | `EXTRA='-e rollback_despite_database=true'` |
| Data patches ran since it went live | `EXTRA="-e rollback_accept_patches='<every name listed>'"` |
| A NOT NULL column it would leave out | `EXTRA="-e rollback_accept_columns='<every column listed>'"` |
| A unique or foreign key added since it went live | `EXTRA='-e {"rollback_accept_constraints": "<every key listed, separated by ;>"}'` |

A status command that could not run, or a release missing from a host, cannot
be overridden. `make rollback` takes the build lock, so it cannot run while a
deploy does.

### What the configuration import will delete

`setup:upgrade` imports `config.php` when it changed, and the import asks for a
yes before it creates, updates or deletes websites, stores, groups and themes.
Without `--no-interaction` a deploy has nobody to answer and the import
aborts; with it, every question is answered yes, including "these stores will
be deleted". So before the cutover, whenever `app:config:status` reports work,
the deploy asks Magento's own importers what they would warn about. Creations,
updates and theme registrations are printed and go ahead. **Anything else, a
deletion or any warning worded otherwise, stops the deploy before anything
goes live**, until it is accepted by exactly what was printed:

```bash
make deploy environment=staging EXTRA='-e {"config_import_accept": "These Stores will be deleted: Second"}'
```

## Rehearsing setup:upgrade

`setup:upgrade` does more than a release's schema changes. It reconciles the
whole database with the code, so it also drops and rebuilds grid tables and
recreates every indexer trigger, and none of that shows in `--dry-run`. Some of
it locks tables customers write to. With `lock_forecast.enabled`, a release
whose `setup:upgrade` will run is rehearsed before anything goes live:

1. The admin host writes production's row counts and sizes, and a dump of its
   schema with the rows `setup:upgrade` reads to decide what to run: module
   versions, applied patches, the stores, the EAV metadata and configuration,
   plus the tables the release's not-yet-applied patches name. Tables holding
   people, orders or payments are never dumped, whatever a patch names, and
   neither are patch-named tables over 10,000 rows; the report lists both, so
   you know which patches ran on an empty table.
2. The builder runs the built release's real `setup:upgrade` against a
   throwaway MariaDB of production's version, loaded with that dump, and keeps
   every schema statement it sends.
3. It loads the dump again and replays each statement, asking the server for
   `ALGORITHM=INSTANT`, then `NOCOPY`, then `INPLACE` with `LOCK=NONE`. The first
   it accepts is the statement's class. None means a table copy that blocks
   writes for as long as it takes.

```yaml
lock_forecast:
  enabled: true
  image: mariadb:11.4      # production's major.minor, or the rehearsal refuses
  stop_on_rows: 1000000    # 0 only reports
  required: false          # stop when the rehearsal itself cannot finish
  extra_tables: []         # more tables whose rows your data patches read
```

**A blocking copy of a table with more rows than `stop_on_rows` stops the
deploy before the cutover.** The row count is InnoDB's estimate, so the
threshold is approximate. So does a column the release narrows: Magento does
not refuse data that no longer fits, it cuts it, with nothing in the output.
Check the data, then accept each narrowing by name with
`EXTRA="-e forecast_accept_narrowing='<entries, separated by ;>'"`.

The report gives rows and bytes, not seconds: how fast a server rebuilds a
table depends on disk and load that a rehearsal does not have. It lists data
patches and data statements by name and count only, because they ran on empty
tables. A class is the best case: a production table carrying earlier instant
changes may need a rebuild where the copy did not. And trigger statements take a
metadata lock that waits for every open transaction on the table, which no
rehearsal can size.

The dump holds the configuration table, secrets included. It is written 0600
and deleted from the host that runs Magento's commands and the builder when the
rehearsal ends, whatever happened. The builder needs Docker and Python 3, and that
host `mariadb-dump` or `mysqldump`.

## Proving the zero-downtime assumptions

A deploy that keeps the old release serving while the new one comes up rests
on claims about Magento: that the previous release keeps working on a schema
one step ahead of it, that two releases sharing a cache do not read each
other's configuration, that a php-fpm reload is what makes a symlink flip take
effect. `bin/zdt-proof` tests each claim against a real store, showing the
failure first and then the fix, and prints one PASS or FAIL line per falsifier.

```bash
export KAPELOS_HOME=/path/to/kapelos   # the store runs under Kapelos
bin/zdt-proof list                     # the eight proofs and two wrappers
bin/zdt-proof p0-2                     # one proof, against the active site
```

The stores come from [Kapelos](https://github.com/kingletas/kapelos), which
gives each one its own containers and database snapshots. **Run them on an
empty or generated store only**: they change its schema, code and settings, and
restore snapshots over its database.
[docs/zero-downtime-proofs.md](docs/zero-downtime-proofs.md) says what each
proof claims, how it shows the failure and the fix, and every line it prints.

## Building only what changed

The compiled code and the static content are each reused from the previous
build on the builder when nothing that phase reads has changed. Each phase has
a fingerprint over the tracked files it reads, the command that runs it and the
settings it depends on; `composer.json`, `composer.lock` and `patches/` stand
for `vendor/`, which is not tracked. `tests/test-build-skip.yml` changes one
file at a time and asserts which fingerprint moves.

```yaml
build_skip:          # group_vars/all/build.yml
  compile: true
  static: true
  max_age_days: 7    # output this old is rebuilt whatever its fingerprint says
```

Two things a fingerprint cannot see: the body of a PHP class that changes static
output, such as an asset preprocessor (its `di.xml` registration is covered),
and configuration held in the database, such as a store's locales. Turn a phase
off for a release that changes either.

**Static content is checked, not trusted.** With parallel jobs,
`setup:static-content:deploy` exits 0 when a theme fails to compile part way:
the error is printed, the theme is short of its files, and the release ships
without its stylesheets. After every static deploy, the build reads the output
for Magento's failure messages, requires every theme and locale to have
reached all its files, and requires the files in `static_sentinels` to exist
for each. Any miss stops the build before anything leaves the builder. A Hyva
theme compiles `css/styles.css` rather than Luma's two stylesheets; set
`static_sentinels` to match.

## Bundling the JavaScript

Magento ships its RequireJS modules as a hundred and fifty separate files, and
bundling them is the difference between a storefront that feels fast and one
that doesn't. Pick a bundler in `group_vars/all/build.yml`:

```yaml
bundler: manipulus     # manipulus | magepack | none
```

Both read the static content the build just deployed, so bundling always runs
*after* `setup:static-content:deploy`, never before it.

| | What it needs | What it costs |
|---|---|---|
| **`manipulus`** (default) | The [Manipulus](https://github.com/kingletas/manipulus) command on the build host, and its module committed and enabled in your store | Nothing else. It parses the codebase, so no browser, no Node and no running store |
| **`magepack`** | Docker on the build host and a committed `magepack.config.js` | `make magepack-image` builds the image. Generating the config is a separate browser-driven step against a running store |
| **`none`** | Nothing | An unbundled storefront. A real answer while you're setting one of the others up |

If the chosen bundler isn't on the build host's PATH, the run stops at the
bundling step with a message naming the fix rather than at whatever the missing
command breaks. Nothing has left the builder at that point.
`extra_build_steps` runs anything else your release needs afterwards -- a
theme's grunt task, a sourcemap upload.

## Running it from a console

`.ordane.yml` configures [Ordane](https://github.com/kingletas/ordane), a console
for an Ansible control plane. It reads `make help` for the targets and
environments; the file carries what that output cannot say.

```bash
ordane doctor --repo .      # what it found, and anything worth fixing
ordane catalog --repo .     # the parsed targets, grouped and graded
ordane app --repo .         # the desktop console
```

**Only `docker` is launchable out of the box**, because that is six throwaway
containers on your own machine. `example` is the template, `test` is the offline
suites, and neither belongs on the allow list. Add your own environment to
`environments.allow` when you have one.

`deploy` is graded `high` and asks you to type the environment's name, because
it flips the symlink and, for a release with database work, takes the site into maintenance. `unlock` is `medium`:
dropping the lock while a build is genuinely running lets a second one start.

### What the delivery numbers can and cannot source

| Measure | Source | State |
|---|---|---|
| Change failure rate | Runs launched through the console, once `deploy: true` | Fills in as you use it |
| Time to restore | The gap between a failed deploy and the next that worked | Fills in as you use it |
| Release frequency | A release log in the repository | **Dormant** |
| Lead time for changes | The same release log | **Dormant** |

The first two need nothing from you: `deploy` is already marked `deploy: true`
and `cutover: true`.

The last two need a release log at `docs/dora/backfill.jsonl`, and **this
playbook does not write one.** What it writes is a deployment event per phase to
`dora.local.path`, which defaults to a file under your own `$HOME` rather than
into the repository. That is per-operator state, not a shared history.

Those events do carry what a release log needs: the release name, the
environment, the commit and the commit count at build time, and the cutover. A
reporter folding them into the repository would light both cards. Writing one
is a real piece of work and isn't shipped.

Until then those two cards stay dormant and say so, which is the point: a zero
would look like a measurement, and *nothing has shipped* and *nothing has been
recorded* are very different sentences.

**`metrics.environments` is set to `production`, which nothing here is.** A
release to a throwaway fleet must never move a delivery number, so the default
is deliberately a name this repository does not define. Put your own there.

## The one rule: inventory vars vs playbook vars

Ansible's precedence for group_vars, low to high:

| # | Source | Here |
|---|---|---|
| 3 | inventory `group_vars/all` | `inventory/<env>/group_vars/all.yml` |
| 5 | playbook `group_vars/all` | `group_vars/all/` |
| 6 | inventory `group_vars/<group>` | *unused* |
| 7 | playbook `group_vars/<group>` | *unused* |

**The playbook side is higher.** So a key declared in both places resolves to
the playbook's value on every environment, and the inventory's value is silently
discarded -- no warning, no error, the deploy just quietly uses the wrong thing.
Add a well-meant "default" playbook-side and you break every environment at
once, invisibly.

So: **any key that varies by environment lives only in
`inventory/<env>/group_vars/all.yml`, and never under `group_vars/`.**

This isn't left to discipline. `test-vars-contract.yml` reads both sides as
*files* -- the collision is invisible in resolved variables, because by then one
side has simply won -- and fails naming the offending keys. It was negative-tested
both ways: with and without a value assertion on the colliding key.

Structural values that do *not* vary stay playbook-side and reference the
inventory scalars, so the dict lives in one place:

```yaml
# group_vars/all/releases.yml   -- structure, one copy
releases:
  path: "{{ site.base }}releases/"    # same everywhere
  complete: "{{ deployment_complete }}"   # <- inventory decides
  kill_php: "{{ kill_php }}"              # <- inventory decides
```

## Running a deploy

```bash
make deploy environment=staging         # build and cut over
make deploy environment=staging branch_name=release/1.2    # another branch
make deploy environment=staging release_name=20260819_1755600000_staging

make deploy environment=staging EXTRA='--check -vv'
make verify environment=staging         # assert on what a deploy left behind
make unlock environment=staging         # clear a stale build lock
```

`branch_name=` and `release_name=` become `--extra-var`, which outranks
everything in group_vars, so they work without the inventory knowing about
them. `branch_name=` does **not** change `suffix`; see above.

### Verifying a deploy, on any environment

`make verify environment=<env>` reads the hosts rather than the deploy's own
output: the symlink points into this environment's releases, the live release
has a usable Magento CLI, every shared link resolves, `env.php` is the shared
copy, the custom payloads landed, no release was left in maintenance mode, and
no build lock survived. When all of it passes it records `deploy.verified`,
which is the one record in the ledger that says somebody checked afterwards.

The fixture fleet's own checks -- that the build called composer, that services
were reloaded and never restarted, that Varnish was banned rather than
restarted, that `setup:upgrade` ran inside the window -- read `/tmp/build-log`,
the call log every fake tool writes. They run only where the inventory says
`fake_tools: true`, which is `inventory/docker`. **Set it false on a real
environment**, as the shipped examples do: there is no call log there, and
without the flag verify would fail on a missing file and never reach the checks
that do apply.

### Why the configuration isn't in the environment

An earlier version of this pipeline passed its settings through a shell profile
and read them back with `lookup('env', ...)`. Two failure modes made that
untenable, and both are silent:

1. **`lookup('env', X)` on an unset name returns an empty string, not
   undefined**, so `| default(...)` never fires and a forgotten export produces
   `''` rather than an error.
2. **A value that reaches Ansible only because a wrapper exported it** is empty
   for every invocation that doesn't go through that wrapper -- including, in
   that case, the git remote.

`bin/check-structure` fails on any reintroduced `lookup('env', ...)`. The only
two allowed are `USER` and `HOME`, which describe the operator rather than the
environment.

## Layout

```text
deployment.yml          seven plays: guard, preflight, build, upload, magento,
                        prune, warm-up threshold
verify-deploy.yml       asserts on the filesystem after a deploy
audit.yml               checks the audit chain, writes an evidence bundle
unlock.yml              clears a stale build lock
rollback.yml            puts an earlier release back, under the guard
test.yml                imports the nine offline suites
tests/                  the suites, plus four symlinks -- see below
    test-vars-contract.yml  test-bundler.yml
    test-release-lock.yml   test-release-prune.yml
    test-outgoing-maintenance.yml  test-upgrade-gate.yml
    test-warmup.yml               test-controls.yml
    test-build-skip.yml           build-skip-case.yml
    test_audit_log.py             (python, run by bin/check)
    test_zdt_proof.py             (python, run by bin/check)
    group_vars -> ../group_vars   tasks -> ../tasks
    handlers   -> ../handlers     inventory -> ../inventory

ansible.cfg             the only config. Resolved from the WORKING directory,
                        which is why every entry point runs from here
Makefile                the entry point
docker.mk         the docker-* targets

group_vars/all/         environment-INDEPENDENT defaults
    system.yml releases.yml git.yml build.yml dora.yml audit.yml
    notifications.yml   credentials + payloads; placeholders, encrypt it
inventory/<env>/        environment-SPECIFIC everything

tasks/
    release-preflight.yml   resolves + VALIDATES; runs first, always
    disk-space.yml          room for a release, before anything is created
    packaging/              git, deploy, build reuse, static checks, bundle, archive
    deploy/                 upload, unarchive
    magento-deploy/         the cutover, the upgrade gate, the health check
    health/ rollback/       the health check, and the guarded rollback
    forecast/               the setup:upgrade rehearsal
    helpers/                puts files/helpers/ where Magento's commands run
    release-lock/           acquire, release
    release-prune.yml  dora-event.yml
handlers/main.yml       every handler; each play imports it
files/                  release payloads releases.custom_files names
files/helpers/          what runs on the hosts: the cache-isolated status
                        commands, the rollback guard's database reads, the
                        snapshot and rehearsal, the static content check

bin/check               make check
bin/check-structure     the five structural checks
bin/docker-suite        the local fleet
bin/zdt-proof           the zero-downtime proofs, run against a Kapelos store
bin/zdt-proof.d/        its library, proofs, PHP payloads and fixture module
docker/                 the local fleet's image, fakes and fixtures
docs/                   from-nothing.md, design.md, ledger.md, compliance.md,
                        zero-downtime-proofs.md
```

### Why tests/ contains four symlinks

**Ansible resolves playbook-adjacent `group_vars/` relative to the playbook
file.** A suite in `tests/` looks for `tests/group_vars/`, finds nothing, and
silently stops testing `group_vars/all/` -- which is half of what these suites are
for. That was this playbook's original layout; it failed on
`releases is defined`, and `test-vars-contract.yml`'s first assertion exists to
catch the regression.

`import_playbook` does **not** rescue it. Measured on ansible-core 2.13: running
`test.yml` from the root and importing `tests/test-*.yml` still resolves
adjacency against `tests/`, and **`playbook_vars_root` doesn't change that** --
neither `top` (the default) nor `all` makes the root `group_vars` load. The play
fails at "Name the release" with `'use_existing_release' is undefined`.

So `tests/` is made to look, to Ansible, exactly like the playbook root:

```text
tests/group_vars -> ../group_vars     the adjacency the suites assert on
tests/tasks      -> ../tasks          import_tasks: tasks/... unchanged
tests/handlers   -> ../handlers       import_tasks: handlers/main.yml
tests/inventory  -> ../inventory      {{ playbook_dir }}/inventory
```

The payoff: **every path inside a suite is byte-identical to the same path in
`deployment.yml`.** No `../` anywhere, so a suite exercises the same references the
deploy does rather than a rewritten copy of them -- which was the whole objection
to putting them in a subdirectory in the first place. Git stores all four as real
symlinks (mode `120000`), not copies.

Every way this can break fails **loudly**, and each was confirmed by deleting the
link and watching it fail:

| Missing | Fails with |
|---|---|
| `group_vars` | the first assertion in `test-vars-contract.yml` |
| `tasks` | `Could not find or access .../tasks/release-preflight.yml` |
| `handlers` | the same, on `handlers/main.yml` |
| `inventory` | `The glob actually matched something` -- 0 files found |

`bin/check-structure` additionally asserts all four exist and resolve to this
playbook's own directories, so a missing or misaimed link is caught *before* any
suite runs rather than four plays in. Negative-tested five ways.

The alternative that was rejected: explicit `include_vars` in each suite. It
works, and it loses exactly the coverage that matters -- it would test an
`include_vars`, not the adjacency the deploy relies on.

`test.yml` remains the single entry point, and `import_playbook` is static, so
`--syntax-check` validates all four paths and a renamed suite cannot silently
stop running. Individual suites still run directly:
`ansible-playbook -i inventory/test tests/test-vars-contract.yml`.

### One ordering constraint

`group_vars/all/build.yml` builds the bundler commands around `{{ wdir }}`, which
`tasks/release-preflight.yml` provides. So **`bundler_steps` cannot be touched
before preflight runs** -- even `bundler_steps is defined` raises, because
evaluating it templates the values. Every suite imports preflight first.

## What the checks cover, and what they don't

```bash
make check         # syntax, inventories, structure, the audit tool, the proof runner, nine offline suites, lint
make docker-test   # the real thing, against six containers
make docker-demo   # the same, building real Magento from GitHub
make docker-down   # afterwards
```

`make check` has six layers:

| Layer | Catches |
|---|---|
| `--syntax-check` × 3 | A bad include path, a malformed task, a bad play key |
| Inventories × 4 | A hosts file where `builder`/`apps`/`admin`/`cron`/`varnish`/`web` don't all resolve. A deploy against a broken one reports "no hosts matched" and exits **0** |
| `bin/check-structure` | A reintroduced `roles:`; a `notify` with no handler; an include path that only resolves at run time; **a parent-path reference**; **a stray `lookup('env', ...)`** |
| `test.yml` | Nine suites: the variable contract and the precedence guard, the disk pre-flight, the `bundler_steps` table, the build lock, the prune against a real temporary filesystem, the replaced release's maintenance flag against another, and which status exit codes and unregistered themes open a maintenance window or stop the cutover, which file changes move which build fingerprint against a real git repository, and the warm-up against a local web server, and the audit, integrity, backup and approval controls against a real git repository and real signing keys |
| `tests/test_*.py` | `bin/audit-log`'s chain and evidence; `bin/zdt-proof` listing every proof and refusing to start without a Kapelos checkout, using stand-ins for Docker and Kapelos |
| yamllint / ansible-lint / shellcheck | Formatting, and shellcheck over `bin/zdt-proof`. A broken tool reads as **SKIP**, never as a failure |

Every structural check has been negative-tested -- a deliberate fault introduced
and confirmed caught.

**`--check` is close to useless for this playbook.** It builds a release on the
builder and extracts it on the fleet, so a dry run skips the interesting half.
That's why `make docker-test` exists; `docker/README.md` documents what is real
in it and what is faked.

**Not covered:** real Magento (no database, no indexers, no static content),
scale and timing, and anything the fakes paper over. A green suite means the
orchestration is sound, not that the release is deployable.

## Adding an environment

```bash
cp -r inventory/example inventory/staging
# edit inventory/staging/hosts and .../group_vars/all.yml, then:
make check
make deploy environment=staging
```

`make check` will tell you if you forgot a key or added one the other
environments don't have. Set every one of the seventeen explicitly, even where
the value is the same as everywhere else. An environment that omits a key falls
back to whatever happens to be around, which is exactly the failure mode the
shell profiles had.
## Scope

**In:** building a release and cutting over to it in one run, which is what a
lower environment needs.

**Out, deliberately:** a production cutover. Production wants build and upload
as one step and the symlink flip as a separate, human-gated one, so somebody
can look at a staged release before it goes live.

This playbook can express half of that: set `deployment_complete: false` and the
deploy runs without flipping the symlink. But a real production path also wants
an approval gate, a rollback target and a cutover that doesn't rebuild. That's a
different playbook, and pretending one covers both is how a deploy goes live
that nobody approved.

**Also out:** restoring the database. The deploy can take a backup before the
cutover, rehearse `setup:upgrade`, and refuse a rollback the database has moved
past, but putting a database back is a decision for a person, with the backup
the audit log names.

## What this doesn't do

Worth saying plainly, because a deploy tool that is vague about its edges is
how people find out the hard way:

- **No database rollback.** `make rollback` and the automatic rollback move
  the code, and refuse when the database has moved past the older release. What
  undoes a database change is a restore from the backup the deploy recorded, and
  that is yours to run. `teardown_releases_to_keep` keeps two releases on disk,
  so there is one to go back to. A release replaced by an older version of this
  playbook still carries `var/.maintenance.flag`: run
  `php bin/magento maint:disable` in it after rolling back to it.
- **No zero-downtime guarantee.** A release whose `setup:db:status` or
  `app:config:status` reports work to do takes a maintenance window, turned on in
  the incoming release before the flip and off after `setup:upgrade`. How long
  that is depends on your catalogue. A release with nothing to do takes no
  window, but every web host still flips at once: nginx and php-fpm are
  reloaded, not restarted, so requests in flight finish, and Varnish drops
  Magento's pages with a ban rather than a restart.
- **No secrets management.** Ansible Vault and a password file, which is the
  floor rather than the ceiling.
- **No CI integration shipped.** It's a playbook; call it from whatever you
  use.

## Known limitations

- **PHP 8.0 and up only.** `php_minimum_version` in
  `group_vars/all/build.yml` is the floor, asserted before the bundler runs. A
  store still on PHP 7 is told so up front rather than by whatever breaks first.
- **Bundling needs one-time setup in your store**, whichever bundler you pick:
  manipulus wants its module committed and enabled, magepack wants a
  `magepack.config.js`. `bundler: none` is a real answer until then.
- **PagerDuty, New Relic, Noibu and Yottaa are wired but off**, with placeholder
  credentials. `tests/test-vars-contract.yml` asserts they stay off in the
  committed defaults, because a notifier turned on in a shared default points
  at whatever account its credentials belong to.
- **Needs Python 3.12 or newer.** ansible-core 2.20 dropped everything below
  it, and pip on an older interpreter resolves an ansible-core from 2023
  rather than refusing. `make venv` checks and says so; override the
  interpreter with `make venv PYTHON=python3.12`.
- **`--check` proves little here.** The playbook builds a release on the
  builder and extracts it on the fleet, so a dry run skips the interesting
  half. `make docker-test` is the answer, and
  [docker/README.md](docker/README.md) says what it does and doesn't prove.

## Licence

MIT. See [LICENSE](LICENSE).
