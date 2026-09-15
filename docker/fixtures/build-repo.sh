#!/bin/bash
# Turn fixtures/magento into a bare git repo the builder can clone.
#
# tasks/packaging/git.yml does `git clean -fd app`, `git reset --hard`,
# `git fetch --prune` and `git checkout -f <branch>`, so this has to be a real
# repo with a real branch -- not a tarball.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="${HERE}/.repo-build"
BARE="${HERE}/magento-repo.git"
BRANCH="${1:-develop}"

rm -rf "${WORK}" "${BARE}"
cp -r "${HERE}/magento" "${WORK}"
cd "${WORK}"
git init -q -b "${BRANCH}"
git -c user.email=suite@local -c user.name=Suite add -A
git -c user.email=suite@local -c user.name=Suite commit -q -m "fixture: initial Magento tree"
# A second commit so `git log base...branch` has a range to describe -- the
# changelog step in git.yml builds one.
printf 'fixture change\n' >> pub/index.php
git -c user.email=suite@local -c user.name=Suite commit -q -am "fixture: a second commit"
git clone -q --bare . "${BARE}"
cd "${HERE}" && rm -rf "${WORK}"
echo "bare repo: ${BARE} (branch ${BRANCH})"
