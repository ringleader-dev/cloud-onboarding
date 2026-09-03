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
# Plus, all on by default and each one a variable you can set to false:
#   - a VPC + subnet + Cloud NAT landing pad (egress out; inbound SSH only from the
#     CIDRs you name),
#   - a reserved subnet for the DNS / HTTPS proxy VM egress control will use,
#   - egress control, which lets Ringleader manage the firewall rules that restrict
#     where your workstations can connect, and
#   - per-workstation runtime identities.
#
# The defaults grant what Ringleader needs for the features available today, so turning
# one on later does not mean a second onboarding pass. See variables.tf for what each
# costs, and the README for how to switch any of them off.
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
#   compute              the VM lifecycle, and the network landing pad
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
# carries. This is not the runtime-identity feature below: a GCE workstation
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

# This grant used to sit behind enable_workstation_identities, which was then off by default, so
# a project onboarded on the documented defaults could not boot a workstation at all. It is
# now unconditional, and this block carries the existing binding over rather than destroying
# and recreating it -- the two addresses are the same project/role/member, and an arbitrary
# destroy-after-create ordering would briefly leave the project with no binding.
moved {
  from = google_project_iam_member.workstation_sa_user[0]
  to   = google_project_iam_member.service_account_user
}

# 2b. Per-workstation runtime identities (on by default; enable_workstation_identities).
#
# Every workstation already runs as a service account (see 2). What this adds is letting
# Ringleader provision one per workstation user and bind roles to it, so a workstation can,
# say, read one bucket. It needs two capabilities the roles above do not carry:
#
#   - create/delete the per-user SA   -> roles/iam.serviceAccountAdmin
#   - bind roles to it on the project -> roles/resourcemanager.projectIamAdmin
#
# This is the broadest grant the module makes, and the one default most worth a deliberate
# decision. roles/resourcemanager.projectIamAdmin lets the holder grant any role in this
# project to any principal, including roles/owner to itself -- inherent, since setting a role
# binding on a project is project-IAM administration. It is why this onboarding asks for a
# project dedicated to Ringleader workstations, and in a shared project you should set
# enable_workstation_identities = false.
#
# You can also get runtime identities without it: create the service accounts and their role
# bindings yourself and name one on the workstation (providerConfig.gcp.serviceAccount). The
# VM still runs as it, and the actAs grant above is all Ringleader needs to attach one it did
# not create. With the variable false the feature fails closed with a 403; nothing else is
# affected.
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

# 2c. Egress control (on by default; enable_egress_control).
#
# Lets Ringleader restrict where your workstations may connect -- an allowlist of IP
# ranges and hosts declared in the workstation manifest, enforced by VPC firewall rules
# that Ringleader creates and keeps up to date. Without it, workstations can reach
# anything your network routes, which is the behaviour every deployment has today.
#
# Ringleader compiles each distinct policy into ONE firewall rule and targets it with a
# network tag, so a fleet of a hundred workstations sharing a policy costs one rule rather
# than a hundred. Moving a workstation between policies is a tag change, which
# roles/compute.instanceAdmin.v1 above already permits. The rules are static: they are
# written when the policy changes, never per connection and never per DNS answer.
#
# The route permissions are for restricting by HOSTNAME rather than by address range, which
# needs the workstation's traffic to arrive at a Ringleader-run proxy. On GCP that steering
# is a custom static route with a next-hop instance, scoped by the same network tag -- so it
# needs no extra subnet, and no change inside the workstation, where a box's own root could
# undo it.
#
# A CUSTOM ROLE, not roles/compute.securityAdmin. That predefined role is the usual answer
# and it is wider than this needs -- it also carries Cloud Armor security policies, SSL
# policies and certificates. The permissions below are what managing VPC firewall rules and
# routes actually takes, per Google's own documentation, and nothing else in this project is
# reachable with them.
#
# compute.networks.updatePolicy is the one that is easy to leave out and hard to diagnose:
# creating a custom static route needs it in addition to compute.routes.create. Google's
# firewall-rules documentation does not list it for firewall rules, so it may be redundant
# there -- but it is required for routes, and a role that has it once covers both.
#
# THE PRIORITY BAND, and the one way a policy is defeated on this cloud. GCE evaluates firewall
# rules lowest-number-first, and Ringleader writes a policy's allowances at 900 and its
# default-deny at 1000 -- both far below GCP's implied allow-all egress at 65535, which is what
# makes the deny bite. Everything under 900 is left free ON PURPOSE, so an operator can always
# override us in their own VPC.
#
# The corollary binds this file: an EGRESS rule added below with a priority under 900 and an
# `allow` clause silently defeats every policy in this VPC, while Ringleader goes on reporting
# them enforced -- it checks the objects it wrote, not yours. Every rule this module creates is
# INGRESS, and that is a property to keep. See gcp/README.md, "What can defeat a policy here".
resource "google_project_iam_custom_role" "egress" {
  count       = var.enable_egress_control ? 1 : 0
  project     = var.project_id
  role_id     = var.egress_role_id
  title       = "Ringleader Egress Control"
  description = "Manage the VPC firewall rules and routes that restrict where Ringleader workstations may connect."

  permissions = [
    "compute.firewalls.create",
    "compute.firewalls.delete",
    "compute.firewalls.get",
    "compute.firewalls.list",
    "compute.firewalls.update",
    "compute.routes.create",
    "compute.routes.delete",
    "compute.routes.get",
    "compute.routes.list",
    "compute.networks.updatePolicy",
  ]

  depends_on = [google_project_service.iam]
}

