#!/usr/bin/env bash
# Encrypt Terraform state and plan files at rest, in one command.
#
# WHY. State is not secret-free — the generated Grafana admin password and the console's
# private key land in it in cleartext, whether the file lives on your laptop or in a
# bucket. This writes an `encryption` block into state-encryption.tf and re-applies, so
# state and plan files are encrypted at rest with AES-GCM, keyed from a passphrase you
# supply. A stolen state file becomes a file, not a credential dump.
#
#   export TF_VAR_state_passphrase='...'     # 16+ chars, FIRST
#   ./scripts/enable-state-encryption.sh
#
# ⚠ LOSE THE PASSPHRASE AND THE STATE IS GONE. Put it in the same password manager as
# everything else BEFORE you run this. There is no recovery.
#
# ⚠ WHY A SEPARATE FILE. The encryption block must NOT exist when there is no passphrase:
# OpenTofu 1.12 crashes (a panic, not an error) if a pbkdf2 key provider is handed a null
# passphrase. state-encryption.tf is therefore created only by this script, after it has
# confirmed the passphrase is in the environment — so a fresh clone, with nothing set,
# has no encryption block at all and works normally.
set -euo pipefail
cd "$(dirname "$0")/../terraform"

TF="${TF:-tofu}"; command -v "$TF" >/dev/null 2>&1 || TF=terraform

if [ -z "${TF_VAR_state_passphrase:-}" ]; then
    cat <<'MSG'
  TF_VAR_state_passphrase is not set, and it is required: it is the passphrase that
  derives the key encrypting your state. Set it in the environment first:

      export TF_VAR_state_passphrase='...'    # then re-run this script

  It is read only from the environment (or the gitignored terraform.tfvars), never from
  a committed file. Keep it in your password manager — losing it is losing the state.
MSG
    exit 1
fi

if [ -f state-encryption.tf ]; then
    echo "state encryption is already enabled (terraform/state-encryption.tf exists)."
    echo "Every tofu command needs TF_VAR_state_passphrase in the environment from now on."
    exit 0
fi

echo "── writing terraform/state-encryption.tf"
cat > state-encryption.tf <<'EOF'
# ══════════════════════════════════════════════════════════════════════════════════
#  STATE ENCRYPTION — created by scripts/enable-state-encryption.sh.
#
#  Encrypts state and plan files at rest with AES-GCM, the key derived from
#  TF_VAR_state_passphrase. The `unencrypted` fallback is how an existing plaintext
#  state file is read once and rewritten encrypted (see the script's apply below); it
#  never causes encrypted data to be written. Remove the `unencrypted` method and the
#  two `fallback` blocks if you want to drop it — but the encryption block itself must
#  NOT be removed while state is encrypted, and if this file is deleted the passphrase
#  stops being read and OpenTofu crashes on the null value. See docs/state-and-credentials.md.
# ══════════════════════════════════════════════════════════════════════════════════
terraform {
  encryption {
    key_provider "pbkdf2" "state" {
      passphrase = var.state_passphrase
    }
    method "aes_gcm" "default" {
      keys = key_provider.pbkdf2.state
    }
    method "unencrypted" "migrate" {}
    state {
      method   = method.aes_gcm.default
      fallback {
        method = method.unencrypted.migrate
      }
    }
    plan {
      method   = method.aes_gcm.default
      fallback {
        method = method.unencrypted.migrate
      }
    }
  }
}
EOF

echo "── rewriting state with the encrypted method"
"$TF" apply -auto-approve -input=false

cat <<MSG

done. State and plan files are now encrypted at rest with AES-GCM, keyed from your
passphrase.

⚠ From now on EVERY $TF command needs it in the environment, or OpenTofu crashes:

    export TF_VAR_state_passphrase='...'

Keep that passphrase safe. There is no recovery if it is lost.
MSG
