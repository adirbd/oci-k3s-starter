#!/usr/bin/env bash
# Move Terraform state off your laptop, in one command.
#
# THE PROBLEM THIS SOLVES. A backend has to exist before `tofu init`, so Terraform cannot
# create its own storage in a single step. Everyone meets this, and the usual answers are
# "click around the console first" or "keep a second Terraform project just for the bucket".
#
# This does the two stages for you and you never see the seam:
#   1. apply with LOCAL state, creating the bucket and an S3 credential
#   2. write backend.hcl, then `tofu init -migrate-state` to move state into it
#
# Afterwards the state file lives in your own OCI tenancy, versioned, and your laptop is no
# longer the only copy.
#
#   ./scripts/enable-remote-state.sh
set -euo pipefail
cd "$(dirname "$0")/../terraform"

need() { grep -qE "^\s*$1\s*=" terraform.tfvars 2>/dev/null; }

echo "── checking prerequisites"
if ! need enable_remote_state; then
    cat <<'MSG'
  Add these to terraform.tfvars first:

      enable_remote_state = true
      oci_user_ocid       = "ocid1.user.oc1..aaaa..."   # Profile menu > your username > OCID

  oci_user_ocid is the one value that cannot be looked up: a Customer Secret Key belongs to
  a user, and a browser session does not tell Terraform which human is driving it.
MSG
    exit 1
fi
need oci_user_ocid || { echo "  oci_user_ocid is missing from terraform.tfvars — see above."; exit 1; }

echo "── stage 1: creating the bucket and credentials (local state)"
tofu apply -auto-approve

echo "── stage 2: writing backend.hcl"
tofu output -raw state_backend_config > backend.hcl
echo "  wrote terraform/backend.hcl  (gitignored)"

# Uncomment the backend block if it is still commented out. Terraform needs `backend "s3" {}`
# to exist before -backend-config means anything.
if ! grep -qE '^\s*backend "s3"' versions.tf; then
    cat <<'MSG'

  ⚠ One edit left, and it has to be by hand: versions.tf still has its backend block
  commented out. Uncomment it, leaving the body EMPTY:

      backend "s3" {}

  The values come from backend.hcl, which is why the block is empty. Then re-run this
  script — everything before this point is idempotent.
MSG
    exit 1
fi

echo "── stage 3: migrating state into the bucket"
export AWS_ACCESS_KEY_ID="$(tofu output -raw state_s3_access_key_id)"
export AWS_SECRET_ACCESS_KEY="$(tofu output -raw state_s3_secret_access_key)"
tofu init -backend-config=backend.hcl -migrate-state

cat <<'MSG'

done. State now lives in your OCI tenancy, versioned.

Every future tofu command needs the credentials in the environment:

    export AWS_ACCESS_KEY_ID=$(tofu output -raw state_s3_access_key_id)
    export AWS_SECRET_ACCESS_KEY=$(tofu output -raw state_s3_secret_access_key)

⚠ Those outputs read from the state you just moved, so once your local copy is gone you
need another source. With rung 4 enabled they are also in OCI Vault as
"<instance_name>-terraform-state-s3" — readable from the console on a machine that has
nothing. Without rung 4, put them in your password manager now, while you still have them.

The local terraform.tfstate is left in place as a backup. Delete it once you have run a
successful apply against the remote backend.
MSG
