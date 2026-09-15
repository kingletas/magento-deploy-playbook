# Local end-to-end suite

Runs this playbook against six throwaway containers instead of real servers,
so the deploy path can be exercised without an AWS account, a VPN, or a
maintenance window.

```bash
make docker-test      # up, reset, deploy twice, verify -- the whole thing
make docker-down      # stop and remove everything
```

`docker` is an **ordinary environment of this playbook** -- `inventory/docker/` --
not a special case. Its settings sit in `inventory/docker/group_vars/all.yml`
exactly the way example's do. The only thing unusual about it is that its
`hosts` file is generated, because container IPs aren't knowable until the
containers run.

## Why it exists

`--check` is close to useless for this playbook: it builds a release on the
builder and extracts it on the fleet, so a dry run skips the interesting half.
Before this suite the only way to know the refactor worked was to deploy to
`example` and watch.

## What is real, and what is faked

This is the important table. The suite tests **orchestration**, not Magento.

| Real | Faked |
|---|---|
| SSH to every host, as `ubuntu`, with `become` | `php` -- dispatches to the composer or Magento fake |
| **The builder-to-web rsync push** (`synchronize`, `delegate_to: builder`) | `composer` -- answers the module's `--format=json` option probe, then creates the directories a real install leaves |
| `git clone` / `reset` / `fetch` / `checkout` from a real bare repo | `bin/magento` -- logs the subcommand; `setup:db:status` and `app:config:status` report "up to date"; `maint:enable` and `maint:disable` write and remove `var/.maintenance.flag` |
| Real tar and untar, real file ownership and modes | `manipulus` -- logs the invocation; `docker run`, for the magepack path |
| The `current` symlink flip, and the shared symlinks into an EFS-shaped path | `service` -- sysv shims in `/etc/init.d/` because there's no init system |
| Every assert, gate, `run_once`, `delegate_to` and handler in the playbook | PagerDuty / New Relic / Noibu / Slack -- off via `notify_via_*` |
| The build lock, including refusing a second concurrent build | |
| The prune, including refusing to delete the live release | |
| The full variable contract, resolved from `inventory/docker/` | |

Every fake appends to `/tmp/build-log` in its container, which is what
`verify-deploy.yml` asserts against and what `make docker-logs` prints. That log
is how the suite proves *which* commands ran and *how many times* -- the
`run_once` regression test counts `cache:flush` invocations in it.

## The fleet

Six containers on one bridge network, from one image. They differ only by which
inventory group they land in, which is how a real fleet works too.

```text
builder   ── clones, builds, tars, and rsyncs to the fleet
web1 web2 ── [apps]
admin     ── [admin]   the delegate target for every Magento CLI step
cron      ── [cron]
varnish   ── restarted by its own play
          └─ apps + admin + cron are [web:children]
```

> `inventory/docker/hosts` is **generated** by `bin/docker-suite up`, using
> container **IPs** rather than names. Names only resolve inside the compose
> network, and published host ports don't work either: `synchronize` delegates
> to the builder and pushes to the target's `ansible_host`, so a
> `127.0.0.1:220X` address would point the builder at itself. Container IPs are
> the one address correct from both the control node and the builder -- which is
> what makes the real rsync path testable.
>
> Only `hosts` is generated. `inventory/docker/group_vars/all.yml` beside it is
> tracked and hand-maintained: the settings don't depend on which IPs docker
> handed out.

## Commands

| Command | Does |
|---|---|
| `make docker-up` | Build the image, start the containers, generate the inventory |
| `make docker-deploy` | Run the deploy exactly as a real one runs: `ansible-playbook -i inventory/docker deployment.yml`, from this directory |
| `make docker-verify` | Assert on what the deploy left behind |
| `make docker-test` | All three, deploying twice so there is a replaced release to verify |
| `make docker-reset` | Clear locks and releases so a run can be repeated |
| `make docker-logs` | Print each container's fake-tool call log |
| `make docker-down` | Stop and remove |
| `bin/docker-suite shell admin` | Get a shell in a container |

`bin/docker-suite deploy` is three lines -- `cd` to the playbook directory and
run `ansible-playbook -i inventory/docker deployment.yml` -- because that is the
whole of how a deploy works. There's no wrapper chain to exercise.

## Configuration

