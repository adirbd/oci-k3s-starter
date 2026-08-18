# ══════════════════════════════════════════════════════════════════════════════════
#  REQUIRED — the three values you cannot avoid
# ══════════════════════════════════════════════════════════════════════════════════

variable "region" {
  description = "OCI region. MUST be your tenancy's HOME region — Always Free resources only exist there, and the home region is fixed when the account is created. e.g. eu-frankfurt-1, us-ashburn-1, il-jerusalem-1."
  type        = string
}

variable "compartment_ocid" {
  description = "Compartment to build in. The tenancy OCID (root compartment) is a fine answer if you have not made any — find it under Identity > Compartments in the console."
  type        = string

  validation {
    condition     = startswith(var.compartment_ocid, "ocid1.")
    error_message = "compartment_ocid must be an OCID — it starts with 'ocid1.'. You may have pasted a display name."
  }
}

variable "ssh_public_key" {
  description = "SSH public key, as CONTENT not a path (e.g. file(\"~/.ssh/id_ed25519.pub\")). This is the only way onto the box until you set up something better, so a typo here costs you a rebuild."
  type        = string

  validation {
    condition     = can(regex("^(ssh-(rsa|ed25519)|ecdsa-sha2-)", trimspace(var.ssh_public_key)))
    error_message = "ssh_public_key must be an OpenSSH PUBLIC key (starts with ssh-ed25519, ssh-rsa or ecdsa-sha2-). If it starts with '-----BEGIN', that is the private half — do not put that here."
  }
}

# ══════════════════════════════════════════════════════════════════════════════════
#  AUTHENTICATION — browser session by default
# ══════════════════════════════════════════════════════════════════════════════════

variable "oci_auth" {
  description = "How the provider authenticates. 'SecurityToken' uses the browser session from `oci session authenticate` and is the default. Use 'APIKey' for CI, where there is no browser."
  type        = string
  default     = "SecurityToken"

  validation {
    condition     = contains(["SecurityToken", "APIKey", "InstancePrincipal", "ResourcePrincipal", "WorkloadIdentity"], var.oci_auth)
    error_message = "oci_auth must be one of: SecurityToken, APIKey, InstancePrincipal, ResourcePrincipal, WorkloadIdentity."
  }
}

variable "oci_config_profile" {
  description = "Which profile in ~/.oci/config to use. `oci session authenticate` prompts for a name and writes one; whatever you typed there goes here."
  type        = string
  default     = "DEFAULT"
}

# The four below are IGNORED unless oci_auth = \"APIKey\". They exist so CI has a path.
# Prefer passing the key via TF_VAR_oci_private_key in the environment over a file.
variable "oci_tenancy_ocid" {
  description = "APIKey auth only: tenancy OCID."
  type        = string
  default     = null
}

variable "oci_user_ocid" {
  description = "APIKey auth only: user OCID."
  type        = string
  default     = null
}

variable "oci_fingerprint" {
  description = "APIKey auth only: fingerprint of the uploaded public key."
  type        = string
  default     = null
}

variable "oci_private_key" {
  description = "APIKey auth only: the private key CONTENT (not a path)."
  type        = string
  default     = null
  sensitive   = true
}

# ══════════════════════════════════════════════════════════════════════════════════
#  THE INSTANCE — sized to fit inside Always Free on purpose
# ══════════════════════════════════════════════════════════════════════════════════

variable "instance_name" {
  description = "Display name for the instance and the resources around it."
  type        = string
  default     = "k3s-01"
}

variable "ocpus" {
  description = "ARM cores. Always Free allows 4 across ALL your A1 instances during the free trial, and 2 after it ends. Default 2 so the box survives the change without you doing anything."
  type        = number
  default     = 2

  # ⚠ THIS GUARD IS NOT PEDANTRY. Oracle's own wording: with more A1 provisioned than an
  # Always Free tenancy allows, "all existing OCI Ampere A1 Compute instances are disabled
  # and then deleted after 30 days" — ALL of them, not the excess. The failure is silent,
  # delayed by a month, and takes machines you did not touch.
  validation {
    condition     = var.ocpus >= 1 && var.ocpus <= 4
    error_message = "ocpus must be 1-4. Above 4 you are outside Always Free entirely; at 3-4 you are inside it ONLY during the free trial, and exceeding the post-trial allowance of 2 deletes EVERY A1 instance in the tenancy after 30 days."
  }
}

variable "memory_gb" {
  description = "RAM in GB. Always Free is 24 during the trial and 12 after. The A1 shape wants 6 GB per core, so keep this at 6x ocpus unless you know why you are not."
  type        = number
  default     = 12

  validation {
    condition     = var.memory_gb >= 6 && var.memory_gb <= 24
    error_message = "memory_gb must be 6-24. See the ocpus note: exceeding the post-trial allowance deletes every A1 instance in the tenancy, not just this one."
  }
}

variable "boot_volume_gb" {
  description = "Boot volume size. Always Free includes 200 GB of block storage TOTAL across all volumes, so leave headroom if you plan a second instance. 50 is comfortable for k3s plus images."
  type        = number
  default     = 50

  validation {
    condition     = var.boot_volume_gb >= 50 && var.boot_volume_gb <= 200
    error_message = "boot_volume_gb must be 50-200. 50 is the OCI minimum for this image; 200 is the entire Always Free block-storage allowance."
  }
}

