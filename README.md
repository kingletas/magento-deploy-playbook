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
make docker-test                   # full end-to-end run, six containers
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

That builds six throwaway containers -- a builder, two app nodes, an admin
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
- [Bundling the JavaScript](#bundling-the-javascript)
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

All three declare **the same thirteen keys**, and `make check` fails if one of
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
| `base_url` | Feeds the warm-up ping URL |
| `ping_url` | Whether the warm-up ping fires at all |
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
make verify environment=docker          # assert on what a deploy left behind
make unlock environment=staging         # clear a stale build lock
```

`branch_name=` and `release_name=` become `--extra-var`, which outranks
everything in group_vars, so they work without the inventory knowing about
them. `branch_name=` does **not** change `suffix`; see above.

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
deployment.yml          seven plays: guard, preflight, build, upload, varnish,
                        magento, prune
verify-deploy.yml       asserts on the filesystem after a deploy
unlock.yml              clears a stale build lock
test.yml                imports the four offline suites
tests/                  the suites, plus four symlinks -- see below
    test-vars-contract.yml  test-bundler.yml
    test-release-lock.yml   test-release-prune.yml
    group_vars -> ../group_vars   tasks -> ../tasks
    handlers   -> ../handlers     inventory -> ../inventory

ansible.cfg             the only config. Resolved from the WORKING directory,
                        which is why every entry point runs from here
Makefile                the entry point
docker.mk         the docker-* targets

group_vars/all/         environment-INDEPENDENT defaults
    system.yml releases.yml git.yml build.yml dora.yml
    notifications.yml   credentials + payloads; placeholders, encrypt it
inventory/<env>/        environment-SPECIFIC everything

tasks/
    release-preflight.yml   resolves + VALIDATES; runs first, always
    disk-space.yml          room for a release, before anything is created
    packaging/              git, deploy, php-build-steps, archive
    deploy/                 upload, unarchive
    magento-deploy/main.yml
    release-lock/           acquire, release
    release-prune.yml  dora-event.yml
handlers/main.yml       every handler; each play imports it
files/                  release payloads releases.custom_files names

bin/check               make check
bin/check-structure     the five structural checks
bin/docker-suite        the local fleet
docker/                 the local fleet's image, fakes and fixtures
docs/                   from-nothing.md, design.md
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
make check         # syntax, inventories, structure, four offline suites, lint
make docker-test   # the real thing, against six containers
make docker-demo   # the same, building real Magento from GitHub
make docker-down   # afterwards
```

`make check` has five layers:

| Layer | Catches |
|---|---|
| `--syntax-check` × 3 | A bad include path, a malformed task, a bad play key |
| Inventories × 4 | A hosts file where `builder`/`apps`/`admin`/`cron`/`varnish`/`web` don't all resolve. A deploy against a broken one reports "no hosts matched" and exits **0** |
| `bin/check-structure` | A reintroduced `roles:`; a `notify` with no handler; an include path that only resolves at run time; **a parent-path reference**; **a stray `lookup('env', ...)`** |
| `test.yml` | 87 tasks across four suites: the variable contract and the precedence guard, the disk pre-flight, the `bundler_steps` table, the build lock, and the prune against a real temporary filesystem |
| yamllint / ansible-lint | Formatting. A broken tool reads as **SKIP**, never as a failure |

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
environments don't have. Set every one of the thirteen explicitly, even where
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

**Also out:** the database. Nothing here runs a migration, a backup or a
restore. `bin/magento setup:upgrade` is invoked as part of the Magento deploy
step, but taking a snapshot first is your pipeline's job, not this playbook's.

## What this doesn't do

Worth saying plainly, because a deploy tool that is vague about its edges is
how people find out the hard way:

- **No rollback command.** The previous releases are still on disk
  (`teardown_releases_to_keep` keeps two) and the cutover is a symlink flip, so
  rolling back is repointing that symlink and clearing caches. There is no
  `make rollback` that does it for you.
- **No zero-downtime guarantee.** Maintenance mode goes on before the Magento
  deploy and off after it. How long that is depends on your catalogue.
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
- **`ansible-core` 2.13 and Python 3.8.9 are both end of life.** Pinned in
  `requirements.txt` and `.python-version` so the current state is
  reproducible. Flip `deprecation_warnings = True` in `ansible.cfg` before
  attempting the upgrade -- that is when the warnings are the point.
- **`--check` proves little here.** The playbook builds a release on the
  builder and extracts it on the fleet, so a dry run skips the interesting
  half. `make docker-test` is the answer, and
  [docker/README.md](docker/README.md) says what it does and doesn't prove.

## Licence

MIT. See [LICENSE](LICENSE).
