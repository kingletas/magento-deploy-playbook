# Contributing

Thanks for looking.

## The gate

```bash
make check
```

That's everything verifiable without touching a host: syntax, every inventory,
five structural checks, six offline suites and lint. It takes seconds.

```bash
make docker-test
```

That's the real rehearsal -- the whole deploy, end to end, against six
throwaway containers. `--check` proves little here, because the playbook builds
a release on one host and extracts it on others, so a dry run skips the
interesting half. Run it before anything that touches the deploy path.

## What a change should look like

- One concern per pull request, with the reasoning in the description.
- `make check` green.
- A test that fails before your change and passes after it. **One direction
  isn't a test**: something that fires isn't evidence it can be quiet, and
  something quiet isn't evidence it can fire. The suites are in `tests/`.
- If you add a variable that varies by environment, it goes in
  `inventory/<env>/group_vars/all.yml` and **nowhere** under `group_vars/`.
  `tests/test-vars-contract.yml` will fail you if it appears in both, and
  [docs/design.md](docs/design.md) explains why that matters.
- An entry in `CHANGELOG.md` under a new heading, saying what changed for
  somebody using this rather than what the diff did.
- Comments say what the code does or what it guards against, in a sentence or
  two. History belongs in the commit message and the changelog.

## Security

Don't open a public issue for a vulnerability.
[SECURITY.md](SECURITY.md) has the reporting route.
