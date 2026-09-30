#!/usr/bin/env bash
# summary: arm 1 again, with deployment/blue_green/enabled on the old servers
#
# Arm 2 (issue #5): the same migration, the same two cache-prefix phases and
# the same traffic, with deployment/blue_green/enabled set in the env.php of
# every server that stays on the old code (the always-new node keeps it off:
# it is on the new code and its setup_version matches). The flag is what the
# issue says silences DbStatusValidator and ConfigChangeDetector on the old
# servers; this arm is where that claim meets a real migration.
#
# Recording and safety exactly as arm1.sh: snapshot before the upgrade, dated
# env.php backups before any edit, restore on every reachable exit path, the
# restore commands printed for the paths no trap can reach.

# shellcheck source=/dev/null  # ARM_DIR is set by bin/zdt-arm at run time
source "$ARM_DIR/lib.sh"

# Read by arm_main in lib.sh as \${ARM_BLUE_GREEN:-0}.
# shellcheck disable=SC2034
ARM_BLUE_GREEN=1
arm_main "$@"
