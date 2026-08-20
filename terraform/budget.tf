# The alarm that replaces Oracle's safety net.
#
# WHY THIS EXISTS. "Upgrade to Pay As You Go" is the standard community fix for
# "Out of host capacity" — paying tenancies get A1 capacity that Free Tier requests are
# refused. The upgrade works, and it silently changes one rule: a Free Tier tenancy
# CANNOT be billed (overshoot disables and deletes resources instead — see the ocpus
# variable), while a PAYG tenancy simply bills for the same mistake.
#
# The variable validations cap everything THIS REPO builds inside the Always Free
# shapes, on any account type. This file is for what those caps cannot see: a resource
# clicked up in the console, a service whose free allowance changes, a mistake in a
# fork. A budget of 1 (in your billing currency) per month, alerting on FORECAST and
# ACTUAL — the goal is not cost management, it is "email me the moment ANYTHING bills".
#
# Created only when budget_alert_email is set: an alert with nobody to mail is dead
# weight, and on a never-upgraded Free Tier there is nothing it could catch anyway.
# Upgraded to PAYG? Set it. The same day.

resource "oci_budget_budget" "zero_spend" {
  count = var.budget_alert_email != null ? 1 : 0

  # Budgets are a tenancy-level object: they live in the ROOT compartment no matter
  # what they watch. When compartment_ocid IS the tenancy (the common case in these
  # docs) nothing more is needed; a child compartment needs tenancy_ocid set too.
  compartment_id = coalesce(var.tenancy_ocid, var.compartment_ocid)

  amount       = var.budget_monthly_limit
  reset_period = "MONTHLY"
  display_name = "${var.instance_name}-zero-spend"
  description  = "Managed by OpenTofu (${var.instance_name}). This stack is meant to fit Always Free entirely — if this budget fires, something is outside it."

  target_type = "COMPARTMENT"
  targets     = [var.compartment_ocid]

  lifecycle {
    precondition {
      condition     = var.tenancy_ocid != null || startswith(var.compartment_ocid, "ocid1.tenancy")
      error_message = "Budgets can only be created in the root compartment. compartment_ocid is a child compartment here, so also set tenancy_ocid (Profile > Tenancy > OCID)."
    }
  }
}

# Two rules, not one: FORECAST fires days before ACTUAL does, and with a 1-unit budget
# the forecast alert reads as "Oracle already believes this month will not be free".
resource "oci_budget_alert_rule" "forecast" {
  count = var.budget_alert_email != null ? 1 : 0

  budget_id      = oci_budget_budget.zero_spend[0].id
  display_name   = "${var.instance_name}-forecast"
  type           = "FORECAST"
  threshold      = 100
  threshold_type = "PERCENTAGE"
  recipients     = var.budget_alert_email
  message        = "OCI forecasts this month's spend to reach ${var.budget_monthly_limit} — the ${var.instance_name} stack is meant to cost 0. Check Billing > Cost Analysis for what started billing, and docs/cost-and-limits.md for what is supposed to be free."
}

resource "oci_budget_alert_rule" "actual" {
  count = var.budget_alert_email != null ? 1 : 0

  budget_id      = oci_budget_budget.zero_spend[0].id
  display_name   = "${var.instance_name}-actual"
  type           = "ACTUAL"
  threshold      = 100
  threshold_type = "PERCENTAGE"
  recipients     = var.budget_alert_email
  message        = "OCI spend has ACTUALLY reached ${var.budget_monthly_limit} this month — the ${var.instance_name} stack is meant to cost 0. Check Billing > Cost Analysis for what is billing, and docs/cost-and-limits.md for what is supposed to be free."
}
