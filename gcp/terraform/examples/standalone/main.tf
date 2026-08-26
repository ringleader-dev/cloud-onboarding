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

  project_id            = var.project_id
  ringleader_issuer_url = var.ringleader_issuer_url
  org_uid               = var.org_uid
  create_network        = var.create_network

  ssh_source_ranges           = var.ssh_source_ranges
  secondary_ssh_source_ranges = var.secondary_ssh_source_ranges
}

output "handoff" {
  value = module.ringleader.handoff
}
