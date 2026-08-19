output "public_ip" {
  description = "Public IP of the instance."
  value       = oci_core_instance.main.public_ip
}

output "ssh" {
  description = "Copy-paste SSH command. Ubuntu images log in as `ubuntu`, not root or opc."
  value       = "ssh ubuntu@${oci_core_instance.main.public_ip}"
}

output "kubeconfig_command" {
  description = "Fetch the cluster's kubeconfig to your machine. The sed rewrites the server address from 127.0.0.1 (correct on the box, useless from your laptop) to the public IP."
  value       = "ssh ubuntu@${oci_core_instance.main.public_ip} 'sudo cat /etc/rancher/k3s/k3s.yaml' | sed 's/127.0.0.1/${oci_core_instance.main.public_ip}/' > kubeconfig && export KUBECONFIG=$PWD/kubeconfig"
}

output "argocd_password_command" {
  description = "Argo CD's initial admin password. It lives in a Secret that Argo creates on first install; change it and delete the Secret once you are in."
  value       = "kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
}

output "next_steps" {
  description = "What to do once apply finishes."
  value       = <<-EOT
    1. Fetch kubeconfig:   see the `kubeconfig_command` output
    2. Watch it come up:   kubectl get pods -A -w
       (the bootstrap timer runs every 15 min, so a slow first boot catches up on its own)
    3. Argo CD UI:         kubectl -n argocd port-forward svc/argocd-server 8080:443
                           then https://localhost:8080  (user: admin)
    4. Password:           see the `argocd_password_command` output

    Add real hostnames instead of port-forward: docs/rung-2-real-urls.md
  EOT
}

# ── The break-glass door ──────────────────────────────────────────────────────────

output "console_connection_id" {
  description = "OCID of the serial console connection. Use it from the OCI console UI, or with the OCI CLI, when SSH is dead."
  value       = oci_core_instance_console_connection.main.id
}

output "console_private_key" {
  description = "PRIVATE key for the serial console (RSA — OCI accepts nothing else). Read it with `tofu output -raw console_private_key` at the moment you need it; do not save a copy next to the state file."
  value       = tls_private_key.console.private_key_openssh
  sensitive   = true
}

# ── Rung 2 outputs (null unless enable_cloudflare = true) ─────────────────────────

output "urls" {
  description = "The hostnames the tunnel serves."
  value = var.enable_cloudflare ? [
    for name, _ in var.tunnel_routes : "https://${name}.${var.domain}"
  ] : []
}

output "cloudflared_secret_command" {
  description = "Create the Kubernetes Secret the connector reads, on macOS/Linux/WSL. Windows PowerShell needs a different form — see cloudflared_secret_command_windows. Better still, enable rung 4 and skip this entirely."
  # Creates the namespace first: the Secret has to exist BEFORE the connector pod starts,
  # but the namespace is normally made by Argo when the app syncs — so doing it here breaks
  # the ordering problem without needing a Kubernetes provider in this root module.
  value = var.enable_cloudflare ? join(" ", [
    "kubectl create namespace cloudflared --dry-run=client -o yaml | kubectl apply -f - &&",
    "tofu output -raw cloudflared_token |",
    "kubectl create secret generic cloudflared-token",
    "-n cloudflared --from-file=token=/dev/stdin",
    "--dry-run=client -o yaml | kubectl apply -f -",
  ]) : "(set enable_cloudflare = true first)"
}

output "cloudflared_secret_command_windows" {
  description = "The same thing for Windows PowerShell. /dev/stdin does not exist there, so the token goes via a variable instead of a pipe — it is briefly visible to `ps`, which is an acceptable trade on your own laptop and another reason rung 4 is the better answer."
  value = var.enable_cloudflare ? join(" ", [
    "kubectl create namespace cloudflared --dry-run=client -o yaml | kubectl apply -f -;",
    "$t = tofu output -raw cloudflared_token;",
    "kubectl create secret generic cloudflared-token -n cloudflared",
    "--from-literal=token=$t --dry-run=client -o yaml | kubectl apply -f -",
  ]) : "(set enable_cloudflare = true first)"
}

output "cloudflared_token" {
  description = "The connector token. Sensitive: it is the credential that lets anything join your tunnel. Read it only through the command above."
  value       = var.enable_cloudflare ? data.cloudflare_zero_trust_tunnel_cloudflared_token.main[0].token : null
  sensitive   = true
}

output "access_status" {
  description = "Whether a login sits in front of these hostnames."
  value = !var.enable_cloudflare ? "n/a — Cloudflare disabled" : (
    length(var.access_allowed_emails) > 0
    ? "protected by Cloudflare Access (${length(var.access_allowed_emails)} allowed address(es))"
    : "⚠ PUBLIC — no access_allowed_emails set, so these hostnames are open to the internet"
  )
}

# ── Rung 4 outputs ────────────────────────────────────────────────────────────────

output "vault_ocid" {
  description = "OCID of the vault. An identifier, not a secret — you need it to store secrets in the right place."
  value       = var.enable_vault ? oci_kms_vault.main[0].id : null
}

output "clustersecretstore_manifest" {
  description = "The ClusterSecretStore, filled in with your vault and region. Apply it with: tofu output -raw clustersecretstore_manifest | kubectl apply -f -"
  value = var.enable_vault ? yamlencode({
    apiVersion = "external-secrets.io/v1"
    kind       = "ClusterSecretStore"
    metadata   = { name = "oci-vault" }
    spec = {
      provider = {
        oracle = {
          vault  = oci_kms_vault.main[0].id
          region = var.region
          # No auth block, no serviceAccountRef, no credential anywhere. ESO calls the
          # instance metadata service from the pod; OCI recognises the machine; the IAM
          # policy decides what it may read. Rotating a credential is impossible because
          # there is not one.
          principalType = "InstancePrincipal"
        }
      }
    }
  }) : "(set enable_vault = true first)"
}

output "vault_secret_names" {
  description = "Names of the entries Terraform put in the vault. These are what an ExternalSecret's remoteRef.key must match — they follow instance_name, so they change if you rename the box."
  value = var.enable_vault ? compact([
    var.enable_cloudflare ? oci_vault_secret.cloudflared_token[0].secret_name : "",
  ]) : []
}

output "grafana_admin_password" {
  description = "Grafana's admin password, generated rather than admin/admin. Read it with `tofu output -raw grafana_admin_password`. The user is `admin`."
  value       = random_password.grafana_admin.result
  sensitive   = true
}

output "access_aud_tags" {
  description = "The AUD tag of each Access application, keyed by hostname. Grafana needs its own to verify Access's JWT — see rung 2, 'Log into Grafana with the same identity'."
  value = {
    for k, app in cloudflare_zero_trust_access_application.protected : k => app.aud
  }
}
