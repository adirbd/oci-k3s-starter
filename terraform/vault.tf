# ══════════════════════════════════════════════════════════════════════════════════
#  RUNG 4 — where secrets live.
#
#  COST: a DEFAULT vault with SOFTWARE-protected keys is Always Free, along with 150
#  secrets. VIRTUAL_PRIVATE vaults and HSM-protected keys are billed — this file uses
#  neither, and says so at each resource so a future edit has to be deliberate.
# ══════════════════════════════════════════════════════════════════════════════════

resource "oci_kms_vault" "main" {
  count = var.enable_vault ? 1 : 0

  compartment_id = var.compartment_ocid
  display_name   = "${var.instance_name}-vault"

  # ⚠ IMMUTABLE, and one-way. DEFAULT is the shared ("virtual") vault and is free;
  # VIRTUAL_PRIVATE is billed per hour and CANNOT be downgraded back.
  vault_type = "DEFAULT"

  freeform_tags = local.tags
}

resource "oci_kms_key" "main" {
  count = var.enable_vault ? 1 : 0

  compartment_id      = var.compartment_ocid
  display_name        = "${var.instance_name}-secrets-key"
  management_endpoint = oci_kms_vault.main[0].management_endpoint

  # SOFTWARE, not HSM. The free allowance covers a small number of HSM key versions, but
  # software keys avoid the capacity fee entirely — and "someone with physical access to
  # Oracle's datacentre" is not in the threat model for a hobby cluster.
  protection_mode = "SOFTWARE"

  key_shape {
    algorithm = "AES"
    length    = 32
  }

  freeform_tags = local.tags
}

# ── The one secret this repo can fill in for you ──────────────────────────────────
#
# With rungs 2 and 4 both on, Terraform already holds the tunnel token — so it writes it
# straight to the vault and the manual "pipe this into kubectl" step disappears. A rebuilt
# box fetches it itself, by being itself.
#
# This is the whole argument for rung 4 in one resource: the credential exists, but never
# on a laptop, never in a shell, and never on the instance's disk.
resource "oci_vault_secret" "cloudflared_token" {
  count = var.enable_vault && var.enable_cloudflare ? 1 : 0

  compartment_id = var.compartment_ocid
  vault_id       = oci_kms_vault.main[0].id
  key_id         = oci_kms_key.main[0].id
  secret_name    = "${var.instance_name}-cloudflared-token"
  description    = "Connector token for the Cloudflare tunnel. Written by terraform, read by External Secrets via instance principal."

  secret_content {
    content_type = "BASE64" # the only type OCI accepts; the value is base64 of the token
    content      = base64encode(data.cloudflare_zero_trust_tunnel_cloudflared_token.main[0].token)
  }
}