variable "image_ocid" {
  description = "Optional: pin a specific Ubuntu ARM image OCID. Leave null to look up the newest Canonical Ubuntu 24.04 aarch64 image automatically. Image OCIDs are region-specific, so a pinned value from one region is invalid in another."
  type        = string
  default     = null
}

# ══════════════════════════════════════════════════════════════════════════════════
#  NETWORK
# ══════════════════════════════════════════════════════════════════════════════════

variable "vcn_cidr" {
  description = "CIDR for the VCN. Change it if it collides with a network you plan to VPN into — overlapping ranges are painful to fix later."
  type        = string
  default     = "10.42.0.0/16"
}

variable "ssh_allowed_cidr" {
  description = "Who may reach port 22. Defaults to the whole internet because on a fresh account you do not yet have another way in — and a box you cannot SSH to is a box you rebuild."
  type        = string
  default     = "0.0.0.0/0"

  # NARROW THIS ONCE YOU HAVE A SECOND DOOR. Key-only auth means the scans in your logs
  # (there will be thousands) are noise, not danger — the real exposure is a future
  # pre-auth sshd bug. But do NOT narrow it until you have TESTED the fallback: this
  # config creates a serial console for exactly that reason, and an untested recovery
  # path is a hypothesis, not a door.
}

# ══════════════════════════════════════════════════════════════════════════════════
#  WHAT RUNS ON IT
# ══════════════════════════════════════════════════════════════════════════════════

variable "k3s_channel" {
  description = "k3s release channel — 'stable' or a pinned version like 'v1.31.4+k3s1'. A channel drifts on rebuild; pin it once you care about reproducibility."
  type        = string
  default     = "stable"
}

variable "argocd_version" {
  description = "Argo CD version to install at first boot. Pinned rather than 'stable' so a rebuild six months from now produces the same cluster."
  type        = string
  # renovate: datasource=github-releases depName=argoproj/argo-cd
  default = "v3.5.1"
}

variable "gitops_repo_url" {
  description = "Repo Argo CD watches. Defaults to this project's own kubernetes/ directory, so the first apply deploys a working sample with NO credentials. Point it at your own repo at rung 3."
  type        = string
  default     = "https://github.com/adirbd/oci-k3s-starter.git"
}

variable "gitops_repo_path" {
  description = "Path inside gitops_repo_url holding the Argo Applications."
  type        = string
  default     = "kubernetes/applications"
}

# ══════════════════════════════════════════════════════════════════════════════════
#  RUNG 2 — Cloudflare. OFF by default; everything above works without it.
# ══════════════════════════════════════════════════════════════════════════════════

variable "enable_cloudflare" {
  description = "Create a Cloudflare Tunnel and DNS records so services get real hostnames with no inbound ports. Requires a domain whose nameservers point at Cloudflare. Leave false and use `kubectl port-forward`."
  type        = bool
  default     = false
}

variable "domain" {
  description = "Your domain, e.g. example.com. Only used when enable_cloudflare = true."
  type        = string
  default     = null
}

variable "cf_api_token" {
  description = "Cloudflare API token with Zone:DNS:Edit and Account:Cloudflare Tunnel. Only used when enable_cloudflare = true."
  type        = string
  default     = null
  sensitive   = true
}

variable "cf_account_id" {
  description = "Cloudflare account ID. Only used when enable_cloudflare = true."
  type        = string
  default     = null
}

variable "cf_zone_id" {
  description = "Cloudflare zone ID for `domain`. Only used when enable_cloudflare = true."
  type        = string
  default     = null
}

variable "tunnel_routes" {
  description = "Hostnames the tunnel serves, and the in-cluster Service each maps to. Note these point straight at Kubernetes Services — there is no ingress controller in the middle, because the tunnel already terminates the request."
  type = map(object({
    service       = string
    no_tls_verify = optional(bool, false)
  }))

  default = {
    # <name>.<your domain>. Change the keys, not the shape.
    home = {
      service = "http://homepage.homepage.svc.cluster.local:3000"
    }
    grafana = {
      service = "http://vm-stack-grafana.observability.svc.cluster.local:80"
    }
    argocd = {
      # ⚠ HTTPS, and TLS verification OFF, and this combination is deliberate.
      # argocd-server serves HTTPS with a SELF-SIGNED certificate, so a normal HTTPS
      # origin fails verification. Sending plain HTTP instead gives you an infinite
      # redirect loop, because the server 301s http→https unless it is started with
      # `--insecure`.
      #
      # Two ways out: patch argocd-cmd-params-cm to set server.insecure=true, or accept
      # its self-signed cert here. This repo does the latter — it keeps Argo exactly as
      # upstream ships it, and the "unverified" hop is pod-to-pod inside one node.
      service       = "https://argocd-server.argocd.svc.cluster.local:443"
      no_tls_verify = true
    }
  }
}

variable "access_allowed_emails" {
  description = "Email addresses allowed through Cloudflare Access. Empty means NO Access app is created and your hostnames are served to the whole internet — fine for a public site, wrong for Grafana."
  type        = list(string)
  default     = []
}
