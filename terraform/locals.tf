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
  image_id = var.image_ocid != null ? var.image_ocid : data.oci_core_images.ubuntu_arm.images[0].id
}
