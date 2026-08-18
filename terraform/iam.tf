# ══════════════════════════════════════════════════════════════════════════════════
#  RUNG 4 — the identity that replaces a credential.
#
#  A dynamic group is what makes `principalType: InstancePrincipal` work: the box
#  authenticates to OCI Vault BY BEING THAT INSTANCE. There is no API key, no token and
#  no file — so there is nothing on the disk to steal, and nothing to rotate. A rebuilt
#  instance re-authenticates on its own, with no human step.
#
#  ⚠ THESE ARE TENANCY-LEVEL OBJECTS. Dynamic groups and policies cannot live in a child
#  compartment, which is why compartment_id below is the TENANCY and not var.compartment_ocid.
#  It also means creating them needs an account allowed to write IAM at the tenancy —
#  fine as the account owner, likely not as a restricted user.
# ══════════════════════════════════════════════════════════════════════════════════

resource "oci_identity_dynamic_group" "instance" {
  count = var.enable_vault ? 1 : 0

  compartment_id = var.tenancy_ocid
  name           = "${var.instance_name}-instances"
  description    = "The ${var.instance_name} instance, for instance-principal auth to OCI Vault."

  # ⚠ MATCHED BY OCID — one machine, named explicitly.
  #
  # The tempting alternative, `instance.compartment.id = '<compartment>'`, silently
  # includes every future instance you ever launch there. A second box would inherit this
  # one's access to every secret without anyone deciding that. Naming the instance means a
  # second box has to be granted deliberately.
  matching_rule = "ALL {instance.id = '${oci_core_instance.main.id}'}"
}

resource "oci_identity_policy" "read_secrets" {
  count = var.enable_vault ? 1 : 0

  compartment_id = var.tenancy_ocid
  name           = "${var.instance_name}-read-secrets"
  description    = "Let the ${var.instance_name} instance read its own secrets, and nothing else."

  # `secret-family` aggregates `secrets` (list and metadata) and `secret-bundles` (the
  # contents). External Secrets needs both: it lists to resolve a name, then reads the
  # bundle.
  #
  # NOTE there is deliberately no `use keys` grant. Decryption happens inside the Vault
  # service, not on the caller's side, so the instance never needs access to the key
  # itself. (If ESO ever 403s on a read, this is the first assumption to re-check.)
  #
  # Scope: the compartment you build in — never `in tenancy`. If your compartment IS the
  # tenancy root, OCI wants the words `in tenancy` instead of an OCID, so both spellings
  # are handled rather than leaving you with a policy that silently grants nothing.
  statements = [
    var.compartment_ocid == var.tenancy_ocid
    ? "Allow dynamic-group ${oci_identity_dynamic_group.instance[0].name} to read secret-family in tenancy"
    : "Allow dynamic-group ${oci_identity_dynamic_group.instance[0].name} to read secret-family in compartment id ${var.compartment_ocid}"
  ]
}
