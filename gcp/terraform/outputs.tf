output "target_service_account_email" {
  value       = google_service_account.onboarding.email
  description = "Hand back to Ringleader: the service account it federates to (the target principal)."
}

output "workload_identity_provider" {
  value       = "//iam.googleapis.com/${google_iam_workload_identity_pool_provider.ringleader.name}"
  description = "Hand back to Ringleader: the WIF provider resource name (the token-exchange audience)."
}

output "project_id" {
  value       = var.project_id
  description = "Hand back to Ringleader: the project your workstations run in."
}

output "subnetwork_self_link" {
  value       = var.create_network ? google_compute_subnetwork.workstations[0].self_link : null
  description = "Hand back to Ringleader (only when create_network = true; otherwise supply your own subnet)."
}

output "additional_subnetwork_self_links" {
  value       = { for r, s in google_compute_subnetwork.additional : r => s.self_link }
  description = "Self-links of the extra regional subnets, keyed by region. Hand back the one a given workstation should use."
}

output "gateway_subnetwork_self_link" {
  value       = var.create_network && var.create_gateway_subnet ? google_compute_subnetwork.gateway[0].self_link : null
  description = "Subnet reserved for the future DNS / HTTPS proxy VM (only when create_gateway_subnet = true)."
}

output "gateway_subnet_cidr" {
  value       = var.create_network && var.create_gateway_subnet ? var.gateway_subnet_cidr : null
  description = "The gateway subnet's range. This is what an egress allowlist names to let workstations reach the proxy, so it is worth recording."
}

# --- Audit: read these back and confirm they say what you expect --------------------
#
# None of these goes back to Ringleader. They exist so the module's security properties are
# something you can verify after applying rather than take on trust from a diff.

output "trusted_subject" {
  value       = local.subject
  description = "The one subject this project's workload identity provider admits. Confirm it is your org's uid and nothing else."
}

output "roles_granted" {
  description = "Every role the onboarding service account holds, for audit."
  value = concat(
    [
      "roles/compute.instanceAdmin.v1",
      "roles/compute.networkUser",
      "roles/iam.serviceAccountUser",
    ],
    var.enable_workstation_identities ? [
      "roles/iam.serviceAccountAdmin -- workstation runtime identities",
      "roles/resourcemanager.projectIamAdmin -- workstation runtime identities",
    ] : [],
    var.enable_egress_control ? [
      "custom ${var.egress_role_id} -- compute.firewalls.*, compute.routes.* and compute.networks.updatePolicy (10 permissions), for egress control",
    ] : [],
  )
}

output "handoff" {
  description = "Everything to hand back to Ringleader, in one place."
  value = {
    target_service_account_email = google_service_account.onboarding.email
    workload_identity_provider   = "//iam.googleapis.com/${google_iam_workload_identity_pool_provider.ringleader.name}"
    project_id                   = var.project_id
    subnetwork_self_link         = var.create_network ? google_compute_subnetwork.workstations[0].self_link : null
  }
}
