# Build a Magento 2 release and deploy it to a fleet.
#
# The deploy targets are shortcuts for an ansible-playbook invocation you can
# type yourself, and each recipe echoes the command it runs:
#
#   ansible-playbook -i inventory/<env> deployment.yml
#   ansible-playbook -i inventory/<env> verify-deploy.yml
#   ansible-playbook -i inventory/<env> unlock.yml
#
# `environment=` names a directory under inventory/, which holds both the hosts
# file and the settings. The rest of the targets are the virtualenv, the
# collections, the gate and the six-container suite.
#
#   make help          list every target and every environment
#   make check         everything verifiable without contacting a host
#   make docker-test   the whole deploy, end to end, six containers, no servers
#
# NOTE make runs recipes from THIS directory, which is what makes ansible.cfg
# apply -- Ansible resolves it from the working directory, never from the
# playbook's location. Nothing here may reference a path above this directory;
# bin/check-structure fails the build if anything does.

MAKEFLAGS += --no-print-directory

# Prefer a virtualenv in this directory, otherwise whatever is on PATH.
VENV   := venv
ifneq ($(wildcard $(VENV)/bin/ansible-playbook),)
  ANSIBLE_PLAYBOOK := $(VENV)/bin/ansible-playbook
  ANSIBLE_GALAXY   := $(VENV)/bin/ansible-galaxy
else
  ANSIBLE_PLAYBOOK := ansible-playbook
  ANSIBLE_GALAXY   := ansible-galaxy
endif

# The interpreter the virtualenv is built from. Must be 3.12 or newer.
PYTHON ?= python3

# Extra ansible-playbook arguments, e.g. make deploy EXTRA='--check -vv'
EXTRA ?=

# Optional per-run overrides. Both are ordinary --extra-var, which outranks
# everything in group_vars, so they work without the inventory knowing.
#
#   branch_name=      build a different branch than the environment's default.
#                     Does NOT change `suffix`.
#   release_name=     reuse an existing release instead of building a new one.
override_vars :=
ifdef branch_name
  override_vars += branch_name='$(branch_name)'
endif
ifdef release_name
  override_vars += release_name_override='$(release_name)'
endif
ifneq ($(strip $(override_vars)),)
  EXTRA_VARS := --extra-var "$(override_vars)"
else
  EXTRA_VARS :=
endif

environments := $(notdir $(patsubst %/,%,$(wildcard inventory/*/)))

.PHONY: help check lint venv collections test deploy verify unlock magepack-image \
        docker-up docker-test docker-demo docker-deploy docker-verify docker-reset \
        docker-logs docker-down

.DEFAULT_GOAL := help

## help: list every target and every environment
help:
	@echo "The playbook is the interface:"
	@echo "  ansible-playbook -i inventory/<env> deployment.yml"
	@echo ""
	@echo "Or through make, which adds the venv and a check that <env> exists:"
	@echo "  make <target> environment=<env> [branch_name=...] [release_name=...]"
	@echo ""
	@echo "Environments (a directory under inventory/):"
	@for e in $(environments); do \
		if [ -f "inventory/$$e/hosts" ]; then echo "  $$e"; \
		else echo "  $$e  (no hosts file -- generated; run make docker-up)"; fi; \
	done
	@echo ""
	@echo "Targets:"
	@grep -hE '^## ' $(MAKEFILE_LIST) | sed -e 's/^## /  /' | sort
	@echo ""
	@echo "Try it with no servers: make docker-test"

# One message in one place for a missing or misspelled environment. The playbook
# carries its own guards for an empty or template inventory, so a direct
# ansible-playbook run is protected too.
define require_environment
	@test -n "$(environment)" || { \
		echo "ERROR: environment= is required."; \
		echo "       Run: make $@ environment=<env>"; \
		echo "       Known: $(environments)"; exit 1; }
	@test -d "inventory/$(environment)" || { \
		echo "ERROR: no inventory/$(environment)/ directory."; \
		echo "       Known: $(environments)"; exit 1; }
	@test -f "inventory/$(environment)/hosts" || { \
		echo "ERROR: inventory/$(environment)/hosts does not exist."; \
		echo "       For the docker environment it is generated: make docker-up"; \
		exit 1; }
	@test -f "inventory/$(environment)/group_vars/all.yml" || { \
		echo "ERROR: inventory/$(environment)/group_vars/all.yml does not exist."; \
		echo "       An environment without it inherits nothing and will fail in"; \
		echo "       release-preflight. Copy another environment's file."; exit 1; }
endef

## deploy: build and deploy in one shot (needs environment=)
deploy:
	$(require_environment)
	$(ANSIBLE_PLAYBOOK) -i inventory/$(environment) deployment.yml $(EXTRA_VARS) $(EXTRA)

## verify: assert on what a deploy left behind (needs environment=)
verify:
	$(require_environment)
	$(ANSIBLE_PLAYBOOK) -i inventory/$(environment) verify-deploy.yml $(EXTRA_VARS) $(EXTRA)

## unlock: remove a stale build lock left by a hard-failed deploy (needs environment=)
unlock:
	$(require_environment)
	$(ANSIBLE_PLAYBOOK) -i inventory/$(environment) unlock.yml $(EXTRA)

## check: everything verifiable without contacting a host
check:
	@bin/check

## test: run the six offline suites only (what check runs as its third layer)
test:
	$(ANSIBLE_PLAYBOOK) -i inventory/test test.yml $(EXTRA)

## lint: yamllint + ansible-lint
lint:
	@yamllint --version >/dev/null 2>&1 \
		|| { echo "yamllint is missing or broken. Run: make venv"; exit 1; }
	yamllint -c .yamllint .
	@ansible-lint --version >/dev/null 2>&1 && ansible-lint \
		|| echo "ansible-lint not installed or not working, skipped"

## venv: build the python virtualenv from requirements.txt
venv:
	@$(PYTHON) -c 'import sys; sys.exit(0 if sys.version_info >= (3, 12) else 1)' || { \
		echo "ERROR: $(PYTHON) is $$($(PYTHON) -V 2>&1), and ansible-core 2.20 and"; \
		echo "       later need 3.12 or newer. pip on an older one resolves an"; \
		echo "       ansible-core from 2023 instead of refusing."; \
		echo "       Run: make venv PYTHON=python3.12"; exit 1; }
	@rm -rf $(VENV)
	$(PYTHON) -m venv $(VENV)
	$(VENV)/bin/pip install --upgrade pip
	$(VENV)/bin/pip install -r requirements.txt
	@echo "Now run: make collections"

## collections: install the Ansible collections this playbook imports
collections:
	$(ANSIBLE_GALAXY) collection install -r requirements.yml

## magepack-image: build the optional magepack bundler image (see group_vars/all/build.yml)
magepack-image:
	docker build -t $(shell sed -n 's/^magepack_image: *//p' group_vars/all/build.yml) docker/magepack

include docker.mk
