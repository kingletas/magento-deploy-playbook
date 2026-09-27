#!/usr/bin/env bash
# summary: the outage, second by second: the breaking rollout vs maintenance mode
#
# Arm 4 (issue #5): for each request type (page, cart, REST, GraphQL,
# health_check.php), the share of requests that fails in each second of the
# rollout of the breaking release — and the same rollout behind maintenance
# mode, so the two outages can be compared. Two legs, the database restored
# between them so both start from the exact same state:
#
#   rollout       — no maintenance mode: old servers serve while the
#                   migration runs. What the customer sees when zero
#                   downtime is attempted on a breaking release.
#   maintenance   — a real maintenance deploy: maintenance:enable on every
#                   node before anything moves, the breaking release linked
#                   on every web node under the page, the page down on every
#                   node after setup:upgrade. The outage maintenance mode
#                   buys, same release, same migration.
#
# Falsifier 4 is judged on the two legs' totals: the rollout must fail more
# requests AND for more seconds than maintenance mode, or the claim
# "maintenance mode is the smaller outage" is reported as disproved. The
# per-second, per-type shares — the shape of what the customer sees — go to
# outage-report-<leg>.txt next to the traffic logs.
#
# Like arm 3, the breaking release comes only from you (ZDT_RELEASE_BREAKING
# / ZDT_LABEL_BREAKING): measuring the wrong release's outage answers a
# question nobody asked, so a missing one stops arm 4 by name.
#
# Recording and safety exactly as the other arms: snapshot before the
# upgrade, the replica gate before anything, maintenance re-enabled hosts
# disabled again on every exit path it can reach (and the exact commands
# printed for the paths no trap can reach).

# shellcheck source=/dev/null  # ARM_DIR is set by bin/zdt-arm at run time
source "$ARM_DIR/lib.sh"

# Read by arm_main / require_env in lib.sh as \${ARM_OUTAGE:-0}.
# shellcheck disable=SC2034
ARM_OUTAGE=1
arm_main "$@"
