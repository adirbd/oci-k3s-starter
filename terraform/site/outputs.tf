output "project_name" {
  description = "The Cloudflare Pages project name."
  value       = cloudflare_pages_project.website.name
}

output "project_subdomain" {
  description = "The project's pages.dev subdomain."
  value       = "${cloudflare_pages_project.website.name}.pages.dev"
}

output "domains" {
  description = "Custom domains attached to the Pages project."
  value       = [for d in cloudflare_pages_domain.site : d.domain]
}

output "urls" {
  description = "Public URLs the site is served at."
  value       = [for h in var.hostnames : "https://${h}"]
}
