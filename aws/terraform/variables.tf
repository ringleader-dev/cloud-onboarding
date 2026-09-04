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

It grants two sets, both bounded to the VPCs in egress_vpc_ids and to allowed_regions
    if set:

      - security-group actions, for the object each compiled policy becomes. Ringleader makes
        one group per distinct policy and attaches it to the workstations carrying that
        policy, so a fleet sharing a policy costs one group -- which matters, because AWS caps
        an ENI at 5 security groups and a region at 2,500. The two ingress actions are for the
        DNS / HTTPS proxy VM, whose own group has to admit workstation traffic.
      - subnet and route-table actions, which is how a workstation's traffic is made to arrive
        at that proxy. An AWS route table is per subnet, so per-policy steering needs a subnet
        per policy.

    ec2:ModifyNetworkInterfaceAttribute does double duty: moving a running workstation between
    security groups, and clearing the source/destination check on the proxy's own interface,
    without which AWS silently drops every packet it forwards.

    Read the actions_granted and egress_scope outputs to see exactly what was granted and how
    tightly it is bounded.

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

variable "region_indexes" {
  type        = map(number)
  default     = {}
  description = <<-EOT
    Which /16 each region's landing pad takes, as region => index. The VPC gets
    10.(60 + index).0.0/16 and every subnet below is carved out of it.

    REQUIRED whenever create_network is set and you have not set vpc_cidr, even for one region:

      region_indexes = {
        "us-east-1" = 0
      }

    Index 0 is 10.60.0.0/16, the range this module has always created, so naming your current
    region at 0 plans as a no-op. The declaration is what buys the enforcement: there is no
    signal in a fresh Terraform state that says "this is the second region", so a module that
    accepted silence would hand a second apply the first one's range without a word. Naming
    them is the signal.

    Onboarding a SECOND region: add it to the map and use the SAME map in BOTH regions' tfvars.

      region_indexes = {
        "us-east-1" = 0
        "eu-west-1" = 1
      }

    The module looks up the region it is actually applying in, so the two VPCs take
    10.60.0.0/16 and 10.61.0.0/16 whichever order you apply them in and whichever tfvars file
    you reach for. Copy a tfvars file to a second region and forget to extend the map and the
    plan FAILS, naming the region -- rather than silently taking 10.60.0.0/16 twice. Two
    regions cannot share an index either; the map is refused.

    That matters because an AWS VPC is regional: a second region is a second VPC, joining them
    later needs an inter-region Transit Gateway, and a Transit Gateway cannot route overlapping
    CIDRs. Two regions applied on one range can never be peered and the only fix is to renumber
    and re-onboard.

    What it still cannot catch, because Terraform cannot read another region's state: an
    operator who REPLACES an entry rather than adding one, moving a region onto an index
    another region already holds in a state this apply cannot see. Keep one map, shared.

    Indexes are 0-9, i.e. 10.60.0.0/16 through 10.69.0.0/16. The ceiling keeps this module
    clear of the Azure module's 10.70.0.0/16 block, so onboarding both clouds does not overlap
    them either. Past ten regions, or on your own IPAM, set vpc_cidr instead -- it overrides
    all of this, and then the allocation is yours to keep distinct.
  EOT

  validation {
    condition     = length(var.region_indexes) == length(distinct(values(var.region_indexes)))
    error_message = "region_indexes must give every region a DISTINCT index; two regions sharing one index is exactly the overlap this variable exists to prevent."
  }

  validation {
    condition     = alltrue([for i in values(var.region_indexes) : floor(i) == i && i >= 0 && i <= 9])
    error_message = "region_indexes values must be whole numbers 0-9, which allocate 10.60.0.0/16 through 10.69.0.0/16. Set vpc_cidr to bring your own range instead."
  }
}

variable "vpc_cidr" {
  type        = string
  default     = null
  description = <<-EOT
    CIDR for the optional VPC. One region's worth.

    Unset -- the default -- derives it from region_indexes: 10.(60 + index).0.0/16, which is
    10.60.0.0/16 for a single region and is what this module has always created. Set it to
    bring your own range, and then you own keeping every region distinct; see region_indexes
    for why that matters.
  EOT

  validation {
    condition     = var.vpc_cidr == null || can(cidrhost(var.vpc_cidr, 0))
    error_message = "vpc_cidr must be a CIDR block, e.g. 10.60.0.0/16."
  }
}

