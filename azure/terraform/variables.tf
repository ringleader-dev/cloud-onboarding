variable "subscription_id" {
  type        = string
  description = "The subscription containing the resource group Ringleader will place workstation VMs in."
}

variable "resource_group_name" {
  type        = string
  description = "An EXISTING resource group you own. The role is scoped to it; this module does not create it."
}

variable "ringleader_issuer_url" {
  type        = string
  description = <<-EOT
    Ringleader's OIDC issuer origin, provided by Ringleader, e.g.
    https://oidc-app.ringleader.dev. NO trailing slash. Azure pins the issuer
    byte-exactly.
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

variable "app_display_name" {
  type        = string
  default     = "ringleader-workstations"
  description = "Display name for the Entra app registration Ringleader authenticates as."
}

variable "role_name" {
  type        = string
  default     = "Ringleader Workstation Operator"
  description = "Display name of the custom least-privilege role."
}

# --- Optional: per-workstation runtime identities ---------------------------

variable "enable_workstation_identities" {
  type        = bool
  default     = false
  description = <<-EOT
    Let Ringleader provision a dedicated user-assigned managed identity per workstation user and
    assign roles to it (a workstation that runs AS an identity). Off by default.

    It adds the Microsoft.ManagedIdentity CRUD + assign actions and Microsoft.Authorization
    roleAssignments write -- which built-in Contributor does NOT have either, so this is a
    capability no standard role grants by default. Scoped to this one resource group.

    Left off, the feature fails closed with a 403; nothing else is affected.
  EOT
}

# --- Optional: egress control -----------------------------------------------

variable "enable_egress_control" {
  type        = bool
  default     = false
  description = <<-EOT
    Let Ringleader manage the network security groups that restrict where your workstations
    may connect. Off by default, and off means nothing changes: workstations reach whatever
    your network routes, exactly as they do today.

    Turning it on adds seven NSG actions to the custom role -- read/write/delete on the group
    and its security rules, plus join/action, which is what lets Ringleader attach a group to
    a workstation's NIC. Still scoped to this one resource group.

    Ringleader compiles each distinct egress policy into one NSG and attaches it to the NICs
    of the workstations carrying that policy, so a fleet sharing a policy costs one group.
    That matters here: Azure caps an NSG at 1,000 rules and will not raise it.

    Leave it off if you only want workstations. You can enable it later by re-applying.
  EOT
}

# --- Optional: a subnet for the future DNS / HTTPS proxy VM ------------------

variable "create_gateway_subnet" {
  type        = bool
  default     = false
  description = <<-EOT
    Reserve a subnet for the DNS / HTTPS proxy VM that Ringleader's hostname-level egress
    control will use. Off by default. Requires create_network.

    The VM itself is not built yet and this creates nothing but an empty subnet, which Azure
    does not bill for. It is worth doing early because the NSG rules that permit
    workstation -> proxy traffic can then name one stable prefix instead of one VM's address,
    and because carving the range now avoids renumbering later.

    It shares the landing pad's NAT gateway, so the proxy will have upstream egress without a
    public IP.
  EOT
}

variable "gateway_subnet_prefix" {
  type        = string
  default     = "10.70.240.0/24"
  description = <<-EOT
    Prefix for the gateway subnet, when create_gateway_subnet is set. Must sit inside
    vnet_address_space, and the default sits well clear of the workstations subnet so growing
    that one later does not collide. If you changed vnet_address_space for a second region,
    change this to match.
  EOT
}

# --- Optional network landing pad (egress out; inbound only via ssh_source_ranges) ---

variable "create_network" {
  type        = bool
  default     = false
  description = "Create a minimal vnet + subnet + NAT gateway + NSG for workstation NICs (egress out; inbound only via ssh_source_ranges). Off by default; provide your own subnet if you already have one."
}

variable "ssh_source_ranges" {
  type        = list(string)
  default     = []
  description = <<-EOT
    CIDRs allowed to reach workstations on TCP 22, when create_network is set. Empty (the default)
    creates the NSG but NO inbound rule, which leaves the workstation unreachable from outside
    the VNet.

    Ringleader has no bastion and no SSH tunnel: `rl shell`, `rl tmux`, port-forwards and
    VS Code Web all dial the workstation on 22. So with no rule, workstations come up and
    report Ready but nobody can get into them -- correct ONLY if you reach the VNet
    privately (VPN / ExpressRoute / peering) from wherever you run `rl`. Otherwise list
    the CIDRs your engineers connect from.
  EOT
}

variable "secondary_ssh_source_ranges" {
  type        = list(string)
  default     = []
  description = <<-EOT
    OPT-IN, off by default. CIDRs allowed to reach the SECONDARY SSH port (TCP 2222) on the
    workstations subnet, when create_network is set.

    Empty -- the default -- creates NO rule at all. A configuration that leaves this unset admits
    exactly what it admitted before this variable existed.

    Some Ringleader workstation types run their own SSH daemon on that port inside the VM, beside
    the VM's own sshd on 22, and `rl shell` dials it instead of 22 for those workstations. Other
    workstation types never use it. Ringleader tells you which you are running; if in doubt, leave
    this empty -- an unopened port costs you nothing but a workstation you cannot reach.

    These ranges are the ONLY narrowing available on Azure: an NSG attaches to the subnet and
    Azure has no per-VM tag to match, so the rule admits the port to every VM on this subnet.
    (On GCP the same rule is scoped to a network tag.) Give the workstations that need it a
    subnet of their own if that is too broad.

    The port itself is not a variable: Ringleader fixes it, and this module supplies it.
  EOT
}

variable "name_prefix" {
  type        = string
  default     = "ringleader"
  description = <<-EOT
    Prefix for every resource the optional landing pad creates. The default reproduces the names
    this module has always used, so changing nothing changes nothing.

    Set it if those names are already taken in this resource group -- a second landing pad, or a
    ringleader-vnet you built earlier and kept. Without it the apply fails on a name collision with a
    resource this module does not own.
  EOT
}

variable "location" {
  type        = string
  default     = "eastus"
  description = "Region for the optional network landing pad."
}

variable "vnet_address_space" {
  type        = string
  default     = "10.70.0.0/16"
  description = <<-EOT
    Address space for the optional vnet. One region's worth.

    Give every region its own range from the first apply. An Azure VNet is regional, so a
    second region is a second VNet, and joining them later needs global VNet peering, which
    cannot join overlapping address spaces. A simple plan: 10.70.0.0/16 for the first region,
    10.71.0.0/16 for the second, and so on.
  EOT
}

variable "subnet_prefix" {
  type        = string
  default     = "10.70.1.0/24"
  description = "Prefix for the optional workstations subnet. Must sit inside vnet_address_space."
}
