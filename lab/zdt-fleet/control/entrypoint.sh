#!/usr/bin/env bash
# Installs the fleet's ssh key for zdt, then waits: the arms run in this
# container through docker compose exec, as zdt.
set -euo pipefail

install -o zdt -g zdt -m 600 /run/zdtfleet/id_ed25519 /home/zdt/.ssh/id_ed25519
exec sleep infinity