variable "subnet_cidr" {
  type        = string
  default     = null
  description = <<-EOT
    CIDR for the optional workstations subnet. Unset -- the default -- takes the first /20 of
    vpc_cidr, which is 10.60.0.0/20 on the default VPC range. Set it only to override; it must
    sit inside vpc_cidr.
  EOT

  validation {
    condition     = var.subnet_cidr == null || can(cidrhost(var.subnet_cidr, 0))
    error_message = "subnet_cidr must be a CIDR block, e.g. 10.60.0.0/20."
  }
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

# --- The subnet the DNS / HTTPS proxy VM runs in (on by default) -------------

variable "create_gateway_subnet" {
  type        = bool
  default     = true
  description = <<-EOT
    Reserve the subnet the DNS / HTTPS proxy VM for Ringleader's hostname-level egress control
    runs in. On by default; set false to opt out. Needs create_network.

    This creates nothing but an empty subnet and its route table, neither of which AWS bills
    for; Ringleader builds the VM itself once you declare an EgressGateway naming this subnet
    as spec.subnet. Carving the range now means the security-group rules that permit
    workstation -> proxy traffic can name one stable range instead of one instance's address,
    and saves renumbering later.

    It is public, routed through the internet gateway, and shares the workstations subnet's
    availability zone. Both are cost decisions: internet ingress is free, so a proxy with its
    own public address carries a fleet's volume for nothing, while the same bytes through a
    managed NAT gateway meter at $0.045/GB -- and AWS charges cross-AZ traffic in both
    directions, so a misplaced proxy costs more than the instance running it.
  EOT
}

variable "gateway_subnet_cidr" {
  type        = string
  default     = null
  description = <<-EOT
    CIDR for the gateway subnet, when create_gateway_subnet is set. Unset -- the default --
    takes the 241st /24 of vpc_cidr, which is 10.60.240.0/24 on the default VPC range. It
    follows vpc_cidr wherever you move it, so a second region needs no edit here.

    It sits well clear of the workstations range so growing that subnet later does not
    collide. A /24 is deliberate headroom: one gateway serves many policies from one subnet --
    it tells them apart by source address, not by where they sit -- so this range never has to
    grow per policy; the headroom is for a second gateway, or a second region's proxy.

    Set it only to override, and then it must sit inside vpc_cidr.
  EOT

  validation {
    condition     = var.gateway_subnet_cidr == null || can(cidrhost(var.gateway_subnet_cidr, 0))
    error_message = "gateway_subnet_cidr must be a CIDR block, e.g. 10.60.240.0/24."
  }
}

# --- A subnet for the boxes a gateway GOVERNS (on by default) ----------------

variable "create_governed_subnet" {
  type        = bool
  default     = true
  description = <<-EOT
    Reserve a second subnet -- the one you put the WORKSTATIONS a gateway governs in. On by
    default; set false to opt out. Needs create_network.

    A gateway steers a whole SUBNET, and it serves only the boxes it holds a policy for, so a
    steered subnet must hold governed boxes and nothing else: put one ungoverned workstation in
    it and that box loses its egress the moment steering lands. The landing pad's
    ringleader-workstations subnet is where EVERY workstation in the VPC goes, governed or not,
    which is why the governed fleet needs a range of its own.

    It is created EMPTY and with NO route table -- deliberately, and it is the whole point.
    Ringleader claims the subnet by creating its own table and associating it, and it refuses
    a subnet that already carries one, because taking over yours would need
    ec2:ReplaceRouteTableAssociation (which the grant does not include) and nothing could put
    yours back. Until a gateway steers it, a box in here has NO route off the subnet at all:
    the VPC's main route table carries only the local route. That is the fail-safe direction --
    a governed box reaches the internet THROUGH its gateway or not at all -- but it does mean
    the gateway has to exist before the boxes do.

    AWS does not bill for a subnet, so leaving this on costs nothing until you use it.
  EOT
}

variable "governed_subnet_cidr" {
  type        = string
  default     = null
  description = <<-EOT
    CIDR for the governed subnet, when create_governed_subnet is set. Unset -- the default --
    takes the 15th /20 of vpc_cidr, which is 10.60.224.0/20 on the default VPC range, and it
    follows vpc_cidr wherever you move it.

    That sits immediately below the gateway subnet at the top of the VPC, which groups the two
    egress-control ranges together and leaves the workstations range at the bottom free to grow
    from a /20 to a /17 without colliding with either.

    It is sized like the workstations subnet rather than like the gateway one: this holds a
    FLEET, where the gateway subnet holds a VM.

    Set it only to override, and then it must sit inside vpc_cidr.
  EOT

  validation {
    condition     = var.governed_subnet_cidr == null || can(cidrhost(var.governed_subnet_cidr, 0))
    error_message = "governed_subnet_cidr must be a CIDR block, e.g. 10.60.224.0/20."
  }
}

variable "tags" {
  type        = map(string)
  default     = {}
  description = "Extra tags to put on every resource this module creates."
}
