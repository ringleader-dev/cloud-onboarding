# Ready-to-apply root: onboard ONE project with your own google provider.
#
#   cp terraform.tfvars.example terraform.tfvars   # then edit
#   terraform init && terraform apply
#   terraform output handoff                        # hand these back to Ringleader

terraform {
  required_version = ">= 1.5"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 6.0"
    }
  }
}

# --- Serving a second organization from this project -------------------------------
#
# Each of these defaults to the same constant the module has always used, so leaving them unset
# changes nothing. A SECOND Ringleader organization onboarding into this same project sets them,
# because the names below are unique within it. See ../../../README.md#serving-a-second-organization.

variable "name_prefix" {
  type        = string
  default     = "ringleader"
  description = "Names the VPC, its subnets, the router, the NAT and the firewall rules."
}

variable "sa_account_id" {
  type        = string
  default     = "ringleader-workstations"
  description = "A service account id is unique per project."
}

variable "pool_id" {
  type        = string
  default     = "ringleader"
  description = "A pool id is unique per project, and a deleted one stays reserved for 30 days."
}

variable "identity_role_id" {
  type        = string
  default     = "ringleaderManagedIdentities"
  description = "A custom role id is unique per project."
}

variable "egress_role_id" {
  type        = string
  default     = "ringleaderEgressControl"
  description = "As above."
}

variable "artifact_storage_role_id" {
  type        = string
  default     = "ringleaderArtifactStorage"
  description = "As above. It names both roles: the second is this id with Provision appended."
}

variable "artifact_storage_bucket" {
  type        = string
  default     = ""
  description = "A bucket YOU created, to take the narrower named width. Empty is the managed width, whose grant reaches every ringleader-* bucket in the project."
}

variable "enable_artifact_storage" {
  type        = bool
  default     = true
  description = "Let Ringleader hold artifact payloads in a bucket in THIS project. On by default. Setting it false is one of the two ways two organizations sharing a project keep their payloads apart; the other is naming a bucket each."
}

variable "artifact_storage_bucket_prefix" {
  type        = string
  default     = ""
  description = "A label of your own that the managed width's buckets must carry in their name, narrowing the grant from every ringleader-* bucket in this project to only ringleader-<this>*. Empty keeps the wider bound. Set it when one project serves several Ringleader organizations. Exactly eight lowercase letters or digits: the bound is a prefix match, so two labels of differing length could overlap and two of the same length never can."
}

provider "google" {
  project = var.project_id
}

variable "project_id" { type = string }
variable "ringleader_issuer_url" { type = string }
variable "org_uid" { type = string }
# The /16 the landing pad's subnets are carved out of. Forwarded below, so a value set in
# terraform.tfvars actually takes effect -- a variable this root did not declare would be
# accepted with a warning and then IGNORED, and the module would refuse the apply.
variable "network_cidr" {
  type    = string
  default = null
}

variable "create_network" {
  type    = bool
  default = true
}

# Who may reach the workstations, and on what. Both are forwarded to the module below, so a value
# set in terraform.tfvars actually takes effect -- a variable this root did not declare would be
# accepted with a warning and then IGNORED, leaving you with a plan that opens nothing.
variable "ssh_source_ranges" {
  type    = list(string)
  default = []
}

# Unset mirrors ssh_source_ranges; [] creates no rule for the second SSH port.
variable "secondary_ssh_source_ranges" {
  type    = list(string)
  default = null
}

# Who may reach the EGRESS GATEWAY VM on the management ports, which is what keeps a workstation an
# egress policy STEERS reachable. Unset mirrors ssh_source_ranges; [] closes it. Forwarded below for
# the same reason as the two above.
variable "gateway_management_source_ranges" {
  type    = list(string)
  default = null
}

# Egress control, and an empty range reserved beside the workstations subnet. Both on by default;
# set either false in terraform.tfvars to opt out. NOTHING is placed in that range on GCP: the
# steering route here is scoped by network tag, so Ringleader runs the proxy VM in the
# workstations' own subnet and refuses Edge.spec.subnet on this provider.
variable "enable_egress_control" {
  type    = bool
  default = true
}

variable "create_gateway_subnet" {
  type    = bool
  default = true
}

variable "create_governed_subnet" {
  type    = bool
  default = false
}

# Off by default: VPC Flow Logs bill per GiB and grant Ringleader nothing. Forwarded below, like the
# rest.
variable "create_flow_logs" {
  type    = bool
  default = false
}

module "ringleader" {
  source = "../.."

  project_id            = var.project_id
  ringleader_issuer_url = var.ringleader_issuer_url
  org_uid               = var.org_uid
  create_network        = var.create_network

  # The landing pad's range. Required with a landing pad and deliberately undefaulted: a
  # subnet's range is force-new, so a module that guessed would destroy the subnet an existing
  # customer's workstations sit in. 10.80.0.0/16 for a new one, 10.60.0.0/16 to keep the ranges
  # this module created before it derived them.
  network_cidr = var.network_cidr

  ssh_source_ranges           = var.ssh_source_ranges
  secondary_ssh_source_ranges = var.secondary_ssh_source_ranges

  gateway_management_source_ranges = var.gateway_management_source_ranges

  enable_egress_control  = var.enable_egress_control
  create_gateway_subnet  = var.create_gateway_subnet
  create_governed_subnet = var.create_governed_subnet

  create_flow_logs = var.create_flow_logs

  # The names a second organization in this project must change; see above.
  artifact_storage_bucket_prefix = var.artifact_storage_bucket_prefix
  enable_artifact_storage        = var.enable_artifact_storage
  artifact_storage_bucket        = var.artifact_storage_bucket
  name_prefix                    = var.name_prefix
  sa_account_id                  = var.sa_account_id
  pool_id                        = var.pool_id
  identity_role_id               = var.identity_role_id
  egress_role_id                 = var.egress_role_id
  artifact_storage_role_id       = var.artifact_storage_role_id
}

output "handoff" {
  value = module.ringleader.handoff
}
