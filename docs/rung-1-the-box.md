# Rung 1 — a box running your container

**You need:** an Oracle Cloud account. Nothing else — no domain, no DNS, no tokens to
create, no repositories to prepare.

At the end of this you have a free ARM server running Kubernetes, with Argo CD watching a
Git repo, reachable from your laptop.

---

## 1. Get the tools

Four things: **git** (to get these files), **OpenTofu** (builds the box), the **OCI CLI**
(browser login only), and **kubectl** (talks to the cluster).

**macOS**

```bash
brew install git opentofu oci-cli kubernetes-cli
```

**Windows** — PowerShell, no admin needed for winget

```powershell
winget install Git.Git
winget install OpenTofu.Tofu
winget install Kubernetes.kubectl
# the OCI CLI has its own installer:
powershell -NoProfile -ExecutionPolicy Bypass -Command `
  "iex ((New-Object Net.WebClient).DownloadString('https://raw.githubusercontent.com/oracle/oci-cli/master/scripts/install/install.ps1'))"
```

> ⚠ **Close PowerShell and open a new one afterwards.** `winget` adds these to your PATH,
> but a shell that is already running does not see it — so `tofu` will report
> "not recognized" until you restart the terminal. This confuses everybody once.

**Linux**

```bash
sudo apt install git   # or your package manager's equivalent
# OpenTofu: https://opentofu.org/docs/intro/install/
# kubectl is not in the default apt repos; grab the binary directly:
curl -LO "https://dl.k8s.io/release/$(curl -Ls https://dl.k8s.io/release/stable.txt)/bin/linux/$(dpkg --print-architecture)/kubectl"
sudo install -m 0755 kubectl /usr/local/bin/kubectl && rm kubectl
curl -fsSL https://raw.githubusercontent.com/oracle/oci-cli/master/scripts/install/install.sh | bash
```

Check they all answer:

```bash
git --version && tofu version && kubectl version --client && oci --version
```

## 2. Get these files

**If you only want to look around**, clone this repo:

```bash
git clone https://github.com/adirbd/oci-k3s-starter.git
cd oci-k3s-starter
```

**If you plan to deploy your own app — fork first, then clone your fork.** Use the Fork
button at the top of [the repo](https://github.com/adirbd/oci-k3s-starter), then:

```bash
git clone https://github.com/YOU/oci-k3s-starter.git
cd oci-k3s-starter
```

Forking now rather than later matters: Argo CD is told which repo to watch **at first boot**
and does not re-read it afterwards. See the note in step 4.

> **Windows users: everything here works in PowerShell**, and every command in these docs
> that differs is given in both forms. You do **not** need WSL — though if you already have
> it, using the Linux instructions inside WSL is completely fine and often smoother, since
> `ssh` and `kubectl` behave identically to everyone else's.
>
> ⚠ One thing to get right: **use PowerShell, not the old `cmd.exe`.** The examples use
> PowerShell quoting, and `cmd` handles quotes differently enough to produce confusing
> errors.

## 3. Log in with a browser

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

## 4. Fill in three values

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
```

| value | where to find it |
|---|---|
| `region` | top-right in the OCI console. **Must be your home region** — Always Free only exists there, and it is fixed at signup |
| `compartment_ocid` | Identity → Compartments. Your tenancy OCID (the root compartment) is a fine answer |
| `ssh_public_key` | the key **content**, pasted in — print it with `cat ~/.ssh/id_ed25519.pub`, or `Get-Content ~\.ssh\id_ed25519.pub` on Windows |

Also set `oci_config_profile` to the profile name from step 2 if you did not call it
`DEFAULT`.

> **Planning to deploy your own app? Fork this repo now and add one more line.**
>
> ```hcl
> gitops_repo_url = "https://github.com/YOU/oci-k3s-starter.git"
> ```
>
> `gitops_repo_url` is baked into cloud-init, which runs **once, at first boot** — setting
> it later does nothing to a running box, and you have to edit the live Application instead.
> Two minutes now saves that. Leave it unset if you just want to look around; the default
> points at this repo and deploys the same sample.



## 5. Apply

```bash
tofu init
../scripts/preflight.sh     # or preflight.ps1 — 10 seconds, saves 20 minutes
tofu apply
```

(`../scripts/`, not `./scripts/` — step 4 moved you into `terraform/`. The scripts
themselves work from any directory.)

The preflight checks the things that otherwise fail *late*: a tfvars that will not parse, an
expired OCI session, missing tools. Each failure names its cause and its fix.

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

**There is a script for this** — it retries on a sensible interval and rotates availability
domains, which is what actually changes the answer:

```bash
../scripts/retry-apply.sh           # or retry-apply.ps1 on Windows
```

## 6. Get in

**The short way** — fetches the kubeconfig and opens every UI at once:

```bash
../scripts/connect.sh           # macOS, Linux, WSL, Git Bash
```
```powershell
..\scripts\connect.ps1          # Windows PowerShell
```

### How this reaches the cluster, since nothing is open

The security list opens **one** inbound port: SSH. The Kubernetes API on 6443 is
deliberately **not** reachable from your laptop — a control plane on the public internet is
a bad trade for saving a flag.

So `connect.sh` opens an SSH tunnel (`ssh -N -L 6443:127.0.0.1:6443`) and kubectl talks to
`127.0.0.1:6443` through it. The kubeconfig is used exactly as fetched; its `127.0.0.1` is
correct, not a mistake to be rewritten.

**Or by hand**, which is the same two moves:

```bash
ssh ubuntu@<ip> 'sudo cat /etc/rancher/k3s/k3s.yaml' > kubeconfig
export KUBECONFIG=$PWD/kubeconfig
ssh -N -L 6443:127.0.0.1:6443 ubuntu@<ip> &      # leave this running
```
```powershell
ssh ubuntu@<ip> 'sudo cat /etc/rancher/k3s/k3s.yaml' | Set-Content kubeconfig
$env:KUBECONFIG = "$PWD\kubeconfig"
Start-Process ssh -ArgumentList '-N','-L','6443:127.0.0.1:6443',"ubuntu@<ip>"
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

## 7. Look at Argo CD

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

**Grafana** does not need any of that. Its password is generated by Terraform and delivered
to the cluster at boot, so there is nothing to change and nothing to remember:

```bash
tofu output -raw grafana_admin_password     # user: admin
```

`connect.sh` prints it too. A rebuild produces the *same* password, because it
lives in Terraform state rather than in your head.

---

## What to look at in Grafana

It opens on **Your cluster** — eight panels: CPU, memory and disk on the box, how many pods
are running, CPU and memory by pod, anything *not* running, and recent restarts. That is
deliberately small; it is the set that answers "is everything fine, and if not, what."

The other dashboards are still there under **Dashboards**. `Node Exporter Full` has roughly
two hundred panels and is the right tool when you have a specific question about the host —
and the wrong first impression, which is why it is not the landing page.

To add your own: create a ConfigMap in the `observability` namespace with the label
`grafana_dashboard: "1"` and your dashboard JSON inside. The sidecar imports it within a
minute. `kubernetes/manifests/dashboard/` is a worked example.

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
