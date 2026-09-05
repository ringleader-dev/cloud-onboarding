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

variable "identity_role_id" {
  type        = string
  default     = "ringleaderManagedIdentities"
  description = <<-EOT
    Id of the custom role that lets Ringleader create and delete the role-less service
    accounts it attaches to the machines it runs here. Change it only if that id is already
    taken in this project -- a custom role id cannot be reused for 7 days after deletion, so
    a re-apply soon after a destroy may need a different one.
  EOT

  validation {
    condition     = can(regex("^[a-zA-Z0-9_.]{3,64}$", var.identity_role_id))
    error_message = "identity_role_id must be 3-64 characters of [a-zA-Z0-9_.] (GCP custom role ids allow no hyphens)."
  }
}

# --- Artifact storage in a bucket of yours (on by default) -------------------

variable "enable_artifact_storage" {
  type        = bool
  default     = true
  description = <<-EOT
    Let Ringleader hold artifact payloads -- sealed agent-session transcripts, workflow file
    outputs, files a workstation publishes -- in a Cloud Storage bucket in THIS project rather
    than in Ringleader's own. On by default; set false to opt out.

    With it off, those bytes go to a bucket Ringleader owns, which is where they go today. That
    is not a failure and nothing degrades; what you cannot then answer is "which of our data is
    in whose account, under whose key", so take this if that question is ever going to be asked
    of you.

    Two widths, and artifact_storage_bucket picks between them:

      - MANAGED (leave artifact_storage_bucket unset). Ringleader creates and converges its own
        buckets here, so their names, lifecycle rules and layout can change without asking you to
        re-apply anything. The grant is confined to buckets whose name starts with "ringleader-",
        by an IAM condition on the binding -- it reaches nothing else in this project, including
        buckets you already have.
      - NAMED (set artifact_storage_bucket). You create one bucket, keep its lifecycle and its
        encryption key yours, and Ringleader gets object access to that one bucket and nothing
        else. It cannot create, reshape or delete a bucket at all.

    Neither width grants any permission to SET an IAM policy, so Ringleader cannot widen its own
    access to this project's storage, and neither grants storage.hmacKeys.* -- an HMAC key is a
    long-lived static credential and this onboarding is keyless throughout.

    Granting it does nothing on its own: until a Ringleader namespace declares a Storage object
    naming a bucket, no payload is written here.
  EOT
}

variable "artifact_storage_bucket" {
  type        = string
  default     = ""
  description = <<-EOT
    The one bucket Ringleader may write artifact payloads to, when you would rather own it than
    let Ringleader create one. Empty -- the default -- takes the managed width instead; see
    enable_artifact_storage.

    Set it to a bucket that already exists in this project. The grant is then bound to that
    bucket alone, and carries no bucket create, update or delete: its location, its lifecycle
    rules and its default encryption key stay yours to set, which is the point of this width.
    Hand the same name back to Ringleader as the Storage object's spec.bucket.

    Ringleader reads the bucket's default-encryption configuration and its location and reports
    both back on that object, so "are these transcripts under our own key, in our own region"
    is answerable without asking us. Reading is all it does with them -- it never sets an
    encryption key and never adds an envelope of its own.
  EOT
}

