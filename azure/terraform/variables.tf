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

# --- One identity across several regions -------------------------------------
#
# An app registration is a tenant-wide object; the custom role is scoped to one resource group. So
# the FIRST region creates the identity and every region after it reuses that one, deploying only
# the role and the landing pad into its own group.

variable "create_identity" {
  type        = bool
  default     = true
  description = <<-EOT
    Create the Entra app registration, service principal and federated credential. True -- the
    default -- is the first (or only) region. Set it FALSE in every later region and pass
    existing_client_id and existing_principal_object_id from the first one's outputs: that apply
    grants the role in ITS OWN resource group to the identity you already handed Ringleader,
    instead of minting a second one you would have to hand back as well.
  EOT
}

variable "existing_client_id" {
  type        = string
  default     = null
  description = <<-EOT
    The first region's target_app_client_id, when create_identity is false. Ignored otherwise.
  EOT
}

variable "existing_principal_object_id" {
  type        = string
  default     = null
  description = <<-EOT
    The first region's service_principal_object_id, when create_identity is false. This is what the
    role assignment names, so a wrong value grants the role to the wrong principal -- take it from
    `terraform output service_principal_object_id` in the region that created the identity, not from
    the portal's app-registration blade (which shows the APPLICATION object id, a different value).
    Ignored when create_identity is true.
  EOT

  validation {
    # Refuse the half-configured pair at plan time. Reusing an identity needs BOTH ids, and a null
    # object id would otherwise reach the role deployment and fail deep inside ARM with a message
    # naming neither variable.
    condition     = var.create_identity || (var.existing_client_id != null && var.existing_principal_object_id != null)
    error_message = "create_identity = false needs both existing_client_id and existing_principal_object_id, from the first region's outputs."
  }
}

variable "deployment_name" {
  type        = string
  default     = "ringleader-onboarding"
  description = <<-EOT
    Name of the ARM deployment that carries the custom role. The default is right for a
    customer, who applies this module ONCE per resource group.

    Change it only when a single resource group holds TWO landing pads — one Ringleader origin
    per invocation, say a staging control plane and a test one sharing an account. An ARM
    deployment is a named resource in the resource group, so two invocations on the default
    would each overwrite the other's on every apply: both Terraform states would claim it, and
    each plan would show the other's roleName as drift, forever. Distinct names give each
    invocation its own deployment record; the role definitions they carry are already distinct
    because role_name is.
  EOT
}

variable "role_name" {
  type        = string
  default     = "Ringleader Workstation Operator"
  description = "Display name of the custom least-privilege role."
}

# --- Per-workstation runtime identities (on by default) ---------------------

variable "enable_workstation_identities" {
  type        = bool
  default     = true
  description = <<-EOT
    Let Ringleader provision a dedicated user-assigned managed identity per workstation user and
    assign roles to it (a workstation that runs AS an identity). On by default; set false to opt out.

    It adds the Microsoft.ManagedIdentity CRUD + assign actions and Microsoft.Authorization
    roleAssignments write -- which built-in Contributor does NOT have either, so this is a
    capability no standard role grants by default. Scoped to this one resource group.

    Left off, the feature fails closed with a 403; nothing else is affected.
  EOT
}

# --- Egress control (on by default) -----------------------------------------

variable "enable_egress_control" {
  type        = bool
  default     = true
  description = <<-EOT
    Let Ringleader manage the network security groups that restrict where your workstations
    may connect. On by default; set false to opt out.

    It adds twenty-three actions to the custom role, still scoped to this one resource group:

      - NSG read/write/delete on the group and its security rules, plus join/action, which is
        what lets Ringleader attach a group to a workstation's NIC;
      - application-security-group read/write/delete, plus joinIpConfiguration/action and
        joinNetworkSecurityRule/action. Ringleader will put each workstation's NIC in a group it
        made and name that group as the destination of the inbound SSH rule it writes in your
        subnet NSG, so that one rule holds steady as workstations come and go. The
        two join actions are the ones people forget: read,
        write and delete grant neither. The rule ships in Ringleader, and the grant arrives early
        so it does not cost you a second apply; and
      - route-table read/write/delete (with its routes and join/action) plus subnet write and
        delete, which is how a workstation's traffic is steered to the DNS / HTTPS proxy when a
        policy names hostnames. An Azure route table attaches per subnet, so per-policy
        steering needs a subnet per policy -- and one Ringleader creates, it must also collect.

    Ringleader compiles each distinct egress policy into one NSG and attaches it to the NICs
    of the workstations carrying that policy, so a fleet sharing a policy costs one group.
    That matters here: Azure caps an NSG at 1,000 rules and will not raise it.

    Granting it restricts no outbound traffic until you declare an egress policy on a
    workstation. Ringleader also uses it to write the rules that admit SSH to the workstations it
    creates. On a workstation with no policy, those rules narrow inbound traffic from outside the
    VNet to TCP 22 and 2222. It is on by default so that declaring a policy later does not need a
    second onboarding pass.
  EOT
}

