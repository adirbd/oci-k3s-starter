#!/usr/bin/env bash
# Move Terraform state off your laptop, in one command.
#
# THE PROBLEM THIS SOLVES. A backend has to exist before `tofu init`, so Terraform cannot
# create its own storage in a single step. Everyone meets this, and the usual answers are
# "click around the console first" or "keep a second Terraform project just for the bucket".
#
# This does the whole thing in ONE run and you never see the seam:
#   1. apply with LOCAL state, creating the bucket and an S3 credential
#   2. write backend.hcl from the outputs
#   3. add `backend "s3" {}` to versions.tf (empty on purpose — backend.hcl has the values)
#   4. `tofu init -migrate-state` to move state into the bucket
#
# Afterwards the state file lives in your own OCI tenancy, versioned, and your laptop is no
# longer the only copy.
#
#   ./scripts/enable-remote-state.sh
set -euo pipefail
cd "$(dirname "$0")/../terraform"

TF="${TF:-tofu}"; command -v "$TF" >/dev/null 2>&1 || TF=terraform

need() { grep -qE "^\s*$1\s*=" terraform.tfvars 2>/dev/null; }
backend_active() { grep -qE '^\s*backend "s3"' versions.tf; }

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

# Once the backend is live, everything below either fails (apply against a backend that
# is not initialised in THIS shell) or is a no-op. Say so instead of half-running.
if backend_active && [ -f backend.hcl ]; then
    cat <<MSG
  remote state looks enabled already: versions.tf declares the backend and backend.hcl
  exists. Nothing to do. To verify, run (with the AWS_* credentials in the environment):

      $TF init -backend-config=backend.hcl && $TF state list
MSG
    exit 0
fi
if backend_active; then
    cat <<'MSG'
  versions.tf declares an active `backend "s3"` block but backend.hcl does not exist,
  so nothing can read the outputs to write it. Comment the block back out and re-run
  this script — it adds the block itself, at the right moment.
MSG
    exit 1
fi

echo "── stage 1: creating the bucket and credentials (local state)"
"$TF" apply -auto-approve

echo "── stage 2: writing backend.hcl"
"$TF" output -raw state_backend_config > backend.hcl
echo "  wrote terraform/backend.hcl  (gitignored)"

# Terraform needs `backend "s3" {}` to exist before -backend-config means anything. The
# block is EMPTY on purpose — every value comes from backend.hcl — and the commented
# example further down versions.tf stays as documentation.
echo "── stage 3: adding backend \"s3\" {} to versions.tf"
awk '/^terraform {/ && !done { print; print "  backend \"s3\" {}"; done=1; next } { print }' \
    versions.tf > versions.tf.tmp && mv versions.tf.tmp versions.tf

echo "── stage 4: migrating state into the bucket"
export AWS_ACCESS_KEY_ID="$("$TF" output -raw state_s3_access_key_id)"
export AWS_SECRET_ACCESS_KEY="$("$TF" output -raw state_s3_secret_access_key)"
"$TF" init -backend-config=backend.hcl -migrate-state

cat <<MSG

done. State now lives in your OCI tenancy, versioned.

Every future $TF command needs the credentials in the environment:

    export AWS_ACCESS_KEY_ID=\$($TF output -raw state_s3_access_key_id)
    export AWS_SECRET_ACCESS_KEY=\$($TF output -raw state_s3_secret_access_key)

⚠ Those outputs read from the state you just moved, so once your local copy is gone you
need another source. With rung 4 enabled they are also in OCI Vault as
"<instance_name>-terraform-state-s3" — readable from the console on a machine that has
nothing. Without rung 4, put them in your password manager now, while you still have them.

The local terraform.tfstate is left in place as a backup. Delete it once you have run a
successful apply against the remote backend.
MSG