variable "artifact_storage_role_id" {
  type        = string
  default     = "ringleaderArtifactStorage"
  description = <<-EOT
    Id of the custom role created when enable_artifact_storage is set. Change it only if that
    id is already taken in this project -- a custom role id cannot be reused for 7 days after
    deletion, so a re-apply soon after a destroy may need a different one. The managed width
    derives a second id from this one by appending "Provision"; see main.tf for why it cannot
    be one role.
  EOT

  validation {
    condition     = can(regex("^[a-zA-Z0-9_.]{3,55}$", var.artifact_storage_role_id))
    error_message = "artifact_storage_role_id must be 3-55 characters of [a-zA-Z0-9_.] (GCP custom role ids allow no hyphens; the limit is 55 rather than 64 to leave room for the derived Provision id)."
  }
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

variable "network_cidr" {
  type        = string
  default     = null
  description = <<-EOT
    The /16 this landing pad's subnets are carved out of. REQUIRED whenever create_network is
    set, and there is deliberately no default:

      network_cidr = "10.80.0.0/16"   # a NEW landing pad -- GCP's own block
      network_cidr = "10.60.0.0/16"   # what this module created BEFORE it derived anything

    Pick the second if you have already applied this module on its defaults. It reproduces
    every range you have byte for byte, and the apply is a no-op.

    Why you are being asked. The three subnet ranges below used to default into 10.60.x, which
    is the block the AWS module allocates -- so a customer onboarding both clouds on the
    documented happy path held two networks that overlap, and could never join them with a VPN
    or an interconnect. Each cloud now has a block of its own: AWS 10.60-10.69, Azure
    10.70-10.79, GCP 10.80-10.89.

    Moving the default silently was not an option. A subnet's ip_cidr_range is force-new, so a
    module that quietly renumbered would DESTROY the subnet every existing workstation sits in,
    and Terraform cannot tell a first apply from a hundredth. Refusing to guess is the only
    shape that is safe in both directions -- which is what the AWS and Azure modules do with
    their region_indexes maps, for the same reason.

    One /16 is enough for every region: a GCP VPC is GLOBAL and its subnets are regional, so
    every region joins this one network (see additional_regions). The rest of the 10.80-10.89
    block is yours for a second project or a second org.
  EOT

  validation {
    condition     = var.network_cidr == null || can(cidrhost(var.network_cidr, 0))
    error_message = "network_cidr must be a CIDR block, e.g. 10.80.0.0/16."
  }
}

variable "subnet_cidr" {
  type        = string
  default     = null
  description = <<-EOT
    Primary IP range for the optional workstations subnet.

    Unset -- the default -- takes the first /20 of network_cidr, which is 10.80.0.0/20 on a new
    landing pad and 10.60.0.0/20 for anyone who set network_cidr to the range they already had.
    It follows network_cidr wherever you move it, so there is no second value to keep in step.
  EOT
}

variable "additional_regions" {
  type        = map(string)
  default     = {}
  description = <<-EOT
    Extra regions to place workstations in, as region => subnet CIDR, e.g.

      { "europe-west1" = "10.80.16.0/20", "asia-southeast1" = "10.80.32.0/20" }

    A GCP VPC is global and its subnets are regional, so these join the same VPC as the
    primary subnet and reach it on internal addresses with no peering -- which is why
    multi-region is cheap here and expensive on AWS and Azure. Ranges must not overlap; GCP
    refuses an overlapping subnet, so a mistake fails the apply rather than breaking routing
    later.

    These are yours to allocate: nothing derives them from network_cidr, so keep them inside
    whichever /16 you gave it (the example above assumes 10.80.0.0/16) and clear of the gateway
    and governed ranges at the top of it.

    Each region also gets its own Cloud Router and Cloud NAT, because both are regional and a
    subnet without them comes up unable to reach the Ringleader control plane.
  EOT
}

# --- A reserved range beside the DNS / HTTPS proxy's own (on by default) -----

variable "create_gateway_subnet" {
  type        = bool
  default     = true
  description = <<-EOT
    Carve an empty range beside the workstations one. On by default; set false to opt out.
    Needs create_network.

    NOTHING IS PLACED IN IT, and that is the difference from the AWS and Azure modules. On GCP
    the route that steers a workstation at the proxy is scoped by NETWORK TAG, and the proxy VM
    carries no such tag -- so it sits in the workstations subnet harmlessly, Ringleader builds
    it there, and EgressGateway.spec.subnet is refused on this provider. Do not hand this
    range back.

    It is on by default because GCP does not bill for a subnet and the three modules then
    address alike, which is what keeps a later renumbering from colliding. Set it false if you
    would rather not carry an unused range.
  EOT
}

variable "gateway_subnet_cidr" {
  type        = string
  default     = null
  description = <<-EOT
    IP range for the gateway subnet, when create_gateway_subnet is set.

    Unset -- the default -- takes the 241st /24 of network_cidr (10.80.240.0/24 on a new landing
    pad), which sits well clear of the workstations range so growing that subnet later does not
    collide. It follows network_cidr wherever you move it. Set it only to override.
  EOT
}

# --- A subnet for the boxes a gateway governs (OFF by default -- GCP does not need one) ------

variable "create_governed_subnet" {
  type        = bool
  default     = false
  description = <<-EOT
    Reserve a subnet for the workstations a gateway governs. OFF by default, and it is the one
    switch here that differs from the AWS and Azure modules, where the same subnet is on.

    On those clouds a route table attaches to a SUBNET, so a gateway steers every box in the one
    it is given, and a governed fleet needs a range of its own or the ungoverned workstations
    beside it lose their egress. On GCP the steering route is scoped by NETWORK TAG -- the tag
    providerConfig.gcp.networkTags already sets -- so a box is governed by carrying that tag and
    by nothing else, and an untagged workstation on the same subnet is untouched.

    So this buys no isolation the tag does not already give you. Turn it on if you want a
    governed fleet in a range of its own for firewall rules of your own to name, or to keep one
    manifest shape across all three clouds. GCP does not bill for a subnet either way.
  EOT
}

variable "governed_subnet_cidr" {
  type        = string
  default     = null
  description = <<-EOT
    IP range for the governed subnet, when create_governed_subnet is set.

    Unset -- the default -- takes the 15th /20 of network_cidr (10.80.224.0/20 on a new landing
    pad), immediately below the gateway subnet, which groups the two egress-control ranges
    together and leaves the workstations range free to grow. Set it only to override, and keep
    it clear of every entry in additional_regions.
  EOT
}
