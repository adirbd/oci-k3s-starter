# Troubleshooting

Ordered by how often it happens.

---

## "Out of host capacity" on apply

**Not your fault, not permanent.** Free ARM capacity is scarce in popular regions.

- Oracle reports it two ways: a clean `OutOfHostCapacity`, or a generic
  `500-InternalError` whose message reads "Out of host capacity". Same thing.
- Capacity is tracked **per availability domain**, so a bare retry can keep hitting the
  same full rack. Different times of day genuinely help.
- `LaunchInstance` is rate-limited to discourage polling — retry every few minutes and
  back off on 429.

**Do not sit there re-running it by hand:**

```bash
./scripts/retry-apply.sh            # macOS, Linux, WSL, Git Bash
./scripts/retry-apply.ps1           # Windows PowerShell
```

It asks every five minutes, **rotates availability domains** (capacity is per-AD, so a
different AD is a genuinely different question), backs off exponentially if Oracle throttles
it, and stops immediately on anything that is *not* a capacity failure — so an expired
session or a bad variable surfaces instead of looping all night.

Asking for less also helps, and a 1-core box is a real cluster:

```bash
./scripts/retry-apply.sh -var ocpus=1 -var memory_gb=6
```

> **Never terminate a working A1 instance to "free up allowance" for a new one.** The next
> launch is not guaranteed to succeed, and people have ended up with zero instances doing
> exactly this. Build the replacement first.

## `tofu apply` fails with an authentication or 401 error

**Almost always an expired session.** `oci session authenticate` issues a SHORT-LIVED
token — it does not last the week. If it worked yesterday and not today, that is this:

```bash
oci session refresh --profile <name>
```

If refresh also fails, the session is past renewing — run `oci session authenticate` again.

**The other cause is the profile name.** `oci session authenticate` prompts you for one, and
most people type something memorable rather than `DEFAULT`. Whatever you typed has to be in
`terraform.tfvars`:

```hcl
oci_config_profile = "the-name-you-typed"
```

Check which profiles exist with `cat ~/.oci/config | grep '^\['`. The error you get for a
wrong profile does not mention profiles.

## The box is up but there is no cluster

The bootstrap re-runs every 15 minutes until it succeeds, so first check whether it is
simply still working:

```bash
ssh ubuntu@<ip> 'systemctl status k3s-starter-bootstrap.timer'
ssh ubuntu@<ip> 'sudo journalctl -u k3s-starter-bootstrap --no-pager | tail -50'
```

Force a run instead of waiting:

```bash
ssh ubuntu@<ip> 'sudo systemctl start k3s-starter-bootstrap'
```

## Pods cannot reach each other, CoreDNS times out, nothing explains it

**This is the OCI-specific one, and it looks exactly like a k3s bug.**

OCI's Ubuntu images are not stock Ubuntu: they ship a populated `/etc/iptables/rules.v4`
with a `REJECT` at the end of `INPUT`. Pod and service traffic hits it and dies. Your VCN
security list looks fine, because the problem is inside the host.

Check whether the accept rules are present:

```bash
ssh ubuntu@<ip> 'sudo iptables -S INPUT | head'
# you should see the k3s pod/service CIDR ACCEPTs at the TOP, before any REJECT
```

Re-apply them if missing:

```bash
sudo iptables -I INPUT 1 -s 10.42.0.0/16 -j ACCEPT
sudo iptables -I INPUT 1 -s 10.43.0.0/16 -j ACCEPT
sudo netfilter-persistent save
```

> ⚠ **Do not `iptables -F`.** Every forum answer says to, and it will appear to work. Those
> rules also carry the return path for the instance metadata service (169.254.169.254) and,
> on some shapes, the iSCSI attachment for the boot volume — the disk you are running from.

## Small requests work, big ones hang forever

Path-MTU discovery is broken — something is dropping ICMP `fragmentation-needed`. `curl` on
a small page succeeds, `git clone` or an image pull hangs with no error.

The security list here allows ICMP type 3 code 4 for exactly this reason. If you edited it,
put that rule back.

## `tofu apply` wants to destroy and recreate the instance

Look at what changed. If it is `metadata`, that is cloud-init — and the OCI provider treats
*any* metadata change as ForceNew.

`instance.tf` carries `ignore_changes = [metadata]` to stop this happening by surprise, so
if you are seeing it, that guard was removed or you asked for it explicitly.

**cloud-init runs once, at first boot.** Pushing new user_data to a live box changes nothing
on it regardless. To genuinely deploy new bootstrap, rebuild on purpose:

```bash
tofu apply -replace=oci_core_instance.main
```

…and only when you are willing to gamble the capacity to get the box back.

