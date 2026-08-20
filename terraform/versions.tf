terraform {
  # OpenTofu 1.10+ (or Terraform 1.10+). 1.10 is the floor because of native state
  # lockfile support, which matters the moment you move state off your laptop.
  required_version = ">= 1.10"

  # ── STATE LIVES LOCALLY BY DEFAULT, AND THAT IS A DELIBERATE STARTER CHOICE ──────
  # No backend block, so `tofu apply` writes terraform.tfstate next to these files and
  # rung 1 needs no bucket, no credentials and no decisions.
  #
  # ⚠ Two things to know before this stops being fine:
  #   1. STATE IS NOT SECRET-FREE. The generated Grafana admin password lands in it in
  #      cleartext, as does anything else marked sensitive. `terraform.tfstate` is
  #      gitignored here; keep it that way, and do not put it on a shared drive.
  #   2. Local state has no locking across machines. One laptop is fine. Two people, or
  #      a laptop plus CI, is how state gets corrupted.
  #
  # When you outgrow it, uncomment this and run `tofu init -migrate-state`. Any
  # S3-compatible store works — and the one you already have is OCI Object Storage:
  # Always Free includes 20 GB and it speaks S3, so state can live in the same account as
  # the box with no new vendor. Cloudflare R2 and Backblaze B2 work identically.
  #
  # Worked example, including the Customer Secret Key step and OpenTofu's state encryption:
  #   docs/state-and-credentials.md
  #
  # backend "s3" {
  #   bucket                      = "your-bucket"
  #   key                         = "oci-k3s-starter/terraform.tfstate"
  #   region                      = "auto"
  #   use_lockfile                = true  # native locking; no DynamoDB table needed
  #   skip_credentials_validation = true  # for non-AWS S3-compatible stores
  #   skip_region_validation      = true
  #   skip_requesting_account_id  = true
  #   skip_s3_checksum            = true
  # }

  # ── STATE ENCRYPTION — off by default. ─────────────────────────────────────────
  # State is not secret-free: the generated Grafana admin password and the console's
  # private key land in it in cleartext, whether it lives locally or in a bucket. When
  # enabled, OpenTofu encrypts state and plan files at rest with AES-GCM, the key derived
  # from a passphrase you supply.
  #
  # The encryption block itself does NOT live in this file. It lives in
  # state-encryption.tf, which does not exist until scripts/enable-state-encryption.sh
  # creates it. That is deliberate: the block must not be present at all when there is no
  # passphrase, or OpenTofu crashes on the null value — a fresh clone must work with
  # nothing set. See docs/state-and-credentials.md and the script.
  #
  # ⚠ LOSE THE PASSPHRASE AND THE STATE IS GONE. Keep it in a password manager before
  # you enable this — there is no recovery.

  required_providers {
    oci = {
      source = "oracle/oci"
      # Pinned to the 8.x minor. The OCI provider ships constantly — a floating major
      # would break you eventually, and it would break you on a day you were doing
      # something else.
      version = "~> 8.27"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.9"
    }
    tls = {
      source = "hashicorp/tls"
      # Generates the RSA keypair for the serial console. NEEDED, not incidental:
      # OCI's instance console connection accepts RSA ONLY. Handing it a modern
      # ed25519 key fails outright with
      #   400-InvalidParameter, Invalid ssh public key type "ssh-ed25519"
      # so the key is generated here rather than asking you to keep an RSA key around
      # for one purpose you hope never to need.
      version = "~> 4.1"
    }
    cloudflare = {
      source = "cloudflare/cloudflare"
      # Only used when enable_cloudflare = true (rung 2). Declared unconditionally
      # because required_providers cannot be made conditional — the provider is simply
      # never configured or called when the toggle is off.
      version = "~> 5.21"
    }
  }
}
