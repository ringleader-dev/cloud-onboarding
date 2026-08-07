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
variable "create_network" {
  type    = bool
  default = false
}

module "ringleader" {
  source = "../.."

  project_id            = var.project_id
  ringleader_issuer_url = var.ringleader_issuer_url
  org_uid               = var.org_uid
  create_network        = var.create_network
}

output "handoff" {
  value = module.ringleader.handoff
}
