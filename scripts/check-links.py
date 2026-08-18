#!/usr/bin/env python3
"""Fail on relative markdown links that do not resolve.

The docs ARE the product in a starter repo — a 404 on the first link someone clicks is
worse than a missing page, because it says the repo is not maintained. External URLs are
not checked: they fail for reasons that have nothing to do with this repo, and a CI job
that goes red when someone else's site is down gets ignored.
"""
import os
import re
import subprocess
import sys

LINK = re.compile(r"\]\(([^)]+)\)")


def main() -> int:
    files = [f for f in subprocess.run(["git", "ls-files"], capture_output=True, text=True)
             .stdout.split() if f.endswith(".md")]
    bad = []
    for path in files:
        for link in LINK.findall(open(path, encoding="utf-8").read()):
            if link.startswith(("http://", "https://", "mailto:", "#")):
                continue
            target = os.path.normpath(os.path.join(os.path.dirname(path), link.split("#")[0]))
            if not os.path.exists(target):
                bad.append(f"{path} -> {link}")
    for b in bad:
        print(f"  FAIL broken link: {b}")
    print(f"{'FAILED' if bad else 'OK'}: {len(files)} markdown files, {len(bad)} broken link(s)")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
