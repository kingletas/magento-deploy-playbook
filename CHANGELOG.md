# Changelog

Entries say what changed for somebody using this, not what the diff did.

## Unreleased

First public release. Everything below is what it contains rather than what
changed, because there's nothing before it.

### Fixed

- A deploy that stops no longer leaves the build lock behind for someone to find. One that stops before anything goes live releases it and records `deploy.failed` with the phase and step. One that stops after the switch in a state a person must see first, a web host lost at the switch or a failed health check left live or in maintenance, keeps it and writes why into it. The lock now says who took it and for which release, and the next deploy is refused with whatever it says. A prune that fails at the end still releases it.
- A failure after the switch no longer ends the run with the lock held and no
  record. When the cache flush, the Varnish ban, `maint:disable` or the indexer
  reset fails, the deploy stops for every host, records `deploy.failed` with
  the step and the error, releases the build lock, and prints the steps left to
  run and whether `make rollback` is still possible. A web host that drops out
  after the switch, or before the cutover begins, now fails the deploy too.
- The deploy now chooses one host to run Magento's commands before anything goes
  live, from `magento_hosts` (the admin group by default), and uses it for every
  one of them. A host that cannot read the database is passed over for the next;
  when none can, the deploy stops with nothing live and the lock released. Before
  this, `setup:upgrade` ran once on every admin host, and an admin host that had
  gone away was found only mid-cutover.
- A release whose `app/etc/config.php` changes its themes or scopes no longer
  fails in the middle of the maintenance window. The configuration import inside
  `setup:upgrade` asks for a yes before it registers them, and with nobody to
  answer it aborted and failed the deploy. `setup:upgrade` now runs with
  `--no-interaction`.
- A release that only adds a theme now gets `setup:upgrade`. Neither
  `setup:db:status` nor `app:config:status` reads the theme table, so both
  passed and the theme was never registered. The upgrade gate now also compares
  the themes the code registers with the ones the database has.
- A release whose `config.php` would delete a website, store, group or theme
  now stops before the cutover until the deletion is accepted by name. The
  configuration import inside `setup:upgrade` warns before deleting, and a
  deploy has nobody to read the warning.
- A `setup:upgrade` that fails after the cutover no longer leaves the build
  lock behind. The site stays in maintenance, `upgrade.failed` is recorded,
  and the run prints how to recover.
- The status commands the deploy runs in the incoming release, before it goes
  live, no longer write that release's configuration into the cache the live
  release is reading. They run with a private file cache, removed afterwards.
  On a Magento too old to allow that they run as before, with a warning.

- Rolling back no longer lands the store in maintenance mode. Maintenance was
  enabled in the release being replaced and disabled only in the new one, so
  every superseded release kept `var/.maintenance.flag`, and repointing the
  symlink at one served the maintenance page. The deploy now removes the flag
  from the release it replaced. Releases replaced before this still carry it;
  run `php bin/magento maint:disable` in one before rolling back to it.
- `setup:upgrade` now runs behind the maintenance page. The page was turned on
  in the release being replaced, and `var` is not shared, so once the symlink
  flipped the new release served customers with no flag while the upgrade ran.
  Maintenance now goes on in the incoming release, before the flip.
- A status command that fails no longer counts as "nothing to do". If
  `setup:db:status` or `app:config:status` exits anything but 0 or 2, the deploy
  stops before the symlink flips.

### Changed

- After the cutover, every app host requests the storefront paths in
  `health.paths` from its own web server, bypassing Varnish. When any fails, the
  release it replaced is put back automatically, provided its code still fits
  the database. A guard decides that before anything moves: the older release's
  own `setup:db:status` must pass against the live database, no data patch may
  have run since it went live, and no NOT NULL column its INSERTs leave out may
  have appeared, nor a unique or foreign key its writes know nothing of. When
  the guard refuses, the live release goes into maintenance,
  because a maintenance page tells a customer to come back and a failing page
  does not, and the deploy stops naming the backup it took.
  `pub/health_check.php` is not used: it never passes through the front
  controller, so it answers 200 on a server refusing every page.
- `make rollback environment=<env>` puts back the release before the live one,
  or `release=<name>`, under the same guard. Each refusal can be overridden only
  by naming exactly what it listed: `rollback_despite_database=true`,
  `rollback_accept_patches=` or `rollback_accept_columns=`. The previous way,
  repointing the symlink by hand, bypasses all of it.
- A build reuses the previous build's compiled code or static content when
  nothing that phase reads has changed. Each phase has a fingerprint over the
  tracked files it reads, the command that runs it and the settings it depends
  on; `build_skip` turns either phase off, and output older than
  `build_skip.max_age_days` is always rebuilt.
