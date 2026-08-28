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
# Two optional extras, both off by default:
#   - a VPC + subnet + Cloud NAT landing pad (egress out; inbound SSH only from the
#     CIDRs you name), and
#   - egress control, which lets Ringleader manage the firewall rules that restrict
#     where your workstations can connect.
#
# Keyless throughout: no service-account key is created. This module declares no
# provider block so it can be referenced from another repository. See
# examples/standalone for a ready-to-apply root configuration.

locals {
  # The claims Ringleader's issuer signs for your org. Pinned here so this trust
  # reaches your org and nothing else:
  #   iss = <issuer_url>/org/<org_uid>
  #   sub = org:<org_uid>
  #   aud = <iss>/gcp
  issuer_uri = "${var.ringleader_issuer_url}/org/${var.org_uid}"
  subject    = "org:${var.org_uid}"
  audience   = "${var.ringleader_issuer_url}/org/${var.org_uid}/gcp"
}

# The APIs this module and the workstation lifecycle need. All five are enabled
# unconditionally, because the fresh, dedicated project this onboarding recommends has
# none of them on:
#
#   iam                  the service account, the pool and the provider
#   cloudresourcemanager the project role bindings below
#   compute              the VM lifecycle, and the optional network landing pad
#   sts / iamcredentials the token exchange and impersonation Ringleader does at run time
#
# Getting this wrong is quiet: the trust federates perfectly and then every VM create
# fails. Enabling an API that is already on is a no-op, so this costs nothing.
#
# Every resource below that needs one declares depends_on -- Terraform infers no
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

# 2. Three predefined roles, project-scoped -- nothing broader.
#
# instanceAdmin.v1 and networkUser are the VM lifecycle itself: create, boot, stop, start
# and delete instances and their disks, and attach a NIC to your subnets.
#
# serviceAccountUser is the third because every workstation VM runs as some service
# account, and attaching one needs iam.serviceAccounts.actAs, which neither Compute role
# carries. This is not the optional runtime-identity feature below: a GCE workstation
# proves its identity to Ringleader with a Google-signed instance identity assertion, and
# the metadata server mints that only for a VM that has an attached service account. So
# Ringleader attaches one on every create -- the workstation's own, or this project's
# default compute service account. Without this role the first create fails with a 403.
#
# It is project-scoped, so it permits acting as any service account in this project, and a
# VM running as a service account can use everything that account can. That is why this
# onboarding asks for a project dedicated to Ringleader workstations. Two things worth
# doing there:
#
#   - Check what your default compute service account holds. Projects created before
#     Google changed the default get roles/editor on it, so a workstation that declares no
#     identity would inherit project editor. Remove that binding if you do not want it.
#   - Or give workstations a purpose-made service account with no roles, per workstation or
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

# This grant used to be part of enable_workstation_identities, which is off by default, so
# a project onboarded on the documented defaults could not boot a workstation at all. It is
# now unconditional, and this block carries the existing binding over rather than destroying
# and recreating it -- the two addresses are the same project/role/member, and an arbitrary
# destroy-after-create ordering would briefly leave the project with no binding.
moved {
  from = google_project_iam_member.workstation_sa_user[0]
  to   = google_project_iam_member.service_account_user
}

# 2b. Optional: per-workstation runtime identities (off by default).
#
# Every workstation already runs as a service account (see 2). What this adds is letting
# Ringleader provision one per workstation user and bind roles to it, so a workstation can,
# say, read one bucket. That needs two capabilities the roles above deliberately do not
# grant, so with this off the feature fails closed with a 403 rather than doing something
# surprising:
#
#   - create/delete the per-user SA   -> roles/iam.serviceAccountAdmin
#   - bind roles to it on the project -> roles/resourcemanager.projectIamAdmin
#
# Please read before turning this on: roles/resourcemanager.projectIamAdmin lets the holder
# grant any role in this project to any principal, including roles/owner to itself. That is
# inherent -- setting a role binding on a project is project-IAM administration -- so enable
# it only in a project dedicated to Ringleader workstations.
#
# You can get runtime identities without it: create the service accounts and their role
# bindings yourself and name one on the workstation (providerConfig.gcp.serviceAccount). The
# VM still runs as it, and the actAs grant above is all Ringleader needs to attach one it did
# not create.
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

