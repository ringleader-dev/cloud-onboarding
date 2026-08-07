# Ringleader GCP onboarding module (OIDC / Workload Identity Federation).
#
# Creates, in one of your projects:
#   - a dedicated least-privilege service account Ringleader acts as,
#   - two Google-maintained predefined Compute roles on the project,
#   - a Workload Identity Pool + OIDC provider trusting Ringleader's per-org
#     issuer, pinned to your org's subject, and
#   - the workloadIdentityUser binding that lets only that subject impersonate
#     the service account.
#
# Optionally, a VPC + subnet + Cloud NAT landing pad: egress out, and inbound SSH only from
# the CIDRs you name (ssh_source_ranges).
#
# Keyless throughout: no service-account key is created. This module declares NO
# provider block so it can be referenced from another repository. See
# examples/standalone for a ready-to-apply root configuration.

locals {
  # The server-derived claims Ringleader's issuer signs for your org. Pinned here
  # so this trust reaches your org and nothing else:
  #   iss = <issuer_url>/org/<org_uid>
  #   sub = org:<org_uid>
  #   aud = <iss>/gcp
  issuer_uri = "${var.ringleader_issuer_url}/org/${var.org_uid}"
  subject    = "org:${var.org_uid}"
  audience   = "${var.ringleader_issuer_url}/org/${var.org_uid}/gcp"
}

# The APIs this module and the workstation lifecycle need. All five are enabled
# unconditionally, because a fresh, dedicated project -- the project this onboarding
# recommends -- has none of them on:
#
#   iam                  creating the service account, the pool and the provider
#   cloudresourcemanager setting the two project role bindings below
#   compute              the VM lifecycle, and the optional network landing pad
#   sts / iamcredentials the token exchange and impersonation Ringleader does at run time
#
# Getting this wrong is quiet: the trust federates perfectly and then every VM create
# fails. Enabling an API that is already on is a no-op, so this costs nothing.
#
# Every resource below that needs one declares depends_on. Terraform infers no
# dependency from an API enablement, so without it the create races the enable.
resource "google_project_service" "iam" {
  project            = var.project_id
  service            = "iam.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "cloudresourcemanager" {
  project            = var.project_id
  service            = "cloudresourcemanager.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "compute" {
  project            = var.project_id
  service            = "compute.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "sts" {
  project            = var.project_id
  service            = "sts.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "iamcredentials" {
  project            = var.project_id
  service            = "iamcredentials.googleapis.com"
  disable_on_destroy = false
}

# 1. A dedicated, least-privilege identity Ringleader acts as.
resource "google_service_account" "onboarding" {
  project      = var.project_id
  account_id   = var.sa_account_id
  display_name = var.sa_display_name
  description  = "Least-privilege identity Ringleader federates to, to manage workstation VMs."

  depends_on = [google_project_service.iam]
}

# 2. Two Google-maintained predefined roles, project-scoped -- nothing broader.
resource "google_project_iam_member" "instance_admin" {
  project = var.project_id
  role    = "roles/compute.instanceAdmin.v1"
  member  = "serviceAccount:${google_service_account.onboarding.email}"

  depends_on = [google_project_service.cloudresourcemanager]
}

resource "google_project_iam_member" "network_user" {
  project = var.project_id
  role    = "roles/compute.networkUser"
  member  = "serviceAccount:${google_service_account.onboarding.email}"

  depends_on = [google_project_service.cloudresourcemanager]
}

# 2b. OPTIONAL: per-workstation RUNTIME identities (off by default).
#
# Ringleader can boot each workstation RUNNING AS a dedicated service account it provisions for
# that user, and bind roles to it (so it can, say, read one bucket). That feature needs three
# capabilities the two roles above deliberately do NOT grant, so with this off it fails closed
# with a 403 rather than doing something surprising:
#
#   - create/delete the per-user SA        -> roles/iam.serviceAccountAdmin
#   - bind roles to it on the project      -> roles/resourcemanager.projectIamAdmin
#   - attach it to a VM (actAs)            -> roles/iam.serviceAccountUser
#
# READ THIS BEFORE TURNING IT ON. `roles/resourcemanager.projectIamAdmin` lets the holder grant ANY
# role in this project to ANY principal -- including granting itself `roles/owner`. It is therefore
# a privilege-escalation path by construction, and no phrasing makes it otherwise: Ringleader
# needs it because setting a role binding on a project IS project-IAM administration.
#
# So enable this ONLY in a project dedicated to Ringleader workstations, never in a project that
# holds anything else you care about. If you want runtime identities without granting it, ask
# Ringleader about pre-creating the service accounts yourself -- the VM will still run as them.
resource "google_project_iam_member" "workstation_sa_admin" {
  count   = var.enable_workstation_identities ? 1 : 0
  project = var.project_id
  role    = "roles/iam.serviceAccountAdmin"
  member  = "serviceAccount:${google_service_account.onboarding.email}"

  depends_on = [google_project_service.cloudresourcemanager]
}

