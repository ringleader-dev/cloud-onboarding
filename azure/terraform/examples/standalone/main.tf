# Ready-to-apply root: onboard ONE resource group with your own providers.
#
#   cp terraform.tfvars.example terraform.tfvars   # then edit
#   az login
#   terraform init && terraform apply
#   terraform output handoff                        # hand these back to Ringleader

terraform {
  required_version = ">= 1.5"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = ">= 3.80, < 5.0"
    }
    azuread = {
      source  = "hashicorp/azuread"
      version = ">= 3.0, < 4.0"
    }
  }
}

provider "azurerm" {
  subscription_id = var.subscription_id
  features {}
}
provider "azuread" {}

variable "subscription_id" { type = string }
variable "resource_group_name" { type = string }
variable "ringleader_issuer_url" { type = string }
variable "org_uid" { type = string }
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
  default = true
}

# Where the landing pad goes, and which /16 it takes. Both are forwarded below for the reason
# above -- a variable this root did not declare would be accepted with a warning and then
# IGNORED, leaving the second region on the first one's range.
variable "location" {
  type    = string
  default = "eastus"
}

variable "region_indexes" {
  type    = map(number)
  default = {}
}

# Bring your own range instead; unset derives it from region_indexes.
variable "vnet_address_space" {
  type    = string
  default = null
}

module "ringleader" {
  source = "../.."

  subscription_id       = var.subscription_id
  resource_group_name   = var.resource_group_name
  ringleader_issuer_url = var.ringleader_issuer_url
  org_uid               = var.org_uid
  create_network        = var.create_network

  ssh_source_ranges           = var.ssh_source_ranges
  secondary_ssh_source_ranges = var.secondary_ssh_source_ranges

  enable_egress_control  = var.enable_egress_control
  create_gateway_subnet  = var.create_gateway_subnet
  create_governed_subnet = var.create_governed_subnet

  # The landing pad's location and its range. region_indexes keys off location, so the same map
  # in a second region's tfvars gives that region a different /16 by construction.
  location           = var.location
  region_indexes     = var.region_indexes
  vnet_address_space = var.vnet_address_space
}

output "handoff" {
  value = module.ringleader.handoff
}
