#!/usr/bin/env bash
# Point Argo CD at a different repo, without hand-editing a live object.
#
# WHY THIS EXISTS (#13). gitops_repo_url is baked into cloud-init, which runs once at first
# boot, so changing it in terraform.tfvars does nothing to a running box. The old advice was
# `kubectl patch application root --type=merge -p '{...}'` over SSH — JSON quoting that is
# easy to mangle, on the wrong machine, and forgotten by morning.
#
# The bootstrap now re-applies /etc/k3s-starter/root-application.yaml on EVERY run, so that
# file is the source of truth on the box. This edits it and kicks the timer.
#
#   ./scripts/set-gitops-repo.sh https://github.com/you/oci-k3s-starter.git
#   ./scripts/set-gitops-repo.sh https://github.com/you/cluster.git kubernetes/applications
set -euo pipefail

REPO="${1:?usage: set-gitops-repo.sh <repo-url> [path] [instance-ip]}"
PATH_IN_REPO="${2:-kubernetes/applications}"
IP="${3:-$(cd "$(dirname "$0")/../terraform" && tofu output -raw public_ip)}"
SSH_USER="${SSH_USER:-ubuntu}"

echo "pointing Argo CD at:"
echo "  repo: $REPO"
echo "  path: $PATH_IN_REPO"
echo "  box:  $IP"
echo

ssh "$SSH_USER@$IP" "sudo sed -i \
    -e 's|repoURL: .*|repoURL: $REPO|' \
    -e 's|path: .*|path: $PATH_IN_REPO|' \
    /etc/k3s-starter/root-application.yaml && \
  sudo systemctl start k3s-starter-bootstrap"

echo
echo "applied. Argo is now watching $REPO."
echo "Confirm with:"
echo "  kubectl -n argocd get application root -o jsonpath='{.spec.source}' | jq"
echo
echo "⚠ Also update terraform.tfvars so a REBUILD uses the same value:"
echo "  gitops_repo_url  = \"$REPO\""
echo "  gitops_repo_path = \"$PATH_IN_REPO\""