- With `lock_forecast.enabled`, a release whose `setup:upgrade` will run is
  rehearsed first. The builder runs its real `setup:upgrade` against a
  throwaway MariaDB of production's version, loaded with production's schema
  and the rows `setup:upgrade` reads, then asks that server how it would run
  each schema statement: instantly, online, or as a table copy that blocks
  writes. Each is sized with production's row counts. A blocking copy over
  `lock_forecast.stop_on_rows` stops the deploy before anything goes live, and so
  does a narrowed column, until `forecast_accept_narrowing` names it. The
  schema dump holds the configuration table, so both copies are deleted when the
  rehearsal ends.

- Every deploy is now recorded in an append-only, hash-chained audit log on the
  control node: nine events per release carrying the commit, the artefact's
  SHA-256, the approver, the backup, and who deployed from where.
  `make audit-verify environment=<env>` re-checks every link, and
  `make evidence environment=<env> release=<id>` writes one release's records,
  its place in the chain, a summary and `SHA256SUMS`. Set `audit.forward` to
  send each record somewhere nobody with access here can rewrite.
- A release is built only if someone other than the deployer signed a tag on its
  commit with a key in `approval.allowed_signers`. Off until you set
  `approval.required`.
- A backup can be required before the cutover. `backup.run` is never, window
  (only when the release takes a maintenance window) or always; the command runs
  on the first admin host and its last line of output is recorded as the backup's
  name. A backup that fails or names nothing stops the deploy with the previous
  release still live.
- The builder records the archive's SHA-256, and every host refuses to unpack an
  archive that does not match it.
- Host key checking is on. Ansible and the builder's rsync both verify the host
  they are talking to, so hosts must be in `known_hosts` before a deploy. The
  Docker suite scans its own containers.
- Tasks that handle a token set `no_log`, so credentials stay out of `-v` output
  and callback plugins.
- A varnish host with no `varnishadm` is refused before the build, rather than
  failing the cutover after the release is already live.
- `bin/check-structure` fails a task that templates a secret without `no_log`, a
  plaintext secret in the committed notification defaults, and anything that
  turns off host key checking.
- New: `docs/compliance.md`, mapping each control to the file that implements it
  and the test that proves it, and saying what it does not cover.

- A release with no database or config work takes no maintenance window. The
  deploy asks the incoming release first and turns maintenance on only when
  either status command exits 2.
- nginx and php-fpm are reloaded after the flip instead of restarted, twice, so
  requests in flight finish. Nothing restarts them after maintenance is off.
- Varnish is no longer restarted. The deploy bans Magento's pages with
  `varnishadm ban obj.http.X-Magento-Tags ~ .`, the same ban Magento's own
  purge sends, so static files and media stay cached. The varnish host needs
  `varnishadm` and the playbook's become user needs to be able to run it.
- The warm-up is configured per environment with one `warmup` setting, which
  replaces `base_url` and `ping_url`. It warms a list of paths and the URLs in
  a sitemap (following an index one level), capped by `limit`, `concurrency` at
  a time, on `base_url`'s host only. It runs as soon as maintenance comes off,
  prints how many URLs answered 2xx and which did not, and fails the run only
  when fewer than `fail_below` percent succeed, after the lock is released. The
  settings are checked before the build starts. The hard-coded `filters.php`
  request is gone.
- Two new deployment events: `cutover.started` before anything changes, with
  whether this release takes a window, and `maintenance.enabled` when it does.

### Added

- `bin/zdt-arm arm3`, the crossing arm of issue #5: two code versions against
  one database with `deployment/blue_green/enabled` on the old servers, first
  across an additive control release (old servers must serve without a guard
  message; passing it alone proves nothing) and then across a release that
  renames or drops a column the old code reads — the evidence. The first
  old-server failure must name the changed object, so failing read bodies are
  saved under the run directory and the verdict greps the chronologically
  first one; an old server answering 200 across a schema it does not match
  fails the falsifier. The breaking change, the read route and the object's
  name come only from you (`ZDT_RELEASE_ADDITIVE/_BREAKING`,
  `ZDT_READ_PATH`, `ZDT_SCHEMA_OBJECT`): a missing one stops arm 3 by name
  rather than guessing an evidence chain. The database is restored between
  the two legs, so the breaking leg starts exactly where the control started.
- `bin/zdt-arm`, the runner for the fleet arms of issue #5. `arm1` runs the
  migration with the blue/green flag off — one shared cache prefix, then a
  prefix per release, traffic on every server; `arm2` runs it again with the
  flag on the old servers; `restore-snapshot` puts a database snapshot back.
  `-n` prints the whole plan — both cache-prefix phases and the snapshot
  restore and relink between them — and runs nothing; without `-y` the arm
  asks about the plan it just printed, never one it did not. The snapshot
  comes before `setup:upgrade` and stops the run when it fails, and so does
  any failed release placement, upgrade or `env.php` edit — a step that
  fails stops the arm instead of letting it report a migration that never
  happened. Every `env.php` is backed up with its contents (the symlink to
  the shared copy is followed, so the backup is the original bytes) and its
  restore command printed. The traffic generator has a hard rate and
  duration cap, asks only routes a stock store serves — name your category
  and product pages in `ZDT_CATEGORY_PATH` / `ZDT_PRODUCT_PATH` — and reads
  a refusal only from a 5xx, no answer, or a guard match. Settings come from
  `ZDT_*` environment variables. See
  [docs/zero-downtime-proofs.md](docs/zero-downtime-proofs.md).
