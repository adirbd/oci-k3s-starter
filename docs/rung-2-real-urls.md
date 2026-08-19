# Rung 2 — real URLs instead of port-forward

**You need:** a domain, with its nameservers pointed at Cloudflare.

**This is the only part of this repo that costs money** — roughly **$10 a year** for the
domain. Cloudflare's plan, the tunnel, the certificate, Access, the DDoS protection and the
CDN are all free; you are paying a registrar for a name, not paying Cloudflare.

> **Bought it through Cloudflare?** Then the nameservers are already pointed and there is
> nothing to do — skip to step 1.
>
> Cloudflare Registrar sells at wholesale with no markup (about $10-11/yr for a `.com` at
> the time of writing; registrar prices drift), and
> other TLDs go cheaper — a `.xyz` or `.dev` is often a few dollars. Any registrar works;
> you just point the nameservers at Cloudflare afterwards.

**You can skip this rung entirely.** Everything from rung 1 keeps working with
`kubectl port-forward` — and if you want your app public *without* buying a domain, there
is a third way: [serving it without Cloudflare](without-cloudflare.md), which opens 80/443
and runs Traefik. You give up the free certificate and the login; the doc is blunt about
what that costs.

---

## Why it is worth ten dollars

Nine reasons, and the first one is the one people underestimate.

### 1. A valid HTTPS certificate, forever, with no work

Not "encrypted" — **valid**, as in no browser warning and a real padlock. This matters more
than it sounds, because **modern browsers refuse to run large parts of the web platform on
an insecure origin**: service workers, WebAuthn/passkeys, the clipboard API, camera and
microphone, geolocation, PWA installation, and HTTP/2 all require HTTPS.

Without it you are not merely seeing a warning — you are developing against a browser with
features switched off, and debugging why your app behaves differently on your laptop than
in production.

The alternative is running cert-manager, solving a DNS-01 challenge, and owning a renewal
that fails silently at 3am. Here the certificate is Cloudflare's problem and always has
been.

### 2. Nothing is listening on the internet

The connector dials **out**. Your security list keeps exactly one inbound rule, for SSH.
There is no web port to scan, no ingress controller to have a CVE, and no "I'll just open
443 for a minute".

### 3. Your server's IP is never published

Traffic reaches Cloudflare, not you. An attacker who wants to hit your box directly has to
find it first, and DNS will not tell them. Origin-IP exposure is how most "I was behind
Cloudflare and still got attacked" stories start.

### 4. A login in front of everything, that you did not write

Cloudflare Access checks identity **before** the request reaches your cluster. Grafana ships
`admin/admin`; Argo CD holds credentials to your infrastructure. Neither should be answering
strangers, and writing your own auth layer for internal tools is a bad use of a weekend.

Adding a collaborator is adding their email address. There are no user accounts on your box
to create, rotate or forget to remove.

### 5. It works from networks you do not control

Corporate wifi, hotel wifi, mobile carriers behind CGNAT, and any network blocking
non-standard ports — all fine, because it is ordinary HTTPS to an ordinary hostname. A
`kubectl port-forward` needs the API server reachable; this does not.

### 6. Your box's IP can change and nothing breaks

The instance has an *ephemeral* public address. The DNS records point at the tunnel, not at
an IP, so a rebuild costs you nothing. Without this you are maintaining dynamic DNS.

### 7. DDoS, WAF and bot protection, at no cost

Absorbed at the edge before it reaches a box that has two cores. Also: your Grafana will not
be crawled and indexed, which is a surprisingly common way people discover their dashboards
were public.

### 8. URLs you can actually share

`grafana.example.com` opens on your phone, on someone else's laptop, in a message to a
friend. `localhost:3001` opens nowhere, and a shared demo is most of the point of running
something publicly at all.

### 9. It is less machinery, not more

Opening 443 the traditional way means an ingress controller, a certificate issuer, an ACME
solver, a renewal cron, and a listening port — five things that can break. The tunnel is one
deployment that dials out.

> **No domain, want to try it anyway?** `cloudflared tunnel --url http://localhost:3000`
> gives you a random `*.trycloudflare.com` address with no account and no domain. It is
> ephemeral and has no Access in front of it, so treat it as a demo rather than a setup —
> but it costs nothing and shows you the shape of the thing.

---

## What it gets you

`grafana.example.com` works from anywhere, with a login in front of it, **and your box
opens no web ports at all** — the only inbound rule stays SSH.

That last part is the interesting bit. A Cloudflare Tunnel is a connector *inside* the
cluster that dials **outbound** to Cloudflare and holds the connection open. Traffic
arrives at Cloudflare's edge and is handed back down that existing connection.

```mermaid
flowchart LR
    B["browser"] --> CF["Cloudflare edge<br/>TLS + Access login"]
    CF -. "back down a connection<br/>the cluster opened" .-> CFD
    subgraph BOX["your box · no web ports open"]
        CFD["cloudflared pod"] --> S["Service<br/>Grafana, Argo, Homepage"]
    end
    CFD -- "dials OUT" --> CF
    style BOX fill:#f6f8fa,stroke:#2ea043
```

