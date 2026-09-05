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

output "network_cidr" {
  value       = var.create_network ? local.network_cidr : null
  description = "The /16 every subnet below is carved out of. Read it back and confirm it is the block you meant: GCP's is 10.80-10.89, and a landing pad that predates the derivation keeps 10.60.0.0/16 by declaring it."
}

output "subnet_cidr" {
  value       = var.create_network ? local.subnet_cidr : null
  description = "The workstations subnet's range -- the first /20 of network_cidr unless overridden."
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
  description = "A reserved, empty range (only when create_gateway_subnet = true). NOT where the egress gateway VM runs and NOT handed back to Ringleader: on GCP the steering route is scoped by network tag and the appliance carries none, so the VM shares the workstations subnet and EgressGateway.spec.subnet is refused. Kept so the addressing matches the AWS and Azure modules and the range stays free; set create_gateway_subnet = false to skip it."
}

output "gateway_subnet_cidr" {
  value       = var.create_network && var.create_gateway_subnet ? local.gateway_subnet_cidr : null
  description = "The reserved range, if you carved one. Nothing is placed in it today -- the gateway VM runs in the workstations subnet, and the <name_prefix>-allow-gateway rule admits them to it by network tag -- so an egress allowlist naming this range would name an empty one. Recorded so a later renumbering does not collide."
}

output "governed_subnetwork_self_link" {
  value       = var.create_network && var.create_governed_subnet ? google_compute_subnetwork.governed[0].self_link : null
  description = "Subnet for the workstations a gateway governs (only when create_governed_subnet = true, which is OFF by default here). On GCP a box is governed by its network tag, not by which subnet it is in -- see the variable's description."
}

output "governed_subnet_cidr" {
  value       = var.create_network && var.create_governed_subnet ? local.governed_subnet_cidr : null
  description = "The governed subnet's range, if you created one."
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
      "custom ${var.egress_role_id} -- compute.firewalls.*, compute.routes.*, compute.networks.updatePolicy and compute.addresses.* (14 permissions), for egress control",
    ] : [],
    local.artifact_storage_managed ? [
      "custom ${var.artifact_storage_role_id} -- storage.buckets.get/update/delete and storage.objects.* (8 permissions), CONDITIONED to buckets named ${local.managed_bucket_prefix}*, for artifact storage",
      "custom ${var.artifact_storage_role_id}Provision -- storage.buckets.create and nothing else, for artifact storage",
    ] : [],
    local.artifact_storage_named ? [
      "custom ${var.artifact_storage_role_id} -- storage.buckets.get and storage.objects.* (6 permissions), on the bucket ${var.artifact_storage_bucket} ONLY, for artifact storage",
    ] : [],
  )
}

output "artifact_storage_grant" {
  value       = var.enable_artifact_storage ? (local.artifact_storage_managed ? "managed" : "named") : null
  description = "Hand back to Ringleader: which width you took, as the Storage object's spec.grant. Null when enable_artifact_storage = false, which is also the answer to \"do not declare a Storage at all\"."
}

output "artifact_storage_bucket" {
  value       = local.artifact_storage_named ? var.artifact_storage_bucket : null
  description = "Hand back to Ringleader as the Storage object's spec.bucket, on the NAMED width. Null on the managed width, where Ringleader creates the bucket and names it ringleader-... itself -- ask it what it created rather than guessing."
}

output "handoff" {
  description = "Everything to hand back to Ringleader, in one place."
  value = {
    target_service_account_email  = google_service_account.onboarding.email
    workload_identity_provider    = "//iam.googleapis.com/${google_iam_workload_identity_pool_provider.ringleader.name}"
    project_id                    = var.project_id
    subnetwork_self_link          = var.create_network ? google_compute_subnetwork.workstations[0].self_link : null
    governed_subnetwork_self_link = var.create_network && var.create_governed_subnet ? google_compute_subnetwork.governed[0].self_link : null
    artifact_storage_grant        = var.enable_artifact_storage ? (local.artifact_storage_managed ? "managed" : "named") : null
    artifact_storage_bucket       = local.artifact_storage_named ? var.artifact_storage_bucket : null
  }
}
