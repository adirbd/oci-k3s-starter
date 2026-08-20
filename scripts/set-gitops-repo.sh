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
# IT ALSO EDITS THE CHILD APPLICATIONS IN THIS CHECKOUT. Some Applications under
# kubernetes/ source this repo themselves (the dashboard, the cloudflared secret), and
# they carry their own repoURL. Pointing only the root app at your fork leaves them
# pulling from upstream: your edits never deploy, and upstream pushes keep syncing into
# your cluster with prune enabled. They are files in git — Argo's selfHeal would revert
# a live patch within minutes — so the fix is made here and takes effect when you push.
#
#   ./scripts/set-gitops-repo.sh https://github.com/you/oci-k3s-starter.git
#   ./scripts/set-gitops-repo.sh https://github.com/you/cluster.git kubernetes/applications
set -euo pipefail

TF="${TF:-tofu}"; command -v "$TF" >/dev/null 2>&1 || TF=terraform

REPO="${1:?usage: set-gitops-repo.sh <repo-url> [path] [instance-ip]}"
PATH_IN_REPO="${2:-kubernetes/applications}"
IP="${3:-$(cd "$(dirname "$0")/../terraform" && "$TF" output -raw public_ip)}"
SSH_USER="${SSH_USER:-ubuntu}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

echo "pointing Argo CD at:"
echo "  repo: $REPO"
echo "  path: $PATH_IN_REPO"
echo "  box:  $IP"
echo

# ── the child Applications, in this checkout ──────────────────────────────────────
# Only Applications sourcing THIS repo are touched: they have a `path:` into it. Helm
# chart sources have `chart:` instead, and their repoURL must stay what it is.
echo "── child Applications that source this repo"
changed=0
for f in "$REPO_ROOT"/kubernetes/applications/*.yaml "$REPO_ROOT"/kubernetes/optional/*.yaml; do
    [ -f "$f" ] || continue
    grep -qE '^[[:space:]]*path: kubernetes/' "$f" || continue
    grep -qF "repoURL: $REPO" "$f" && continue
    sed -i.bak "s|repoURL: .*|repoURL: $REPO|" "$f" && rm -f "$f.bak"
    echo "  updated ${f#"$REPO_ROOT"/}"
    changed=1
done
[ "$changed" -eq 1 ] || echo "  already pointing at $REPO — nothing to change"
echo

# ── the root Application, on the box ──────────────────────────────────────────────
echo "── root Application on the box"
ssh "$SSH_USER@$IP" "sudo sed -i \
    -e 's|repoURL: .*|repoURL: $REPO|' \
    -e 's|path: .*|path: $PATH_IN_REPO|' \
    /etc/k3s-starter/root-application.yaml && \
  sudo systemctl start k3s-starter-bootstrap"

echo
echo "applied. Argo is now watching $REPO."
echo "Confirm with:"
echo "  kubectl -n argocd get application root -o jsonpath='{.spec.source}' | jq"
if [ "$changed" -eq 1 ]; then
    echo
    echo "⚠ The child Application edits above are LOCAL. Argo reads them from git, so:"
    echo "  git add kubernetes && git commit -m 'point Argo CD at $REPO' && git push"
fi
echo
echo "⚠ Also update terraform.tfvars so a REBUILD uses the same value:"
echo "  gitops_repo_url  = \"$REPO\""
echo "  gitops_repo_path = \"$PATH_IN_REPO\""
