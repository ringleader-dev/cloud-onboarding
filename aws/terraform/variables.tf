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

variable "role_name" {
  type        = string
  default     = "ringleader-workstations"
  description = "Name of the IAM role Ringleader assumes via AssumeRoleWithWebIdentity. Its ARN is what you hand back to Ringleader."
}

variable "permissions_boundary_arn" {
  type        = string
  default     = null
  description = "Optional IAM permissions boundary to attach to the onboarding role (belt-and-suspenders in accounts that require one)."
}

# --- Optional: restrict the role to specific regions --------------------------

variable "allowed_regions" {
  type        = list(string)
  default     = []
  description = <<-EOT
    Regions the role may act in. Empty (the default) places no region condition —
    the role can create workstations in any region of THIS account (the account is
    the boundary). Set it to the region(s) you configure on the CloudIdentity
    (providerConfig.aws.region) to bound the role to exactly those.
  EOT
}

# --- Optional: per-workstation runtime identities (instance profiles) ---------

variable "enable_workstation_identities" {
  type        = bool
  default     = false
  description = <<-EOT
    Let Ringleader attach an EC2 instance profile to a workstation (a workstation that runs
    AS an IAM role, e.g. to read one bucket). Off by default.

    Turning it on grants the onboarding role iam:PassRole, scoped to roles under
    workstation_identity_path. That is the minimum the feature needs (RunInstances
    with an IamInstanceProfile requires the caller to be able to pass that role) and
    nothing more; the passable roles are still ones YOU create under that path.

    Left off, the feature fails closed with an AccessDenied rather than doing
    something surprising; nothing else is affected.
  EOT
}

variable "workstation_identity_path" {
  type        = string
  default     = "/ringleader-workstations/"
  description = "IAM path the onboarding role may iam:PassRole from, when enable_workstation_identities is set. Put per-workstation roles under this path so nothing else in the account is passable."
}

# --- Optional network landing pad (public subnet + internet gateway) ----------

variable "create_network" {
  type        = bool
  default     = false
  description = <<-EOT
    Create a minimal VPC + public subnet + internet gateway + security group for
    workstation NICs. Off by default; supply your own subnet + security group if you
    already have one. The subnet is PUBLIC (route to an internet gateway), which
    gives a workstation both egress (to come up) and, with a public IP and the
    security-group rule below, inbound SSH. No NAT gateway is created (it bills by the
    hour); a purely private workstation needs one — see create_nat_gateway.
  EOT
}

variable "vpc_cidr" {
  type        = string
  default     = "10.60.0.0/16"
  description = "CIDR for the optional VPC."
}

variable "subnet_cidr" {
  type        = string
  default     = "10.60.0.0/20"
  description = "CIDR for the optional workstations subnet."
}

variable "availability_zone" {
  type        = string
  default     = null
  description = "AZ for the optional subnet (default: the first AZ in the provider's region)."
}

variable "ssh_source_ranges" {
  type        = list(string)
  default     = []
  description = <<-EOT
    CIDRs allowed to reach workstations on TCP 22, when create_network is set. Empty
    (the default) opens NO inbound rule.

    Ringleader has no bastion and no SSH tunnel: `rl shell`, `rl tmux`, port-forwards
    and VS Code Web all dial the workstation on 22. So with no rule, workstations come up and report
    Ready but nobody can get into them -- correct ONLY if you reach the subnet
    privately (VPN / Direct Connect / peering) from wherever you run `rl`. Otherwise
    list the CIDRs your engineers connect from. 0.0.0.0/0 is accepted but is a
    decision, not a default.
  EOT
}

variable "secondary_ssh_source_ranges" {
  type        = list(string)
  default     = []
  description = <<-EOT
    OPT-IN, off by default. CIDRs allowed to reach the SECONDARY SSH port (TCP 2222) on the
    workstations security group, when create_network is set.

    Empty -- the default -- opens NO rule at all. A configuration that leaves this unset admits
    exactly what it admitted before this variable existed.

    Some Ringleader workstation types run their own SSH daemon on that port inside the instance,
    beside the instance's own sshd on 22, and `rl shell` dials it instead of 22 for those
    workstations. Other workstation types never use it. Ringleader tells you which you are
    running; if in doubt, leave this empty -- an unopened port costs you nothing but a workstation
    you cannot reach.

    Like the rule for 22, this applies to every instance in the workstations security group. Give
    the workstations that need the port a security group of their own if that is too broad.

    The port itself is not a variable: Ringleader fixes it, and this module supplies it.
  EOT
}

variable "create_nat_gateway" {
  type        = bool
  default     = false
  description = <<-EOT
    Also create a NAT gateway so a workstation with NO public IP
    (providerConfig.aws.assignPublicIp: false) still has egress to come up.
    Off by default because a NAT gateway bills per hour plus data processing. Leave it
    off if your workstations get public IPs (the default) -- the internet gateway
    already gives those egress for free.
  EOT
}

variable "tags" {
  type        = map(string)
  default     = {}
  description = "Extra tags to put on every resource this module creates."
}
