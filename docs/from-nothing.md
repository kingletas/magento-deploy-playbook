# From nothing to a deploy you can watch

This gets you from a fresh clone to a full Magento release deploy running in
front of you, on six containers, with no servers and no credentials. Then it
shows you what to change to point it at real hosts.

Everything here has been run from a clean checkout. If a step doesn't do what
it says, that's a bug -- please open an issue.

## Contents

- [What you need](#what-you-need)
- [1. Install](#1-install)
- [2. Check the install](#2-check-the-install)
- [3. Watch a real deploy](#3-watch-a-real-deploy)
- [4. Look at what it did](#4-look-at-what-it-did)
- [5. Point it at your own hosts](#5-point-it-at-your-own-hosts)
- [When something goes wrong](#when-something-goes-wrong)

## What you need

- Python 3.8 or newer
- Docker, for step 3 only
- Around 2 GB of disk for the container images

You don't need a Magento installation, a database, any credentials, or a
server. Steps 1, 2 and 4 don't need Docker either.

## 1. Install

```bash
git clone https://github.com/kingletas/magento-deploy-playbook.git
cd magento-deploy-playbook
make venv
make collections
```

`make venv` builds a Python virtualenv in `venv/` from the pinned
`requirements.txt`. `make collections` installs the two Ansible collections the
playbook uses: `community.general` for the Slack and PagerDuty modules, and
`ansible.posix` for the rsync push that moves a release from the builder to the
web hosts.

The Makefile prefers `venv/bin/ansible-playbook` when it exists and falls back
to whatever is on your `PATH`, so a system-wide Ansible works too.

## 2. Check the install

```bash
make check
```

This is everything that can be verified without contacting a host, and it takes
a few seconds. It runs a syntax check over all three playbooks, parses every
inventory and asserts the host groups resolve, runs five structural checks over
the repository itself, runs four offline test suites (around 87 tasks), and
lints.

You should see it finish without a failure. A `SKIP` next to yamllint or
ansible-lint means the tool isn't installed, which is fine.

If this passes, the playbook is correctly installed. Nothing has been
contacted, and nothing has been changed.

## 3. Watch a real deploy

```bash
make docker-test
```

The first run takes a few minutes because it builds the container image.

What happens: six containers come up -- a builder, two app nodes, an admin
host, a cron host and varnish -- on their own docker network, with SSH between
them and a throwaway key. A bare git repository holding a tiny fake Magento
tree is bind-mounted into the builder as the release source. Then the real
playbook runs against them, exactly as it would against real servers:

1. **Preflight.** Resolves the release name, checks every host has room.
2. **Lock.** Takes a build lock on the builder so a second run cannot start.
3. **Build.** Clones the repo, checks out the branch, generates a changelog,
   compiles and deploys static content, bundles the JavaScript, tars the result.
4. **Upload.** rsyncs the tarball to every web host.
5. **Maintenance mode**, then extract, link the shared directories, copy the
   custom payloads.
6. **Deploy.** Runs the Magento deploy steps, flips the `current` symlink.
7. **Prune.** Removes old releases and archives, keeping the live one.
8. **Unlock**, and a warm-up ping.

Nothing is stubbed at the Ansible layer. Every assert, every `run_once`, every
`delegate_to` and every handler runs for real. What is faked is inside the
containers: `php`, `composer` and `bin/magento` are scripts that record what
they were asked to do. [docker/README.md](../docker/README.md) is the full list
of what is real and what isn't.

## 4. Look at what it did

```bash
make verify environment=docker
```

This asserts on the filesystem the deploy left behind, rather than on whether
the deploy reported success -- which are different claims. It checks the
release is where it should be, `current` points at it, `bin/magento` is present
and executable, `app/etc/env.php` is a symlink rather than a baked-in copy, the
custom payloads landed, and the admin-only steps ran once rather than once per
web host.

To look around by hand:

```bash
./bin/docker-suite shell web1
ls -la /var/www/html/
```

## 4b. Do it again with real Magento

```bash
make docker-demo
```

Same six containers, same playbook, but the release is a shallow clone of
Magento Open Source from GitHub instead of the fixture -- so the tarball, the
rsync out to five hosts and the cutover all move a real 435 MB release. The
repository is public, so there's nothing to authenticate.

```bash
make docker-demo DEMO_REPO=https://github.com/you/store.git DEMO_BRANCH=main
```

points it at yours instead. Then:

```bash
./bin/docker-suite shell web1
readlink -f /var/www/html/magento_current    # what is live
cat /var/www/html/magento_current/pub/summary.txt
```

That last file is the changelog the build generated. After a shallow clone it
says the changelog was unavailable, because `git log base...branch` has no
merge base to work from -- the step is written to fall back rather than fail a
release over a reporting string. Drop `git_depth` and you get a real one.

When you're done:

```bash
make docker-down
```

## 5. Point it at your own hosts

```bash
cp -r inventory/example inventory/staging
```

`inventory/example/` is a template, not a working environment: its hosts are
under `example.com`, which RFC 2606 reserves so it can never name a real
machine. The playbook refuses to run while those names are still in place, and
says what to do instead -- so the mistake costs you a sentence rather than
seven SSH failures.

Then edit two files.

**`inventory/staging/hosts`** -- your host names, in the same groups. The group
names aren't free-form: the handlers loop over `groups.apps + groups.admin`
and `groups.cron + groups.admin`, so an inventory that renames one breaks at
handler time. `builder` and `varnish` sit outside `web` on purpose.

**`inventory/staging/group_vars/all.yml`** -- the thirteen keys. Every comment
in that file explains what its key decides. The three that catch people:

- `deployment_complete` -- when false the deploy runs green and never flips the
  symlink. Useful deliberately, miserable by accident.
- `suffix` -- names the release directory and scopes the prune. Keep it unique
  per environment, or one environment's prune will match another's releases.
- `php_version` -- must be 8.0 or above. The build asserts it against
  `php_minimum_version` before it runs anything.

**Decide about bundling.** `bundler` in `group_vars/all/build.yml` is
`manipulus` by default, and both bundlers need one-time setup inside your store
before they work. Set it to `none` for your first deploy and come back to it --
an unbundled storefront is slower, not broken, and README.md has the detail.

Then:

```bash
make check                          # catches a missing or invented key
make deploy environment=staging EXTRA='--check -vv'
make deploy environment=staging
```

Or without `make`, which is the same thing:

```bash
ansible-playbook -i inventory/staging deployment.yml
```

The hosts need SSH access from wherever you run this, a user that can `become`,
and Python 3 installed. `ansible_user` is set in the inventory; everything else
(address, key, jump host) comes from your own SSH config.

`--check` is close to useless for this playbook, because it builds a release on
the builder and extracts it on the fleet -- a dry run skips the interesting
half. It will catch an unreachable host and a syntax problem, and that is about
it. `make docker-test` is the real rehearsal.

## When something goes wrong

**"This inventory still has the template's placeholder hosts in it".** You are
running against `inventory/example/`, which is the thing you copy rather than
the thing you deploy. Copy it and edit the copy.

**"no hosts matched" and it exits 0.** The inventory parsed but the groups did
not resolve. `make check` catches this; run it.

**The run stops saying a lock file exists.** A previous run died without
releasing it. `make unlock environment=<name>`.

**Tasks fail with "Unable to change directory".** `deployment_complete` is
false, so `current` was never repointed and the tasks that `chdir` into it have
nowhere to go.

**The build stops saying a bundler isn't on the build host's PATH.** Install
it, point `<bundler>_command` at a `docker run` invocation, or set
`bundler: none` in `group_vars/all/build.yml` until you have it set up. Nothing
has left the builder at that point.

**The build stops saying PHP is below the floor.** This playbook supports 8.0
and up. Set `php_version` in your inventory.

**A notification didn't arrive.** Check the `notify_via_*` gate first, not the
credential. An empty token with the gate on still calls the module on every
run, and the failure is swallowed -- so the run looks clean and nothing is
delivered. The "Report which notifications landed" task says which of them
actually went out.
