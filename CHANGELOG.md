# Changelog

Entries say what changed for somebody using this, not what the diff did.

## Unreleased

First public release. Everything below is what it contains rather than what
changed, because there's nothing before it.

### Fixed

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

- A release with no database or config work takes no maintenance window. The
  deploy asks the incoming release first and turns maintenance on only when
  either status command exits 2.
- nginx and php-fpm are reloaded after the flip instead of restarted, twice, so
  requests in flight finish. Nothing restarts them after maintenance is off.
- Varnish is no longer restarted. The deploy bans Magento's pages with
  `varnishadm ban obj.http.X-Magento-Tags ~ .`, the same ban Magento's own
  purge sends, so static files and media stay cached. The varnish host needs
  `varnishadm` and the playbook's become user needs to be able to run it.
- The warm-up ping fires when maintenance comes off, before the prune and the
  lock release, rather than as the very last step.
- Two new deployment events: `cutover.started` before anything changes, with
  whether this release takes a window, and `maintenance.enabled` when it does.

### Added

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