# 2c. Optional: egress control (off by default).
#
# Lets Ringleader restrict where your workstations may connect -- an allowlist of IP
# ranges and hosts declared in the workstation manifest, enforced by VPC firewall rules
# that Ringleader creates and keeps up to date. Without it, workstations can reach
# anything your network routes, which is the behaviour every deployment has today.
#
# Ringleader compiles each distinct policy into ONE firewall rule and targets it with a
# network tag, so a fleet of a hundred workstations sharing a policy costs one rule rather
# than a hundred. Moving a workstation between policies is a tag change, which
# roles/compute.instanceAdmin.v1 above already permits.
#
# A CUSTOM ROLE, not roles/compute.securityAdmin. That predefined role is the usual answer
# and it is wider than this needs -- it also carries Cloud Armor security policies, SSL
# policies and certificates. The five permissions below are what managing VPC firewall rules
# actually takes, per Google's own documentation, and nothing else in this project is
# reachable with them.
#
# If a firewall rule create is ever denied on a project where this is enabled, the first
# permission to add is compute.networks.updatePolicy. Google's firewall-rules documentation
# does not list it, which is why it is not here.
resource "google_project_iam_custom_role" "egress" {
  count       = var.enable_egress_control ? 1 : 0
  project     = var.project_id
  role_id     = var.egress_role_id
  title       = "Ringleader Egress Control"
  description = "Manage the VPC firewall rules that restrict where Ringleader workstations may connect."

  permissions = [
    "compute.firewalls.create",
    "compute.firewalls.delete",
    "compute.firewalls.get",
    "compute.firewalls.list",
    "compute.firewalls.update",
  ]

  depends_on = [google_project_service.iam]
}

