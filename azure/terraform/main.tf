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
# NAT gateway + NSG landing pad, a reserved subnet for the DNS / HTTPS proxy VM that
# hostname-level egress control will use, egress control itself (letting Ringleader manage
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
resource "azuread_application" "workstations" {
  display_name     = var.app_display_name
  sign_in_audience = "AzureADMyOrg"
}

resource "azuread_service_principal" "workstations" {
  client_id = azuread_application.workstations.client_id
}

# The federation trust: Ringleader presents a signed token whose sub is your org, and this
# credential trusts only that (issuer, subject, audience) triple.
resource "azuread_application_federated_identity_credential" "ringleader" {
  application_id = azuread_application.workstations.id
  display_name   = "ringleader-oidc"
  description    = "Ringleader OIDC federation for org ${var.org_uid}."
  issuer         = local.issuer
  subject        = local.subject
  audiences      = [local.audience]
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
  name                = "ringleader-onboarding"
  resource_group_name = var.resource_group_name
  deployment_mode     = "Incremental"

  template_content = file("${path.module}/../arm/azuredeploy.json")

  parameters_content = jsonencode({
    principalId                 = { value = azuread_service_principal.workstations.object_id }
    roleName                    = { value = var.role_name }
    enableWorkstationIdentities = { value = var.enable_workstation_identities }
    enableEgressControl         = { value = var.enable_egress_control }
  })
}

# --- Network landing pad, on by default (egress out; inbound only via ssh_source_ranges) ---
#
# One region's worth. An Azure VNet is regional, so a second region means a second VNet
# joined by global VNet peering -- which is non-transitive and cannot join overlapping
# address spaces. Give every region a distinct vnet_address_space from the first apply; see
# that variable's description and azure/README.md for a suggested plan.

resource "azurerm_virtual_network" "workstations" {
  count               = var.create_network ? 1 : 0
  name                = "${var.name_prefix}-vnet"
  location            = var.location
  resource_group_name = var.resource_group_name
  address_space       = [var.vnet_address_space]
}

resource "azurerm_subnet" "workstations" {
  count                = var.create_network ? 1 : 0
  name                 = "workstations"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.workstations[0].name
  address_prefixes     = [var.subnet_prefix]
}

# A home for the future DNS / HTTPS proxy VM -- created empty, and on by default.
#
# Ringleader's egress control can point workstations at a proxy that resolves names and
# terminates HTTPS for the hosts you allow. That VM is not built yet, but where it will live
# is worth settling now: giving it a subnet of its own means the NSG rules that permit
# workstation -> proxy traffic can name one stable prefix instead of one VM's address, and
# carving the range now avoids renumbering later. Azure does not bill for a subnet.
#
# No NSG is attached. Azure's defaults already allow intra-VNet traffic and deny inbound from
# the internet, which is the right posture for a proxy; Ringleader adds what it needs when the
# VM ships. It shares the NAT gateway below, so the proxy has upstream egress with no public IP.
resource "azurerm_subnet" "gateway" {
  count                = var.create_network && var.create_gateway_subnet ? 1 : 0
  name                 = "gateway"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.workstations[0].name
  address_prefixes     = [var.gateway_subnet_prefix]
}

# Inbound SSH -- the difference between a workstation that comes up and one you can use.
#
# Azure's default rules already allow intra-VNet traffic and deny inbound from the internet,
# so a subnet with no NSG is not "open" -- it is unreachable from outside the VNet.
# Ringleader's setup traffic is fine with that: a workstation only needs egress to reach the
# control plane, which the NAT gateway below provides. But `rl shell`, `rl tmux`, port-forwards
# and VS Code Web all dial the workstation on TCP 22 directly -- there is no bastion, proxy or
# SSH tunnel -- so without a rule the workstation comes up healthy, reports Ready, and nobody
# can get into it.
#
# Leave ssh_source_ranges empty and only the NSG (with Azure's defaults) is created. Choose
# that only if you reach the VNet privately (VPN / ExpressRoute / peering) from wherever you
# run `rl`.
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
