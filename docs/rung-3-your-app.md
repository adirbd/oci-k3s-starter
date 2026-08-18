# Rung 3 — deploy your own app

> ### Status
> The path described here — build to ghcr.io, point Argo at a **public** repo — works
> today. Argo's **private**-repo credentials are configured by hand (the Secret below);
> there is no Terraform for that yet.

**You need:** your app's source, and about ten minutes.

---

## First: you need an image, not source

Kubernetes runs **container images**. It cannot build your code — so somewhere between
`git push` and a running pod, something has to produce an image and put it in a registry.

That is one extra step, and it can be automatic. **The shortest path that stays free:**

```
your code ──push──> GitHub Actions ──builds──> ghcr.io ──Argo/k8s pulls──> running
```

Copy [`examples/build-and-push.yaml`](../examples/build-and-push.yaml) into
`.github/workflows/` **in your app's repo**. It builds your Dockerfile and pushes to GitHub
Container Registry on every push to `main`. There is no registry account to create and no
credential to manage — `GITHUB_TOKEN` is issued to the workflow automatically.

### ⚠ Build for ARM, or nothing will run

Oracle's free tier is **Ampere — ARM, aarch64**. A normal `docker build` on an Intel or
Apple-Silicon-emulating-x86 setup, or on a standard GitHub runner, produces an **amd64**
image. Kubernetes will happily pull it, start it, and fail with:

```
exec /app: exec format error
```

That message says nothing about architecture, and it is the single most common way a first
deploy fails here. The supplied workflow sets `platforms: linux/arm64`, which is the whole
fix.

> If your app repo is **public**, GitHub's native ARM runners (`runs-on: ubuntu-24.04-arm`)
> are free and much faster than emulation. For a **private** repo they are a paid plan, so
> the workflow uses QEMU emulation, which is free everywhere and takes a few minutes.

### Public or private image?

**Start public.** A public image needs no pull secret, and your *code* can stay private
while the built image is public — they are separate settings on GitHub.

If the image must be private, the cluster needs credentials to pull it:

```bash
kubectl create secret docker-registry ghcr \
  --docker-server=ghcr.io \
  --docker-username=YOUR_GITHUB_USER \
  --docker-password=YOUR_PAT \
  -n my-app
```

…and `imagePullSecrets: [{name: ghcr}]` in the pod spec. That PAT is exactly the kind of
credential [rung 4](rung-4-secrets.md) exists to keep off your disk.

### No Dockerfile yet?

Any base image works, as long as it is multi-arch — `node`, `python`, `golang`,
`eclipse-temurin` and most official images all publish arm64. Check with:

```bash
docker manifest inspect node:22-alpine | grep -A2 arm64
```

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

## A worked example

[`examples/my-app.yaml`](../examples/my-app.yaml) is a complete one — Application,
Deployment and Service — with the two things people leave out and regret: a **memory
limit** (one runaway process on a 12 GB box takes down Grafana and Argo with it) and
**probes**, without which Kubernetes cannot tell "started" from "working".

It also pins an image by **SHA rather than `latest`**. Kubernetes cannot tell that a moving
tag changed, so pushing a new `latest` leaves the old pod running and you conclude the
deploy is broken. The build workflow tags every image with its commit SHA for exactly this.

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