## Terraform says my SSH key is invalid

The variable wants the **public** key as content:

```hcl
ssh_public_key = file("~/.ssh/id_ed25519.pub")   # note .pub
```

If it starts with `-----BEGIN`, that is the private half. Do not put that there.

## The serial console rejects my key

**OCI's console connection accepts RSA only.** An ed25519 key fails with
`400-InvalidParameter, Invalid ssh public key type "ssh-ed25519"`.

You do not need to solve this — an RSA keypair is generated for you:

```bash
tofu output -raw console_private_key > /tmp/console_key && chmod 600 /tmp/console_key
```

## I locked myself out of SSH

In order:

1. **Serial console** — ignores the security list, sshd and k3s entirely. See above.
2. **Widen the security list** temporarily: set `ssh_allowed_cidr = "0.0.0.0/0"` and apply.
   Key-only auth means this is survivable while you fix things.
3. **Rebuild.** Everything here is declared; `tofu apply -replace=oci_core_instance.main`
   gets you a fresh box. This is only cheap if you were not storing state on it.

## kubectl says the connection is refused

The kubeconfig on the box points at `127.0.0.1`, which is correct *there* and useless from
your laptop. Rewrite it:

```bash
ssh ubuntu@<ip> 'sudo cat /etc/rancher/k3s/k3s.yaml' | sed 's/127.0.0.1/<ip>/' > kubeconfig
```

Note this reaches the API server over the public internet. Fine for one developer with a
narrow `ssh_allowed_cidr`; not what you want long-term. Rung 2 and Tailscale both fix it.

## Argo is up but no apps appear at all

Look at the root Application first:

```bash
kubectl -n argocd get application root -o jsonpath='{.status.conditions}' | jq
```

**`repository not found` / `authentication required`** means Argo cannot clone the repo. It
is given **no credentials at first boot**, so `gitops_repo_url` has to be cloneable
anonymously.

Almost always this is because you pointed it at **your own repo, which is private** — the
starter's default is public and works untouched. The symptom is the confusing part: a
healthy cluster, a green apply, and nothing in it.

Fix: make the repo public, or give Argo credentials
([rung 3](rung-3-your-app.md#private-repo--app-vs-token)) and then:

```bash
kubectl -n argocd delete application root      # it will be recreated by the bootstrap timer
```

Confirm what it is actually pointed at:

```bash
kubectl -n argocd get application root -o jsonpath='{.spec.source}' | jq
```

## My pod says `exec format error`

**Your image is the wrong architecture.** Oracle's free tier is Ampere — **aarch64** — and
a normal `docker build` on an Intel or Apple-Silicon machine, or on a standard GitHub
runner, produces an **amd64** image. Kubernetes pulls it, starts it, and the binary cannot
run. The message says nothing about architecture, so people go looking in their Dockerfile.

Check what you actually pushed:

```bash
docker manifest inspect ghcr.io/you/your-app:tag | grep -i architecture
```

Build for ARM — [`examples/build-and-push.yaml`](../examples/build-and-push.yaml) does this
with `platforms: linux/arm64`. See [rung 3](rung-3-your-app.md).

## My pod says `ImagePullBackOff`

If the image is **private**, the cluster has no credentials for it. Nothing gives Kubernetes
your GitHub login automatically.

```bash
kubectl -n <ns> describe pod <pod> | tail -20   # the real reason is at the bottom
```

`unauthorized` or `denied` means credentials. Either make the package public — image
visibility is a **separate setting from the repo's**, so your code can stay private — or
create a pull secret ([rung 3](rung-3-your-app.md#private-repo--app-vs-token)).

`not found` usually means a typo in the tag, or you pushed `latest` and referenced a SHA.

## I pushed to Git and nothing happened

Check what Argo is actually watching:

```bash
kubectl -n argocd get application root -o jsonpath='{.spec.source.repoURL}'
```

If that is **not your repo**, your push went somewhere Argo has never looked. Out of the box
it points at this project, and pointing it at yours is [rung 3](rung-3-your-app.md).

Note `gitops_repo_url` is baked into cloud-init, which runs **once at first boot** — changing
it in `terraform.tfvars` afterwards does nothing to a running box. Edit the live object
instead:

```bash
kubectl -n argocd edit application root
```

## Argo shows an app as OutOfSync forever

Usually the repo or path is wrong. Check what it is actually looking at:

```bash
kubectl -n argocd get application root -o jsonpath='{.spec.source}' | jq
```

If you changed `gitops_repo_url` **after** the first apply, cloud-init did not re-run —
that value only takes effect at first boot. Edit the live Application instead:

```bash
kubectl -n argocd edit application root
```
