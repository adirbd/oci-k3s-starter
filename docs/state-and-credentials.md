# Where state lives, and where your tokens live

Two questions everyone reaches on their second day. Neither has a single right answer, so
here is what each choice costs.

---

## Terraform state

**What is actually in it.** State is not a log of what you did — it is a copy of what
exists, **including values marked sensitive**. In this repo that means the generated Grafana
admin password, the RSA private key for the serial console, and (with rung 2) the tunnel
token. Treat `terraform.tfstate` as a credential file, because it is one.

### Local, the default

Fine for one person on one machine, which is most people running this.

What you are accepting:

- **It is not encrypted.** Anything with read access to the file has those values.
- **There is no locking across machines.** One laptop is fine; a laptop plus CI, or two
  people, is how state gets corrupted.
- **Losing it is expensive.** Not fatal — you can rebuild — but Terraform no longer knows
  the box exists, and you clean up by hand in the console.

`.gitignore` already excludes it. Keep it that way.

### Remote — one command

The obvious home is the account you already have: **Always Free includes 20 GB of object
storage**, and OCI exposes an **S3-compatible** endpoint, so the standard `s3` backend works
with no new vendor, no new bill and no new login.

Terraform cannot create its own backend in one step — a backend has to exist before
`tofu init` — so this does it in two stages and hides the seam:

```hcl
# terraform.tfvars
enable_remote_state = true
oci_user_ocid       = "ocid1.user.oc1..aaaa..."   # Profile menu > your username > OCID
```

```bash
./scripts/enable-remote-state.sh
```

That creates the bucket (versioned, private), generates an S3 **Customer Secret Key**, writes
`backend.hcl`, adds the empty `backend "s3" {}` block to `versions.tf` itself, and runs
`tofu init -migrate-state` — one run, no seam. Leave the backend block alone beforehand:
the script inserts it at the right moment, and stops with instructions if it finds one
already declared by hand.

**Why `oci_user_ocid` is the one thing you have to paste:** a Customer Secret Key belongs to
a user, and a browser session does not tell Terraform which human is driving it. Everything
else — the namespace, the endpoint, the bucket — is looked up or created.

Afterwards, every `tofu` command needs the credentials in the environment:

```bash
export AWS_ACCESS_KEY_ID=$(tofu output -raw state_s3_access_key_id)
export AWS_SECRET_ACCESS_KEY=$(tofu output -raw state_s3_secret_access_key)
```

> ⚠ **Those outputs read the state they unlock.** Once your laptop's copy is gone you need
> another source. **With [rung 4](rung-4-secrets.md) enabled they are also written to OCI
> Vault** as `<instance_name>-terraform-state-s3`, readable from the console on a machine
> that has nothing else — which answers "where do I keep these without a password manager".
> Without rung 4, put them somewhere safe while you still have them.

**Cloudflare R2** works identically (10 GB free) if you would rather keep it there — same
shape, different endpoint, `region = "auto"`, and you create the bucket and token yourself.

### Encrypt it, wherever it lives

Remote does not mean private: the bucket holds the same cleartext secrets. OpenTofu can
encrypt state before it is written, with a passphrase you supply:

```hcl
terraform {
  encryption {
    key_provider "pbkdf2" "passphrase" {
      passphrase = var.state_passphrase   # from TF_VAR_state_passphrase
    }
    method "aes_gcm" "default" {
      keys = key_provider.pbkdf2.passphrase
    }
    state {
      method   = method.aes_gcm.default
      enforced = true
    }
    plan {
      method   = method.aes_gcm.default
      enforced = true
    }
  }
}
```

⚠ **Lose the passphrase and the state is gone.** Put it in the same password manager as
everything else, before you enable this.

---

## Your Cloudflare token

**There is no Cloudflare credential helper for Terraform.** `wrangler` logs in with OAuth
and stores its own token, and `flarectl` is a separate CLI — the Terraform provider reads
neither. So the token has to reach the process yourself.

**And there is no `.env` support either.** Terraform does not read `.env` files natively
and no script in this repo sources one — a token placed there silently never reaches the
provider (a real fork's setup assistant guessed exactly that; preflight now warns about
it). Keep the token out of files entirely: set it in the shell session, ideally pulled
from a password manager as shown below.

### Use the provider's own environment variable

The provider reads **`CLOUDFLARE_API_TOKEN`** natively. `cf_api_token` defaults to `null`
here, so this works with no configuration at all:

```bash
export CLOUDFLARE_API_TOKEN="..."     # macOS, Linux, WSL
```
```powershell
$env:CLOUDFLARE_API_TOKEN = "..."     # Windows
```

Prefer it over `TF_VAR_cf_api_token`: it is the provider's documented convention, it works
with any tooling that talks to Cloudflare, and it keeps the value out of Terraform's
variable machinery entirely.

