# kubernetes/

What Argo CD deploys. **A file in `applications/` is an app; deleting the file retires it.**

Terraform installs k3s and Argo CD, then applies one root Application pointing here with
`directory.recurse: true`. From that moment Git is in charge and nothing else installs
anything — two sources of truth is how a cluster starts disagreeing with its own
description.

```
applications/
├── infra-observability.yaml   VictoriaMetrics + Grafana
├── app-homepage.yaml          one page listing everything
└── app-sample.yaml            podinfo — proof it works, delete when done
```

## Reaching them at rung 1

There is no ingress controller yet (k3s ships Traefik; cloud-init disables it, because one
you are not using is memory you cannot spend on your app). Use port-forward:

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

For a private repo you need credentials — see [../docs/rung-3-your-app.md](../docs/rung-3-your-app.md).