resource "google_project_iam_member" "workstation_project_iam_admin" {
  count   = var.enable_workstation_identities ? 1 : 0
  project = var.project_id
  role    = "roles/resourcemanager.projectIamAdmin"
  member  = "serviceAccount:${google_service_account.onboarding.email}"

  depends_on = [google_project_service.cloudresourcemanager]
}

resource "google_project_iam_member" "workstation_sa_user" {
  count   = var.enable_workstation_identities ? 1 : 0
  project = var.project_id
  role    = "roles/iam.serviceAccountUser"
  member  = "serviceAccount:${google_service_account.onboarding.email}"

  depends_on = [google_project_service.cloudresourcemanager]
}

# 3. The federation trust: a pool + OIDC provider that trusts Ringleader's issuer
#    for your org only.
resource "google_iam_workload_identity_pool" "ringleader" {
  project                   = var.project_id
  workload_identity_pool_id = var.pool_id
  display_name              = "Ringleader"
  description               = "Trusts Ringleader's OIDC issuer to run workstation VMs as ${google_service_account.onboarding.email}."

  depends_on = [google_project_service.iam]
}

# Two independent pins: the token's audience AND its subject must match your org.
# The provider never uses a principalSet://.../* wildcard -- access is bound to the
# single mapped subject below.
resource "google_iam_workload_identity_pool_provider" "ringleader" {
  project                            = var.project_id
  workload_identity_pool_id          = google_iam_workload_identity_pool.ringleader.workload_identity_pool_id
  workload_identity_pool_provider_id = var.provider_id
  display_name                       = "Ringleader OIDC"

  attribute_condition = "assertion.sub == '${local.subject}'"

  attribute_mapping = {
    "google.subject" = "assertion.sub"
  }

  oidc {
    issuer_uri        = local.issuer_uri
    allowed_audiences = [local.audience]
  }
}

# 4. Only the federated principal for your org's subject may impersonate the SA.
resource "google_service_account_iam_member" "workload_identity_user" {
  service_account_id = google_service_account.onboarding.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principal://iam.googleapis.com/${google_iam_workload_identity_pool.ringleader.name}/subject/${local.subject}"
}

# --- Optional network landing pad (egress out; inbound only via ssh_source_ranges) ---

resource "google_compute_network" "workstations" {
  count                   = var.create_network ? 1 : 0
  project                 = var.project_id
  name                    = "ringleader-vpc"
  auto_create_subnetworks = false

  depends_on = [google_project_service.compute]
}

resource "google_compute_subnetwork" "workstations" {
  count                    = var.create_network ? 1 : 0
  project                  = var.project_id
  name                     = "ringleader-workstations"
  region                   = var.region
  network                  = google_compute_network.workstations[0].id
  ip_cidr_range            = var.subnet_cidr
  private_ip_google_access = true
}

resource "google_compute_router" "workstations" {
  count   = var.create_network ? 1 : 0
  project = var.project_id
  name    = "ringleader-router"
  region  = var.region
  network = google_compute_network.workstations[0].id
}

resource "google_compute_router_nat" "workstations" {
  count                              = var.create_network ? 1 : 0
  project                            = var.project_id
  name                               = "ringleader-nat"
  region                             = var.region
  router                             = google_compute_router.workstations[0].name
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"
}

# Inbound SSH -- the difference between a workstation that COMES UP and one you can actually USE.
#
# A custom-mode VPC has NO firewall rules, and GCP's implied rule denies all ingress. Ringleader's
# setup traffic is fine with that (a workstation only needs EGRESS to reach the Ringleader control
# plane, which Cloud NAT above provides). But `rl shell`, `rl tmux`, port-forwards and VS Code Web
# all dial the workstation on TCP 22 directly -- Ringleader ships no bastion, no proxy and no SSH
# tunnel -- so with no rule here the workstation comes up healthy, reports Ready, and nobody can
# get into it.
#
# Leave ssh_source_ranges EMPTY and no rule is created: choose that only if you reach the subnet
# privately (VPN / Interconnect / VPC peering) from wherever you run `rl`. Otherwise list the public
# CIDRs your engineers connect from. 0.0.0.0/0 is accepted but is a decision, not a default.
resource "google_compute_firewall" "ssh" {
  count     = var.create_network && length(var.ssh_source_ranges) > 0 ? 1 : 0
  project   = var.project_id
  name      = "ringleader-allow-ssh"
  network   = google_compute_network.workstations[0].name
  direction = "INGRESS"

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_ranges = var.ssh_source_ranges
  target_tags   = [var.workstation_network_tag]
}
