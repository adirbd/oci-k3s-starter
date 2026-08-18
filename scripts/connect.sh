#!/usr/bin/env bash
# Fetch the kubeconfig and open every UI at once. macOS / Linux / WSL / Git Bash.
#
# The dashboards are only reachable via port-forward until rung 2, and remembering four
# incantations is exactly the kind of friction that makes people stop using a thing.
set -euo pipefail

IP="${1:-$(cd "$(dirname "$0")/../terraform" && tofu output -raw public_ip)}"
KUBECONFIG_PATH="${KUBECONFIG_PATH:-$(cd "$(dirname "$0")/.." && pwd)/kubeconfig}"

if [ ! -f "$KUBECONFIG_PATH" ]; then
    echo "fetching kubeconfig from $IP"
    # The server address in k3s.yaml is 127.0.0.1, which is correct ON the box and useless
    # from here.
    ssh "ubuntu@$IP" 'sudo cat /etc/rancher/k3s/k3s.yaml' \
        | sed "s/127.0.0.1/$IP/" > "$KUBECONFIG_PATH"
    chmod 600 "$KUBECONFIG_PATH"
fi
export KUBECONFIG="$KUBECONFIG_PATH"

kubectl get nodes || { echo "cluster not reachable yet — see docs/troubleshooting.md"; exit 1; }

echo
echo "opening port-forwards (ctrl-c to stop all):"
echo "  Homepage   http://localhost:3000"
echo "  Argo CD    https://localhost:8080   (user: admin)"
echo "  Grafana    http://localhost:3001    (admin/admin)"
echo "  podinfo    http://localhost:9898"
echo
echo "Argo CD password:"
kubectl -n argocd get secret argocd-initial-admin-secret \
    -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || echo "(not created yet)"
echo; echo

trap 'kill 0' EXIT
kubectl -n homepage      port-forward svc/homepage 3000:3000        >/dev/null 2>&1 &
kubectl -n argocd        port-forward svc/argocd-server 8080:443    >/dev/null 2>&1 &
kubectl -n observability port-forward svc/vm-stack-grafana 3001:80  >/dev/null 2>&1 &
kubectl -n sample        port-forward svc/sample-podinfo 9898:9898  >/dev/null 2>&1 &
wait