`inventory/docker/group_vars/all.yml`, which is an ordinary environment file --
the same shape as `inventory/example/group_vars/all.yml`, with fixture values.

Three values are fixtures rather than production-shaped:

- `archive_min_bytes: 1024` -- the fixture release is a few KB, so the 10 MB
  floor asserted by `tasks/packaging/archive.yml` has to come down. 1 KB still
  catches an empty tarball, which is what the assert is for. This is per
  environment precisely so this can differ.
- `git_repo: /srv/magento-repo.git` -- the bare fixture repo, bind-mounted
  read-only. No network egress, no credentials.
- `notify_via_slack: false` -- see below.

`deployment_complete: true` is set because without it `releases.complete` is
false and the symlink is never repointed -- the deploy runs green but nothing goes
live. That's a real footgun rather than a suite quirk, which is why
`tasks/release-preflight.yml` now asserts the key is defined at all.

### Slack really is off now

This file used to claim Slack was "off via `notify_via_*`". It wasn't.
`notify_via_slack` was `true` playbook-side and `SLACK_TOKEN` was empty, so every
suite run called the Slack module and `failed_when: false` swallowed the failure.
`notify_via_slack` is per-environment now and `false` here; the handler reports
`skipping:` on all six containers.

## The fixture repo

`fixtures/magento/` is a minimal Magento-shaped tree -- `bin/magento`,
`app/etc/`, `pub/`, `composer.json`. `fixtures/build-repo.sh` turns it into a
bare repo with two commits on `develop`, because `tasks/packaging/git.yml` does
a real `clone`, `reset --hard`, `fetch --prune` and `checkout`, and builds a
changelog from a commit range. A tarball wouldn't do.

Rebuild it with `docker/fixtures/build-repo.sh develop`.

## Testing the other branch of the upgrade gate

By default both status commands report "up to date", so `setup:upgrade` is
correctly skipped and `verify-deploy.yml` asserts that. To exercise the other
side:

```bash
docker exec -e MAGENTO_FAKE_NEEDS_UPGRADE=1 mdp-admin true
```

That env var has to be set on the container rather than passed per-command, so
in practice add it to the `admin` service in `docker-compose.yml` and recreate.

## What this doesn't cover

- **Real Magento.** No database, no indexers, no static content. A release that
  extracts and symlinks correctly here could still be broken Magento.
- **Scale and timing.** Two app nodes on one host say nothing about a 5-node
  rsync fan-out or a realistic maintenance window.
- **Anything the fakes paper over.** `composer install` never resolves a
  dependency; the bundler never bundles anything.

Treat a green suite as "the orchestration is sound", not "this release is
deployable".

## Things the suite found the first time it ran

Kept as a record, because each one is a real defect in something that looked
fine:

1. **A repo-relative SSH key path broke under the `cd`.** The inventory had
   `ansible_ssh_private_key_file=docker/keys/id_test`, resolved against the
   playbook directory rather than the repo root, and every host went unreachable.
   It is absolute now, generated by `bin/docker-suite`. Still relevant after the
   restructure: Ansible is invoked from the playbook directory because that is
   where `ansible.cfg` is, so a path relative to the inventory *file* isn't the
   same thing as a path relative to the working directory.
2. **`IdentitiesOnly=yes` is mandatory.** Without it `ssh` offers every key in
   the operator's agent, and six containers at the default `MaxAuthTries` reject
   the connection before the right key is tried.
3. **The builder genuinely runs as `ubuntu`.** `/var/www/html` owned by
   `www-data` made the clone fail with "Permission denied". A `become_user`
   without a `become` beside it doesn't switch user -- it reads as though it
   does, and the task simply runs as the login user.
4. **The `composer` module shells out as `php composer ...`.** It runs
   `composer help install --format=json` first and parses the result to discover
   options. A `php` fake that blindly forwarded to the Magento fake made it die
   in `from_json`.
5. **`--working-dir` is passed space-separated,** not `--working-dir=`. The fake
   parsed only the `=` form and silently created its directories in `$HOME`.
6. **Failure-proof logging hid a real problem.** After `reset` deleted
   `/tmp/build-log`, the first writer owned it and every other user's entries
   were silently dropped -- because the fakes suppress logging errors on purpose.
   `reset` now truncates instead of removing.
