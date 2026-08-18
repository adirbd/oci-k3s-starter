#!/usr/bin/env python3
"""Render every Argo Application's chart with its own values, and assert what comes out.

WHY THIS EXISTS. On 2026-08-18 this repo shipped a values file that set four dashboard
keys. Two did not exist in the chart at all, and the two that did pruned nothing — eleven
dashboards stayed enabled. Nothing complained: Helm accepts unknown values keys and
ignores them silently, so kubectl, helm lint and Argo all reported success.

A values file is a REQUEST. The only way to know what it did is to render the chart and
read the answer.

  1. RENDER       — the chart renders at all with these values
  2. NAME LENGTH  — no rendered name exceeds Kubernetes' 63-character limit
  3. ASSERTIONS   — per-app facts about the OUTPUT, listed below

⚠ A NOTE ON THE CHECK THAT IS NOT HERE. The obvious idea — flag values keys that do not
appear in the chart's own values.yaml — was tried and removed: it is wrong often enough to
be useless. Charts ship empty maps (`resources: {}`), so every sub-key looks unknown;
subchart values (Grafana's, here) never appear in the parent's values.yaml at all; and
`image.tag` is legitimately absent because it defaults to appVersion. It produced 17
findings, 17 of them false. Asserting on the rendered output is slower to write and
actually true.

Usage:  scripts/check-apps.py [dirs...]  (defaults to kubernetes/applications + optional)
"""
import subprocess
import sys
import glob
import yaml

MAX_NAME = 63  # DNS-1035 labels (Services) and pod volume names


def sh(*args):
    return subprocess.run(args, capture_output=True, text=True)


# ── Per-app assertions ────────────────────────────────────────────────────────────
# Each takes the list of rendered objects and returns a list of failure strings.

def assert_vm_stack(docs):
    problems = []

    cfg = next((d for d in docs if d["kind"] == "ConfigMap"
                and "sync-job" in d["metadata"]["name"]), None)
    if cfg is None:
        return ["expected a sync-job ConfigMap; the dashboard set could not be verified"]

    dash = yaml.safe_load(cfg["data"]["config.yaml"])["dashboards"]["dashboards"]
    enabled = sorted(k for k, v in dash.items() if (v or {}).get("enabled") is not False)

    # THE REGRESSION GUARD. Adding a dashboard is fine — but it has to be deliberate,
    # because the default is ON and the failure mode is a Grafana full of empty panels
    # for components k3s does not run.
    expected = ["node-exporter-full", "victoriametrics-single-node", "victoriametrics-vmagent"]
    if enabled != expected:
        problems.append(
            f"dashboards enabled changed: expected {expected}, got {enabled}. "
            "Every dashboard is ON unless individually disabled — if you added one on "
            "purpose, update this assertion."
        )

    # Alerting is off by design; an Alertmanager with no receiver drops messages silently.
    for kind in ("VMAlert", "VMAlertmanager"):
        found = [d["metadata"]["name"] for d in docs if d["kind"] == kind]
        if found:
            problems.append(f"{kind} rendered ({found}) but alerting is meant to be off")

    return problems


def assert_homepage(docs):
    problems = []
    for cm in (d for d in docs if d["kind"] == "ConfigMap"):
        settings = (cm.get("data") or {}).get("settings.yaml")
        if not settings:
            continue
        layout = yaml.safe_load(settings).get("layout")
        # Helm's toYaml SORTS MAP KEYS. A map here is silently reordered on render and the
        # file stops describing the page. Only a list survives.
        if not isinstance(layout, list):
            problems.append(
                f"settings.yaml layout rendered as {type(layout).__name__}, expected list — "
                "a map is alphabetised by Helm and your ordering is lost"
            )
    return problems


ASSERTIONS = {
    "vm-stack": assert_vm_stack,
    "homepage": assert_homepage,
}


def main() -> int:
    # Both directories: kubernetes/optional holds apps that are not deployed by default
    # (the tunnel connector), and "not deployed yet" is no reason to ship it unrendered.
    targets = sys.argv[1:] or ["kubernetes/applications", "kubernetes/optional"]
    failures = 0

    paths = [p for t in targets for p in sorted(glob.glob(f"{t}/*.yaml"))]
    for path in paths:
        app = yaml.safe_load(open(path, encoding="utf-8"))
        if app.get("kind") != "Application":
            continue

        src = app["spec"]["source"]
        chart, repo, ver = src.get("chart"), src["repoURL"], src.get("targetRevision")
        name = app["metadata"]["name"]

        if not chart:
            print(f"  skip {name}: not a Helm source")
            continue

        values = src.get("helm", {}).get("values", "")
        alias = f"ci-{chart}"
        sh("helm", "repo", "add", alias, repo)
        sh("helm", "repo", "update", alias)

        with open("/tmp/ci-values.yaml", "w", encoding="utf-8") as fh:
            fh.write(values)

        r = sh("helm", "template", name, f"{alias}/{chart}", "--version", ver,
               "-f", "/tmp/ci-values.yaml", "--include-crds=false")
        if r.returncode != 0:
            print(f"  FAIL {name}: chart did not render\n{r.stderr[-800:]}")
            failures += 1
            continue

        docs = [d for d in yaml.safe_load_all(r.stdout) if d]
        problems = [
            f"name over {MAX_NAME} chars: {d['kind']}/{d['metadata']['name']}"
            for d in docs
            if len(d.get("metadata", {}).get("name", "")) > MAX_NAME
        ]
        if name in ASSERTIONS:
            problems += ASSERTIONS[name](docs)

        if problems:
            failures += 1
            print(f"  FAIL {name} ({chart} {ver})")
            for p in problems:
                print(f"        {p}")
        else:
            checked = " + assertions" if name in ASSERTIONS else ""
            print(f"  OK   {name} ({chart} {ver}) — {len(docs)} objects{checked}")

    print("FAILED" if failures else "OK", f"— {failures} application(s) with problems")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
