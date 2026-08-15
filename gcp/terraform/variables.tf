variable "project_id" {
  type        = string
  description = "The GCP project Ringleader will place workstation VMs in (your billing/RBAC boundary)."
}

variable "ringleader_issuer_url" {
  type        = string
  description = <<-EOT
    Ringleader's OIDC issuer origin, provided by Ringleader, e.g.
    https://oidc-app.ringleader.dev. NO trailing slash.
  EOT

  validation {
    condition     = can(regex("^https://[^/]+$", var.ringleader_issuer_url))
    error_message = "ringleader_issuer_url must be an https origin with no path or trailing slash."
  }
}

variable "org_uid" {
  type        = string
  description = <<-EOT
    Your Ringleader organization id, provided by Ringleader. A lowercase RFC-4122
    UUID. Only a Ringleader token carrying sub = org:<org_uid> can federate in.
  EOT

  validation {
    condition     = can(regex("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", var.org_uid))
    error_message = "org_uid must be a lowercase RFC-4122 UUID (8-4-4-4-12 hex), as Ringleader gives it to you."
  }
}

variable "sa_account_id" {
  type        = string
  default     = "ringleader-workstations"
  description = "Account id (the part before @) of the onboarding service account."
}

variable "sa_display_name" {
  type        = string
  default     = "Ringleader Workstations"
  description = "Display name of the onboarding service account."
}

variable "pool_id" {
  type        = string
  default     = "ringleader"
  description = "Workload Identity Pool id. A deleted pool is soft-deleted for 30 days and its id stays reserved."
}

variable "provider_id" {
  type        = string
  default     = "oidc"
  description = "Workload Identity Pool provider id."
}

# --- Optional: per-workstation runtime identities ---------------------------

variable "enable_workstation_identities" {
  type        = bool
  default     = false
  description = <<-EOT
    Let Ringleader PROVISION a dedicated service account per workstation user and BIND ROLES to it
    (e.g. so one workstation can read one bucket). Off by default.

    This is not what makes a workstation run as an identity -- every workstation already does, on
    the project's default compute service account. It is only about Ringleader creating those
    accounts and granting them roles for you. You can get the same result without this by creating
    the service accounts yourself and naming one on the workstation
    (providerConfig.gcp.serviceAccount).

    SECURITY: this grants roles/resourcemanager.projectIamAdmin, which can grant ANY role in this
    project to ANY principal -- including roles/owner to itself. That is inherent (setting a role
    binding IS project-IAM administration), not an artifact of how this module is written. Turn it
    on ONLY in a project dedicated to Ringleader workstations.

    Left off, the feature fails closed with a 403; nothing else is affected.
  EOT
}

# --- Optional network landing pad (egress out; inbound only via ssh_source_ranges) ---

variable "create_network" {
  type        = bool
  default     = false
  description = "Create a minimal VPC + subnet + Cloud NAT for workstation NICs (egress out; inbound only via ssh_source_ranges). Off by default; provide your own subnet if you already have one."
}

variable "ssh_source_ranges" {
  type        = list(string)
  default     = []
  description = <<-EOT
    CIDRs allowed to reach workstations on TCP 22, when create_network is set. Empty (the default)
    creates NO inbound rule.

    Ringleader has no bastion and no SSH tunnel: `rl shell`, `rl tmux`, port-forwards and
    VS Code Web all dial the workstation on 22. So with no rule, workstations come up and
    report Ready but nobody can get into them -- correct ONLY if you reach the subnet
    privately (VPN / Interconnect / peering) from wherever you run `rl`. Otherwise list
    the CIDRs your engineers connect from.
  EOT
}

variable "workstation_network_tag" {
  type        = string
  default     = "ringleader-workstation"
  description = "Network tag the inbound-SSH rule targets. Put the same tag on your workstations (providerConfig.gcp.networkTags) so the rule applies to them and to nothing else in the VPC."
}

variable "region" {
  type        = string
  default     = "us-central1"
  description = "Region for the optional network landing pad."
}

variable "subnet_cidr" {
  type        = string
  default     = "10.60.0.0/20"
  description = "Primary IP range for the optional workstations subnet."
}
