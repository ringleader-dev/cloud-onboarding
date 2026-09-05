# Ringleader Azure onboarding module (OIDC / Federated Identity Credential).
#
# Creates, in an existing resource group you own:
#   - an Entra app registration + service principal (the identity Ringleader
#     authenticates as),
#   - a custom least-privilege role (narrower than built-in Contributor) and its
#     assignment, scoped to that one resource group, deployed from the ARM template
#     (../arm/azuredeploy.json) so both supported paths grant exactly the same action
#     list, and
#   - a federated identity credential trusting Ringleader's per-org issuer, so
#     Ringleader authenticates with a signed token instead of a secret.
#
# Plus, all on by default and each one a variable you can set to false: a vnet + subnet +
# NAT gateway + NSG landing pad, the subnet the DNS / HTTPS proxy VM for hostname-level
# egress control runs in, egress control itself (letting Ringleader manage
# the NSGs that restrict where workstations may connect), and per-workstation managed
# identities.
#
# The defaults grant what Ringleader needs for the features available today, so turning one
# on later does not mean a second onboarding pass. Only the landing pad's NAT gateway and
# public IP cost money; see variables.tf, and the README for how to switch any of them off.
#
# Keyless: no client secret is created or stored. This module declares no provider blocks
# so it can be referenced from another repository. See examples/standalone for a
# ready-to-apply root configuration.

locals {
  # The per-org issuer Ringleader signs with. Azure pins the issuer byte-exactly, so this
  # must match exactly; the audience is Microsoft's documented value.
  issuer   = "${var.ringleader_issuer_url}/org/${var.org_uid}"
  subject  = "org:${var.org_uid}"
  audience = "api://AzureADTokenExchange"
}

# The identity Ringleader authenticates as.
#
# ONE identity serves every region, and that is why these three resources are switchable. An app
# registration is a TENANT-wide Microsoft Graph object with no region and no resource group, while
# the custom role below is scoped to ONE resource group -- so a second region applied with the
# defaults would mint a SECOND app registration, with its own client id and therefore its own
# `CloudIdentity` to hand back, while neither identity could act in the other's group. Set
# `create_identity = false` in every region after the first and pass the first one's ids: that apply
# then deploys the role and the landing pad into its own group and grants them to the identity you
# already have. See ../README.md#a-second-region-name-it-do-not-renumber-it.
#
# Applying twice into ONE resource group is not the way around it. It collides on the role
# deployment below, whose name is a fixed literal, and it would still mint the second app -- nothing
# about an app registration is scoped by group or location.
resource "azuread_application" "workstations" {
  count            = var.create_identity ? 1 : 0
  display_name     = var.app_display_name
  sign_in_audience = "AzureADMyOrg"
}

resource "azuread_service_principal" "workstations" {
  count     = var.create_identity ? 1 : 0
  client_id = azuread_application.workstations[0].client_id
}

# The federation trust: Ringleader presents a signed token whose sub is your org, and this
# credential trusts only that (issuer, subject, audience) triple.
#
# It belongs to the APPLICATION, not to any region, so a `create_identity = false` apply must not
# author a second one -- the credential the first region created is the one that is already trusted.
resource "azuread_application_federated_identity_credential" "ringleader" {
  count          = var.create_identity ? 1 : 0
  application_id = azuread_application.workstations[0].id
  display_name   = "ringleader-oidc"
  description    = "Ringleader OIDC federation for org ${var.org_uid}."
  issuer         = local.issuer
  subject        = local.subject
  audiences      = [local.audience]
}

locals {
  # Whichever identity this apply is granting the role to: the one it just created, or the one an
  # earlier region created and the operator named. Every reference below goes through these two, so
  # there is no path that reads the created resource directly and breaks in the reusing mode.
  target_client_id    = var.create_identity ? azuread_application.workstations[0].client_id : var.existing_client_id
  principal_object_id = var.create_identity ? azuread_service_principal.workstations[0].object_id : var.existing_principal_object_id
}

