#!/usr/bin/env python3
"""Fail on duplicate YAML keys — including inside embedded Helm values blocks.

PyYAML silently keeps the LAST of a duplicated key, so a file with two `resources:`
blocks parses fine, deploys fine, and quietly ignores half of what you wrote. Nothing
else in the toolchain complains: kubectl, Helm and Argo all behave the same way.

Usage:  scripts/check-dup-keys.py [paths...]     (defaults to kubernetes/)
"""
import sys
import glob
import yaml


class DupLoader(yaml.SafeLoader):
    pass


def _no_dups(loader, node, deep=False):
    seen, dups = set(), []
    for key_node, _ in node.value:
        key = loader.construct_object(key_node, deep=deep)
        if key in seen:
            dups.append(key)
        seen.add(key)
    if dups:
        line = node.start_mark.line + 1
        raise ValueError(f"duplicate key(s) {dups} in mapping starting at line {line}")
    return yaml.SafeLoader.construct_mapping(loader, node, deep)


DupLoader.add_constructor(yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, _no_dups)


def check(path: str) -> list[str]:
    problems = []
    text = open(path, encoding="utf-8").read()
    try:
        docs = list(yaml.load_all(text, DupLoader))
    except ValueError as e:
        return [f"{path}: {e}"]
    except yaml.YAMLError as e:
        return [f"{path}: not valid YAML: {e}"]

    # The bit everything else misses: Argo Applications carry a whole Helm values
    # document as a STRING. Duplicates in there are invisible to any YAML linter
    # pointed at the file, because to YAML it is one scalar.
    for doc in docs:
        if not isinstance(doc, dict):
            continue
        values = (
            doc.get("spec", {})
            .get("source", {})
            .get("helm", {})
            .get("values")
        )
        if values:
            try:
                yaml.load(values, DupLoader)
            except ValueError as e:
                problems.append(f"{path}: in embedded helm values: {e}")
            except yaml.YAMLError as e:
                problems.append(f"{path}: embedded helm values not valid YAML: {e}")
    return problems


def main() -> int:
    targets = sys.argv[1:] or ["kubernetes"]
    files = []
    for t in targets:
        files.extend(glob.glob(f"{t}/**/*.yaml", recursive=True) if "*" not in t else glob.glob(t))
        if t.endswith((".yaml", ".yml")):
            files.append(t)
    files = sorted(set(f for f in files if f.endswith((".yaml", ".yml"))))

    problems = []
    for f in files:
        problems += check(f)

    for p in problems:
        print(f"  FAIL {p}")
    embedded = sum(1 for f in files if "helm" in open(f, encoding="utf-8").read())
    print(f"{'FAILED' if problems else 'OK'}: {len(files)} files "
          f"({embedded} with embedded helm values), {len(problems)} problem(s)")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
