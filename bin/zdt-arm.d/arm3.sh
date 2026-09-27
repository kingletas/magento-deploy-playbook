#!/usr/bin/env bash
# summary: two code versions, one database, the flag on — across a schema-breaking release
#
# Arm 3 (issue #5): the arm the whole issue turns on. The flag is ON, and two
# releases cross the same database while at least one node stays on the old
# code throughout:
#
#   1. the ADDITIVE control — a release that only adds. Old servers with the
#      flag on must serve pages, REST and GraphQL without a guard message.
#      Passing here proves nothing on its own (the issue says so); a guard
#      message here disproves the flag's claim on the cheapest release.
#   2. the BREAKING evidence — a release that renames or drops a column the
#      old code reads. The first failure on an old server must name that
#      column or table, and the read path must not sail through. A run whose
#      old servers answer 200 across it, or whose first failure names
#      something else, FAILS falsifier 3.
#
# The schema object and the read route are the lab's, never a guess: set
# ZDT_SCHEMA_OBJECT to the renamed/dropped name and ZDT_READ_PATH to a route
# that really reads it. The database is restored between the two crossings so
# the breaking one starts from the same state as the control. Response bodies
# of failing reads and guard matches are saved under the run directory — the
# first failure's own words are the evidence, not a status code.
#
# Recording and safety exactly as arm1: snapshot before the upgrade, dated
# env.php backups before any edit, restore on every reachable exit path, the
# restore commands printed for the paths no trap can reach, the replica gate
# before anything.

# shellcheck source=/dev/null  # ARM_DIR is set by bin/zdt-arm at run time
source "$ARM_DIR/lib.sh"

# Read by arm_main / require_env in lib.sh as \${ARM_CROSSING:-0}.
# shellcheck disable=SC2034
ARM_CROSSING=1
arm_main "$@"