# Not granted, and deliberately: GCP's own FQDN filtering.
#
# Google can do hostname filtering natively, through FQDN objects in a network firewall
# POLICY rule. It is the only native option on any of the three clouds priced in the same
# order as running a small VM, and it may turn out to be the right answer for some customers.
#
# It is not granted here because taking it needs two further grants, and one of them is
# sharper than it looks:
#
#   - firewall POLICY management (compute.firewallPolicies.create/update/use plus
#     compute.networks.setFirewallPolicy) -- policy rules are a different object from the VPC
#     firewall rules above, and FQDN objects exist only in them; and
#   - resource-manager TAG administration, because a policy rule targets a SECURE tag rather
#     than the network tags Ringleader already sets. Tag administration is a documented
#     privilege-escalation path in an organization that uses tags in IAM conditions -- whoever
#     can set a tag can satisfy a condition written against it.
#
# So this is left as a deliberate opt-in rather than folded into the default: it buys a
# capability nobody has committed to using, at a cost that depends on how your organization
# uses tags. If you want it, add a second custom role with those permissions and bind it to
# the same service account -- nothing else in this module has to change.

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

# --- Network landing pad, on by default (egress out; inbound only via ssh_source_ranges) ---
#
# A GCP VPC is a GLOBAL resource whose subnets are regional, and instances in any region
# reach each other on internal addresses with no peering. That makes multi-region cheap
# here in a way it is not on AWS or Azure: add a region by adding a subnet (see
# additional_regions), and one gateway VM can serve all of them.

# The ranges are DERIVED from one /16 rather than defaulted three times over, so moving the
# network moves every subnet with it and there is no second literal to forget.
#
# The /16 has to be DECLARED, because Terraform cannot discover it and the answer differs. This
# module used to default into 10.60.x, which is the block the AWS module allocates, so a customer
# onboarding both clouds on the documented happy path held two overlapping networks. GCP's block
# is 10.80-10.89 now -- but a subnet's ip_cidr_range is force-new, so simply moving the default
# would DESTROY the subnet every existing workstation sits in. Refusing silence is the only shape
# that is right for both a new landing pad and an existing one; the precondition below says so in
# the message, naming both answers.
#
# Unlike its AWS and Azure siblings this takes no region index. A GCP VPC is GLOBAL, so one /16
# serves every region (additional_regions carves the extra subnets out of it) and there is no
# second network to keep distinct.
locals {
  # A placeholder so the expressions below stay evaluable when nothing is declared; the precondition
  # is what actually refuses that case, with a message naming both branches, and every reader of
  # these locals carries the same create_network count -- so it is never reached on a successful
  # apply. It is GCP's OWN block rather than the historical 10.60 deliberately: an unreachable
  # fallback should still fail in the safe direction, and 10.60 is the range the AWS module
  # allocates, which is the collision this variable exists to remove.
  network_cidr = coalesce(var.network_cidr, "10.80.0.0/16")

  # The offsets are the AWS module's, so the same /16 produces the same three subnets on both
  # clouds: the first /20, the 15th /20 immediately below the gateway range, and the 241st /24.
  subnet_cidr          = var.subnet_cidr != null ? var.subnet_cidr : cidrsubnet(local.network_cidr, 4, 0)
  governed_subnet_cidr = var.governed_subnet_cidr != null ? var.governed_subnet_cidr : cidrsubnet(local.network_cidr, 4, 14)
  gateway_subnet_cidr  = var.gateway_subnet_cidr != null ? var.gateway_subnet_cidr : cidrsubnet(local.network_cidr, 8, 240)
}

resource "google_compute_network" "workstations" {
  count                   = var.create_network ? 1 : 0
  project                 = var.project_id
  name                    = "${var.name_prefix}-vpc"
  auto_create_subnetworks = false

  depends_on = [google_project_service.compute]

  # Skipped entirely when create_network is false: a customer who brings their own subnet carves
  # no range here and has nothing to declare.
  lifecycle {
    precondition {
      condition     = var.network_cidr != null
      error_message = "network_cidr is unset, so this landing pad cannot tell a NEW allocation from one that already exists -- and it must not guess, because a subnet's range is force-new and a wrong answer destroys the subnet your workstations are in. Set network_cidr = \"10.60.0.0/16\" to keep the ranges this module created before it derived them (an existing landing pad then plans as a no-op), or network_cidr = \"10.80.0.0/16\" for a new one -- 10.80-10.89 is GCP's own block, clear of the AWS module's 10.60-10.69 and the Azure module's 10.70-10.79."
    }
  }
}

