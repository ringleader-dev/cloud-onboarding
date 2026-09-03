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

# Unset mirrors ssh_source_ranges; [] closes the second SSH port.
variable "secondary_ssh_source_ranges" {
  type    = list(string)
  default = null
}

# Egress control, and a home for the proxy VM it will eventually use. Both on by default;
# set either false in terraform.tfvars to opt out.
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

  enable_egress_control  = var.enable_egress_control
  create_gateway_subnet  = var.create_gateway_subnet
  create_governed_subnet = var.create_governed_subnet
}

output "handoff" {
  value = module.ringleader.handoff
}
