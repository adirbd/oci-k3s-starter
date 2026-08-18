# ══════════════════════════════════════════════════════════════════════════════════
#  RUNG 2 — real hostnames, with no inbound ports.
#
#  Everything in this file is created ONLY when enable_cloudflare = true. With it false
#  the provider is never called, no credentials are needed, and rung 1 is unaffected.
#
#  HOW IT WORKS, because it is the opposite of the usual arrangement: a connector pod
#  inside the cluster dials OUT to Cloudflare and holds that connection open. Requests
#  arrive at Cloudflare's edge and are handed back down it. Nothing listens on the public
#  internet — the security list still has exactly one inbound rule, for SSH.
#
#      browser → Cloudflare edge → (tunnel, outbound-established) → cloudflared → Service
#
#  Compare with opening 443: an ingress controller, a certificate, a DNS-01 solver, a
#  renewal that fails silently at 3am, and a listening port. This is fewer moving parts
#  AND a smaller attack surface, which is not a trade you get often.
# ══════════════════════════════════════════════════════════════════════════════════

resource "cloudflare_zero_trust_tunnel_cloudflared" "main" {
  count = var.enable_cloudflare ? 1 : 0

  account_id = var.cf_account_id
  name       = var.instance_name

  # ⚠ NOT THE PROVIDER DEFAULT, AND IMMUTABLE.
  # "cloudflare" means the routing below is what the connector obeys, fetched from the
  # API. The default, "local", means a YAML file on the origin — which this design does
  # not have, because the connector is a pod.
  #
  # Changing it later REPLACES the tunnel, which issues a new ID and a new token, which
  # means new DNS records and a new Kubernetes Secret. Get it right before the first apply.
  config_src = "cloudflare"
}

# The connector's credential. Terraform creates the tunnel, so Terraform is what can read
# the token — see the `cloudflared_secret_command` output for how it reaches the cluster.
data "cloudflare_zero_trust_tunnel_cloudflared_token" "main" {
  count = var.enable_cloudflare ? 1 : 0

  account_id = var.cf_account_id
  tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.main[0].id
}

resource "cloudflare_zero_trust_tunnel_cloudflared_config" "main" {
  count = var.enable_cloudflare ? 1 : 0

  account_id = var.cf_account_id
  tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.main[0].id

  config = {
    ingress = concat(
      [
        for name, route in var.tunnel_routes : {
          hostname = "${name}.${var.domain}"
          service  = route.service
          origin_request = {
            no_tls_verify = route.no_tls_verify
          }
        }
      ],
      # ⚠ REQUIRED, AND IT MUST BE LAST. cloudflared needs a catch-all rule with no
      # hostname; without it the config is rejected outright. Anything not matched above
      # gets a 404 from the connector rather than reaching your cluster.
      [{ service = "http_status:404" }],
    )
  }
}

# ── DNS ───────────────────────────────────────────────────────────────────────────
# A CNAME per hostname, pointing at the tunnel rather than at any IP address. This is
# what makes the box's ephemeral public IP a non-issue: rebuild it, get a new address,
# and these records do not change.
resource "cloudflare_dns_record" "tunnel" {
  for_each = var.enable_cloudflare ? var.tunnel_routes : {}

  zone_id = var.cf_zone_id
  name    = each.key
  type    = "CNAME"
  content = "${cloudflare_zero_trust_tunnel_cloudflared.main[0].id}.cfargotunnel.com"

  # proxied = true is REQUIRED, not a preference. A cfargotunnel.com target is only
  # resolvable through Cloudflare's proxy; unproxied, the name simply does not resolve.
  proxied = true
  ttl     = 1 # "automatic", and the only legal value while proxied
  comment = "Managed by OpenTofu — ${var.instance_name} tunnel"
}

# ── Access: a login in front of everything ────────────────────────────────────────
#
# Created only if you list emails. That is deliberate: an Access app with no policy is
# not "open with a warning", it is a lock with no key — and the failure mode of guessing
# for you is locking you out of your own Grafana.
#
# ⚠ WITH NO EMAILS LISTED, YOUR HOSTNAMES ARE PUBLIC. The tunnel closes your ports; it
# does not ask who is knocking. Grafana ships admin/admin.

resource "cloudflare_zero_trust_access_policy" "members" {
  count = var.enable_cloudflare && length(var.access_allowed_emails) > 0 ? 1 : 0

  account_id = var.cf_account_id
  name       = "${var.instance_name} — allowed members"
  decision   = "allow"
  include    = [for e in var.access_allowed_emails : { email = { email = e } }]
}

resource "cloudflare_zero_trust_access_application" "protected" {
  for_each = var.enable_cloudflare && length(var.access_allowed_emails) > 0 ? var.tunnel_routes : {}

  account_id = var.cf_account_id
  name       = "${each.key}.${var.domain}"
  domain     = "${each.key}.${var.domain}"
  type       = "self_hosted"

  # A WEEK, not the 24h default, and the reason is a real outage rather than convenience.
  # When a session expires mid-use, Access redirects the in-flight XHR to its login page.
  # A browser cannot report that as "your session expired" — it reports it as a CORS
  # error, so every app appears broken at once and nothing says why.
  session_duration = "168h"

  # OPTIONS preflights carry no cookies, so Access treats them as unauthenticated and
  # swallows them into the login redirect — a guaranteed CORS failure on any app that
  # makes a non-simple request. Pass them to the origin instead.
  options_preflight_bypass = true

  # The session cookie should not be readable by page JavaScript.
  http_only_cookie_attribute = true

  policies = [{
    id         = cloudflare_zero_trust_access_policy.members[0].id
    precedence = 1
  }]
}