# --- The subnet the DNS / HTTPS proxy VM runs in (on by default) -------------

# --- Artifact storage in a storage account of yours (on by default) ----------

variable "enable_artifact_storage" {
  type        = bool
  default     = true
  description = <<-EOT
    Let Ringleader hold artifact payloads -- sealed agent-session transcripts, workflow file
    outputs, files a workstation publishes -- in a storage account in THIS resource group rather
    than in Ringleader's own cloud. On by default; set false to opt out.

    With it off, those bytes go to a bucket Ringleader owns, which is where they go today.
    Nothing degrades and nothing fails; what you cannot then answer is "which of our data is in
    whose account, under whose key".

    It adds the Microsoft.Storage read actions plus the four blob DATA actions -- read, write,
    delete and add -- so access is by Entra ID and a short-lived token. It deliberately does NOT
    add listKeys or listAccountSas: an account key is a long-lived static credential, and this
    onboarding is keyless throughout.

    Two widths, and artifact_storage_account_name picks between them:

      - MANAGED (leave it unset). Ringleader also creates and converges the storage account and
        its containers, so their names, lifecycle rules and layout can change without asking you
        to re-apply.
      - NAMED (set it). Every account and container write and delete is dropped: Ringleader may
        put blobs in containers you made and may neither create, reshape nor delete an account or
        a container.

    Granting it does nothing on its own: until a Ringleader namespace declares a Storage object
    naming a destination, no payload is written here. The Azure Blob backend itself ships after
    the GCS one, so on this cloud the grant deliberately arrives before the feature -- that is
    what stops Azure support from costing every customer a second apply.
  EOT
}

variable "artifact_storage_account_name" {
  type        = string
  default     = ""
  description = <<-EOT
    The storage account Ringleader may write artifact payloads to, when you would rather own it
    than let Ringleader create one. Empty -- the default -- takes the managed width instead; see
    enable_artifact_storage.

    Read what this DOES and does not narrow. The custom role is scoped to this resource group,
    as every other action in it is, so naming an account narrows what Ringleader may DO -- no
    account or container writes at all -- and not which account it may reach. If you need the
    reach narrowed too, put the account in a resource group of its own; this module's boundary
    is one resource group and it does not pretend otherwise.

    Hand the name back to Ringleader alongside the container it should write to.
  EOT
}

variable "create_gateway_subnet" {
  type        = bool
  default     = true
  description = <<-EOT
    Reserve the subnet the DNS / HTTPS proxy VM for Ringleader's hostname-level egress control
    runs in. On by default; set false to opt out. Needs create_network.

    This creates nothing but an empty subnet, which Azure does not bill for; Ringleader builds
    the VM itself once you declare an EgressGateway naming this subnet as spec.subnet. It is
    worth doing early because the NSG rules that permit workstation -> proxy traffic can then
    name one stable prefix instead of one VM's address, and because carving the range now
    avoids renumbering later.

    The subnet is associated with the landing pad's NAT gateway, and that is what the gateway
    VM's egress rests on: it takes no public address of its own unless Ringleader is asked for
    one (EgressGateway.spec.publicAddress).
  EOT
}

