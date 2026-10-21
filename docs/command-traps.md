# Magento commands that report success and did not do the job

Found on 2026-09-24 on a private copy of an OSS 2.4.8-p2 snapshot (MariaDB
11.4), closing deploy gaps in this playbook.

- `setup:static-content:deploy -j N` exits 0 when a theme's LESS fails to
  compile. The error is printed, the theme stops short of its files (1864 of
  1963) and `styles-m.css` is missing; without `-j` the same fault exits 1. An
  empty `.less` file does the same under `-j` ("LESS file is empty"). Check the
  output, the progress lines and the compiled files, never the exit code.
- `setup:upgrade` without `--no-interaction` fails when `config.php`'s themes or
  scopes change: its `app:config:import` asks for a yes, gets none, prints
  "Import failed: Aborted." and exits 1. With `--no-interaction` it answers
  every warning yes, including "These Stores will be deleted"
  (`QuestionPerformer\YesNo` returns true when non-interactive). Read the
  importers' `getWarningMessages()` first; that is the only confirmation on the
  `setup:upgrade` path.
- A release that only adds a theme passes both `setup:db:status` and
  `app:config:status` (neither reads the `theme` table), so a gate built on them
  skips `setup:upgrade` and the theme is never registered.
- `setup:db:status` does catch a `setup_version` bump: it runs `OldDbValidator`,
  the same `DbVersionInfo` comparison as the front-controller guard.
- Any `bin/magento` command writes into the shared cache, even `setup:db:status`
  (4 keys). `MAGENTO_DC__OVERRIDE` with a whole `cache` block of file backends
  keeps it out; per-key `MAGENTO_DC_*` overrides never reach the cache factory.
- One `setup:upgrade` recreated 1,014 mview triggers and dropped and rebuilt
  `customer_grid_flat`, none of it shown by `--dry-run`.
