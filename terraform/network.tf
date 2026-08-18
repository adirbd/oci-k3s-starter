# A VCN with one public subnet. Nothing clever — but three of these settings can never be
# changed after creation, so they are worth getting right the first time.

data "oci_identity_availability_domains" "ads" {
  compartment_id = var.compartment_ocid
}

resource "oci_core_vcn" "main" {
  compartment_id = var.compartment_ocid
  cidr_blocks    = [var.vcn_cidr]
  display_name   = "${var.instance_name}-vcn"

  # ⚠ IMMUTABLE. Alphanumeric only, <= 15 chars, must start with a letter.
  # This bakes into every host's internal DNS name — <host>.<subnet>.<vcn>.oraclevcn.com —
  # so a name you regret means recreating the VCN, not renaming it. (If you build through
  # the console wizard instead, you get labels like `vcn08120005` and are stuck with them.)
  dns_label = "vcn"

  freeform_tags = local.tags
}

resource "oci_core_internet_gateway" "main" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.main.id
  display_name   = "${var.instance_name}-igw"
  enabled        = true
  freeform_tags  = local.tags
}

resource "oci_core_route_table" "public" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.main.id
  display_name   = "${var.instance_name}-rt-public"

  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_internet_gateway.main.id
    description       = "Default route to the internet gateway"
  }

  freeform_tags = local.tags
}

resource "oci_core_security_list" "public" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.main.id
  display_name   = "${var.instance_name}-sl-public"

  egress_security_rules {
    destination      = "0.0.0.0/0"
    destination_type = "CIDR_BLOCK"
    protocol         = "all"
    description      = "Unrestricted egress — the box pulls images, packages and Git"
  }

  # SSH. The ONLY inbound rule by default.
  #
  # Note what is deliberately NOT here: 80 and 443. You do not need them. At rung 1 you
  # reach services with `kubectl port-forward` over this SSH connection; at rung 2 the
  # Cloudflare Tunnel dials OUT, so inbound HTTP is never required. A box with no web
  # ports open is not an inconvenience, it is the design.
  ingress_security_rules {
    protocol    = "6" # TCP
    source      = var.ssh_allowed_cidr
    source_type = "CIDR_BLOCK"
    description = "SSH"

    tcp_options {
      min = 22
      max = 22
    }
  }

  # ── HTTP/HTTPS, only when you asked for it ────────────────────────────────────
  # dynamic, so the rules simply do not exist when enable_public_http is false — rather
  # than existing with a source nobody can reach, which is harder to reason about.
  dynamic "ingress_security_rules" {
    for_each = var.enable_public_http ? [80, 443] : []
    content {
      protocol    = "6" # TCP
      source      = var.public_http_cidr
      source_type = "CIDR_BLOCK"
      description = "HTTP(S) — direct exposure, no tunnel"

      tcp_options {
        min = ingress_security_rules.value
        max = ingress_security_rules.value
      }
    }
  }

  # Path-MTU discovery. Leave this alone.
  #
  # Without ICMP fragmentation-needed getting back to you, large packets black-hole
  # SILENTLY: `curl` on a small page works, `git clone` or a big image pull hangs forever
  # with no error. It is the classic "the network works until you move real data" bug and
  # it costs hours to diagnose because everything you test first succeeds.
  ingress_security_rules {
    protocol    = "1" # ICMP
    source      = "0.0.0.0/0"
    source_type = "CIDR_BLOCK"
    description = "ICMP fragmentation-needed — required for path-MTU discovery"

    icmp_options {
      type = 3
      code = 4
    }
  }

  freeform_tags = local.tags
}

resource "oci_core_subnet" "public" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.main.id
  cidr_block     = cidrsubnet(var.vcn_cidr, 8, 0)
  display_name   = "${var.instance_name}-public"

  # ⚠ IMMUTABLE, same as the VCN's.
  dns_label = "public"

  # ⚠ ALSO PERMANENT, and the one that actually bites: this decides whether anything in
  # this subnet may EVER have a public IP. Set to true by a wizard, the only fix is a new
  # subnet. Explicit here rather than inherited, because the default is not obvious and
  # the consequence is not reversible.
  prohibit_public_ip_on_vnic = false

  # No availability_domain = a REGIONAL subnet. This is the right default: an AD-specific
  # subnet pins every future instance to one availability domain, which matters when you
  # are hunting scarce free-tier capacity across ADs.
  route_table_id    = oci_core_route_table.public.id
  security_list_ids = [oci_core_security_list.public.id]

  freeform_tags = local.tags
}