variable "gateway_subnet_prefix" {
  type        = string
  default     = null
  description = <<-EOT
    Prefix for the gateway subnet, when create_gateway_subnet is set. Unset -- the default --
    takes the 241st /24 of vnet_address_space, which is 10.70.240.0/24 on the default VNet
    range. It follows vnet_address_space wherever you move it, so a second region needs no
    edit here, and it sits well clear of the workstations subnet so growing that one later does
    not collide.

    Set it only to override, and then it must sit inside vnet_address_space.
  EOT

  validation {
    condition     = var.gateway_subnet_prefix == null || can(cidrhost(var.gateway_subnet_prefix, 0))
    error_message = "gateway_subnet_prefix must be a CIDR block, e.g. 10.70.240.0/24."
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
    it and that box loses its egress the moment steering lands. The workstations subnet is where
    EVERY workstation in the VNet goes, governed or not, which is why the governed fleet needs a
    prefix of its own.

    It is created empty, carries the same NSG as the workstations subnet (so `rl shell` still
    reaches a box in it), and carries NEITHER a route table NOR a NAT gateway. Ringleader claims
    the subnet by putting its own UDR on it and declines one that already references a route
    table; and a governed box's egress is meant to be the gateway's, not a NAT gateway's.

    Azure's implicit default outbound access is disabled on it for the same reason, and that
    flag is fixed AT SUBNET CREATION -- setting it later replaces the subnet, so it has to be
    right on the first apply.

    Azure does not bill for a subnet, so leaving this on costs nothing until you use it.
  EOT
}

variable "governed_subnet_prefix" {
  type        = string
  default     = null
  description = <<-EOT
    Prefix for the governed subnet, when create_governed_subnet is set. Unset -- the default --
    takes the 15th /20 of vnet_address_space, which is 10.70.224.0/20 on the default VNet
    range, and it follows vnet_address_space wherever you move it.

    That sits immediately below the gateway subnet at the top of the VNet, which groups the two
    egress-control ranges together and leaves the workstations prefix at the bottom free to
    grow.

    It is sized like a fleet rather than like the gateway subnet, which holds one VM.

    Set it only to override, and then it must sit inside vnet_address_space.
  EOT

  validation {
    condition     = var.governed_subnet_prefix == null || can(cidrhost(var.governed_subnet_prefix, 0))
    error_message = "governed_subnet_prefix must be a CIDR block, e.g. 10.70.224.0/20."
  }
}

variable "additional_governed_subnets" {
  type        = map(string)
  default     = {}
  description = <<-EOT
    More governed subnets, beside the one create_governed_subnet reserves: a map of a label you
    choose to that subnet's address prefix. Empty by default. Needs create_network.

    A gateway steers a whole subnet, and a subnet belongs to one Ringleader namespace, so each
    namespace that runs its own gateway needs a governed subnet of its own. Add one entry per
    such namespace beyond the first. The label only names the subnet (governed-<label>) and keys
    it in the additional_governed_subnet_ids output. It means nothing to Ringleader, so naming
    it after the namespace that will use the subnet is a convenient choice.

    Each subnet is built exactly like the governed subnet above: the workstations NSG, no route
    table, no NAT gateway, and default outbound access disabled. There is no derived default, so
    each prefix must be written out. It must sit inside vnet_address_space and overlap no other
    subnet, or the apply fails. On the default VNet range, the six /20s from 10.70.128.0/20 to
    10.70.208.0/20 are free and leave the workstations prefix room to grow.

    Changing an entry's prefix changes the subnet in place, renaming a label replaces the subnet,
    and removing an entry deletes it. Azure refuses all three while anything is deployed in the
    subnet.
  EOT

  validation {
    condition     = alltrue([for label, prefix in var.additional_governed_subnets : can(regex("^[a-z0-9]([a-z0-9-]{0,38}[a-z0-9])?$", label)) && can(cidrhost(prefix, 0))])
    error_message = "additional_governed_subnets maps a label of lowercase letters, digits and hyphens (at most 40 characters, starting and ending with a letter or digit) to a CIDR block, e.g. { team-a = \"10.70.208.0/20\" }."
  }
}

# --- Network landing pad, on by default (egress out; SSH in via your rule and Ringleader's) ---

variable "create_network" {
  type        = bool
  default     = true
  description = <<-EOT
    Create a minimal vnet + subnet + NAT gateway + NSG for workstation NICs (egress out;
    inbound only through ssh_source_ranges and the one SSH rule Ringleader adds). On by
    default; set false and supply your own subnet instead.

    On Azure a workstation has no public IP unless you ask for one, so without a NAT gateway
    it has no egress and never comes up -- which is why this landing pad is the default here.
    The NAT gateway and its public IP do bill per hour, so set this false if you already have
    a subnet with egress for these VMs.
  EOT
}

variable "ssh_source_ranges" {
  type        = list(string)
  default     = []
  description = <<-EOT
    CIDRs allowed to reach every VM on the workstations and governed subnets on TCP 22, when
    create_network is set. Empty (the default) creates the NSG with NO inbound rule of yours.

    Ringleader has no bastion and no SSH tunnel: `rl shell`, `rl tmux`, port-forwards and
    VS Code Web all dial the workstation on 22. Ringleader adds its own rule to this NSG, at a
    priority between 3000 and 3999, admitting TCP 22 and 2222 from any address to the
    workstations it creates and to no other VM. List CIDRs here to reach the other VMs on those
    subnets, or to keep your engineers able to reach a workstation when Ringleader cannot write
    its rule. Such a workstation reports SSHAdmissionMissing.
  EOT
}

variable "secondary_ssh_source_ranges" {
  type        = list(string)
  default     = null
  description = <<-EOT
    CIDRs allowed to reach the secondary SSH port (TCP 2222) on the workstations subnet, when
    create_network is set.

    Unset -- the default -- mirrors ssh_source_ranges, on the reasoning that if you opened 22
    to your engineers you almost certainly want 2222 open to the same people. Set it to []
    to create no rule for the port, or to a narrower list to open it to fewer.

    Some Ringleader workstation types run their own SSH daemon on that port inside the VM,
    beside the VM's own sshd on 22, and `rl shell` dials it instead of 22 for those. Others
    never use it, and for those the rule is harmless. Ringleader's own rule already admits the
    port to the workstations it creates, as ssh_source_ranges describes.

    These ranges are the only narrowing available on Azure: an NSG attaches to the subnet and
    Azure has no per-VM tag to match, so the rule admits the port to every VM on this subnet.
    (On GCP the same rule is scoped to a network tag.) Give the workstations that need it a
    subnet of their own if that is too broad.

    The port itself is not a variable: Ringleader fixes it, and this module supplies it.
  EOT
}

variable "gateway_management_source_ranges" {
  type        = list(string)
  default     = null
  description = <<-EOT
    CIDRs allowed through the gateway subnet's NSG to the EGRESS GATEWAY VM on the management
    ports, when create_network and create_gateway_subnet are set.

    Unset -- the default -- mirrors ssh_source_ranges, so the engineers who could reach a
    workstation still can after an egress policy steers it. Set it to [] to close the rule, or to a
    narrower list to open it to fewer. Name no ssh_source_ranges and this opens nothing either.

    What it is for. A workstation an egress policy steers stops answering on its own address from
    outside the VNet, because the steering route also carries the reply to a connection the box
    never opened. The management connection then goes through the gateway VM, which forwards it to
    the box. Ringleader admits that traffic in the NSG on the gateway VM's NIC, but for inbound
    traffic Azure evaluates the subnet's NSG first and both must allow. This variable is the
    subnet's half.

    What it exposes. The rule admits TCP 22 and 30000-32767 into the gateway subnet. Ringleader puts
    only the gateway VM there, and the NSG on that VM's NIC still decides what reaches it. From the
    internet nothing is reachable until the gateway has a public address, which it has only when
    EgressGateway.spec.publicAddress asks for one. A forwarded connection keeps its source address,
    so the steered workstation's own NSG still decides whether to accept it.

    Set [] if you reach the VNet privately. Without the rule a steered workstation is reachable only
    from inside the VNet or a network joined to it. You do not supply the ports: the module carries
    them.
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

variable "region_indexes" {
  type        = map(number)
  default     = {}
  description = <<-EOT
    Which /16 each region's landing pad takes, as location => index. The VNet gets
    10.(70 + index).0.0/16 and every subnet below is carved out of it.

    REQUIRED whenever create_network is set and you have not set vnet_address_space, even for
    one region:

      region_indexes = {
        "eastus" = 0
      }

    Index 0 is 10.70.0.0/16, the range this module has always created, so naming your current
    location at 0 plans as a no-op. The declaration is what buys the enforcement: there is no
    signal in a fresh Terraform state that says "this is the second region", so a module that
    accepted silence would hand a second apply the first one's range without a word. Naming
    them is the signal.

    Onboarding a SECOND region: add it to the map and use the SAME map in BOTH regions' tfvars.

      region_indexes = {
        "eastus"     = 0
        "westeurope" = 1
      }

    The module looks up var.location, so the two VNets take 10.70.0.0/16 and 10.71.0.0/16
    whichever order you apply them in and whichever tfvars file you reach for. Copy a tfvars
    file to a second region and forget to extend the map and the plan FAILS, naming the
    location -- rather than silently taking 10.70.0.0/16 twice. Two locations cannot share an
    index either; the map is refused.

    That matters because an Azure VNet is regional: a second region is a second VNet, joining
    them later needs global VNet peering, and peering cannot join overlapping address spaces.
    Two regions applied on one range can never be peered and the only fix is to renumber and
    re-onboard.

    What it still cannot catch, because Terraform cannot read another region's state: an
    operator who REPLACES an entry rather than adding one, moving a location onto an index
    another one already holds in a state this apply cannot see. Keep one map, shared.

    Indexes are 0-9, i.e. 10.70.0.0/16 through 10.79.0.0/16. The floor keeps this module clear
    of the AWS module's 10.60.0.0/16 block, so onboarding both clouds does not overlap them
    either. Past ten regions, or on your own IPAM, set vnet_address_space instead -- it
    overrides all of this, and then the allocation is yours to keep distinct.
  EOT

  validation {
    condition     = length(var.region_indexes) == length(distinct(values(var.region_indexes)))
    error_message = "region_indexes must give every location a DISTINCT index; two regions sharing one index is exactly the overlap this variable exists to prevent."
  }

  validation {
    condition     = alltrue([for i in values(var.region_indexes) : floor(i) == i && i >= 0 && i <= 9])
    error_message = "region_indexes values must be whole numbers 0-9, which allocate 10.70.0.0/16 through 10.79.0.0/16. Set vnet_address_space to bring your own range instead."
  }
}

variable "vnet_address_space" {
  type        = string
  default     = null
  description = <<-EOT
    Address space for the optional vnet. One region's worth.

    Unset -- the default -- derives it from region_indexes: 10.(70 + index).0.0/16, which is
    10.70.0.0/16 for a single region and is what this module has always created. Set it to
    bring your own range, and then you own keeping every region distinct; see region_indexes
    for why that matters.
  EOT

  validation {
    condition     = var.vnet_address_space == null || can(cidrhost(var.vnet_address_space, 0))
    error_message = "vnet_address_space must be a CIDR block, e.g. 10.70.0.0/16."
  }
}

variable "subnet_prefix" {
  type        = string
  default     = null
  description = <<-EOT
    Prefix for the optional workstations subnet. Unset -- the default -- takes the second /24
    of vnet_address_space, which is 10.70.1.0/24 on the default VNet range. Set it only to
    override; it must sit inside vnet_address_space.
  EOT

  validation {
    condition     = var.subnet_prefix == null || can(cidrhost(var.subnet_prefix, 0))
    error_message = "subnet_prefix must be a CIDR block, e.g. 10.70.1.0/24."
  }
}

# --- Flow logs for the VNet this module creates (OFF by default) -----------------------------

variable "create_flow_logs" {
  type        = bool
  default     = false
  description = <<-EOT
    Record virtual network flow logs for the VNet this module creates, written to a storage
    account created for them. Off by default. Needs create_network; a network you bring yourself
    is yours to log.

    It is off because it bills and grants Ringleader nothing. In most regions Azure charges per GB
    of flow logs collected beyond 5 GB a month per subscription, plus the storage. It is here
    because compliance scans such as Azure Policy's "Audit flow logs configuration for every
    virtual network" expect flow logs on every virtual network. These are VNet flow logs, not NSG
    flow logs, which Azure no longer lets anyone create.

    The flow log and its storage account are created in the Network Watcher's resource group, not
    in resource_group_name. Ringleader's custom role is scoped to resource_group_name, and with
    enable_artifact_storage on it may read and delete every blob there. The Network Watcher's
    resource group is outside that scope, so Ringleader can neither read nor delete the records.
    Whoever applies this needs to create resources in the Network Watcher's resource group as
    well; see azure/README.md.

    Turning it off again deletes the flow log and its storage account, with every record in it.
  EOT
}

variable "flow_log_retention_days" {
  type        = number
  default     = 365
  description = "How many days the storage account keeps each flow log record, when create_flow_logs is set. This module accepts 1 to 365."

  validation {
    condition     = floor(var.flow_log_retention_days) == var.flow_log_retention_days && var.flow_log_retention_days >= 1 && var.flow_log_retention_days <= 365
    error_message = "flow_log_retention_days must be a whole number from 1 to 365."
  }
}

variable "network_watcher_name" {
  type        = string
  default     = null
  description = <<-EOT
    The Network Watcher that records the flow log, when create_flow_logs is set. When unset, which
    is the default, it is NetworkWatcher_<location>, the name Azure's automatic watcher usually
    has. Set it if your subscription's watcher has another name, for example <location>-watcher
    from the Azure CLI.

    It must exist and be in location. Otherwise the plan or apply fails, naming it.
  EOT
}

variable "network_watcher_resource_group_name" {
  type        = string
  default     = "NetworkWatcherRG"
  description = <<-EOT
    The resource group that holds network_watcher_name, when create_flow_logs is set. The flow log
    and its storage account are created here too, because Azure requires a flow log to live beside
    its Network Watcher. The default is the group Azure creates for its automatic watchers. It must
    not be resource_group_name, the group Ringleader's role reaches.
  EOT
}
