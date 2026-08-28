variable "ringleader_issuer_url" {
  type        = string
  description = "Ringleader's OIDC issuer origin, provided by Ringleader, e.g. https://oidc-app.ringleader.dev. No trailing slash."

  validation {
    condition     = can(regex("^https://[^/]+$", var.ringleader_issuer_url))
    error_message = "ringleader_issuer_url must be an https origin with no path or trailing slash."
  }
}

variable "org_uid" {
  type        = string
  description = <<-EOT
    Your Ringleader organization id, provided by Ringleader. A lowercase RFC-4122 UUID.
    Only a Ringleader token carrying sub = org:<org_uid> can federate in.
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

  validation {
    condition     = can(regex("^[a-zA-Z0-9_+=,.@-]{1,64}$", var.role_name))
    error_message = "role_name must be a valid IAM role name (1-64 chars of [a-zA-Z0-9_+=,.@-])."
  }
}

variable "max_session_duration" {
  type        = number
  default     = 3600
  description = <<-EOT
    Maximum lifetime, in seconds, of the temporary credentials Ringleader mints by assuming
    this role. AWS allows 3600-43200; 3600 is both AWS's default and this module's, so setting
    it changes nothing on an existing role.

    The short ceiling is deliberate: Ringleader re-mints before expiry, so it costs nothing
    and it bounds how long a leaked credential is worth anything.
  EOT

  validation {
    condition     = var.max_session_duration >= 3600 && var.max_session_duration <= 43200
    error_message = "max_session_duration must be between 3600 and 43200 seconds (AWS's own bounds)."
  }
}

variable "permissions_boundary_arn" {
  type        = string
  default     = null
  description = "Optional IAM permissions boundary to attach to the onboarding role, for accounts that require one."
}

# --- Restrict the role to specific regions ------------------------------------

variable "allowed_regions" {
  type        = list(string)
  default     = []
  description = <<-EOT
    Regions the role may act in. Empty (the default) places no region condition -- the role
    can create workstations in any region of this account, since the account is the boundary.
    Set it to the region(s) you configure on the CloudIdentity (providerConfig.aws.region) to
    bound the role to exactly those.
  EOT
}

# --- Per-workstation runtime identities, instance profiles (on by default) ----

variable "enable_workstation_identities" {
  type        = bool
  default     = true
  description = <<-EOT
    Let Ringleader attach an EC2 instance profile to a workstation, so the workstation runs
    as an IAM role (to read one bucket, say). On by default; set false to opt out.

    It grants the onboarding role iam:PassRole, scoped to roles under
    workstation_identity_path and to ec2.amazonaws.com only. That is the minimum the feature
    needs -- RunInstances with an IamInstanceProfile requires the caller to be able to pass
    that role -- and nothing more; the passable roles are still ones you create under that
    path, so with no roles there it grants reach over nothing.

    Set false and the feature fails closed with an AccessDenied; nothing else is affected.
  EOT
}

variable "workstation_identity_path" {
  type        = string
  default     = "/ringleader-workstations/"
  description = "IAM path the onboarding role may iam:PassRole from, when enable_workstation_identities is set. Put per-workstation roles under this path so nothing else in the account is passable."
}

# --- Egress control (on by default) -------------------------------------------

variable "enable_egress_control" {
  type        = bool
  default     = true
  description = <<-EOT
    Let Ringleader manage the security groups that restrict where your workstations may
    connect. On by default; set false to opt out.

    It grants six security-group actions, a security-group-rules read, and
    ec2:ModifyNetworkInterfaceAttribute -- bounded to the VPCs in egress_vpc_ids, and to
    allowed_regions if set. Ringleader compiles each distinct egress policy into one security
    group and attaches it to the workstations carrying that policy, so a fleet sharing a
    policy costs one group -- which matters, because AWS caps an ENI at 5 security groups and
    a region at 2,500.

    The two ingress actions in that set are for the DNS / HTTPS proxy VM, whose own group has
    to admit workstation traffic. Read the actions_granted and egress_scope outputs to see
    exactly what was granted and how tightly it is bounded.

    Granting it does not restrict anything on its own: until you declare an egress policy on
    a workstation, nothing changes. It is on by default so that declaring one later does not
    need a second onboarding pass.
  EOT
}

variable "egress_vpc_ids" {
  type        = list(string)
  default     = []
  description = <<-EOT
    VPC ids the egress permissions are confined to, when enable_egress_control is set. The
    security-group actions then apply only to groups in these VPCs.

    Leave it empty and this module uses the VPC it created (create_network = true). If you
    bring your own network and leave this empty too, the permissions are bounded by region
    alone, which lets Ringleader manage security groups anywhere in that region -- so name
    your VPC here if you brought one.
  EOT
}