# The custom least-privilege role and its assignment, deployed from the shared ARM template
# so the action list lives in exactly one place (../arm/azuredeploy.json). That template also
# owns the two switchable unions -- the ManagedIdentity actions for per-workstation runtime
# identities, and the NSG actions for egress control -- so there is nothing to duplicate here.
#
# file(), not templatefile(): the template is authored in ARM's own `[...]` expression syntax,
# which templatefile() would wrongly try to interpret as Terraform `${...}`. It has no
# Terraform interpolation, so file() passes it through verbatim. Resource-group scoped,
# matching `az deployment group create`.
#
# Why the template looks spare: Azure stores its own normalized copy of a template and echoes
# that back, and this resource compares the echo against the file. Anything Azure rewrites
# shows up as a permanent diff -- `terraform plan` reporting changes on every run, forever, on
# a step nobody touched -- so azuredeploy.json is authored in the form Azure stores. Four
# rules, and breaking one costs no apply and no error, only a config that can never be quiet
# again:
#
#   1. no top-level `metadata` block   (Azure drops it; the prose lives in ../arm/README.md)
#   2. no `outputs` block              (one less surface Azure rewrites)
#   3. no parameter with a defaultValue that this resource does not pass explicitly -- Azure
#      materializes the default into the stored parameters while the file leaves it unset.
#      Hence the role definition's GUID is a template variable, not a parameter.
#   4. every parameter `type` in ARM's canonical casing -- "String", "Bool", "Int", "Object",
#      "Array", "SecureString", "SecureObject". ARM accepts the lowercase spellings and the
#      docs use them, but Azure stores the capitalized form, so a lowercase `"type": "string"`
#      here is a permanent one-line diff per parameter. Check what Azure holds with
#      `az deployment group export -g <rg> -n ringleader-onboarding`.
#
# Deliberately no `lifecycle { ignore_changes = [template_content, ...] }`: that would silence
# the noise by also silencing a real edit to the action list, so bumping the module version
# would quietly not re-deploy the role.
resource "azurerm_resource_group_template_deployment" "role" {
  name                = var.deployment_name
  resource_group_name = var.resource_group_name
  deployment_mode     = "Incremental"

  template_content = file("${path.module}/../arm/azuredeploy.json")

  parameters_content = jsonencode({
    principalId                 = { value = local.principal_object_id }
    roleName                    = { value = var.role_name }
    enableWorkstationIdentities = { value = var.enable_workstation_identities }
    enableEgressControl         = { value = var.enable_egress_control }
    enableArtifactStorage       = { value = var.enable_artifact_storage }
    artifactStorageAccountName  = { value = var.artifact_storage_account_name }
  })
}

# --- Network landing pad, on by default (egress out; inbound only via ssh_source_ranges) ---
#
# One region's worth. An Azure VNet is regional, so a second region means a second VNet
# joined by global VNet peering -- which is non-transitive and cannot join overlapping
# address spaces. Two regions applied on one range can never be peered, and the only remedy
# is to renumber and re-onboard, so the allocation has to be right from the FIRST apply.
#
# Hence the ranges are DERIVED rather than documented. region_indexes maps each location to
# the /16 its landing pad takes, and the module reads the index for var.location -- so two
# regions given one map cannot take one range whatever order they are applied in. Every subnet
# then comes out of that /16, so there is no second variable to keep in step and no way to
# move the VNet and leave a subnet behind.
#
# Every default below reproduces the literal this module shipped before the derivation, so an
# existing single-region landing pad plans as a no-op: see azure/README.md for the table.

