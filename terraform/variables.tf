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
  description = "Your user OCID. Needed for TWO things: APIKey auth, and enable_remote_state (a Customer Secret Key belongs to a user). Profile menu > your username > OCID. It is the one value that cannot be looked up — a browser session does not tell Terraform which human is driving it."
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
  #
  # On a tenancy UPGRADED to Pay As You Go, the same overshoot BILLS instead of deleting.
  # The cap holds on any account type on purpose: upgrading is a capacity move, not a
  # license to build paid infrastructure — see docs/cost-and-limits.md and budget.tf.
  validation {
    condition     = var.ocpus >= 1 && var.ocpus <= 4
    error_message = "ocpus must be 1-4. Above 4 you are outside Always Free entirely: on Free Tier exceeding the allowance deletes EVERY A1 instance in the tenancy after 30 days, and on Pay As You Go it bills. This repo stays inside Always Free on any account type."
  }
}

variable "memory_gb" {
  description = "RAM in GB. Always Free is 24 during the trial and 12 after. The A1 shape wants 6 GB per core, so keep this at 6x ocpus unless you know why you are not."
  type        = number
  default     = 12

  validation {
    condition     = var.memory_gb >= 6 && var.memory_gb <= 24
    error_message = "memory_gb must be 6-24. See the ocpus note: on Free Tier exceeding the allowance deletes every A1 instance in the tenancy, and on Pay As You Go it bills instead."
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

# ── Cost guardrails ────────────────────────────────────────────────────────────────

variable "budget_alert_email" {
  description = "Email for the zero-spend budget (budget.tf). Null (default) creates no budget — fine on a never-upgraded Free Tier, where Oracle cannot bill you at all. ⚠ SET THIS THE DAY YOU UPGRADE TO PAY AS YOU GO: the upgrade is the standard fix for 'Out of host capacity', and it silently swaps 'cannot be billed' for 'bills for the same mistake'. The shape/storage validations cap everything this repo creates inside Always Free; the budget catches what they cannot see."
  type        = string
  default     = null

  validation {
    condition     = var.budget_alert_email == null || can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", var.budget_alert_email))
    error_message = "budget_alert_email must be a single email address."
  }
}

variable "budget_monthly_limit" {
  description = "Monthly budget amount, in the tenancy's billing currency. 1 on purpose: the point is 'tell me the moment ANYTHING bills', not cost management. OCI does not accept 0."
  type        = number
  default     = 1

  validation {
    condition     = var.budget_monthly_limit >= 1
    error_message = "budget_monthly_limit must be at least 1 — OCI budgets do not accept smaller amounts, and for this stack 1 already means 'any spend at all is unexpected'."
  }
}

variable "availability_domain_index" {
  description = "Which availability domain to build in, by position (0, 1, 2...). CAPACITY IS TRACKED PER AD, so when a launch fails with 'Out of host capacity', asking a different AD is a genuinely different request — retrying the same one can fail all day. scripts/retry-apply.sh rotates this for you. Wraps automatically, so any number is legal even in single-AD regions."
  type        = number
  default     = 0

  validation {
    condition     = var.availability_domain_index >= 0
    error_message = "availability_domain_index must be 0 or greater."
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
  description = "CIDR for the VCN. MUST NOT overlap k3s's internal networks: pods use 10.42.0.0/16 and Services 10.43.0.0/16 by default. Change it if it collides with a network you plan to VPN into — overlapping ranges are painful to fix afterwards."
  type        = string
  default     = "10.10.0.0/16"

  # ⚠ THIS GUARD EXISTS BECAUSE THE DEFAULT WAS ONCE 10.42.0.0/16 — exactly k3s's pod
  # network. The node would have taken an address from the same range its own pods use.
  # That does not fail cleanly: it produces intermittent, unexplainable networking, and
  # nothing in any log says "your VCN overlaps your CNI".
  #
  # A string prefix check rather than real CIDR arithmetic, because Terraform has no
  # "does A overlap B" function. It catches the two ranges that matter, which is the
  # whole point.
  validation {
    condition     = !startswith(var.vcn_cidr, "10.42.") && !startswith(var.vcn_cidr, "10.43.")
    error_message = "vcn_cidr must not use 10.42.x or 10.43.x — those are k3s's default pod and Service networks, and overlapping them breaks cluster networking in ways that are very hard to diagnose."
  }
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
  description = "k3s to install at first boot: a pinned version like 'v1.36.3+k3s1' (the default — a rebuild six months from now produces the same cluster, the same reasoning as argocd_version) or a channel like 'stable' (drifts on rebuild). The bootstrap routes each shape to the right installer variable — they are NOT interchangeable: a version passed as a channel 404s at the channel server."
  type        = string
  # renovate: datasource=github-releases depName=k3s-io/k3s
  default = "v1.36.3+k3s1"
}

variable "fault_domain" {
  description = "Fault domain to request, e.g. 'FAULT-DOMAIN-2' — the API names; the console's 'FD-1' labels are rejected with 400-InvalidParameter. Empty (default) lets Oracle choose. retry-apply rotates this: in a SINGLE-availability-domain region (many home regions), rotating the AD index wraps to the same AD every time, and the fault domain is the only axis left on which a retry is a genuinely different question."
  type        = string
  default     = ""
}

variable "argocd_version" {
  description = "Argo CD version to install at first boot. Pinned rather than 'stable' so a rebuild six months from now produces the same cluster."
  type        = string
  # renovate: datasource=github-releases depName=argoproj/argo-cd
  default = "v3.5.2"
}

variable "gitops_repo_url" {
  description = "Repo Argo CD watches. Defaults to this project (public), so the first apply deploys a working sample with no credentials. ⚠ When you point this at YOUR repo: Argo gets no credentials at first boot, so a private repo needs a step — see docs/rung-3-your-app.md."
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

# ══════════════════════════════════════════════════════════════════════════════════
#  RUNG 4 — OCI Vault. OFF by default.
# ══════════════════════════════════════════════════════════════════════════════════

variable "enable_vault" {
  description = "Create an OCI Vault plus the IAM that lets this instance read it BY BEING ITSELF — no API key on the box. Requires tenancy_ocid, and an account allowed to create dynamic groups and policies (the tenancy owner is; a restricted user may not be)."
  type        = bool
  default     = false
}

variable "tenancy_ocid" {
  description = "Your tenancy OCID. REQUIRED when enable_vault = true, because dynamic groups and policies are tenancy-level objects and cannot be created anywhere else. Find it under Profile > Tenancy."
  type        = string
  default     = null

  validation {
    condition     = var.tenancy_ocid == null || startswith(coalesce(var.tenancy_ocid, "ocid1."), "ocid1.tenancy")
    error_message = "tenancy_ocid must be a tenancy OCID — it starts with 'ocid1.tenancy'."
  }
}

variable "enable_public_http" {
  description = "Open ports 80 and 443 to the internet, for serving your app WITHOUT Cloudflare. Off by default. You also need an ingress controller — see kubernetes/optional/app-traefik.yaml and docs/without-cloudflare.md."
  type        = bool
  default     = false

  # ⚠ THIS IS THE ONE SETTING THAT PUTS YOUR CLUSTER ON THE INTERNET.
  #
  # It is a legitimate choice — it is how most servers have always worked — but understand
  # what changes: with the tunnel, nothing listens and your origin IP is unpublished. With
  # this, anything you expose is directly reachable and scanned within minutes, and you own
  # the TLS certificate, the renewals and whatever is listening.
  #
  # Do NOT combine this with an exposed Argo CD or Grafana: both hold credentials to
  # your infrastructure, and a login page alone is a thin thing to put on the internet.
}

variable "public_http_cidr" {
  description = "Who may reach ports 80/443 when enable_public_http = true. Defaults to the whole internet, which is the point of a web server — narrow it to your own address if you are only testing."
  type        = string
  default     = "0.0.0.0/0"
}

# ══════════════════════════════════════════════════════════════════════════════════
#  REMOTE STATE — optional, and off by default.
# ══════════════════════════════════════════════════════════════════════════════════

variable "enable_remote_state" {
  description = "Create an OCI Object Storage bucket and S3 credentials for Terraform state, so it stops living only on your laptop. Local state is fine for one person; this is for durability and for working from more than one machine. Run scripts/enable-remote-state.sh rather than doing it by hand."
  type        = bool
  default     = false
}

variable "state_bucket_name" {
  description = "Name for the state bucket. Bucket names are unique per tenancy, not globally."
  type        = string
  default     = "terraform-state"
}
