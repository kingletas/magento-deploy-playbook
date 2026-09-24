#!/usr/bin/env python3
"""Checks that setup:static-content:deploy did the job, instead of trusting its
exit code.

    static-verify.py --root DIR --sentinels JSON [--since EPOCH] < deploy-output

With parallel jobs (-j), a theme whose LESS fails to compile stops part way,
the error goes to the output, and the command still exits 0: the failure
happens in a child process whose status the parent does not pass on. The
theme is then shipped without its stylesheets. So three things are checked:

  1. the output carries none of the messages Magento prints on a failure
  2. every theme and locale the output reports reached all of its files: the
     last progress line for each must read N/N
  3. the files named in --sentinels exist, are not empty and, with --since,
     were written by this deploy, for every theme and locale deployed.
     --sentinels is JSON: {"frontend": [...], "adminhtml": [...]}, each a list
     of alternatives, each alternative a list of paths under
     pub/static/<area>/<vendor>/<theme>/<locale>/. A theme passes when every
     path of any one alternative is there, so a Luma-shaped and a Hyva-shaped
     theme can both pass one setting

Prints what it found as JSON and exits 1 when any check fails.
"""
import argparse
import json
import os
import re
import sys

FAILURE_SIGNATURES = (
    "Error happened during deploy process",
    "ParseError",
    "Compilation from source",
    "Fatal error:",
    "Exception:",
)
ESCAPE = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")
PROGRESS = re.compile(r"^\s*((?:frontend|adminhtml)/[^\s/]+/[^\s/]+/[A-Za-z]{2,3}(?:_[A-Za-z]{2,4})*)\s+(\d+)/(\d+)", re.MULTILINE)


def main():
    parser = argparse.ArgumentParser(description="Check a static content deploy did the job.")
    parser.add_argument("--root", required=True, help="the release root")
    parser.add_argument("--sentinels", required=True, help='JSON: {"frontend": [[...], ...], "adminhtml": [[...]]}')
    parser.add_argument("--since", type=float, default=0, help="the deploy's start, as a Unix time")
    args = parser.parse_args()
    sentinels = json.loads(args.sentinels)

    output = ESCAPE.sub("", sys.stdin.read()).replace("\r", "\n")
    signatures = sorted({s for s in FAILURE_SIGNATURES if s in output})

    last = {}
    for target, done, total in PROGRESS.findall(output):
        last[target] = (int(done), int(total))
    incomplete = [f"{t} stopped at {d}/{n}" for t, (d, n) in sorted(last.items()) if d < n]

    def fresh(path):
        return (os.path.isfile(path) and os.path.getsize(path) > 0
                and os.path.getmtime(path) >= args.since)

    missing = []
    for target in sorted(last):
        area = target.split("/", 1)[0]
        alternatives = sentinels.get(area, [])
        # A flat list of paths is one alternative.
        if alternatives and all(isinstance(a, str) for a in alternatives):
            alternatives = [alternatives]
        if not alternatives:
            continue
        base = os.path.join(args.root, "pub", "static", target)
        if not any(all(fresh(os.path.join(base, p)) for p in paths) for paths in alternatives):
            missing.append(f"{target}/(" + " or ".join("+".join(paths) for paths in alternatives) + ")")
    if not os.path.isfile(os.path.join(args.root, "pub", "static", "deployed_version.txt")):
        missing.append("deployed_version.txt")

    problems = []
    if not last:
        problems.append("the output reports no theme at all, so nothing can be checked")
    if signatures:
        problems.append("the output carries failure messages: " + ", ".join(signatures))
    if incomplete:
        problems.append("themes that did not finish: " + "; ".join(incomplete))
    if missing:
        problems.append("files missing, empty or older than this deploy: " + ", ".join(missing))

    print(json.dumps({"themes": sorted(last), "signatures": signatures, "incomplete": incomplete,
                      "missing": missing, "problems": problems}))
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
