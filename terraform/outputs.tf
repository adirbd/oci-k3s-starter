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
