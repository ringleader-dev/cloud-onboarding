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
  default = false
}

# Who may reach the workstations, and on what. Both are forwarded to the module below, so a value
# set in terraform.tfvars actually takes effect -- a variable this root did not declare would be
# accepted with a warning and then IGNORED, leaving you with a plan that opens nothing.
variable "ssh_source_ranges" {
  type    = list(string)
  default = []
}

variable "secondary_ssh_source_ranges" {
  type    = list(string)
  default = []
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
}

output "handoff" {
  value = module.ringleader.handoff
}