locals {
  # An unlisted location falls back to index 0 so the expressions below stay evaluable; the
  # precondition on the VNet is what actually refuses it, with a message that names the region.
  region_index = try(var.region_indexes[var.location], 0)

  region_index_known = contains(keys(var.region_indexes), var.location)

  # 10.(70 + index).0.0/16. Index 0 is 10.70.0.0/16, this module's historical default.
  vnet_address_space = var.vnet_address_space != null ? var.vnet_address_space : cidrsubnet("10.0.0.0/8", 8, 70 + local.region_index)

  # The three subnets, carved out of whichever /16 the VNet took. The offsets reproduce the
  # literals these variables used to default to: the second /24, the 15th /20 immediately below
  # the gateway range, and the 241st /24 at the top.
  subnet_prefix          = var.subnet_prefix != null ? var.subnet_prefix : cidrsubnet(local.vnet_address_space, 8, 1)
  governed_subnet_prefix = var.governed_subnet_prefix != null ? var.governed_subnet_prefix : cidrsubnet(local.vnet_address_space, 4, 14)
  gateway_subnet_prefix  = var.gateway_subnet_prefix != null ? var.gateway_subnet_prefix : cidrsubnet(local.vnet_address_space, 8, 240)
}

resource "azurerm_virtual_network" "workstations" {
  count               = var.create_network ? 1 : 0
  name                = "${var.name_prefix}-vnet"
  location            = var.location
  resource_group_name = var.resource_group_name
  address_space       = [local.vnet_address_space]

  # The allocation has to be DECLARED, because Terraform cannot discover it. There is no signal
  # in a fresh state that says "this is the second region", so a module that accepted silence
  # would hand the second apply the first one's range and only find out at the peering months
  # later, when renumbering means re-onboarding. Refusing silence is what makes the collision
  # impossible instead of merely discouraged -- and the right moment to insist is the FIRST
  # apply, which is the only one where the answer is still free.
  #
  # Both preconditions are skipped entirely when create_network is false: a customer who brings
  # their own network never carves a range here and has nothing to declare.
  lifecycle {
    precondition {
      condition     = length(var.region_indexes) > 0 || var.vnet_address_space != null
      error_message = "region_indexes is empty, so this landing pad cannot know whether ${var.location} is your first region or your second. Name every region you onboard -- region_indexes = { \"${var.location}\" = 0 } keeps this one on 10.70.0.0/16, the range it has always had -- and give the next region index 1. Or set vnet_address_space to allocate the ranges yourself."
    }

    precondition {
      condition     = local.region_index_known || var.vnet_address_space != null
      error_message = "region_indexes does not name ${var.location}, the location this landing pad is being created in, so this apply would take index 0's range a second time. Add \"${var.location}\" with an index no other region uses, or set vnet_address_space to allocate this region's range yourself."
    }
  }
}

resource "azurerm_subnet" "workstations" {
  count                = var.create_network ? 1 : 0
  name                 = "workstations"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.workstations[0].name
  address_prefixes     = [local.subnet_prefix]
}