resource "google_project_iam_member" "egress" {
  count   = var.enable_egress_control ? 1 : 0
  project = var.project_id
  role    = google_project_iam_custom_role.egress[0].id
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

# Two independent pins: the token's audience and its subject must both match your org.
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
#
# A GCP VPC is a GLOBAL resource whose subnets are regional, and instances in any region
# reach each other on internal addresses with no peering. That makes multi-region cheap
# here in a way it is not on AWS or Azure: add a region by adding a subnet (see
# additional_regions), and one gateway VM can serve all of them.

resource "google_compute_network" "workstations" {
  count                   = var.create_network ? 1 : 0
  project                 = var.project_id
  name                    = "${var.name_prefix}-vpc"
  auto_create_subnetworks = false

  depends_on = [google_project_service.compute]
}

resource "google_compute_subnetwork" "workstations" {
  count                    = var.create_network ? 1 : 0
  project                  = var.project_id
  name                     = "${var.name_prefix}-workstations"
  region                   = var.region
  network                  = google_compute_network.workstations[0].id
  ip_cidr_range            = var.subnet_cidr
  private_ip_google_access = true
}

# A home for the future DNS / HTTPS proxy VM -- created empty, and only if you ask.
#
# Ringleader's egress control can point workstations at a proxy that resolves names and
# terminates HTTPS for the hosts you allow. That VM is not built yet, but where it will
# live is worth settling now: giving it a subnet of its own means the firewall rules that
# permit workstation -> proxy traffic can name one stable range instead of one VM's address.
#
# It costs nothing to leave in place -- GCP does not bill for a subnet -- and Cloud NAT
# below already covers every range in this region, so the proxy gets upstream egress with
# no extra work.
resource "google_compute_subnetwork" "gateway" {
  count                    = var.create_network && var.create_gateway_subnet ? 1 : 0
  project                  = var.project_id
  name                     = "${var.name_prefix}-gateway"
  region                   = var.region
  network                  = google_compute_network.workstations[0].id
  ip_cidr_range            = var.gateway_subnet_cidr
  private_ip_google_access = true
}

# Extra regions, in the SAME global VPC.
#
# One entry per region you want workstations in, mapped to that region's subnet range;
# GCP refuses overlapping ranges within a VPC, so a collision fails the apply rather than
# breaking routing later.
#
# Cloud Router and Cloud NAT are regional, so each extra region gets its own pair -- a
# subnet without them comes up and cannot reach the Ringleader control plane.
resource "google_compute_subnetwork" "additional" {
  for_each                 = var.create_network ? var.additional_regions : {}
  project                  = var.project_id
  name                     = "${var.name_prefix}-workstations-${each.key}"
  region                   = each.key
  network                  = google_compute_network.workstations[0].id
  ip_cidr_range            = each.value
  private_ip_google_access = true
}

resource "google_compute_router" "additional" {
  for_each = var.create_network ? var.additional_regions : {}
  project  = var.project_id
  name     = "${var.name_prefix}-router-${each.key}"
  region   = each.key
  network  = google_compute_network.workstations[0].id
}

resource "google_compute_router_nat" "additional" {
  for_each                           = var.create_network ? var.additional_regions : {}
  project                            = var.project_id
  name                               = "${var.name_prefix}-nat-${each.key}"
  region                             = each.key
  router                             = google_compute_router.additional[each.key].name
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}

resource "google_compute_router" "workstations" {
  count   = var.create_network ? 1 : 0
  project = var.project_id
  name    = "${var.name_prefix}-router"
  region  = var.region
  network = google_compute_network.workstations[0].id
}

resource "google_compute_router_nat" "workstations" {
  count                              = var.create_network ? 1 : 0
  project                            = var.project_id
  name                               = "${var.name_prefix}-nat"
  region                             = var.region
  router                             = google_compute_router.workstations[0].name
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"

  # ERRORS_ONLY, not ALL: a NAT that exhausts its ports otherwise fails silently, and the
  # only symptom is a workstation that comes up and cannot reach the Ringleader control
  # plane -- which looks like a Ringleader outage from inside the box. Error-only logging is
  # a small, bounded volume in Cloud Logging; full logging on a busy subnet is not.
  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}

# Inbound SSH -- the difference between a workstation that comes up and one you can use.
#
# A custom-mode VPC has no firewall rules and GCP's implied rule denies all ingress.
# Ringleader's setup traffic is fine with that: a workstation only needs egress to reach the
# control plane, which Cloud NAT above provides. But `rl shell`, `rl tmux`, port-forwards and
# VS Code Web all dial the workstation on TCP 22 directly -- there is no bastion, proxy or SSH
# tunnel -- so with no rule here the workstation comes up healthy, reports Ready, and nobody
# can get into it.
#
# Leave ssh_source_ranges empty and no rule is created. Choose that only if you reach the
# subnet privately (VPN / Interconnect / VPC peering) from wherever you run `rl`. Otherwise
# list the public CIDRs your engineers connect from. 0.0.0.0/0 is accepted but is a decision,
# not a default.
resource "google_compute_firewall" "ssh" {
  count     = var.create_network && length(var.ssh_source_ranges) > 0 ? 1 : 0
  project   = var.project_id
  name      = "${var.name_prefix}-allow-ssh"
  network   = google_compute_network.workstations[0].name
  direction = "INGRESS"

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_ranges = var.ssh_source_ranges
  target_tags   = [var.workstation_network_tag]
}

locals {
  # The secondary SSH port. Fixed by Ringleader, so it is a constant here rather than a
  # variable: you never have to know the number, and it cannot drift from the port
  # Ringleader actually dials. A wrong value would be a rule that exists, reads correctly in
  # the console, and admits nothing.
  secondary_ssh_port = 2222
}

# A second SSH port -- created only if you ask for it.
#
# Some Ringleader workstation types run their own SSH daemon on a secondary port inside the
# VM, while the VM's own sshd keeps 22, and `rl shell` dials that port for such a workstation.
# Others never use it; Ringleader tells you which you are running. If in doubt, leave
# secondary_ssh_source_ranges empty -- the default creates nothing, and a configuration that
# does not set it plans and applies exactly as it did before the variable existed.
#
# It carries its own tag rather than reusing the one above, so the port opens on the
# workstations that need it and on nothing else. Put both tags on those workstations, since
# the rule above still supplies their TCP 22:
#
#   providerConfig.gcp.networkTags: [ringleader-workstation, ringleader-secondary-ssh]
resource "google_compute_firewall" "secondary_ssh" {
  count     = var.create_network && length(var.secondary_ssh_source_ranges) > 0 ? 1 : 0
  project   = var.project_id
  name      = "${var.name_prefix}-allow-secondary-ssh"
  network   = google_compute_network.workstations[0].name
  direction = "INGRESS"

  allow {
    protocol = "tcp"
    ports    = [tostring(local.secondary_ssh_port)]
  }

  source_ranges = var.secondary_ssh_source_ranges
  target_tags   = [var.secondary_ssh_network_tag]
}

# Workstation-to-workstation traffic inside the subnet -- off unless you ask for it.
#
# A custom-mode VPC has no firewall rules and GCP denies ingress by default, so today two
# workstations here cannot reach each other at all, not even ping. That is a real posture: a
# compromised box cannot scan its neighbours. It is also a real limit, and which one you want
# is yours to choose.
#
# It admits tcp/udp/icmp from the workstation subnet ranges only, never from the internet,
# and is scoped to the workstation tag so anything else in this VPC is unaffected.
resource "google_compute_firewall" "internal" {
  count     = var.create_network && var.allow_internal_traffic ? 1 : 0
  project   = var.project_id
  name      = "${var.name_prefix}-allow-internal"
  network   = google_compute_network.workstations[0].name
  direction = "INGRESS"

  source_ranges = concat([var.subnet_cidr], values(var.additional_regions))
  target_tags   = [var.workstation_network_tag]

  allow { protocol = "tcp" }
  allow { protocol = "udp" }
  allow { protocol = "icmp" }
}
