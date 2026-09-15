# Why this playbook is shaped the way it is

Four decisions that aren't obvious from reading the tasks, each one made
because the alternative failed quietly.

## Contents

- [No roles](#no-roles)
- [An environment is a directory](#an-environment-is-a-directory)
- [Configuration never comes from the process environment](#configuration-never-comes-from-the-process-environment)
- [Every silent failure got an assertion](#every-silent-failure-got-an-assertion)

## No roles

The packaging, upload and Magento-deploy steps are plain task files under
`tasks/`, not galaxy roles.

A role is the right answer when it is genuinely reusable and versioned. A
deployment role for one application is usually neither: it ends up carrying the
site's own paths and conventions, so nobody else can use it, and it lives in a
second repository where a change is invisible to the playbook that depends on
it.

The concrete failure was worse than that. Three roles were pinned by SHA in
`requirements.yml`, installed once years earlier from a branch, then hand-edited
in place. `ansible-galaxy install` skips a role that is already present, so
those edits survived every install and existed in no repository anywhere.

A fresh clone got the pinned code, which was a different program. It was missing
an entire build step, so the first deploy from a clean machine would have failed
on a file that was never there.

**Anything a deploy depends on is in the repository the deploy lives in.** The
whole of what runs is here, and `bin/check-structure` fails on a reintroduced
`roles:` key, because an installed role with the same name would silently run a
second copy of logic that is already inlined.

## An environment is a directory

```text
inventory/staging/hosts                  which hosts, in which groups
inventory/staging/group_vars/all.yml     every value that varies
```

`make deploy environment=staging` takes the directory name. There is nothing
else: no profile to source, no submodule, no exported variables.

`inventory/example/` is the template those are copied from. Its hosts are under
`example.com`, which RFC 2606 reserves, and `tasks/template-guard.yml` refuses
a run that still names them -- so the mistake reads as a sentence rather than
as a fleet of SSH failures.

### The precedence trap this exists to close

Ansible's group_vars precedence, low to high:

| # | Source | Here |
|---|---|---|
| 3 | inventory `group_vars/all` | `inventory/<env>/group_vars/all.yml` |
| 5 | playbook `group_vars/all` | `group_vars/all/` |
| 6 | inventory `group_vars/<group>` | unused |
| 7 | playbook `group_vars/<group>` | unused |

**The playbook side is higher.** A key declared on both sides resolves to the
playbook's value on every environment, and the inventory's value is discarded
with no warning. Add a well-meant default playbook-side and every environment
breaks at once, invisibly -- each one still *looks* configured.

So any key that varies by environment lives only in the inventory, and never
under `group_vars/`.

That isn't left to discipline. `tests/test-vars-contract.yml` compares the two
sets of **files** and fails naming the offending key. It has to compare files:
by the time a value resolves, one side has already won and the loser leaves no
trace, so no amount of inspecting resolved variables can find the collision.

Structural values that don't vary stay playbook-side and reference the
inventory scalars, so the dict lives in one place rather than four:

```yaml
# group_vars/all/releases.yml
releases:
  path: "{{ site.base }}releases/"        # same everywhere
  complete: "{{ deployment_complete }}"   # the inventory decides
  kill_php: "{{ kill_php }}"              # the inventory decides
```

## Configuration never comes from the process environment

No `lookup('env', ...)` for anything that configures a deploy.
`bin/check-structure` fails on a reintroduced one; `USER` and `HOME` are the
only two allowed, and they describe the operator rather than the environment.

Two reasons, both learned from a chain of shell wrappers that did exactly this.

**`lookup('env', X)` on an unset name returns an empty string, not undefined.**
So `| default('8.3')` never fires. A forgotten export produces `''`, which
flows onward and interpolates into whatever reads it. A New Relic application
name had shipped for months as `app-prod-;app-web;app-prod` because one name
in the middle of it had never been set anywhere.

**Sourcing a file doesn't export what it assigns.** A profile that says
`GIT_REPO=...` without `export`, sourced by a wrapper script, sets a shell
variable that Ansible cannot see. In the case this is drawn from, what actually
made those values visible was an `export $(shell sed -n ... )` line in the
Makefile -- so running the wrapper directly, outside `make`, got empty values
for every one of them, including the git remote. A deploy would have cloned
from nothing.

Both failures are silent, and both stop existing once the values live in a
file Ansible reads itself.

## Every silent failure got an assertion

The pattern throughout: where a step can do nothing and still report success,
there's a check in front of it that says so.

| Check | The silent failure it replaced |
|---|---|
| `deployment_complete` asserted **defined** | Absent meant the symlink was never flipped. The deploy ran green and nothing went live. Asserted `is defined`, not truthy -- `false` is a legitimate value |
| `suffix` asserted non-empty | An empty suffix widened the prune's scope to other environments' releases |
| Disk space, before anything is created | A host filling up mid-extraction left a partial release, the fleet in a mixed state and the site in maintenance mode |
| Archive size floor | An empty tarball uploads and extracts perfectly |
| `bin/magento` exists after extraction | Repointing `current` at a directory that isn't a release |
| Build lock, acquired once | Two people building the same environment at the same time |
| Inventory groups resolve | A deploy against a broken inventory prints "no hosts matched" and exits **0** |
| Notifier gates asserted off in committed defaults | A notifier left on points at whatever account its credentials belong to |

The maintenance-mode step is the one worth singling out, because it is the
shape of the whole problem. It used to be a handler triggered by `notify` on a
`stat` task -- and **a `stat` never reports changed**, so the handler never
fired and a deploy ran against a live site with no maintenance page. Nothing
errored. It's a plain task now.
