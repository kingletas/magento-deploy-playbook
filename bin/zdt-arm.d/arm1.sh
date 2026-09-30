#!/usr/bin/env bash
# summary: the migration with the flag off, shared then per-release cache prefixes
#
# Arm 1 (issue #5): the migration with deployment/blue_green/enabled OFF on
# every server, first with one shared cache prefix and then with a prefix per
# release, with traffic on every server throughout. The migration is driven
# end to end on the admin node: a snapshot first (no snapshot, no run), then
# setup:upgrade against the primary, while at least one node stays on the old
# code and the always-new node carries the new release.
#
# What it records: falsifier 5 from HAProxy's stats (the health check never
# takes a refusing server out of rotation), falsifier 1 from the replica
# after the migration (live, lag back to zero within five minutes, checksums
# of the touched tables match), and the guard-message counts as facts for the
# results document. The arm claims no PASS for falsifiers 2-4: those belong
# to arms 3 and 4 and to Commerce runs.
#
# Falsifier 2 on Open Source and Mage-OS is a control expected to pass —
# nothing on these editions reads the replica (a db/slave_connection declared
# in env.php is accepted and never read; routing reads to a replica is Adobe
# Commerce's ResourceConnections). Say so in the results document.
#
# Changes: nothing outside what the plan prints, and it restores env.php on
# every exit path it can reach (dated backups plus printed restore commands
# cover the paths it cannot).

# shellcheck source=/dev/null  # ARM_DIR is set by bin/zdt-arm at run time
source "$ARM_DIR/lib.sh"

arm_main "$@"
