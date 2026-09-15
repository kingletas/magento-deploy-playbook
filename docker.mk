# The local environment, which is also the end-to-end test harness.
#
# `docker` is an ordinary environment of this playbook. Only its hosts file is
# different: container IPs are not knowable until the containers run, so it is
# generated. See docker/README.md.
#
# Named docker.mk, not Makefile.docker: `*.docker` is a common unanchored rule
# in a global excludes file, and the old name was silently left out of a commit.

# Real Magento Open Source, public, no credentials. Point it at your own with
# `make docker-demo DEMO_REPO=... DEMO_BRANCH=...`.
DEMO_REPO   ?= https://github.com/magento/magento2.git
DEMO_BRANCH ?= 2.4-develop

## docker-up: build and start the fake fleet (six containers) and write its hosts file
docker-up:
	@bin/docker-suite up

## docker-test: full local end-to-end run -- up, reset, deploy, verify
docker-test:
	@bin/docker-suite test

## docker-demo: the same run, but building REAL Magento cloned from GitHub
# The archive, the rsync fan-out and the cutover all move a real release rather
# than the few-KB fixture. Shallow on purpose, so the changelog step has no merge
# base and falls back to a message saying so.
docker-demo:
	@bin/docker-suite up
	@bin/docker-suite reset
	@bin/docker-suite deploy -e git_repo='$(DEMO_REPO)' -e branch_name='$(DEMO_BRANCH)' -e git_depth=1
	@bin/docker-suite verify
	@echo ""
	@echo "Deployed $(DEMO_REPO) ($(DEMO_BRANCH)) to six containers."
	@echo "Look around:  bin/docker-suite shell web1"
	@echo "Tear down:    make docker-down"

## docker-deploy: run the deploy playbook against the fake fleet
docker-deploy:
	@bin/docker-suite deploy

## docker-verify: assert on what the last docker deploy produced
docker-verify:
	@bin/docker-suite verify

## docker-reset: clear locks and releases so a docker run can be repeated
docker-reset:
	@bin/docker-suite reset

## docker-logs: show what the fake tools were asked to do, per container
docker-logs:
	@bin/docker-suite logs

## docker-down: stop and remove the fake fleet
docker-down:
	@bin/docker-suite down