### Better: fetch it at the start of each session

Do not store it in a file at all — read it from wherever you already keep passwords, so it
lives only in the shell that needs it:

```bash
export CLOUDFLARE_API_TOKEN=$(op read "op://Private/cloudflare/token")        # 1Password
export CLOUDFLARE_API_TOKEN=$(bw get password cloudflare-terraform)          # Bitwarden
export CLOUDFLARE_API_TOKEN=$(security find-generic-password -s cf -w)       # macOS Keychain
export CLOUDFLARE_API_TOKEN=$(pass show cloudflare/terraform)                # pass
```

```powershell
$env:CLOUDFLARE_API_TOKEN = (op read "op://Private/cloudflare/token")
```

The point is not which manager. It is that the token exists in one place you already
protect, and reaches Terraform without ever being written to disk in this repo.

### If you would rather just type it once

`terraform.tfvars` is gitignored, so putting `cf_api_token = "..."` there is not
*dangerous* — it is a plaintext credential on your disk, which is the same posture as most
CLI tools. Know that you have made that choice rather than discovering it later.

**Never** put it in `terraform.tfvars.example`, which *is* committed.

### Scope it properly

Whatever you do with the token, give it only:

- **Zone → DNS → Edit**
- **Account → Cloudflare Tunnel → Edit**
- **Account → Access: Apps and Policies → Edit** (only if using Access)

A token scoped to one zone and three permissions is a much smaller problem than a Global
API Key, which can do anything to every domain you own. There is no reason to use the
latter here.

---

## The same question for OCI

You do not have this problem: rung 1 uses `oci session authenticate`, which produces a
**short-lived** token in `~/.oci`. Nothing to store, nothing to rotate, and it expires on
its own. That is why it is the default rather than the API-key flow —
see [rung 1](rung-1-the-box.md#3-log-in-with-a-browser).

---

## Rotating secrets that leaked through state

If `terraform.tfstate` was ever committed, pushed, or stored somewhere you no longer trust,
treat the secrets inside it as compromised. Here is what to rotate and how.

### Cloudflare tunnel token

The most urgent: this token lets anything join your tunnel.

The tunnel — and therefore its token — is **Terraform-managed**, so rotation is one
command, not a dashboard trip:

```bash
tofu apply -replace='cloudflare_zero_trust_tunnel_cloudflared.main[0]'
```

That issues a new tunnel identity and token, and the same apply updates the DNS records
and (with rung 4) the vault entry. **Do not edit the vault entry by hand** — Terraform
owns it and the next apply puts its own value back.

Then get the new token to the connector. With rung 4:

```bash
kubectl -n cloudflared delete secret cloudflared-token   # ExternalSecret recreates it in seconds
kubectl -n cloudflared rollout restart deployment        # connector reads the token at start
```

Without rung 4, re-run the `cloudflared_secret_command` output, then the same rollout
restart. Expect a brief blip while the connector reconnects.

### Grafana admin password

The password lives in three places that must agree: Terraform state, the file cloud-init
wrote on the box (`/etc/k3s-starter/grafana-admin.yaml`, **re-asserted by the bootstrap
timer every 15 minutes**), and the cluster Secret. Changing only the cluster Secret is
therefore undone within 15 minutes. Rotate at the source instead:

```bash
tofu apply -replace=random_password.grafana_admin
```

That puts a new password in state — but cloud-init runs once, so the box still holds the
old file. Either **rebuild** (`tofu apply -replace=oci_core_instance.main` — the clean
way, if you can spare the capacity gamble), or update the file in place:

```bash
NEW=$(tofu output -raw grafana_admin_password)
ssh ubuntu@<ip> "sudo sed -i 's|admin-password: .*|admin-password: \"$NEW\"|' /etc/k3s-starter/grafana-admin.yaml \
  && sudo systemctl start k3s-starter-bootstrap"
kubectl -n observability rollout restart deployment vm-stack-grafana
```

### Console RSA key

Generated by Terraform. The keypair is only useful for OCI serial console access.

```bash
tofu apply -replace=tls_private_key.console
```

Existing console sessions break (they used the old key). Download the new one:

```bash
tofu output -raw console_private_key > /tmp/console_key && chmod 600 /tmp/console_key
```

### Terraform state S3 credentials

The Customer Secret Key used by the `s3` backend. Generate the new one **first**, then
delete the old — the other order locks you out of your own state mid-rotation:

```bash
tofu apply -replace=oci_identity_customer_secret_key.state
export AWS_ACCESS_KEY_ID=$(tofu output -raw state_s3_access_key_id)
export AWS_SECRET_ACCESS_KEY=$(tofu output -raw state_s3_secret_access_key)
```

Then remove the old key in the console (Identity → Users → your user → Customer secret
keys) if Terraform's replace left it behind.
