# Rung 1 — a box running your container

**You need:** an Oracle Cloud account. Nothing else — no domain, no DNS, no tokens to
create, no repositories to prepare.

At the end of this you have a free ARM server running Kubernetes, with Argo CD watching a
Git repo, reachable from your laptop.

---

## 1. Get the tools

You need three: **OpenTofu** (builds the box), the **OCI CLI** (browser login only), and
**kubectl** (talks to the cluster).

**macOS**

```bash
brew install opentofu oci-cli kubernetes-cli
```

**Windows** — PowerShell, no admin needed for winget

```powershell
winget install OpenTofu.Tofu
winget install Kubernetes.kubectl
# the OCI CLI has its own installer:
powershell -NoProfile -ExecutionPolicy Bypass -Command `
  "iex ((New-Object Net.WebClient).DownloadString('https://raw.githubusercontent.com/oracle/oci-cli/master/scripts/install/install.ps1'))"
```

**Linux**

```bash
# OpenTofu: https://opentofu.org/docs/intro/install/
curl -fsSL https://raw.githubusercontent.com/oracle/oci-cli/master/scripts/install/install.sh | bash
```

> **Windows users: everything here works in PowerShell**, and every command in these docs
> that differs is given in both forms. You do **not** need WSL — though if you already have
> it, using the Linux instructions inside WSL is completely fine and often smoother, since
> `ssh` and `kubectl` behave identically to everyone else's.
>
> ⚠ One thing to get right: **use PowerShell, not the old `cmd.exe`.** The examples use
> PowerShell quoting, and `cmd` handles quotes differently enough to produce confusing
> errors.

## 2. Log in with a browser

```bash
oci session authenticate
```

It asks for your region, opens a browser, you log in, and it writes a short-lived token to
a profile in `~/.oci/config`. **Remember the profile name you type** — it goes in
`terraform.tfvars` below.

When it expires:

```bash
oci session refresh --profile <name>
```

> **Why not an API key?** The usual Oracle guide has you generate an RSA key, upload the
> public half, copy a fingerprint, find two OCIDs, and leave a `.pem` in `~/.oci` forever.
> That file is the thing that leaks — it has no expiry and no owner. A session dies on its
> own. This is one of the rare cases where the safer path is also the shorter one.
>
> For CI, where there is no browser, set `oci_auth = "APIKey"` and supply the key —
> preferably via `TF_VAR_oci_private_key` in the environment rather than a file.

## 3. Fill in three values

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
```

| value | where to find it |
|---|---|
| `region` | top-right in the OCI console. **Must be your home region** — Always Free only exists there, and it is fixed at signup |
| `compartment_ocid` | Identity → Compartments. Your tenancy OCID (the root compartment) is a fine answer |
| `ssh_public_key` | `cat ~/.ssh/id_ed25519.pub`, or use `file("~/.ssh/id_ed25519.pub")` |

Also set `oci_config_profile` to the profile name from step 2 if you did not call it
`DEFAULT`.

## 4. Apply

```bash
tofu init
tofu apply
```

### ⚠ Expect "Out of host capacity" on your first try

This is the single most common thing that goes wrong, **it is not your configuration**,
and it is not permanent. Free ARM capacity is genuinely scarce in popular regions.

Things worth knowing:

- Oracle reports it two different ways — a clean `OutOfHostCapacity`, or a generic
  `500-InternalError` whose message merely says "Out of host capacity". Same problem.
- Capacity is tracked **per availability domain**, so a bare retry can keep landing on the
  same full rack. Trying at different times of day genuinely helps.
- `LaunchInstance` is rate-limited on purpose to discourage tight polling. Retry every few
  minutes, and back off when you get a 429.
- Some people get it in minutes; some need a day of retrying. Neither means you did
  anything wrong.

## 5. Get in

**The short way** — fetches the kubeconfig and opens every UI at once:

```bash
./scripts/connect.sh            # macOS, Linux, WSL, Git Bash
```
```powershell
./scripts/connect.ps1           # Windows PowerShell
```

**Or by hand.** The kubeconfig on the box points at `127.0.0.1`, which is correct *there*
and useless from your laptop, so it has to be rewritten:

```bash
ssh ubuntu@<ip> 'sudo cat /etc/rancher/k3s/k3s.yaml' \
  | sed 's/127.0.0.1/<ip>/' > kubeconfig
export KUBECONFIG=$PWD/kubeconfig
```
```powershell
(ssh ubuntu@<ip> 'sudo cat /etc/rancher/k3s/k3s.yaml') -replace '127\.0\.0\.1','<ip>' |
  Set-Content kubeconfig
$env:KUBECONFIG = "$PWD\kubeconfig"
```

```bash
kubectl get nodes
kubectl get pods -A
```

> The login user is **`ubuntu`** — not `root`, and not `opc` (that is Oracle Linux).

> The default `gitops_repo_url` is this repo, which is public, so there is nothing to
> configure here. It becomes something to think about at [rung 3](rung-3-your-app.md), when
> you point Argo at *your* repo — Argo gets no credentials at first boot, so a private one
> needs a step.

### If the cluster is not there yet, wait

The bootstrap runs at first boot **and then every 15 minutes** until it succeeds. That is
deliberate: first boot is the least reliable moment in a machine's life — DNS may not be
up, a mirror may be slow, GitHub may rate-limit you. A one-shot script that fails at minute
two leaves a box that looks perfectly healthy and is simply empty.

Watch it:

```bash
ssh ubuntu@<ip> 'sudo journalctl -u k3s-starter-bootstrap -f'
```

## 6. Look at Argo CD

```bash
kubectl -n argocd port-forward svc/argocd-server 8080:443
# then https://localhost:8080  — user: admin
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d
```
```powershell
kubectl -n argocd port-forward svc/argocd-server 8080:443
# there is no `base64` on Windows; .NET does the decode
$b64 = kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}'
[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b64))
```

Change that password and delete the Secret once you are in.

---

## What just happened

```
tofu apply
   └── OCI: VCN, subnet, security list (SSH in, everything out), ARM instance
         └── cloud-init, once, at first boot
               ├── iptables rules INSERTED ahead of Oracle's REJECT
               ├── k3s          (traefik disabled — you are not using it yet)
               ├── Argo CD
               └── the root Application → this repo's kubernetes/applications
                     └── from here on, Git is in charge
```

Nothing else installs applications. Two sources of truth is how a cluster starts
disagreeing with its own description.

## The way back in, before you need it

The box has a **serial console** — a connection to its serial port through Oracle's own
endpoint. It does not traverse your network, ignores the security list, and works when
sshd is dead and k3s is wedged.

It is created automatically, and it is free. **Use it once now, while nothing is broken**,
so that you know it works:

```bash
tofu output -raw console_private_key > /tmp/console_key && chmod 600 /tmp/console_key
tofu output console_connection_id
```

Then follow the connect string from the OCI console UI (Instance → Console connection).

> An untested recovery path is a hypothesis, not a door. This is also why
> `ssh_allowed_cidr` still defaults to the whole internet: **do not narrow it until you
> have proven you have another way in.** Key-only auth makes the scans in your logs noise
> rather than danger.

## Next

- Real URLs instead of `port-forward` → [rung 2](rung-2-real-urls.md)
- Deploy your own app → [rung 3](rung-3-your-app.md)
- What this costs and what is left for your app → [cost and limits](cost-and-limits.md)
- Something is broken → [troubleshooting](troubleshooting.md)
