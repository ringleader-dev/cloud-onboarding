variable "project_id" {
  type        = string
  description = "The GCP project Ringleader will place workstation VMs in (your billing/RBAC boundary)."
}

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

# --- Per-workstation runtime identities (on by default) ---------------------

variable "enable_workstation_identities" {
  type        = bool
  default     = true
  description = <<-EOT
    Let Ringleader provision a dedicated service account per workstation user and bind roles
    to it (so one workstation can read one bucket, say). On by default; set false to opt out.

    This is not what makes a workstation run as an identity -- every workstation already
    does, on the project's default compute service account. It is only about Ringleader
    creating those accounts and granting them roles. You can get the same result without it
    by creating the service accounts yourself and naming one on the workstation
    (providerConfig.gcp.serviceAccount).

    This is the one default worth a deliberate decision, because it is the broadest grant
    this module makes: roles/resourcemanager.projectIamAdmin can grant any role in this
    project to any principal, including roles/owner to itself. That is inherent -- setting a
    role binding is project-IAM administration -- and it is why this onboarding asks for a
    project dedicated to Ringleader workstations. In a shared project, set this to false.

    Set false and the feature fails closed with a 403; nothing else is affected.
  EOT
}

# --- Egress control (on by default) -----------------------------------------

variable "enable_egress_control" {
  type        = bool
  default     = true
  description = <<-EOT
    Let Ringleader manage the VPC firewall rules that restrict where your workstations may
    connect. On by default; set false to opt out.

    It grants a custom project role with ten permissions and nothing else:
    compute.firewalls.* for the rules that carry an allowlist, compute.routes.* for the static
    route that steers a workstation's traffic at the DNS / HTTPS proxy when the policy names
    hostnames rather than address ranges, and compute.networks.updatePolicy, which creating
    that route additionally requires. Deliberately not roles/compute.securityAdmin, which also
    carries Cloud Armor security policies, SSL policies and certificates.

    Ringleader compiles each distinct egress policy into one firewall rule targeted by
    network tag, so a fleet sharing a policy costs one rule rather than one per workstation.
    The rules are static -- written when a policy changes, never per connection.

    GCP's own FQDN filtering is NOT included: it lives in firewall policy rules targeted by
    secure tags, so it would need firewall-policy management and resource-manager tag
    administration on top. See the note beside the role in main.tf.

    Granting it does not restrict anything on its own: until you declare an egress policy on
    a workstation, nothing changes. It is on by default so that declaring one later does not
    need a second onboarding pass.
  EOT
}

variable "egress_role_id" {
  type        = string
  default     = "ringleaderEgressControl"
  description = <<-EOT
    Id of the custom role created when enable_egress_control is set. Change it only if that
    id is already taken in this project -- a custom role id cannot be reused for 7 days after
    deletion, so a re-apply soon after a destroy may need a different one.
  EOT

  validation {
    condition     = can(regex("^[a-zA-Z0-9_.]{3,64}$", var.egress_role_id))
    error_message = "egress_role_id must be 3-64 characters of [a-zA-Z0-9_.] (GCP custom role ids allow no hyphens)."
  }
}

# --- Network landing pad, on by default (egress out; inbound only via ssh_source_ranges) ---

variable "create_network" {
  type        = bool
  default     = true
  description = <<-EOT
    Create a minimal VPC + subnet + Cloud NAT for workstation NICs (egress out; inbound only
    via ssh_source_ranges). On by default; set false and supply your own subnet instead.

    Worth knowing: Cloud NAT bills per hour and per GB, so this default starts a small meter
    even before you run a workstation. Set it false if you already have a subnet for these
    VMs -- everything else in this module works the same either way.
  EOT
}

variable "ssh_source_ranges" {
  type        = list(string)
  default     = []
  description = <<-EOT
    CIDRs allowed to reach workstations on TCP 22, when create_network is set. Empty (the
    default) creates no inbound rule.

    Ringleader has no bastion and no SSH tunnel: `rl shell`, `rl tmux`, port-forwards and
    VS Code Web all dial the workstation on 22. So with no rule, workstations come up and
    report Ready but nobody can get into them -- correct only if you reach the subnet
    privately (VPN / Interconnect / peering) from wherever you run `rl`. Otherwise list the
    CIDRs your engineers connect from.
  EOT
}

variable "workstation_network_tag" {
  type        = string
  default     = "ringleader-workstation"
  description = "Network tag the inbound-SSH rule targets. Put the same tag on your workstations (providerConfig.gcp.networkTags) so the rule applies to them and to nothing else in the VPC."
}

