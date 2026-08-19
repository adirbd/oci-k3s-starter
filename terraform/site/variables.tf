variable "cf_api_token" {
  description = "Cloudflare API token with scope: Account -> Cloudflare Pages:Edit, Account Settings:Read, Zone -> DNS:Edit."
  type        = string
  sensitive   = true
}

variable "cf_account_id" {
  description = "Cloudflare account ID."
  type        = string
}

variable "cf_zone_id" {
  description = "Cloudflare zone ID for the domain."
  type        = string
}

variable "domain" {
  description = "The apex domain, e.g. danieliyahu.com."
  type        = string
}

variable "project_name" {
  description = "Cloudflare Pages project name."
  type        = string
  default     = "daniel-personal-website"
}

variable "github_owner" {
  description = "GitHub owner of the site repo (for the Pages Git source connection)."
  type        = string
  default     = "danieliyahu1"
}

variable "github_repo" {
  description = "GitHub repo name of the site (for the Pages Git source connection)."
  type        = string
  default     = "daniel-personal-website"
}

variable "production_branch" {
  description = "Branch that deploys to production on Pages."
  type        = string
  default     = "master"
}

variable "hostnames" {
  description = "Hostnames to serve from Pages (apex + www etc.)."
  type        = list(string)
  default     = ["danieliyahu.com", "www.danieliyahu.com"]
}
