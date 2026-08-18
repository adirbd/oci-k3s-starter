# Rung 4 — secrets without secrets on disk

> ### ⚠ Not built yet
> Design only. No Vault resources exist in `terraform/` today.

**You need:** nothing extra. OCI Vault is already in your account.

---

## The problem with every other option

Your app needs a database password. The usual answers:

- **A Secret in the cluster** — fine, until you want it in Git, and it is base64, not encryption.
- **Encrypted in Git** (SOPS, sealed-secrets) — good, but now there is a *decryption key*,
  and it has to live on the box. You have moved the problem, not removed it.
- **A cloud secret manager** — good, but the box needs an API credential to talk to it. Same
  move again.

Every one ends with **a credential on the machine** that unlocks the rest.

## What OCI gives you instead

**Instance principal.** The box authenticates *by being that instance* — Oracle vouches for
its identity, the same way it knows which VM is asking. There is no key, no token, and no
file. Nothing to rotate, and nothing to steal from the disk.

```
instance ──"I am instance ocid1.instance..."──→ OCI IAM
   │                                              │ dynamic group + policy say yes
   └────────────── secret value ←─────────────────┘
```

Steal the disk and you get nothing: the credential was never on it.

## The pieces

| | |
|---|---|
| **Vault + key** | where secrets live, encrypted with a key you own |
| **Dynamic group** | "instances in this compartment" — membership by rule, not enrolment |
| **Policy** | that group may `read secret-bundles` in that compartment. Read only. |
| **External Secrets Operator** | in-cluster, turns Vault entries into Kubernetes Secrets |

## What it looks like in use

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: db-password
spec:
  secretStoreRef:
    name: oci-vault
    kind: ClusterSecretStore
  target:
    name: db-password        # the k8s Secret it creates
  data:
    - secretKey: password
      remoteRef:
        key: my-app-db-password   # the NAME of the vault entry
```

**Note what is in Git: a name, never a value.** That file is safe in a public repo. The
value is fetched at runtime by a machine that proved its own identity.

## Why not SOPS here

The homelab this came from uses SOPS with an age key, and deliberately does **not** on this
box — because an age key able to decrypt everything has no business on the only
internet-facing machine you own.

Instance principal has no equivalent key to leak. On a box with a public IP, that
difference is the whole argument.

## Deliberate limits

- **Read-only.** The policy grants reading secret bundles, not writing. The box consumes
  secrets; it does not manage them.
- **One compartment.** The dynamic group is scoped to the compartment this repo builds in,
  not the tenancy.
- **Vault costs.** Secrets themselves are free; a *virtual private vault* is not. Use the
  default shared vault.
