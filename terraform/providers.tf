# ── OCI: browser session by default, API key if you need one ──────────────────────
#
# The default is `SecurityToken` — the session you get from `oci session authenticate`,
# which opens a browser, logs you in, and writes a short-lived token to an OCI CLI
# profile. Refresh it with `oci session refresh --profile <name>`.
#
# WHY THIS IS THE DEFAULT rather than the API key every Oracle tutorial starts with:
# the API-key flow asks you to generate an RSA key, upload the public half, copy a
# fingerprint out of the console, find two OCIDs, and then leave a .pem on your laptop
# forever. That file is the thing that leaks. A session expires on its own.
#
# It is also, unusually, the shorter path — one command instead of six steps. When the
# safer option is also the easier one, it should be the default.
#
# FOR CI, where no browser exists, set:
#   oci_auth = "APIKey"
# and supply tenancy/user/fingerprint/private key (see variables.tf). Prefer
# `TF_VAR_oci_private_key` in the environment over a file on disk.
#
# Other valid values the provider accepts: "InstancePrincipal" (running from inside
# OCI), "ResourcePrincipal" (OCI Functions), "WorkloadIdentity" (OKE pods).
provider "oci" {
  auth                = var.oci_auth
  config_file_profile = var.oci_config_profile
  region              = var.region

  # Ignored unless auth = "APIKey". Left as null in the session-token path, where the
  # provider takes all of this from the CLI profile instead.
  tenancy_ocid = var.oci_tenancy_ocid
  user_ocid    = var.oci_user_ocid
  fingerprint  = var.oci_fingerprint
  private_key  = var.oci_private_key
}

# ── Cloudflare: only reached when enable_cloudflare = true (rung 2) ────────────────
#
# A provider block with no resources referencing it is inert — Terraform will not
# authenticate or contact the API — so leaving this configured with a null token costs
# nothing while enable_cloudflare is false. That is what makes rung 2 genuinely
# optional rather than merely "documented as optional".
provider "cloudflare" {
  api_token = var.cf_api_token
}
