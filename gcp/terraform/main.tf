# Ringleader GCP onboarding module (OIDC / Workload Identity Federation).
#
# Creates, in one of your projects:
#   - a dedicated least-privilege service account Ringleader acts as,
#   - three Google-maintained predefined roles on the project,
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

# 2. Three Google-maintained predefined roles, project-scoped -- nothing broader.
#
# instanceAdmin.v1 and networkUser are the VM lifecycle itself: create, boot, stop, start and
# delete instances and their disks, and attach a NIC to your subnets.
#
# serviceAccountUser is the third because EVERY workstation VM runs AS some service account, and
# attaching one to an instance requires iam.serviceAccounts.actAs on it -- a permission neither of
# the two Compute roles carries. This is NOT the optional runtime-identity feature below: a GCE
# workstation authenticates to Ringleader with a Google-signed INSTANCE IDENTITY assertion, and the
# metadata server mints that only for a VM that HAS an attached service account (it is served under
# service-accounts/default/identity). So Ringleader attaches one on every create -- the
# workstation's own declared service account, or, when it declares none, this project's DEFAULT
# COMPUTE service account. Without this role the very first create fails with a 403 on actAs and no
# workstation in this project can boot.
#
# It is project-scoped, so it permits acting as ANY service account in this project -- and a VM
# running as a service account can use everything that account can. That is exactly why this
# onboarding asks for a project DEDICATED to Ringleader workstations: in a shared project this
# reaches whatever else lives there. Two things worth doing in that project:
#
#   - check what your default compute service account holds. Projects created before Google
#     changed the default get roles/editor on it, so a workstation that declares no identity of
#     its own would inherit project editor. Remove that binding if you do not want it.
#   - or give workstations a purpose-made service account with no roles at all, per workstation or
#     fleet-wide (providerConfig.gcp.serviceAccount). Ringleader attaches it instead of the
#     default; it still needs actAs, which this role grants.
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

resource "google_project_iam_member" "service_account_user" {
  project = var.project_id
  role    = "roles/iam.serviceAccountUser"
  member  = "serviceAccount:${google_service_account.onboarding.email}"

  depends_on = [google_project_service.cloudresourcemanager]
}

# This grant used to be part of enable_workstation_identities, which is off by default -- so a
# project onboarded on the documented defaults could not boot a workstation at all. It is now
# unconditional, and this block carries the existing binding over rather than destroying and
# recreating it (the two addresses are the same project/role/member, and an arbitrary
# destroy-after-create ordering would leave the project with no binding at all).
moved {
  from = google_project_iam_member.workstation_sa_user[0]
  to   = google_project_iam_member.service_account_user
}

# 2b. OPTIONAL: per-workstation RUNTIME identities (off by default).
#
# Every workstation already runs as a service account (see 2 above). What this adds is letting
# Ringleader PROVISION one per workstation user and BIND ROLES to it, so a workstation can, say,
# read one bucket. That needs two capabilities the roles above deliberately do NOT grant, so with
# this off it fails closed with a 403 rather than doing something surprising:
#
#   - create/delete the per-user SA        -> roles/iam.serviceAccountAdmin
#   - bind roles to it on the project      -> roles/resourcemanager.projectIamAdmin
#
# (Attaching a service account to a VM -- actAs -- is roles/iam.serviceAccountUser, granted
# unconditionally above because no workstation can boot without it.)
#
# READ THIS BEFORE TURNING IT ON. `roles/resourcemanager.projectIamAdmin` lets the holder grant ANY
# role in this project to ANY principal -- including granting itself `roles/owner`. It is therefore
# a privilege-escalation path by construction, and no phrasing makes it otherwise: Ringleader
# needs it because setting a role binding on a project IS project-IAM administration.
#
# So enable this ONLY in a project dedicated to Ringleader workstations, never in a project that
# holds anything else you care about. If you want runtime identities without granting it, create
# the service accounts and their role bindings yourself and name them on the workstation
# (providerConfig.gcp.serviceAccount) -- the VM will still run as them, and actAs above is all
# Ringleader needs to attach one it did not create.
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