# --- Network landing pad, on by default (public subnet + internet gateway) ----

variable "create_network" {
  type        = bool
  default     = true
  description = <<-EOT
    Create a minimal VPC + public subnet + internet gateway + security group for workstation
    NICs. On by default; set false and supply your own subnet and security group instead.

    The subnet is public (routed to an internet gateway), which gives a workstation both
    egress to come up and, with a public IP and the security-group rule, inbound SSH. The VPC,
    subnet, gateway and security group are all free; the NAT gateway below is not.
  EOT
}

variable "vpc_cidr" {
  type        = string
  default     = "10.60.0.0/16"
  description = <<-EOT
    CIDR for the optional VPC. One region's worth.

    Give every region its own range from the first apply. An AWS VPC is regional, so a second
    region is a second VPC, and joining them later needs an inter-region Transit Gateway,
    which cannot route overlapping CIDRs. Re-applying this module in another region on the
    default would produce two VPCs that can never be peered, and the fix at that point is to
    renumber and re-onboard. A simple plan: 10.60.0.0/16 for the first region, 10.61.0.0/16
    for the second, and so on.
  EOT
}

variable "subnet_cidr" {
  type        = string
  default     = "10.60.0.0/20"
  description = "CIDR for the optional workstations subnet. Must sit inside vpc_cidr."
}

variable "availability_zone" {
  type        = string
  default     = null
  description = "AZ for the optional subnets (default: the first AZ in the provider's region). The workstations and gateway subnets share it, because AWS charges for cross-AZ traffic in both directions."
}

variable "ssh_source_ranges" {
  type        = list(string)
  default     = []
  description = <<-EOT
    CIDRs allowed to reach workstations on TCP 22, when create_network is set. Empty (the
    default) opens no inbound rule.

    Ringleader has no bastion and no SSH tunnel: `rl shell`, `rl tmux`, port-forwards and
    VS Code Web all dial the workstation on 22. So with no rule, workstations come up and
    report Ready but nobody can get into them -- correct only if you reach the subnet
    privately (VPN / Direct Connect / peering) from wherever you run `rl`. Otherwise list the
    CIDRs your engineers connect from. 0.0.0.0/0 is accepted but is a decision, not a default.
  EOT
}

variable "secondary_ssh_source_ranges" {
  type        = list(string)
  default     = null
  description = <<-EOT
    CIDRs allowed to reach the secondary SSH port (TCP 2222) on the workstations security
    group, when create_network is set.

    Unset -- the default -- mirrors ssh_source_ranges, on the reasoning that if you opened 22
    to your engineers you almost certainly want 2222 open to the same people. Set it to []
    to close the port explicitly, or to a narrower list to open it to fewer.

    Some Ringleader workstation types run their own SSH daemon on that port inside the
    instance, beside the instance's own sshd on 22, and `rl shell` dials it instead of 22 for
    those. Others never use it, and for those the rule is harmless.

    Like the rule for 22, this applies to every instance in the workstations security group.
    Give the workstations that need the port a security group of their own if that is too
    broad.

    The port itself is not a variable: Ringleader fixes it, and this module supplies it.
  EOT
}

variable "create_nat_gateway" {
  type        = bool
  default     = true
  description = <<-EOT
    Create a NAT gateway and a private route table, so anything on this VPC without a public
    IP still has egress -- a workstation created with providerConfig.aws.assignPublicIp:
    false, or the gateway subnet below (which requires it).

    This is the one default that costs money: a NAT gateway bills per hour plus data
    processing, whether or not anything uses it. Set it false, along with
    create_gateway_subnet, if all your workstations get public IPs -- the internet gateway
    already gives those egress for free.
  EOT
}

# --- A subnet for the future DNS / HTTPS proxy VM (on by default) ------------

variable "create_gateway_subnet" {
  type        = bool
  default     = true
  description = <<-EOT
    Reserve a private subnet for the DNS / HTTPS proxy VM that Ringleader's hostname-level
    egress control will use. On by default; set false to opt out. Needs create_network and
    create_nat_gateway.

    The VM itself is not built yet and this creates nothing but an empty subnet, which AWS
    does not bill for. Carving the range now means the security-group rules that permit
    workstation -> proxy traffic can name one stable range instead of one instance's address,
    and saves renumbering later.
  EOT
}

variable "gateway_subnet_cidr" {
  type        = string
  default     = "10.60.240.0/24"
  description = <<-EOT
    CIDR for the gateway subnet, when create_gateway_subnet is set. Must sit inside vpc_cidr,
    and the default sits well clear of the workstations range so growing that subnet later
    does not collide. If you changed vpc_cidr for a second region, change this to match.
  EOT
}

variable "tags" {
  type        = map(string)
  default     = {}
  description = "Extra tags to put on every resource this module creates."
}
