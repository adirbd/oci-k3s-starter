#!/usr/bin/env bash
# Open an SSH tunnel to the cluster and launch k9s over it. macOS / Linux / WSL / Git Bash.
#
# ⚠ THE TUNNEL IS NOT A CONVENIENCE, IT IS THE ONLY WAY IN.
# The security list opens exactly one inbound port: SSH. The Kubernetes API on 6443 is NOT
# reachable from your laptop, deliberately — exposing a control plane to the internet is a
# bad trade for saving one flag. So k9s (like kubectl) talks to 127.0.0.1:6443 and this
# script forwards that down the SSH connection.
#
# This is also why the kubeconfig is used AS FETCHED, with its `server: https://127.0.0.1:6443`
# intact. An earlier version rewrote it to the public IP, which could not work: the port is
# closed, and k3s's API certificate carries a 127.0.0.1 SAN rather than the public address,
# so even an open port would have failed TLS verification. (Reported as #9.)
#
# One command, then quit k9s and the tunnel closes with it. If you also want the web UIs
# (Argo CD, Grafana, Homepage), run ./scripts/connect.sh instead.
set -euo pipefail

TF="${TF:-tofu}"; command -v "$TF" >/dev/null 2>&1 || TF=terraform

IP="${1:-$(cd "$(dirname "$0")/../terraform" && "$TF" output -raw public_ip)}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KUBECONFIG_PATH="${KUBECONFIG_PATH:-$REPO_ROOT/kubeconfig}"
SSH_USER="${SSH_USER:-ubuntu}"

# The trap is registered BEFORE the fetch: a Ctrl-C during a hung ssh must not leave a
# half-written admin kubeconfig behind (the temp name is also covered by .gitignore).
tmp=""
ssh_pid=""
cleanup() { [ -n "$tmp" ] && rm -f "$tmp"; [ -n "$ssh_pid" ] && kill "$ssh_pid" 2>/dev/null || true; }
trap cleanup EXIT

# -s, not -f: an earlier failed fetch (k3s not up yet) must not leave an empty file
# behind that every later run trusts. Fetch to a temp file and move it only on success,
# so a half-written kubeconfig can never poison the next attempt.
stale=false
if [ ! -s "$KUBECONFIG_PATH" ]; then
    stale=true
elif ! grep -q 'server: https://127.0.0.1:6443' "$KUBECONFIG_PATH" 2>/dev/null; then
    # Positive check, not a wrong-server pattern: public IPs can start with 1 too
    # (130.61.x.x is an OCI range), and a negated character class quietly misses them.
    echo "kubeconfig does not point at 127.0.0.1 (an old version rewrote these) — refetching"
    stale=true
fi
if [ "$stale" = true ]; then
    echo "fetching kubeconfig from $IP"
    tmp="$(mktemp "$KUBECONFIG_PATH.XXXXXX")"
    if ssh "$SSH_USER@$IP" 'sudo cat /etc/rancher/k3s/k3s.yaml' > "$tmp" && [ -s "$tmp" ]; then
        chmod 600 "$tmp"
        mv "$tmp" "$KUBECONFIG_PATH"
        tmp=""
    else
        echo
        echo "could not fetch the kubeconfig — k3s is probably still installing."
        echo "  watch it:   ssh $SSH_USER@$IP 'sudo journalctl -u k3s-starter-bootstrap -f'"
        echo "  then re-run this script."
        exit 1
    fi
fi
export KUBECONFIG="$KUBECONFIG_PATH"

echo "opening SSH tunnel to the Kubernetes API (6443)"
ssh -N -L 6443:127.0.0.1:6443 "$SSH_USER@$IP" &
ssh_pid=$!

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

if ! command -v k9s >/dev/null 2>&1; then
    echo
    echo "k9s is not installed. Get it, then re-run:"
    echo "  brew install derailed/k9s/k9s        # macOS"
    echo "  sudo snap install k9s                # or download from"
    echo "  https://github.com/derailed/k9s/releases"
    echo "the tunnel stays open — press Ctrl-C to stop it."
    wait "$ssh_pid" 2>/dev/null || true
    exit 0
fi

echo
echo "launching k9s (quit k9s to close the tunnel)"
k9s
