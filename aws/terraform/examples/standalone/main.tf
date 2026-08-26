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
      version = ">= 5.0"
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

variable "secondary_ssh_source_ranges" {
  type    = list(string)
  default = []
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

  # A public-subnet landing pad: egress out (so a workstation can come up) + inbound SSH
  # from your ranges.
  create_network    = true
  ssh_source_ranges = var.ssh_source_ranges

  # Off unless you set it: the secondary SSH port some workstation types use.
  secondary_ssh_source_ranges = var.secondary_ssh_source_ranges
}

output "handoff" {
  value = module.ringleader_onboarding.handoff
}
