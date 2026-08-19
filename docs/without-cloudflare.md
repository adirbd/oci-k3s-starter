# Serving your app without Cloudflare

**You need:** nothing extra. No domain, no account.

You give up the valid certificate, the login, and the closed ports. That trade is the whole
reason [rung 2](rung-2-real-urls.md) exists — but this path is legitimate, it is how servers
have always worked, and if you just want your app on the internet today it is the shortest
route.

---

## What you get, honestly

| | with Cloudflare (rung 2) | this way |
|---|---|---|
| Inbound ports open | **none** | 80 and 443 |
| Valid HTTPS certificate | free, automatic | **you own it** — see below |
| Login in front of things | Access, built in | you build it |
| Your server's IP | never published | public, and scanned within minutes |
| Cost | ~$10/yr for a domain | nothing |

## Do it

**1. Open the ports**

```hcl
# terraform.tfvars
enable_public_http = true

# While testing, narrow it to yourself — https://ifconfig.me tells you your address:
# public_http_cidr = "203.0.113.4/32"
```

```bash
tofu apply
```

**2. Add an ingress controller**

Something has to listen on :80 and route by hostname. k3s ships Traefik and this repo
disables it — deliberately, because with a tunnel it is dead weight. Turn it back on:

```bash
kubectl apply -f kubernetes/optional/app-traefik.yaml
```

That works immediately and needs no fork — Argo CD manages the app from the moment the
object exists, whoever created it.

**The durable way** is to have Argo read it from Git, which needs the repo Argo watches to
be *yours* — that is [rung 3](rung-3-your-app.md). Once it is:

```bash
cp kubernetes/optional/app-traefik.yaml kubernetes/applications/
git commit -am "add ingress" && git push
```

> ⚠ Do not run the second form before rung 3. Out of the box `gitops_repo_url` points at
> **this** project, so a push goes somewhere Argo is not watching — or fails outright — and
> the symptom is simply nothing happening.

It uses `service.type: LoadBalancer`, which on k3s means the built-in **servicelb** binds
the node's ports directly — no cloud load balancer, and nothing to pay for.

**3. Point something at your app**

```bash
kubectl get svc -n traefik
curl http://<your-public-ip>        # 404 from Traefik = it works, nothing is routed yet
```

> ⚠ **`EXTERNAL-IP` will show a `10.x` address, and that is correct.** On OCI the public
> address is 1:1 NAT at the network level — it never appears on the instance's interface —
> so k3s reports the node's private IP. It looks like the load balancer failed. It has not:
> curl the **public** address and Traefik answers.
>
> If you would rather k3s knew its public address (some charts read it), reinstall with
> `--node-external-ip $(curl -s http://169.254.169.254/opc/v2/instance/ -H 'Authorization: Bearer Oracle' | jq -r .metadata.public_ip)`.
> Not required for anything here.

Then give your app an Ingress:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: my-app
  namespace: my-app
spec:
  ingressClassName: traefik
  rules:
    - host: my-app.203-0-113-4.nip.io   # ← see below
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: my-app
                port: { number: 80 }
```

## A hostname without buying a domain

`nip.io` and `sslip.io` resolve any address embedded in the name back to that address:

```
my-app.203-0-113-4.nip.io   →  203.0.113.4
anything.1-2-3-4.sslip.io   →  1.2.3.4
```

Nothing to register, nothing to configure — enough to test hostname routing today.

> They are fine for development and wrong for anything lasting: you depend on a free
> third-party resolver, and the hostname changes if your IP does.

## The certificate problem

**This is the real cost of skipping Cloudflare**, and it is worth being blunt.

- **Plain HTTP** works immediately, and browsers will mark it *Not secure*. Worse, **large
  parts of the web platform are switched off on an insecure origin** — service workers,
  passkeys/WebAuthn, the clipboard API, camera, microphone, geolocation, PWA install. If
  your app uses any of those, it will not work here and the failure will look like a bug in
  your code.
- **A self-signed certificate** removes the eavesdropping problem but not the warning
  interstitial, and API clients reject it by default.
- **Let's Encrypt with a real domain** gives you a proper certificate without Cloudflare —
  add cert-manager, use an HTTP-01 challenge through the ingress you just deployed. This
  works well. Note you are now buying a domain anyway, and running the renewal machinery
  that the tunnel would have done for free.
- **Let's Encrypt on a `nip.io` name**: do not plan around it. Rate limits are shared
  across everyone using that domain, so issuance fails unpredictably.

## What to do about the front door

You have opened your cluster to the internet. Two things follow, and neither is optional:

**Do not expose Grafana or Argo CD.** Grafana has a generated admin password, but it is still a login on the public internet. Argo CD holds
credentials to your infrastructure. Reach those with `./scripts/connect.sh` as before, and
give an Ingress only to your own app.

**Expect the scanning.** Within minutes of opening 80/443 you will see probes for
`/wp-login.php`, `/.env` and `/.git/config` in the access logs. That is background noise on
the internet, not an attack on you — but it is also why "just for a minute" is how things
get compromised.

## Going back

Set `enable_public_http = false`, apply, and delete
`kubernetes/applications/app-traefik.yaml`. The ports close and the controller is pruned.
