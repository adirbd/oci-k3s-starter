# scripts/

Two kinds of thing live here. **Only the first is for you.**

## For you

| | |
|---|---|
| `connect.sh` | fetch the kubeconfig and open every UI at once — macOS, Linux, WSL, Git Bash |
| `connect.ps1` | the same, for Windows PowerShell |

```bash
./scripts/connect.sh          # or ./scripts/connect.ps1
```

It writes `kubeconfig` into the repo root (gitignored), prints the Argo CD password, and
holds four port-forwards open until you press Ctrl-C. Until rung 2 gives you real
hostnames, this is how you reach anything.

## For CI

These run on every push and are also runnable locally, which is the point — a check you
cannot run before pushing is a check that wastes your time.

| | |
|---|---|
| `check-apps.py` | renders every Argo Application's chart and asserts facts about the output |
| `check-dup-keys.py` | duplicate YAML keys, including inside embedded Helm values |
| `check-links.py` | relative links in the docs resolve |

```bash
python3 scripts/check-apps.py
```

`check-apps.py` is the one worth knowing about. A Helm values file is a *request* — Helm
accepts keys it does not recognise and ignores them silently, so the only way to know what
your values did is to render the chart and read the answer. It has already caught two bugs
that every other tool reported as success.
