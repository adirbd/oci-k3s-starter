# Rung 3 — deploy your own app

> ### Status: works today for public repos
> `gitops_repo_url` is wired, so pointing Argo at a **public** repo works now. The
> **private**-repo credential wiring described below is designed but not yet implemented.

**You need:** a Git repo with your Kubernetes manifests.

---

## The model

Argo CD watches one directory. **A file in that directory is an app; deleting the file
retires the app.** There is no list to maintain and no deploy command to run — `git push`
is the deploy button.

```
your-repo/
└── kubernetes/applications/
    ├── my-api.yaml          ← an Argo Application
    └── my-worker.yaml
```

## Public repo — nothing to configure

```hcl
gitops_repo_url  = "https://github.com/you/your-cluster.git"
gitops_repo_path = "kubernetes/applications"
```

> ⚠ Changing these **after** the first apply does nothing on a running box: they are baked
> into cloud-init, which runs once. Edit the live Application instead:
> ```bash
> kubectl -n argocd edit application root
> ```
> This trips everyone once. It is the same property that makes the box reproducible.

## Private repo — App vs token

Argo needs credentials. Two options, and the right answer is not the obvious one.

|  | Personal access token | **GitHub App** |
|---|---|---|
| Tied to | **you** | the repo/org |
| Expiry | 90 days, or never (worse) | 1-hour installation tokens, auto-refreshed |
| If you leave / rotate | everything breaks | keeps working |
| Scope | whatever you granted, often too much | per-repository, read-only if you like |
| Setup | 60 seconds | ~5 minutes |

**Use a GitHub App** for anything you intend to keep. A PAT is fine for an afternoon, and
its real failure mode is not theft — it is the 90-day expiry landing on a day you have
forgotten this exists, or a token that never expires quietly outliving your access.

### The App, briefly

1. GitHub → Settings → Developer settings → **GitHub Apps** → New
2. Permissions: **Repository → Contents: Read-only**. That is all Argo needs.
3. Install it on the one repo.
4. Note the **App ID**, **Installation ID**, and download the private key.
5. Give them to Argo:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: repo-my-cluster
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: repository
stringData:
  type: git
  url: https://github.com/you/your-cluster.git
  githubAppID: "123456"
  githubAppInstallationID: "654321"
  githubAppPrivateKey: |
    -----BEGIN RSA PRIVATE KEY-----
    ...
```

> That key is a real credential. Committing this file to the repo Argo is reading would be
> a closed loop of the wrong kind — see [rung 4](rung-4-secrets.md) for where it should
> actually live.

## A minimal Application

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: my-api
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/you/your-cluster.git
    targetRevision: HEAD
    path: apps/my-api
  destination:
    server: https://kubernetes.default.svc
    namespace: my-api
  syncPolicy:
    automated:
      prune: true      # delete the file, delete the resources
      selfHeal: true   # hand-edit the cluster and it reverts
    syncOptions:
      - CreateNamespace=true
```

`prune` and `selfHeal` are what make Git authoritative rather than advisory. Turn them off
and you have a deploy tool that also lets the cluster drift — the worst of both.

## Next

- Secrets, without secrets on disk → [rung 4](rung-4-secrets.md)
