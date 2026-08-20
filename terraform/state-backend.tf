# ══════════════════════════════════════════════════════════════════════════════════
#  Somewhere for state to live, created by the same tool that needs it.
#
#  THE CHICKEN AND EGG, STATED PLAINLY: a backend must exist BEFORE `tofu init`, so
#  Terraform cannot create its own storage in one step. Everyone hits this. The usual
#  answers are "click around the console first" or "run a second Terraform project".
#
#  This is the third answer: build the bucket with LOCAL state, then migrate the state into
#  it. Two stages, one script — scripts/enable-remote-state.sh does both and you never see
#  the seam.
#
#  All of it is off unless enable_remote_state = true, and the default backend stays local.
# ══════════════════════════════════════════════════════════════════════════════════

# Looked up, not asked for. The object storage namespace is a per-tenancy string that the
# S3-compatible endpoint needs, and hunting for it in the console is exactly the kind of
# step that makes people give up on remote state.
data "oci_objectstorage_namespace" "ns" {
  count          = var.enable_remote_state ? 1 : 0
  compartment_id = var.compartment_ocid
}

resource "oci_objectstorage_bucket" "state" {
  count = var.enable_remote_state ? 1 : 0

  compartment_id = var.compartment_ocid
  namespace      = data.oci_objectstorage_namespace.ns[0].namespace
  name           = var.state_bucket_name

  # NoPublicAccess is the provider default; stated because this bucket holds a file with
  # your Grafana password and the console's private key in it.
  access_type = "NoPublicAccess"

  # Keeps every version of the state file. Storage is free up to 20 GB and a state file is
  # measured in kilobytes, so the cost of this is nothing and the value is being able to go
  # back after a bad apply.
  versioning = "Enabled"

  freeform_tags = local.tags
}

# The S3-compatible endpoint authenticates with a Customer Secret Key — an access key and
# secret pair, NOT your API signing key. Generating it here saves a five-step console visit.
#
# ⚠ THE SECRET IS RETURNED ONCE, AT CREATION, and lives in Terraform state from then on —
# the same state this key is about to protect. That circularity is real but benign: if you
# lose local state before migrating, generate a new key and re-run. It is not a
# lock-yourself-out situation, just a repeat.
resource "oci_identity_customer_secret_key" "state" {
  count = var.enable_remote_state ? 1 : 0

  display_name = "${var.instance_name}-terraform-state"
  user_id      = var.oci_user_ocid
}

# Stored in the vault too when rung 4 is on — which is the answer to "where do I keep these
# without a password manager". Recoverable from the OCI console by someone who has lost
# their laptop, which is precisely when they are needed.
resource "oci_vault_secret" "state_credentials" {
  count = var.enable_remote_state && var.enable_vault ? 1 : 0

  compartment_id = var.compartment_ocid
  vault_id       = oci_kms_vault.main[0].id
  key_id         = oci_kms_key.main[0].id
  secret_name    = "${var.instance_name}-terraform-state-s3"
  description    = "S3-compatible credentials for the Terraform state bucket. AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY, as JSON."

  secret_content {
    content_type = "BASE64"
    content = base64encode(jsonencode({
      AWS_ACCESS_KEY_ID     = oci_identity_customer_secret_key.state[0].id
      AWS_SECRET_ACCESS_KEY = oci_identity_customer_secret_key.state[0].key
      endpoint              = "https://${data.oci_objectstorage_namespace.ns[0].namespace}.compat.objectstorage.${var.region}.oraclecloud.com"
      bucket                = var.state_bucket_name
    }))
  }
}