# Where the DNS / HTTPS proxy VM runs -- created empty, and on by default.
#
# Ringleader's egress control points workstations at a proxy that resolves names and terminates
# HTTPS for the hosts you allow, and it builds that VM itself once you hand this subnet's id
# back as EgressGateway.spec.subnet -- and none before that: a UDR attaches per subnet and
# replaces the default route of everything in it, so a proxy sitting in a subnet it steers would
# route its own egress into itself. A subnet of its own also means the NSG rules that permit
# workstation -> proxy traffic can name one stable prefix instead of one VM's address. Azure does
# not bill for a subnet.
#
# IT GETS AN NSG OF ITS OWN, and the reason is the one thing about Azure that is easy to state
# backwards: "Azure allows intra-VNet traffic and denies the internet" describes the DEFAULT RULES
# INSIDE an NSG, not the platform. A subnet with no NSG and a NIC with no NSG have no rules at all,
# so nothing is filtered -- and the gateway VM Ringleader builds here carries a STANDALONE PUBLIC IP
# (azgateway's EnsureGatewayNetwork creates one before the NIC, unconditionally), which would put the
# proxy's listeners and its sshd on the internet. Ringleader does attach an NSG to that VM's own NIC,
# so this one is the second layer rather than the only one; a NIC NSG that failed to be created, or
# was removed, would otherwise leave nothing.
#
# IT CARRIES ONE RULE, AND THE DEFAULTS ARE NOT A SUBSTITUTE FOR IT. Azure's AllowVnetInBound at
# 65000 is `source VirtualNetwork -> DESTINATION VirtualNetwork`, and a steered packet is neither:
# a UDR next hop does not rewrite the destination, so what arrives here is `src = the governed
# workstation, dst = the public host it was talking to`. That misses AllowVnetInBound, falls through
# to DenyAllInBound at 65500, and every governed box loses the internet while the gateway itself
# stays healthy and the route stays in place -- the silent outage this whole feature exists to
# remove. So the rule below allows the VNet inbound to ANY destination, which is exactly what
# Ringleader writes on the gateway VM'''s own NIC (azgateway'''s `gatewayNSGRule`); this group is the
# second layer, and the two must say the same thing or the outer one decides.
#
# Everything else is Azure'''s defaults, which is the point: one allow plus DenyAllInBound is
# "reachable from inside the network, from nowhere else". Outbound is untouched, so the gateway keeps
# the internet access it exists to police (AllowInternetOutBound at 65001).
#
# The subnet is associated with the NAT gateway below, so anything placed here has egress without an
# address of its own.
resource "azurerm_subnet" "gateway" {
  count                = var.create_network && var.create_gateway_subnet ? 1 : 0
  name                 = "gateway"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.workstations[0].name
  address_prefixes     = [local.gateway_subnet_prefix]
}

resource "azurerm_network_security_group" "gateway" {
  count               = var.create_network && var.create_gateway_subnet ? 1 : 0
  name                = "${var.name_prefix}-gateway-nsg"
  location            = var.location
  resource_group_name = var.resource_group_name
}

resource "azurerm_network_security_rule" "gateway_vnet_inbound" {
  count                       = var.create_network && var.create_gateway_subnet ? 1 : 0
  name                        = "allow-vnet-inbound"
  resource_group_name         = var.resource_group_name
  network_security_group_name = azurerm_network_security_group.gateway[0].name
  priority                    = 4000
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "*"
  source_address_prefix       = "VirtualNetwork"
  source_port_range           = "*"
  # ANY destination, not VirtualNetwork -- see the comment above. A steered packet arrives here
  # addressed to the public host the workstation was reaching, and narrowing this to the VNet is the
  # same as denying it.
  destination_address_prefix = "*"
  destination_port_range     = "*"
}

resource "azurerm_subnet_network_security_group_association" "gateway" {
  count                     = var.create_network && var.create_gateway_subnet ? 1 : 0
  subnet_id                 = azurerm_subnet.gateway[0].id
  network_security_group_id = azurerm_network_security_group.gateway[0].id
}

# Inbound SSH -- the difference between a workstation that comes up and one you can use.
#
# The NSG below is what makes the default rules apply at all. AllowVnetInBound at 65000 and
# DenyAllInBound at 65500 are rules INSIDE a group -- a subnet and a NIC with none are not
# filtered, they are unfiltered -- so this module attaches one to every subnet it creates and the
# ssh rule is added to it rather than to bare metal.
# Ringleader's setup traffic needs no rule at all: a workstation only needs egress to reach the
# control plane, which the NAT gateway below provides. But `rl shell`, `rl tmux`, port-forwards
# and VS Code Web all dial the workstation on TCP 22 directly -- there is no bastion, proxy or
# SSH tunnel -- so without a rule the workstation comes up healthy, reports Ready, and nobody
# can get into it.
#
# Leave ssh_source_ranges empty and only the NSG (with Azure's defaults) is created. Choose
# that only if you reach the VNet privately (VPN / ExpressRoute / peering) from wherever you
# run `rl`.
#
# THIS GROUP IS THE SUBNET LAYER, and a workstation with an egress policy carries a SECOND one.
# Azure evaluates the subnet NSG and the NIC NSG and both must allow. Ringleader compiles a
# policy into a NIC-level NSG, so the two layers divide cleanly: this one decides who may REACH
# the workstation, and Ringleader's decides where the workstation may CONNECT. Two rules follow.
#
# Keep inbound narrowing HERE rather than on a NIC. A NIC carries at most one NSG, so declaring
# spec.egress on a box whose interface you supplied yourself
# (providerConfig.azure.networkInterfaceId) REPLACES whatever group was on it -- and Ringleader's
# carries a deliberately neutral inbound allow, because a fresh NSG ends in DenyAllInBound and an
# outbound-only group on a NIC that had none would cut SSH to the box's public address. Neutral
# means this subnet's rules become the whole story, which WIDENS inbound if that NIC group was
# narrowing anything. Ringleader never touches the subnet, so rules here always survive.
#
# And do not add an OUTBOUND Deny here. It cannot tighten a policy -- the NIC NSG already denies
# whatever the policy does not list -- but it can BREAK one, by blocking a destination the policy
# allows, which reads as Ringleader ignoring the allowlist. See azure/README.md, "Two NSGs, at
# two layers".
resource "azurerm_network_security_group" "workstations" {
  count               = var.create_network ? 1 : 0
  name                = "${var.name_prefix}-workstations-nsg"
  location            = var.location
  resource_group_name = var.resource_group_name
}

