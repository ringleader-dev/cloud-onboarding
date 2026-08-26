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

variable "secondary_ssh_source_ranges" {
  type        = list(string)
  default     = []
  description = <<-EOT
    OPT-IN, off by default. CIDRs allowed to reach the SECONDARY SSH port (TCP 2222) on the
    workstations you tag with secondary_ssh_network_tag, when create_network is set.

    Empty -- the default -- creates NO rule at all. A configuration that leaves this unset admits
    exactly what it admitted before this variable existed.

    Some Ringleader workstation types run their own SSH daemon on that port inside the VM, beside
    the VM's own sshd on 22, and `rl shell` dials it instead of 22 for those workstations. Other
    workstation types never use it. Ringleader tells you which you are running; if in doubt, leave
    this empty -- an unopened port costs you nothing but a workstation you cannot reach.

    The port itself is not a variable: Ringleader fixes it, and this module supplies it.
  EOT
}

variable "secondary_ssh_network_tag" {
  type        = string
  default     = "ringleader-secondary-ssh"
  description = <<-EOT
    Network tag the secondary-SSH rule targets, so that rule reaches only the workstations that
    need the port. Put it on those workstations ALONGSIDE workstation_network_tag, e.g.
    providerConfig.gcp.networkTags: [ringleader-workstation, ringleader-secondary-ssh].
    Replacing the first tag rather than adding to it would take TCP 22 away with it.
  EOT
}

variable "name_prefix" {
  type        = string
  default     = "ringleader"
  description = <<-EOT
    Prefix for every resource the optional landing pad creates. The default reproduces the names
    this module has always used, so changing nothing changes nothing.

    Set it if those names are already taken in this project -- a second landing pad, or a
    ringleader-vpc you built earlier and kept. Without it the apply fails on a name collision with a
    resource this module does not own.
  EOT
}

variable "allow_internal_traffic" {
  type        = bool
  default     = false
  description = <<-EOT
    Let workstations on this subnet reach EACH OTHER (tcp/udp/icmp from the subnet's own range).
    Off by default, and off is not an oversight.

    A custom-mode VPC has no firewall rules, so today two workstations here cannot reach each other
    at all -- which means a compromised box cannot scan its neighbours. Turn this on if your
    workflows need workstation-to-workstation traffic; leave it off otherwise. It never admits
    anything from outside the subnet.
  EOT
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