resource "google_compute_subnetwork" "workstations" {
  count                    = var.create_network ? 1 : 0
  project                  = var.project_id
  name                     = "${var.name_prefix}-workstations"
  region                   = var.region
  network                  = google_compute_network.workstations[0].id
  ip_cidr_range            = local.subnet_cidr
  private_ip_google_access = true
}

# A home for the future DNS / HTTPS proxy VM -- created empty, and on by default.
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
  ip_cidr_range            = local.gateway_subnet_cidr
  private_ip_google_access = true
}

# An optional home for the WORKSTATIONS that gateway governs -- and the one place this module
# differs from its AWS and Azure siblings, where the same subnet is on by default.
#
# On those clouds a route table attaches to a SUBNET, so a gateway steers every box in the one
# it takes, and a governed fleet needs a subnet of its own or the ungoverned boxes beside it
# lose their egress. On GCP steering is a custom static route scoped by NETWORK TAG -- the same
# tag providerConfig.gcp.networkTags already sets -- so a box is governed by carrying the tag
# and by nothing else. An untagged workstation on the same subnet is not steered and keeps its
# egress. GCP therefore needs no governed subnet, and this is off by default.
#
# It exists anyway, for the operator who wants one: to give a governed fleet its own range for
# firewall rules of their own to name, or simply to keep one manifest shape across three clouds.
# It buys no isolation that the tag does not already give you.
resource "google_compute_subnetwork" "governed" {
  count                    = var.create_network && var.create_governed_subnet ? 1 : 0
  project                  = var.project_id
  name                     = "${var.name_prefix}-governed"
  region                   = var.region
  network                  = google_compute_network.workstations[0].id
  ip_cidr_range            = local.governed_subnet_cidr
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

  # Unset mirrors ssh_source_ranges: if you opened 22 to your engineers you almost certainly
  # want 2222 open to the same people. An explicit [] closes the port.
  secondary_ssh_ranges = var.secondary_ssh_source_ranges == null ? var.ssh_source_ranges : var.secondary_ssh_source_ranges
}

# A second SSH port, opened to the same ranges as 22 unless you say otherwise.
#
# Some Ringleader workstation types run their own SSH daemon on a secondary port inside the
# VM, while the VM's own sshd keeps 22, and `rl shell` dials that port for such a workstation.
# Others never use it, and for those this rule is harmless -- which is why it follows
# ssh_source_ranges rather than making you find out which kind you are running. Set
# secondary_ssh_source_ranges = [] to close it.
#
# It carries its own tag rather than reusing the one above, so the port opens on the
# workstations that need it and on nothing else. Put both tags on those workstations, since
# the rule above still supplies their TCP 22:
#
#   providerConfig.gcp.networkTags: [ringleader-workstation, ringleader-secondary-ssh]
resource "google_compute_firewall" "secondary_ssh" {
  count     = var.create_network && length(local.secondary_ssh_ranges) > 0 ? 1 : 0
  project   = var.project_id
  name      = "${var.name_prefix}-allow-secondary-ssh"
  network   = google_compute_network.workstations[0].name
  direction = "INGRESS"

  allow {
    protocol = "tcp"
    ports    = [tostring(local.secondary_ssh_port)]
  }

  source_ranges = local.secondary_ssh_ranges
  target_tags   = [var.secondary_ssh_network_tag]
}

# Workstation-to-workstation traffic inside the subnet -- on unless you turn it off.
#
# This is the one default that widens rather than grants. Without it a custom-mode VPC has no
# firewall rules and GCP denies ingress, so two workstations cannot reach each other at all,
# not even ping -- a real posture, in which a compromised box cannot scan its neighbours. With
# it they can, which matches what Azure's default NSG rules already allow and is what
# workflows that split work across boxes need. Set allow_internal_traffic = false for the
# tighter posture.
#
# It admits tcp/udp/icmp from the workstation subnet ranges only, never from the internet,
# and is scoped to the workstation tag so anything else in this VPC is unaffected. The governed
# subnet is one of those ranges when you create one: a workstation does not stop being a
# workstation because a gateway steers it, and leaving it out would give a governed box a
# quietly different posture from the box beside it.
resource "google_compute_firewall" "internal" {
  count     = var.create_network && var.allow_internal_traffic ? 1 : 0
  project   = var.project_id
  name      = "${var.name_prefix}-allow-internal"
  network   = google_compute_network.workstations[0].name
  direction = "INGRESS"

  source_ranges = concat(
    [local.subnet_cidr],
    var.create_governed_subnet ? [local.governed_subnet_cidr] : [],
    values(var.additional_regions),
  )
  target_tags = [var.workstation_network_tag]

  allow { protocol = "tcp" }
  allow { protocol = "udp" }
  allow { protocol = "icmp" }
}
