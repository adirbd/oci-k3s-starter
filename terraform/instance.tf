# ── The image ─────────────────────────────────────────────────────────────────────
#
# Looked up rather than hardcoded, because image OCIDs are REGION-SPECIFIC: an OCID
# copied from a blog post is simply invalid in your region, with an error that does not
# say so clearly.
#
# ⚠ `Minimal` images are excluded on purpose. The A1 shape needs the standard image —
# the Minimal variants ship a trimmed kernel/package set and lead to a box that boots
# but misbehaves in ways that look like your fault rather than the image's.
data "oci_core_images" "ubuntu_arm" {
  compartment_id           = var.compartment_ocid
  operating_system         = "Canonical Ubuntu"
  operating_system_version = "24.04"
  shape                    = "VM.Standard.A1.Flex"
  sort_by                  = "TIMECREATED"
  sort_order               = "DESC"

  filter {
    name   = "display_name"
    values = ["^Canonical-Ubuntu-24\\.04-aarch64-[0-9.-]+$"]
    regex  = true
  }
}

# ── The box ───────────────────────────────────────────────────────────────────────

resource "oci_core_instance" "main" {
  # Modulo, so the index wraps instead of erroring: regions have 1 or 3 ADs and the retry
  # script does not need to know which. Asking a DIFFERENT AD is the single most effective
  # response to "Out of host capacity" — the pools are separate.
  availability_domain = data.oci_identity_availability_domains.ads.availability_domains[
    var.availability_domain_index % length(data.oci_identity_availability_domains.ads.availability_domains)
  ].name
  compartment_id = var.compartment_ocid
  display_name   = var.instance_name
  shape          = "VM.Standard.A1.Flex"

  # Empty means "Oracle picks" — the right first ask. retry-apply then rotates through
  # the three FDs, which matters most in 1-AD regions (see the fault_domain variable).
  fault_domain = var.fault_domain != "" ? var.fault_domain : null

  # ⚠ EXPECT "Out of host capacity" ON YOUR FIRST TRY. This is the single most common
  # thing that goes wrong, it is not your configuration, and it is not permanent.
  #
  # Free ARM capacity is genuinely scarce in popular regions. Oracle returns the failure
  # two different ways — a clean `OutOfHostCapacity`, or a generic `500-InternalError`
  # whose message merely reads "Out of host capacity" — so match on the text, not the code.
  #
  # Capacity is tracked PER AVAILABILITY DOMAIN and per fault domain, so a bare retry can
  # keep landing on the same full host. Retrying every few minutes works; `LaunchInstance`
  # is rate-limited on purpose to discourage tight polling, so back off on 429.
  #
  # ⚠ AND: never destroy a working A1 instance before its replacement exists. Terminating
  # to "free up allowance" first is exactly how you end up with none — the next launch is
  # not guaranteed to succeed.
  shape_config {
    ocpus         = var.ocpus
    memory_in_gbs = var.memory_gb
  }

  source_details {
    source_type             = "image"
    source_id               = local.image_id
    boot_volume_size_in_gbs = var.boot_volume_gb # grows online, never shrinks
  }

  create_vnic_details {
    subnet_id      = oci_core_subnet.public.id
    display_name   = "${var.instance_name}-vnic"
    hostname_label = var.instance_name

    # Ephemeral, not reserved. An ephemeral public IP lives as long as the VNIC: it
    # survives reboot and stop/start, and is only released when the instance is
    # terminated. Reserved IPs are not clearly inside Always Free, and the real answer to
    # "the address might change" is a DNS record (rung 2), not a pinned IP.
    assign_public_ip = true
  }

  metadata = {
    ssh_authorized_keys = var.ssh_public_key

    # Runs ONCE, at first boot. See the lifecycle block below before you edit it.
    user_data = base64encode(templatefile("${path.module}/cloud-init.yaml", {
      k3s_channel      = var.k3s_channel
      argocd_version   = var.argocd_version
      gitops_repo_url  = var.gitops_repo_url
      gitops_repo_path = var.gitops_repo_path

      # Delivered at boot so the cluster never runs on admin/admin, and so a REBUILD comes
      # back with the same password rather than a new one nobody knows.
      grafana_admin_password = random_password.grafana_admin.result

      # Rendered here so the box can apply it itself at boot, rather than a human pasting
      # `tofu output clustersecretstore_manifest` into kubectl — a step that is easy to skip
      # and does not survive a rebuild (#12). Empty string when rung 4 is off.
      clustersecretstore = var.enable_vault ? indent(6, yamlencode({
        apiVersion = "external-secrets.io/v1"
        kind       = "ClusterSecretStore"
        metadata   = { name = "oci-vault" }
        spec = {
          provider = {
            oracle = {
              vault         = oci_kms_vault.main[0].id
              region        = var.region
              principalType = "InstancePrincipal"
            }
          }
        }
      })) : ""
    }))
  }

  freeform_tags = local.tags

  # ⚠ WITHOUT THIS, EDITING cloud-init.yaml DESTROYS A RUNNING BOX.
  #
  # The OCI provider treats ANY change to `metadata` as ForceNew, so a one-character fix
  # to the bootstrap silently plans `must be replaced`. On scarce free-tier capacity a
  # destroy is not reliably reversible — you may not get another instance back today.
  #
  # Ignoring it is not a workaround, it is the honest semantics: cloud-init runs once, at
  # first boot. Pushing new user_data to a live instance changes nothing on the box even
  # where the provider allows it, so a diff here is never something you want applied by
  # surprise.
  #
  # To actually deploy new cloud-init, rebuild deliberately:
  #   tofu apply -replace=oci_core_instance.main
  # and only when you are willing to gamble the capacity.
  lifecycle {
    ignore_changes = [metadata]

    precondition {
      condition     = local.image_id != null
      error_message = "No Canonical Ubuntu 24.04 aarch64 image matched in this region. Either the image naming changed upstream, or 24.04 is not published where you are building. Fix: find one with `oci compute image list --compartment-id <ocid> --operating-system 'Canonical Ubuntu' --shape VM.Standard.A1.Flex` and pass it as image_ocid."
    }
  }
}

# ── The way back in ───────────────────────────────────────────────────────────────
#
# A serial console connection. This is the door that survives the others: it reaches the
# instance's serial port through Oracle's OWN endpoint, so it does not traverse your VCN,
# is unaffected by the security list, and works when sshd is dead, networking is
# misconfigured and k3s is wedged.
#
# Declared rather than clicked, so a rebuilt instance gets one automatically. Created by
# hand it would belong to one machine, and would silently disappear on the rebuild — i.e.
# exactly when you needed it.
#
# Free, and idle. It costs nothing to have and everything to lack.
resource "oci_core_instance_console_connection" "main" {
  instance_id   = oci_core_instance.main.id
  public_key    = tls_private_key.console.public_key_openssh
  freeform_tags = local.tags
}

# Its own RSA key — and not by preference.
#
# ⚠ OCI's console connection accepts RSA ONLY. Passing a modern ed25519 key (very likely
# what your `ssh_public_key` is) fails outright:
#   400-InvalidParameter, Invalid ssh public key type "ssh-ed25519"
#
# Generating it here rather than asking you to keep a second key around preserves the
# property that matters: nothing to remember, and nothing to hunt for during an incident.
#
# ⚠ The private half lands in TERRAFORM STATE. That is the trade — see versions.tf on
# where state lives and why you should not treat it as public. Read it with:
#   tofu output -raw console_private_key
resource "tls_private_key" "console" {
  algorithm = "RSA"
  rsa_bits  = 4096
}