The connector dials **out** and holds the connection open. Requests arrive at Cloudflare
and come back down it — so nothing is listening on the public internet.

Your security list still has exactly one inbound rule, for SSH. There is no web port to
scan, and nothing serving HTTP that could have a CVE.

Note there is **no ingress controller** in that path. The tunnel terminates the request and
hands it straight to a Kubernetes Service, so k3s's Traefik stays disabled and you save
both the memory and the certificate machinery.

## 1. Get three values from Cloudflare

| | where |
|---|---|
| **Account ID** | dashboard → right-hand sidebar |
| **Zone ID** | same sidebar, with your domain selected |
| **API token** | My Profile → API Tokens → Create |

The token needs:

- **Zone → DNS → Edit**
- **Account → Cloudflare Tunnel → Edit**
- **Account → Access: Apps and Policies → Edit** (only if you want the login)

## 2. Turn it on

```hcl
# terraform.tfvars
enable_cloudflare = true
domain            = "example.com"
cf_account_id     = "..."
cf_zone_id        = "..."

# ⚠ Without this, your hostnames are PUBLIC.
access_allowed_emails = ["you@example.com"]
```

```bash
export TF_VAR_cf_api_token=...    # keep it out of the file
tofu apply
```
```powershell
$env:TF_VAR_cf_api_token = "..."
tofu apply
```

That creates the tunnel, its routing, a proxied CNAME per hostname, and — if you listed
emails — a Cloudflare Access application in front of each one.

## 3. Give the connector its token

```bash
tofu output -raw cloudflared_secret_command   # then run what it prints
```

It creates the namespace and the Secret in one go, piping the token from Terraform
straight into `kubectl`. The token never lands in a file or your shell history.

## 4. Deploy the connector

It ships in `kubernetes/optional/`, which Argo does **not** watch — otherwise every rung-1
user would get a CrashLooping pod for a tunnel they never set up.

```bash
kubectl apply -f kubernetes/optional/app-cloudflared.yaml
```

That works immediately and needs no fork — Argo CD manages the app from the moment the
object exists, whoever created it.

**The durable way** is to have Argo read it from Git, which needs the repo Argo watches to
be *yours* — that is [rung 3](rung-3-your-app.md). Once it is:

```bash
cp kubernetes/optional/app-cloudflared.yaml kubernetes/applications/
git commit -am "enable the tunnel" && git push
```

> ⚠ Do not run the second form before rung 3. Out of the box `gitops_repo_url` points at
> **this** project, so a push goes somewhere Argo is not watching — or fails outright — and
> the symptom is simply nothing happening.

Argo picks it up within a few minutes. Then:

```bash
kubectl -n cloudflared get pods          # two, both Running
tofu output urls
```

---

## Two things that will bite you

### Homepage rejects its own hostname

Homepage validates the `Host` header against an allowlist. The default in
`app-homepage.yaml` only knows about `localhost`, so through the tunnel every request
fails with a bare **"Host validation"** error and the page never renders — with nothing to
say a config key is missing.

Add your hostname:

```yaml
env:
  - name: HOMEPAGE_ALLOWED_HOSTS
    value: localhost:3000,home.example.com
```

### Argo CD and the redirect loop

`argocd-server` serves HTTPS with a **self-signed** certificate and 301-redirects plain
HTTP to HTTPS. So:

- route it over HTTP → infinite redirect loop
- route it over HTTPS → certificate verification fails

`tunnel_routes` therefore sends Argo over HTTPS with `no_tls_verify = true`. The
alternative is patching `argocd-cmd-params-cm` to set `server.insecure=true`; this repo
prefers leaving Argo exactly as upstream ships it, since the unverified hop is pod-to-pod
inside a single node.

## What Access actually does

It puts an identity check **ahead of** your cluster: `grafana.example.com` asks who you are
before the request reaches the tunnel at all. Your app never sees an unauthenticated
request.

Three settings here came from a real outage rather than a preference:

- **`session_duration = "168h"`** — when a session expires mid-use, Access redirects the
  in-flight XHR to its login page. A browser cannot report that as "your session expired";
  it reports a **CORS error**. Every app appears broken at once, and nothing says why.
- **`options_preflight_bypass`** — OPTIONS preflights carry no cookies, so Access treats
  them as unauthenticated and swallows them into the login redirect. Guaranteed CORS
  failure on any non-simple request.
- **`http_only_cookie_attribute`** — the session cookie should not be readable by page JS.

> **Pin your identity provider.** If One-Time-PIN is enabled account-wide, anyone who can
> receive mail at an allowed address can log in. Fine for you; think about it before adding
> a whole domain to the allowlist.

## Rolling back

Set `enable_cloudflare = false` and apply — the tunnel, DNS records and Access apps are all
removed. Delete `kubernetes/applications/app-cloudflared.yaml` and Argo prunes the
connector. You are back at rung 1 with nothing left behind.

## Next

- Deploy your own app → [rung 3](rung-3-your-app.md)
