# scripts/

Two kinds of thing live here. **Only the first is for you.**

## For you

| | |
|---|---|
| `preflight.sh` / `.ps1` | check tools, tfvars, OCI session and Cloudflare Access before applying |
| `retry-apply.sh` / `.ps1` | keep asking Oracle for the instance until capacity frees up |
| `connect.sh` / `.ps1` | fetch the kubeconfig and open every UI at once |
| `set-gitops-repo.sh` | point Argo CD at a different repo on a running box |
| `enable-remote-state.sh` | move Terraform state off your laptop into your own OCI bucket |

```bash
./scripts/retry-apply.sh      # when apply says "Out of host capacity"
./scripts/connect.sh          # once it exists
```

`retry-apply.sh` is the one you will need first. "Out of host capacity" is the normal first
answer when asking for a free ARM box, and Oracle offers no queue and no notification — only
asking again. It rotates availability domains (capacity is tracked per-AD), backs off when
throttled, and stops on anything that is not a capacity failure rather than burying it.

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
| `check-image-arch.py` | every image the charts pull has a `linux/arm64` build |
| `check-argocd-manifest.py` | the Argo CD install manifest can actually be applied |
| `check-links.py` | relative links in the docs resolve |

```bash
python3 scripts/check-apps.py
```

`check-apps.py` is the one worth knowing about. A Helm values file is a *request* — Helm
accepts keys it does not recognise and ignores them silently, so the only way to know what
your values did is to render the chart and read the answer. It has already caught two bugs
that every other tool reported as success.
