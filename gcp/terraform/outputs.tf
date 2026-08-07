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

output "handoff" {
  description = "Everything to hand back to Ringleader, in one place."
  value = {
    target_service_account_email = google_service_account.onboarding.email
    workload_identity_provider   = "//iam.googleapis.com/${google_iam_workload_identity_pool_provider.ringleader.name}"
    project_id                   = var.project_id
    subnetwork_self_link         = var.create_network ? google_compute_subnetwork.workstations[0].self_link : null
  }
}
