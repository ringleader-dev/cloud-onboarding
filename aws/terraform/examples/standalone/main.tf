# Standalone root configuration: apply the Ringleader AWS onboarding module against
# one account/region with a landing-pad network. Copy terraform.tfvars.example to
# terraform.tfvars, fill in the two values Ringleader gave you, then:
#
#   terraform init && terraform apply
#
# Hand `terraform output handoff` back to Ringleader.

terraform {
  required_version = ">= 1.3"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0"
    }
  }
}

variable "region" {
  type        = string
  default     = "us-east-1"
  description = "AWS region to create the landing-pad network in, and to run workstations in."
}

variable "ringleader_issuer_url" {
  type = string
}

variable "org_uid" {
  type = string
}

variable "ssh_source_ranges" {
  type    = list(string)
  default = []
}

# Unset mirrors ssh_source_ranges; [] creates no rule for the second SSH port.
variable "secondary_ssh_source_ranges" {
  type    = list(string)
  default = null
}

# Egress control, a NAT gateway, and the subnet the proxy VM runs in. All on by default. The
# gateway subnet is PUBLIC and routed through the internet gateway, so it does not need the NAT
# gateway -- the two are independent, and the NAT gateway is the one of these that bills hourly.
# Hand `gateway_subnet_id` from the handoff back as Edge.spec.subnet; no gateway VM is
# built until you do.
variable "enable_egress_control" {
  type    = bool
  default = true
}

variable "create_nat_gateway" {
  type    = bool
  default = true
}

variable "create_gateway_subnet" {
  type    = bool
  default = true
}

variable "create_governed_subnet" {
  type    = bool
  default = true
}

# More governed subnets, one per namespace that runs its own proxy. Forwarded below, like the rest.
variable "additional_governed_subnets" {
  type    = map(string)
  default = {}
}

# Off by default: VPC flow logs bill per GB and grant Ringleader nothing. Both are forwarded below,
# like the rest.
variable "create_flow_logs" {
  type    = bool
  default = false
}

variable "flow_log_retention_days" {
  type    = number
  default = 365
}

# Which /16 each region's landing pad takes. Forwarded below, so a value set in
# terraform.tfvars actually takes effect -- a variable this root did not declare would be
# accepted with a warning and then IGNORED, leaving the second region on the first one's range.
variable "region_indexes" {
  type    = map(number)
  default = {}
}

# Bring your own range instead; unset derives it from region_indexes.
variable "vpc_cidr" {
  type    = string
  default = null
}

# --- Serving a second organization from this account -------------------------------
#
# Each of these defaults to the same constant the module has always used, so leaving them unset
# changes nothing. A SECOND Ringleader organization onboarding into this same account sets them,
# because the names below are unique within it. See ../../../README.md#serving-a-second-organization.

variable "role_name" {
  type        = string
  default     = "ringleader-workstations"
  description = "IAM role names are unique per account."
}

variable "flow_log_group_name" {
  type        = string
  default     = "ringleader-workstations-flow-logs"
  description = "Log group names are unique per account and region."
}

variable "workstation_identity_path" {
  type        = string
  default     = "/ringleader-workstations/"
  description = "The IAM path Ringleader may pass workstation roles under."
}

variable "artifact_storage_bucket" {
  type        = string
  default     = ""
  description = "A bucket YOU created, to take the narrower named width. Empty is the managed width, whose grant reaches every ringleader-* bucket in the account."
}

variable "enable_artifact_storage" {
  type        = bool
  default     = true
  description = "Let Ringleader hold artifact payloads in a bucket in THIS account. On by default. Setting it false is one of the two ways two organizations sharing an account keep their payloads apart; the other is naming a bucket each."
}

variable "artifact_storage_bucket_prefix" {
  type        = string
  default     = ""
  description = "A label of your own that the managed width's buckets must carry in their name, narrowing the grant from every ringleader-* bucket in this account to only ringleader-<this>*. Empty keeps the wider bound. Set it when one account serves several Ringleader organizations. Exactly eight lowercase letters or digits: the bound is a prefix match, so two labels of differing length could overlap and two of the same length never can."
}

provider "aws" {
  region = var.region
}

module "ringleader_onboarding" {
  source = "../../"

  ringleader_issuer_url = var.ringleader_issuer_url
  org_uid               = var.org_uid

  # Bound the role to the region you actually use.
  allowed_regions = [var.region]

  # The landing pad's range. region_indexes keys off the provider's region above, so the same
  # map in a second region's tfvars gives that region a different /16 by construction.
  region_indexes = var.region_indexes
  vpc_cidr       = var.vpc_cidr

  # A public-subnet landing pad: egress out (so a workstation can come up) + inbound SSH
  # from your ranges.
  create_network    = true
  ssh_source_ranges = var.ssh_source_ranges

  # Off unless you set it: the secondary SSH port some workstation types use.
  secondary_ssh_source_ranges = var.secondary_ssh_source_ranges

  enable_egress_control  = var.enable_egress_control
  create_nat_gateway     = var.create_nat_gateway
  create_gateway_subnet  = var.create_gateway_subnet
  create_governed_subnet = var.create_governed_subnet

  additional_governed_subnets = var.additional_governed_subnets

  create_flow_logs        = var.create_flow_logs
  flow_log_retention_days = var.flow_log_retention_days

  # The names a second organization in this account must change; see above.
  artifact_storage_bucket_prefix = var.artifact_storage_bucket_prefix
  enable_artifact_storage        = var.enable_artifact_storage
  artifact_storage_bucket        = var.artifact_storage_bucket
  role_name                      = var.role_name
  flow_log_group_name            = var.flow_log_group_name
  workstation_identity_path      = var.workstation_identity_path
}

output "handoff" {
  value = module.ringleader_onboarding.handoff
}