- `bin/zdt-fleet`, the checks the multi-database runs stand on. `replica-check`
  refuses to pass unless the replica is replicating, and records the facts a
  run is judged against as one JSON object; `table-checksums` compares tables
  between the primary and the replica. Settings come from `ZDT_*` environment
  variables. See [docs/zero-downtime-proofs.md](docs/zero-downtime-proofs.md).
- `bin/zdt-proof` runs eight proofs of the assumptions a zero-downtime deploy
  rests on, against a Magento store running under Kapelos: which schema
  mismatches a live release survives, whether two releases sharing a cache read
  each other's configuration, which asset URLs break at the flip, whether a
  php-fpm reload makes the flip take effect, and three more. Each shows the
  failure first and then the fix, and prints one PASS or FAIL line per
  falsifier. Set `KAPELOS_HOME` to your Kapelos checkout; a proof refuses to
  start without it. [docs/zero-downtime-proofs.md](docs/zero-downtime-proofs.md)
  says what each proof claims and every line it prints. `make check` now runs
  the runner's tests and shellcheck.
- Two guards on the inventory, in the playbook rather than in `make`, so they
  apply however it is invoked: an inventory with no hosts in it is refused
  rather than reporting success having deployed nothing, and one still naming
  `inventory/example/`'s `example.com` placeholders is refused with a sentence
  saying what to copy rather than failing at the SSH layer.
- A single playbook, `deployment.yml`, that builds a Magento 2 release on a
  builder host, pushes it to a fleet, deploys Magento onto it, flips the
  `current` symlink and prunes what it replaced.
- A build lock, so two people cannot cut the same environment at once.
  `unlock.yml` clears a stale one.
- Per-environment inventories: an environment is a directory under
  `inventory/`, holding both the hosts and the settings. No shell profile, no
  exported variables, no `lookup('env', ...)`.
- `verify-deploy.yml`, which asserts on the filesystem a deploy left behind
  rather than on whether the deploy reported success.
- A Docker suite: six throwaway containers and a bare fixture repository, so
  the whole deploy can be watched end to end with no servers and no
  credentials. `make docker-test`.
- `make docker-demo`, which runs that same suite against a real Magento Open
  Source clone from GitHub instead of the fixture, so the archive, the rsync
  fan-out and the cutover move a real 435 MB release. `DEMO_REPO` and
  `DEMO_BRANCH` point it at any repository.
- Optional shallow cloning: set `git_depth` to skip history the build doesn't
  need.
- A choice of JavaScript bundler, set with `bundler` in
  `group_vars/all/build.yml`. `manipulus` is the default and needs no browser,
  no Node and no running store; `magepack` is there for stores already using it,
  with an image built by `make magepack-image`; `none` is a real answer while
  you set either up. The run stops with a message naming the fix if the chosen
  bundler isn't on the build host's PATH.
- `extra_build_steps`, for anything else a release needs on the build host.
- PHP 8.0 is the supported floor, asserted before the build steps run, so a
  store still on PHP 7 is told so rather than finding out from whatever breaks
  first.
- Four offline test suites (87 assertions) covering the variable contract and
  its precedence guard, the bundler table, the build lock and the prune.
- Five structural checks over the repository itself: no roles, every `notify`
  resolves, every include resolves, no path above the playbook directory, no
  stray environment lookups.
- ansible-core 2.21 and ansible-lint 26, replacing the 2.13 and 6.8 lines that
  were end of life. Needs Python 3.12 or newer, which `make venv` checks for.
  `deprecation_warnings` is on, because a warning is the only notice you get
  before the next removal.
- `.ordane.yml`, so the playbook works with the Ordane console out of the box.
  Only the throwaway `docker` fleet is launchable, `deploy` is graded dangerous
  and asks for the environment's name, and the targets are grouped. Which
  delivery measures it can source, and which stay dormant for want of a release
  log, are set out in the README.
- `REQUIRE_LINT=1` turns a missing linter into a failure rather than a skip.
  CI sets it, because there a missing linter means the install broke and a
  green run would be a lie.
- DORA instrumentation: a local JSONL event log, with optional Prometheus and
  New Relic sinks.
- Slack, PagerDuty, New Relic, Noibu and Yottaa integrations, wired and off by
  default with placeholder credentials.
