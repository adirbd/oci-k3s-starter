# Cost, limits, and how much is left for your app

Short version: **this costs nothing, permanently** — but the allowance is smaller than the
one you get during your trial, and overshooting it is punished far more harshly than you
would expect.

---

## The one that can actually hurt you

> **Exceeding the Always Free ARM allowance disables and then deletes EVERY Ampere A1
> instance in your tenancy after 30 days — not just the excess.**

That is Oracle's documented behaviour, and it has three properties that make it nasty:

1. It is **silent**. Nothing fails at the moment you overshoot.
2. It is **delayed by a month**, so the cause is long forgotten.
3. It takes **machines you did not touch**, including ones that were fine.

This is why `variables.tf` refuses values above the allowance instead of trusting you to
remember. It is the one guard in this repo that exists to prevent data loss rather than a
failed apply.

## The allowance

> ⚠ **Check your own, do not trust this table.** Allowances differ between accounts and
> Oracle changes them over time; the figures below are what one tenancy actually saw. Yours
> are in the console under **Governance → Limits, Quotas and Usage**, filtered to
> `VM.Standard.A1.Flex` — that page is authoritative and this page is not.

| | during the free trial | after it ends |
|---|---|---|
| ARM (A1) cores | 4 | **2** |
| ARM memory | 24 GB | **12 GB** |
| Block storage | 200 GB total | 200 GB total |
| Outbound transfer | 10 TB/month | 10 TB/month |

The trial is roughly 30 days from signup. **The defaults here are 2 cores / 12 GB on
purpose** — the box survives the transition without you doing anything. If you raise them
to use the trial headroom, put a reminder in your calendar to lower them again, and
remember that lowering is an in-place resize with a reboot, not a rebuild.

> Ignore the console banner offering "3,000 OCPU hours". That describes trial credits, not
> the Always Free allowance, and reading it as the cap is how people overshoot.

## What the stack itself uses

Rough steady-state on an idle 2-core / 12 GB box:

| | approx RAM |
|---|---|
| Ubuntu + system | ~0.4 GB |
| k3s (control plane + kubelet + containerd) | ~1.0 GB |
| Argo CD | ~0.7 GB |
| VictoriaMetrics + Grafana | ~1.2 GB |
| Homepage | ~0.1 GB |
| **Total, as installed** | **~3.5 GB** |

**Which leaves roughly 8 GB for your app** — a lot, for one developer's side project.

Each optional component you add comes out of that 8 GB:

| | approx RAM |
|---|---|
| cloudflared (rung 2, ×2 replicas) | ~0.15 GB |
| External Secrets (rung 4, 3 components) | ~0.3 GB |
| Traefik (only without Cloudflare) | ~0.15 GB |

Even with all of them you are near 4 GB, so the headline holds — but it is worth knowing
that "the platform" grows as you climb.

These are observations from a comparable box, not guarantees; measure yours with
`kubectl top nodes`. The point is the order of magnitude: the platform costs you about a
quarter of the machine, not most of it.

> If you only want a container runtime and no dashboards, dropping the monitoring stack
> gets you another ~1.2 GB. It is one file in `kubernetes/applications/`.

## What is genuinely free, and what is not

**Free, always:**
- 2 ARM cores / 12 GB RAM (one instance or split across several)
- 200 GB block storage total
- 10 TB/month outbound
- The VCN, internet gateway, security lists, and the **serial console**

**Not free, or not clearly free — this repo avoids all of it:**
- **Reserved public IPs.** The instance uses an *ephemeral* IP, which survives reboot and
  stop/start and is only released on termination.
- **Load balancers.** Free tier includes a small one, but this repo uses a Cloudflare
  Tunnel instead — no web ports open, and no allowance spent.
- **NAT gateways.** Not used. The single subnet is public.
- **Block volumes beyond 200 GB**, and **backups** of them.

## The one thing that is not free

**A domain — about $10 a year.** That is the entire bill for this repo, and it is optional:
rung 1 needs no domain at all.

To be precise about who charges you: **Cloudflare's plan is free** — the tunnel, the TLS
certificate, Access with SSO, DDoS protection, the WAF and the CDN all cost nothing on the
free tier. What costs money is *registering a name*, which you pay a registrar for.
Cloudflare Registrar happens to sell at wholesale with no markup (about $10-11/yr for a
`.com` when this was written — prices drift, so check),
and other TLDs are often cheaper.

Whether it is worth it is argued in full in [rung 2](rung-2-real-urls.md) — the short
version is that a valid HTTPS certificate is not cosmetic, since browsers disable service
workers, passkeys, the clipboard API and camera access on insecure origins.

## If you upgrade to Pay As You Go

"Upgrade to PAYG" is the standard community fix for **"Out of host capacity"**, and it
genuinely works — paying tenancies get A1 capacity that Free Tier requests are refused.
The Always Free allowance survives the upgrade (many accounts report keeping the full
4 cores / 24 GB rather than dropping to 2 / 12 — as ever, **your** Limits page is
authoritative, not this one). So the upgrade can be a pure availability move.

**But it silently changes the failure mode.** On Free Tier, Oracle *cannot bill you* —
overshoot is punished with the deletion described at the top of this page. On PAYG, the
same overshoot just… bills. The safety net you never noticed is gone the moment the
upgrade completes.

What this repo does about it, on any account type:

1. **The caps do not move.** `variables.tf` refuses anything outside the Always Free
   shape regardless of how the tenancy is billed: 4 cores, 24 GB RAM, 200 GB storage,
   A1.Flex only. Everything else it creates — VCN, ephemeral IP (never a reserved one),
   Cloudflare tunnel instead of a load balancer, `DEFAULT`-type vault, the state bucket
   inside the 20 GB object-storage allowance — sits in services that are free on any
   account. **Upgrading is meant to buy availability, not to allow paid infrastructure**,
   and the configuration keeps refusing the latter either way.

2. **A zero-spend budget, as code.** One value in `terraform.tfvars`:

   ```hcl
   budget_alert_email = "you@example.com"
   ```

   The next apply creates a budget of **1** (your billing currency) per month over the
   compartment, alerting at both *forecast* and *actual* — in effect, "email me the
   moment Oracle believes this month will not be free". It catches what the caps cannot
   see: a resource clicked up in the console, a free allowance Oracle changes, a mistake
   in a fork. On a never-upgraded Free Tier it is safely unnecessary (there is nothing
   to bill), which is why it only turns on once you give it an address.

Two honest caveats: budget evaluation is not instant — Oracle refreshes cost data a few
times a day, so the email can lag the mistake by hours — and budgets attach to the
**root compartment**, so if your `compartment_ocid` is a child compartment you must set
`tenancy_ocid` as well.

## Watch it yourself

Set `budget_alert_email` even if nothing else on this page applies to you — free tier or
not, it turns "surprise bill" into "email". (Not applying yet? The console equivalent is
**Billing → Cost Management → Budgets**: root compartment, any amount above zero,
alerting at 100%.)

Then check **Governance → Limits, Quotas and Usage**, filter to `Compute`, and look at
`VM.Standard.A1.Flex` — it shows exactly how much of your ARM allowance is in use, which
is the number that matters.