resource "azurerm_network_security_rule" "ssh" {
  count                       = var.create_network && length(var.ssh_source_ranges) > 0 ? 1 : 0
  name                        = "AllowRingleaderSSHInbound"
  resource_group_name         = var.resource_group_name
  network_security_group_name = azurerm_network_security_group.workstations[0].name
  priority                    = 1000
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "22"
  source_address_prefixes     = var.ssh_source_ranges
  destination_address_prefix  = "*"
}

locals {
  # The secondary SSH port (see the rule below). Fixed by Ringleader, so it is a constant here
  # rather than a variable: you never have to know the number, and it cannot drift from the
  # port Ringleader actually dials. A wrong value would be a rule that exists, reads correctly
  # in the portal, and admits nothing.
  secondary_ssh_port = 2222

  # Unset mirrors ssh_source_ranges: if you opened 22 to your engineers you almost certainly
  # want 2222 open to the same people. An explicit [] closes the port.
  secondary_ssh_ranges = var.secondary_ssh_source_ranges == null ? var.ssh_source_ranges : var.secondary_ssh_source_ranges
}

# A second SSH port, opened to the same ranges as 22 unless you say otherwise.
#
# Some Ringleader workstation types run their own SSH daemon on a secondary port inside the
# VM, while the VM's own sshd keeps 22, and `rl shell` dials that port for such a workstation.
# Others never use it, and for those this rule is harmless -- which is why it follows
# ssh_source_ranges rather than making you find out which kind you are running. Set
# secondary_ssh_source_ranges = [] to close it.
#
# The source ranges are the only narrowing available here, and that is Azure rather than a
# shortcut: an NSG attaches to the subnet and Azure has no per-VM tag for a rule to match, so
# this admits the port to every VM on the workstations subnet. (The GCP module scopes the same
# rule to a network tag.) If that is too broad, put the workstations that need the port on a
# subnet of their own with its own NSG.
resource "azurerm_network_security_rule" "secondary_ssh" {
  count                       = var.create_network && length(local.secondary_ssh_ranges) > 0 ? 1 : 0
  name                        = "AllowRingleaderSecondarySSHInbound"
  resource_group_name         = var.resource_group_name
  network_security_group_name = azurerm_network_security_group.workstations[0].name
  priority                    = 1010
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = tostring(local.secondary_ssh_port)
  source_address_prefixes     = local.secondary_ssh_ranges
  destination_address_prefix  = "*"
}

resource "azurerm_subnet_network_security_group_association" "workstations" {
  count                     = var.create_network ? 1 : 0
  subnet_id                 = azurerm_subnet.workstations[0].id
  network_security_group_id = azurerm_network_security_group.workstations[0].id
}

