# kubernetes/

What Argo CD deploys. **A file in `applications/` is an app; deleting the file retires it.**

Terraform installs k3s and Argo CD, then applies one root Application pointing here with
`directory.recurse: true`. From that moment Git is in charge and nothing else installs
anything — two sources of truth is how a cluster starts disagreeing with its own
description.

```
applications/                  deployed automatically
├── infra-observability.yaml   VictoriaMetrics + Grafana
├── infra-dashboard.yaml       the one dashboard worth opening
├── app-homepage.yaml          one page listing everything
└── app-sample.yaml            podinfo — proof it works, delete when done (and take the
                               "Your apps" group in app-homepage.yaml with it — an empty
                               group crashes the whole dashboard, #30)

optional/                      NOT deployed — copy into applications/ when you want them
├── app-cloudflared.yaml       the tunnel connector          (rung 2)
├── app-external-secrets.yaml  reads secrets from OCI Vault  (rung 4)
└── app-traefik.yaml           ingress, only if you are NOT using Cloudflare
```

## Reaching them at rung 1

There is no ingress controller by default (k3s ships Traefik; cloud-init disables it,
because one you are not using is memory you cannot spend on your app). At rung 2 the
Cloudflare Tunnel makes one unnecessary; if you are going without Cloudflare, add it back
with `optional/app-traefik.yaml` — see
[../docs/without-cloudflare.md](../docs/without-cloudflare.md).

Meanwhile, use port-forward — or `../scripts/connect.sh`, which does all four at once:

```bash
kubectl -n argocd    port-forward svc/argocd-server 8080:443    # https://localhost:8080
kubectl -n observability port-forward svc/vm-stack-grafana 3001:80   # http://localhost:3001
kubectl -n homepage  port-forward svc/homepage 3000:3000        # http://localhost:3000
kubectl -n sample    port-forward svc/sample-podinfo 9898:9898  # http://localhost:9898
```

Rung 2 replaces all of that with real hostnames.

## Two traps these files are shaped around

**Dashboards are ON unless individually turned off.** There is no "disable all, then enable
these". `infra-observability.yaml` therefore lists mostly `false` — turning three on prunes
nothing. The final answer appears only in the sync job's rendered config, so verify with
`helm template` rather than by reading your own values file.

**Homepage's `layout` must be a LIST, not a map.** Helm's `toYaml` sorts map keys
alphabetically, so a map is silently reordered on render and your file stops describing the
page. Both shapes are accepted by Homepage; only the list survives Helm.

## Adding your own

Copy `app-sample.yaml`, change the source, commit. Argo picks it up within a few minutes,
or immediately if you hit Refresh in the UI.

> ⚠ **Committing only does something once Argo is watching YOUR repo.** Out of the box
> `gitops_repo_url` points at this project, so a push lands somewhere Argo is not looking
> and nothing happens — with no error to explain it. Point it at your own repo first
> ([rung 3](../docs/rung-3-your-app.md)), or apply a file directly while you experiment:
>
> ```bash
> kubectl apply -f kubernetes/optional/app-traefik.yaml
> ```
>
> Argo manages the app either way; only the source of truth differs.
