# Rung 2 — real URLs instead of port-forward

> ### ⚠ Not built yet
> The variables exist (`enable_cloudflare`, `domain`, `cf_*`) but the resources behind them
> do not. Setting `enable_cloudflare = true` today changes nothing. This page is the design,
> kept here so the plan is reviewable — it will lose this banner when the code lands.

**You need:** a domain whose nameservers point at Cloudflare. Free.

**You can skip this rung entirely.** Everything from rung 1 keeps working with
`kubectl port-forward`.

---

## What it gets you

`grafana.example.com` works from anywhere, with a login in front of it, **and your box
still has no inbound ports open**.

That last part is the interesting bit. A Cloudflare Tunnel is a connector *inside* the
cluster that dials **outbound** to Cloudflare and holds the connection open. Traffic
arrives at Cloudflare's edge and is handed back down that existing connection. Nothing
listens on the public internet, so there is nothing to port-scan.

```
browser → Cloudflare edge → (tunnel, outbound-established) → cloudflared pod → service
```

Compare with the usual approach — open 443, run an ingress controller, get a certificate,
keep it renewed, and hope nothing else is listening. This is fewer moving parts *and* a
smaller attack surface.

## What gets created

| | |
|---|---|
| `cloudflare_zero_trust_tunnel_cloudflared` | the tunnel |
| `cloudflare_zero_trust_tunnel_cloudflared_config` | hostname → service routing |
| `cloudflare_dns_record` (one per hostname) | CNAME to `<tunnel-id>.cfargotunnel.com`, proxied |
| a `cloudflared` Deployment | in-cluster, taking its token from a Secret |

**`config_src = "cloudflare"` is not the provider default and matters:** it means the
routing above is what the connector obeys. The default (`local`) means a YAML file on the
box, which this design does not have — and changing it later replaces the tunnel and
issues a new token.

## Access: the login in front

Cloudflare Access puts an identity check ahead of the tunnel, so `grafana.example.com`
asks *who you are* before it reaches your cluster at all. Log in with Google or GitHub;
your app never sees an unauthenticated request.

One wildcard application over `*.example.com` covers every hostname at once — simpler than
per-app policies, and it cannot drift out of sync with itself.

> **Pin the identity provider.** If you leave One-Time-PIN enabled account-wide, anyone who
> can receive email at an allowed address can log in. Pin the app to the specific IdP you
> mean.

## Why not just open 443?

You can. You would then own: an ingress controller, cert-manager, a DNS-01 solver, a
renewal that fails silently at 3am, and a listening port. The tunnel replaces all of it
with an outbound connection.

The trade is a dependency on Cloudflare. That is real — which is precisely why this rung is
optional and rung 1 does not need it.

## Next

- Deploy your own app → [rung 3](rung-3-your-app.md)