resource "azurerm_public_ip" "nat" {
  count               = var.create_network ? 1 : 0
  name                = "${var.name_prefix}-nat-pip"
  location            = var.location
  resource_group_name = var.resource_group_name
  allocation_method   = "Static"
  sku                 = "Standard"
}

resource "azurerm_nat_gateway" "workstations" {
  count               = var.create_network ? 1 : 0
  name                = "${var.name_prefix}-nat"
  location            = var.location
  resource_group_name = var.resource_group_name
  sku_name            = "Standard"
}

resource "azurerm_nat_gateway_public_ip_association" "workstations" {
  count                = var.create_network ? 1 : 0
  nat_gateway_id       = azurerm_nat_gateway.workstations[0].id
  public_ip_address_id = azurerm_public_ip.nat[0].id
}

resource "azurerm_subnet_nat_gateway_association" "workstations" {
  count          = var.create_network ? 1 : 0
  subnet_id      = azurerm_subnet.workstations[0].id
  nat_gateway_id = azurerm_nat_gateway.workstations[0].id
}

resource "azurerm_subnet_nat_gateway_association" "gateway" {
  count          = var.create_network && var.create_gateway_subnet ? 1 : 0
  subnet_id      = azurerm_subnet.gateway[0].id
  nat_gateway_id = azurerm_nat_gateway.workstations[0].id
}

# And a home for the WORKSTATIONS that gateway governs -- also empty, also on by default.
#
# A gateway steers a whole subnet, and it serves only the boxes it holds a policy for, so a
# steered subnet has to hold governed boxes and nothing else. The workstations subnet above is
# where every workstation in this VNet goes, governed or not; steering that one would take the
# egress of every box in it that has no policy. Hence a second prefix.
#
# It gets the SAME NSG as the workstations subnet, and for the same reason: an NSG is what makes
# Azure's default rules apply at all -- DenyAllInBound included -- and Ringleader ships no bastion,
# so the ssh rule in that same group is the only way to reach a governed box. Without the group
# there is neither the closure nor the way in. The NSG narrows inbound only -- Azure's
# AllowInternetOutBound at 65001 is untouched -- so attaching it grants the box no egress.
#
# It gets NO NAT gateway and NO route table, and both omissions are deliberate:
#
#   - No route table, because Ringleader claims the subnet by PUTting a UDR of its own onto it
#     and declines a subnet that already references one. It could technically put yours back --
#     unlike AWS, where the permission to re-associate simply does not exist -- but it declines
#     for the same fail-safe reason, so an operator learns one rule across both clouds.
#   - No NAT gateway, because a governed box's egress is the gateway's job. Attaching one would
#     hand every box in here an unpoliced path to the internet for the whole window before
#     steering lands, and the UDR overrides it the moment it does. A box with its own public IP
#     still has Azure's own outbound until then; that is Azure's behaviour, not something this
#     module can take away, and it is a reason to create governed boxes without one.
#   - default_outbound_access DISABLED, which is the half Azure DOES let the module take away.
#     Without it a VM here with no public IP would still reach the internet through Azure's
#     implicit SNAT -- an unpoliced path that survives having withheld the NAT gateway, and the
#     one thing that would leave this subnet less fail-safe than its AWS twin (where no route
#     table means no route at all). Azure fixes this flag AT SUBNET CREATION: setting it later
#     REPLACES the subnet, so it has to be right on the first apply.
resource "azurerm_subnet" "governed" {
  count                           = var.create_network && var.create_governed_subnet ? 1 : 0
  name                            = "governed"
  resource_group_name             = var.resource_group_name
  virtual_network_name            = azurerm_virtual_network.workstations[0].name
  address_prefixes                = [local.governed_subnet_prefix]
  default_outbound_access_enabled = false
}

resource "azurerm_subnet_network_security_group_association" "governed" {
  count                     = var.create_network && var.create_governed_subnet ? 1 : 0
  subnet_id                 = azurerm_subnet.governed[0].id
  network_security_group_id = azurerm_network_security_group.workstations[0].id
}
