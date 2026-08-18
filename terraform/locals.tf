locals {
  # Tagged so you can tell, a year from now, which console resources came from this repo
  # and which you clicked together at 1am. `tofu destroy` only removes what it created;
  # everything else is yours to find by hand.
  tags = {
    managed_by = "opentofu"
    project    = "oci-k3s-starter"
    instance   = var.instance_name
  }

  # The image to boot. A pinned image_ocid wins; otherwise take the newest Canonical
  # Ubuntu the lookup returned.
  # ⚠ NOT just images[0]. If the filter matches nothing — Canonical renames something, or
  # 24.04 leaves your region — `images[0]` is an "index out of range" error that tells you
  # nothing about why. The check below turns that into a sentence naming the cause and the
  # way out.
  ubuntu_images = data.oci_core_images.ubuntu_arm.images
  image_id      = var.image_ocid != null ? var.image_ocid : (length(local.ubuntu_images) > 0 ? local.ubuntu_images[0].id : null)
}
