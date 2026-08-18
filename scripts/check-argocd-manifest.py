#!/usr/bin/env python3
"""Check that the Argo CD install manifest can actually be applied.

WHY THIS EXISTS. cloud-init installs Argo CD with `kubectl apply -f install.yaml`. Two of
Argo's CRDs are enormous — applications.argoproj.io ~406 KB, applicationsets.argoproj.io
~1.39 MB — and a client-side apply stores the whole object in a `last-applied-configuration`
ANNOTATION, which Kubernetes caps at 262144 bytes. The apply fails with

    metadata.annotations: Too long: must have at most 262144 bytes

`set -e` then aborts the bootstrap, the timer retries every 15 minutes, and it fails the
same way forever. The box is up, SSH works, the cluster answers — and Argo CD is not there.

Nothing else in CI can see this: no job runs kubectl, so the bug is invisible until someone
boots a real machine. This asserts the property instead: IF any object in the manifest is
over the limit, the bootstrap MUST be using --server-side.

Usage:  scripts/check-argocd-manifest.py
"""
import re
import sys
import urllib.request
from pathlib import Path

LIMIT = 262144  # metadata.annotations total, in bytes


def main() -> int:
    cloud_init = Path("terraform/cloud-init.yaml").read_text(encoding="utf-8")
    variables = Path("terraform/variables.tf").read_text(encoding="utf-8")

    m = re.search(r'variable "argocd_version".*?default\s*=\s*"([^"]+)"', variables, re.S)
    if not m:
        print("  FAIL could not find argocd_version's default in terraform/variables.tf")
        return 1
    version = m.group(1)

    url = f"https://raw.githubusercontent.com/argoproj/argo-cd/{version}/manifests/install.yaml"
    print(f"  checking {version} ...")
    try:
        raw = urllib.request.urlopen(url, timeout=60).read()
    except Exception as e:  # network flake should not fail the build
        print(f"  SKIP could not fetch the manifest ({e})")
        return 0

    oversized = []
    for doc in raw.split(b"\n---\n"):
        if not doc.strip() or len(doc) <= LIMIT:
            continue
        name = re.search(rb"^\s+name:\s*(\S+)", doc, re.M)
        oversized.append((name.group(1).decode() if name else "<unknown>", len(doc)))

    uses_ssa = "apply --server-side" in cloud_init

    for name, size in oversized:
        print(f"    {name}: {size} bytes — over the {LIMIT} client-side limit")

    if oversized and not uses_ssa:
        print(f"  FAIL {len(oversized)} object(s) exceed the annotation limit, but cloud-init "
              f"applies client-side. Add --server-side, or the bootstrap fails on a real boot.")
        return 1

    if oversized:
        print(f"  OK   {len(oversized)} oversized object(s), and cloud-init uses --server-side")
    else:
        print(f"  OK   nothing exceeds {LIMIT} bytes")
    return 0


if __name__ == "__main__":
    sys.exit(main())
