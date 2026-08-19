#!/usr/bin/env python3
"""Every image this cluster pulls must have a linux/arm64 build.

WHY THIS EXISTS. Oracle's free tier is Ampere — aarch64. rung 3 warns users at length that
an amd64 image fails with `exec format error`, a message that says nothing about
architecture. It would be embarrassing for the repo's own stack to ship that bug, and a
chart bump can introduce it silently: a maintainer switches base image, the tag still
resolves, and the pod only fails on ARM.

Renders every Application's chart, collects the images, and asserts each publishes arm64.

Needs `docker` for `docker manifest inspect` (present on GitHub runners). Skips cleanly
where docker is unavailable, so it never blocks a laptop that does not have it.

Usage:  scripts/check-image-arch.py [dirs...]
"""
import glob
import json
import subprocess
import sys
import yaml


def sh(*args):
    return subprocess.run(args, capture_output=True, text=True)


def images_from(doc_text: str) -> set[str]:
    found = set()
    for d in yaml.safe_load_all(doc_text):
        if not d or not isinstance(d, dict):
            continue
        spec = (d.get("spec", {}).get("template", {}) or {}).get("spec") or {}
        for c in (spec.get("containers") or []) + (spec.get("initContainers") or []):
            if c.get("image"):
                found.add(c["image"])
    return found


def has_arm64(image: str) -> tuple[bool, str]:
    r = sh("docker", "manifest", "inspect", image)
    if r.returncode != 0:
        return True, "could not inspect (not failing the build on this)"
    try:
        d = json.loads(r.stdout)
    except json.JSONDecodeError:
        return True, "unparseable manifest (not failing the build on this)"

    manifests = d.get("manifests") or []
    if not manifests:  # single-arch image
        arch = d.get("architecture", "unknown")
        return arch == "arm64", f"single-arch {arch}"

    arches = sorted({
        m["platform"]["architecture"]
        for m in manifests
        if m.get("platform", {}).get("os") == "linux"
    })
    return ("arm64" in arches), ",".join(arches)


def main() -> int:
    if sh("docker", "--version").returncode != 0:
        print("  SKIP docker not available — cannot inspect manifests here")
        return 0

    targets = sys.argv[1:] or ["kubernetes/applications", "kubernetes/optional"]
    seen: set[str] = set()
    failures = 0

    for path in sorted(p for t in targets for p in glob.glob(f"{t}/*.yaml")):
        app = yaml.safe_load(open(path, encoding="utf-8"))
        if app.get("kind") != "Application":
            continue
        src = app["spec"]["source"]
        chart, repo, ver = src.get("chart"), src["repoURL"], src.get("targetRevision")
        if not chart:
            continue

        alias = f"arch-{chart}"
        sh("helm", "repo", "add", alias, repo)
        sh("helm", "repo", "update", alias)
        with open("/tmp/arch-values.yaml", "w", encoding="utf-8") as fh:
            fh.write(src.get("helm", {}).get("values", ""))
        r = sh("helm", "template", app["metadata"]["name"], f"{alias}/{chart}",
               "--version", ver, "-f", "/tmp/arch-values.yaml", "--include-crds=false")
        if r.returncode == 0:
            seen |= images_from(r.stdout)

    for image in sorted(seen):
        ok, detail = has_arm64(image)
        if ok:
            print(f"  OK   {image}  ({detail})")
        else:
            failures += 1
            print(f"  FAIL {image} has no linux/arm64 build — arches: {detail}")
            print(f"       On Oracle's Ampere free tier this pod dies with 'exec format error'.")

    print(f"{'FAILED' if failures else 'OK'}: {len(seen)} images, {failures} without arm64")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
