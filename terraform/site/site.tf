# Cloudflare Pages project for the personal website. This is the single source of
# truth for the site's Pages project, its custom domains, and the DNS that points at
# it — replacing the resources that were previously created by hand via wrangler/API.
#
# ⚠ ADOPTION: these resources already exist in Cloudflare. They are adopted with
# `tofu import` so `apply` treats them as in-place rather than recreating them
# (recreating would drop the certificate and the Git connection).

resource "cloudflare_pages_project" "website" {
  account_id        = var.cf_account_id
  name              = var.project_name
  production_branch = var.production_branch

  # Git connection: keeps auto-deploy on push working exactly as it does today.
  source {
    type = "github"
    config {
      owner             = var.github_owner
      repo_name         = var.github_repo
      production_branch = var.production_branch
    }
  }
}

# Custom domains on the Pages project (apex + www). Each gets an edge certificate
# issued automatically by Cloudflare.
resource "cloudflare_pages_domain" "site" {
  for_each = toset(var.hostnames)

  account_id   = var.cf_account_id
  project_name = cloudflare_pages_project.website.name
  domain       = each.value
}

# DNS records pointing each hostname at the Pages project. Proxied = served through
# Cloudflare's edge with a valid certificate.
resource "cloudflare_dns_record" "site" {
  for_each = toset(var.hostnames)

  zone_id = var.cf_zone_id
  name    = each.value == var.domain ? "@" : each.value
  type    = "CNAME"
  content = "${cloudflare_pages_project.website.name}.pages.dev"
  proxied = true
  ttl     = 1
  comment = "Managed by OpenTofu — ${var.project_name} Pages"
}
