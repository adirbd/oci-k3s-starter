#!/usr/bin/env bash
# Open an SSH tunnel to the cluster, then every UI at once. macOS / Linux / WSL / Git Bash.
#
# ⚠ THE TUNNEL IS NOT A CONVENIENCE, IT IS THE ONLY WAY IN.
# The security list opens exactly one inbound port: SSH. The Kubernetes API on 6443 is NOT
# reachable from your laptop, deliberately — exposing a control plane to the internet is a
# bad trade for saving one flag. So kubectl talks to 127.0.0.1:6443 and this script forwards
# that down the SSH connection.
#
# This is also why the kubeconfig is used AS FETCHED, with its `server: https://127.0.0.1:6443`
# intact. An earlier version rewrote it to the public IP, which could not work: the port is
# closed, and k3s's API certificate carries a 127.0.0.1 SAN rather than the public address,
# so even an open port would have failed TLS verification. (Reported as #9.)
set -euo pipefail

IP="${1:-$(cd "$(dirname "$0")/../terraform" && tofu output -raw public_ip)}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KUBECONFIG_PATH="${KUBECONFIG_PATH:-$REPO_ROOT/kubeconfig}"
SSH_USER="${SSH_USER:-ubuntu}"

if [ ! -f "$KUBECONFIG_PATH" ]; then
    echo "fetching kubeconfig from $IP"
    ssh "$SSH_USER@$IP" 'sudo cat /etc/rancher/k3s/k3s.yaml' > "$KUBECONFIG_PATH"
    chmod 600 "$KUBECONFIG_PATH"
fi
export KUBECONFIG="$KUBECONFIG_PATH"

cleanup() { kill 0 2>/dev/null || true; }
trap cleanup EXIT

echo "opening SSH tunnel to the Kubernetes API (6443)"
ssh -N -L 6443:127.0.0.1:6443 "$SSH_USER@$IP" &

# Wait for the tunnel rather than sleeping a guessed amount: a slow link should not look
# like a broken cluster.
for _ in $(seq 1 30); do
    kubectl get --raw /readyz >/dev/null 2>&1 && break
    sleep 1
done

if ! kubectl get nodes >/dev/null 2>&1; then
    echo
    echo "the cluster is not answering through the tunnel."
    echo "  - is the box finished booting?   ssh $SSH_USER@$IP 'sudo journalctl -u k3s-starter-bootstrap -n 30'"
    echo "  - see docs/troubleshooting.md"
    exit 1
fi

kubectl get nodes

echo
echo "opening port-forwards (ctrl-c to stop everything):"
echo "  Homepage   http://localhost:3000"
echo "  Argo CD    https://localhost:8080   (user: admin)"
echo "  Grafana    http://localhost:3001    (user admin — password below)"
echo "  podinfo    http://localhost:9898"
echo
echo "Argo CD password:"
kubectl -n argocd get secret argocd-initial-admin-secret \
    -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || echo "(not created yet)"
echo
echo "Grafana password (user: admin):"
kubectl -n observability get secret grafana-admin \
    -o jsonpath='{.data.admin-password}' 2>/dev/null | base64 -d \
    || echo "(not created yet — or run: tofu output -raw grafana_admin_password)"
echo; echo

kubectl -n homepage      port-forward svc/homepage 3000:3000        >/dev/null 2>&1 &
kubectl -n argocd        port-forward svc/argocd-server 8080:443    >/dev/null 2>&1 &
kubectl -n observability port-forward svc/vm-stack-grafana 3001:80  >/dev/null 2>&1 &
kubectl -n sample        port-forward svc/sample-podinfo 9898:9898  >/dev/null 2>&1 &
wait