variable "secondary_ssh_source_ranges" {
  type        = list(string)
  default     = null
  description = <<-EOT
    CIDRs allowed to reach the secondary SSH port (TCP 2222) on the workstations you tag with
    secondary_ssh_network_tag, when create_network is set.

    Unset -- the default -- mirrors ssh_source_ranges, on the reasoning that if you opened 22
    to your engineers you almost certainly want 2222 open to the same people. Set it to []
    to close the port explicitly, or to a narrower list to open it to fewer.

    Some Ringleader workstation types run their own SSH daemon on that port inside the VM,
    beside the VM's own sshd on 22, and `rl shell` dials it instead of 22 for those. Others
    never use it, and for those the rule is harmless.

    The rule targets its own network tag, so it only ever reaches workstations you tag with
    it. The port itself is not a variable: Ringleader fixes it, and this module supplies it.
  EOT
}

variable "secondary_ssh_network_tag" {
  type        = string
  default     = "ringleader-secondary-ssh"
  description = <<-EOT
    Network tag the secondary-SSH rule targets, so that rule reaches only the workstations
    that need the port. Put it on those workstations alongside workstation_network_tag, e.g.
    providerConfig.gcp.networkTags: [ringleader-workstation, ringleader-secondary-ssh].
    Replacing the first tag rather than adding to it would take TCP 22 away with it.
  EOT
}

variable "name_prefix" {
  type        = string
  default     = "ringleader"
  description = <<-EOT
    Prefix for every resource the optional landing pad creates. The default reproduces the
    names this module has always used, so changing nothing changes nothing.

    Set it if those names are already taken in this project -- a second landing pad, or a
    ringleader-vpc you built earlier and kept. Without it the apply fails on a name collision
    with a resource this module does not own.
  EOT
}

variable "allow_internal_traffic" {
  type        = bool
  default     = true
  description = <<-EOT
    Let workstations reach each other (tcp/udp/icmp from the workstation subnet ranges).
    On by default; set false to opt out.

    This is the one default that widens rather than grants: with it off, a custom-mode VPC has
    no firewall rules and two workstations cannot reach each other at all, so a compromised box
    cannot scan its neighbours. On, they can. It matches what Azure's default NSG rules already
    allow, and it is what workflows that split work across boxes need.

    It never admits anything from outside the subnets. If your boxes never talk to each other,
    false is the tighter choice.
  EOT
}

variable "region" {
  type        = string
  default     = "us-central1"
  description = "Region for the optional network landing pad's first subnet, its Cloud Router and its Cloud NAT."
}

variable "subnet_cidr" {
  type        = string
  default     = "10.60.0.0/20"
  description = "Primary IP range for the optional workstations subnet."
}

variable "additional_regions" {
  type        = map(string)
  default     = {}
  description = <<-EOT
    Extra regions to place workstations in, as region => subnet CIDR, e.g.

      { "europe-west1" = "10.60.16.0/20", "asia-southeast1" = "10.60.32.0/20" }

    A GCP VPC is global and its subnets are regional, so these join the same VPC as the
    primary subnet and reach it on internal addresses with no peering -- which is why
    multi-region is cheap here and expensive on AWS and Azure. Ranges must not overlap; GCP
    refuses an overlapping subnet, so a mistake fails the apply rather than breaking routing
    later.

    Each region also gets its own Cloud Router and Cloud NAT, because both are regional and a
    subnet without them comes up unable to reach the Ringleader control plane.
  EOT
}

# --- A subnet for the future DNS / HTTPS proxy VM (on by default) ------------

variable "create_gateway_subnet" {
  type        = bool
  default     = true
  description = <<-EOT
    Reserve a subnet for the DNS / HTTPS proxy VM that Ringleader's hostname-level egress
    control will use. On by default; set false to opt out. Needs create_network.

    The VM itself is not built yet and this creates nothing but an empty subnet, which GCP
    does not bill for -- which is why it is on by default. Carving the range now means the
    firewall rules that permit workstation -> proxy traffic can name one stable range instead
    of one VM's address, and saves renumbering later.

    Cloud NAT already covers every range in this region, so the proxy will have upstream
    egress with no further setup.
  EOT
}

variable "gateway_subnet_cidr" {
  type        = string
  default     = "10.60.240.0/24"
  description = <<-EOT
    IP range for the gateway subnet, when create_gateway_subnet is set. The default sits well
    clear of the workstations range so growing that subnet later does not collide.
  EOT
}
