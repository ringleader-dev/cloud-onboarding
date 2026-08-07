# Ringleader Azure onboarding module (OIDC / Federated Identity Credential).
#
# Creates, in an EXISTING resource group you own:
#   - an Entra app registration + service principal (the identity Ringleader
#     authenticates as),
#   - a custom least-privilege role (narrower than built-in Contributor) and its
#     assignment, scoped to that one resource group, deployed from the ARM template
#     (../arm/azuredeploy.json) so that both supported paths grant exactly the same
#     action list, and
#   - a federated identity credential trusting Ringleader's per-org issuer, so
#     Ringleader authenticates with a signed token instead of a secret.
#
# Optionally, a vnet + subnet + NAT gateway + NSG landing pad: egress out, and inbound SSH
# only from the CIDRs you name (ssh_source_ranges).
#
# Keyless: no client secret is created or stored. This module declares NO
# provider blocks so it can be referenced from another repository. See
# examples/standalone for a ready-to-apply root configuration.

locals {
  # The per-org issuer Ringleader signs with. Azure pins the issuer byte-exactly,
  # so this must match exactly; the audience is Microsoft's documented value.
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

# The federation trust: Ringleader presents a signed token whose sub is your org,
# and this credential trusts only (issuer, subject, audience) for your org.
resource "azuread_application_federated_identity_credential" "ringleader" {
  application_id = azuread_application.workstations.id
  display_name   = "ringleader-oidc"
  description    = "Ringleader OIDC federation for org ${var.org_uid}."
  issuer         = local.issuer
  subject        = local.subject
  audiences      = [local.audience]
}

# The custom least-privilege role + its assignment, deployed from the shared ARM
# template so the action list lives in exactly ONE place (../arm/azuredeploy.json). The
# template also owns the `enableWorkstationIdentities` union (the ManagedIdentity CRUD +
# roleAssignments-write actions for per-workstation runtime identities), so there is nothing
# to duplicate in HCL.
#
# file(), NOT templatefile(): the template is authored in ARM's own `[...]` expression syntax
# (`[guid(...)]`, `[if(parameters('enableWorkstationIdentities'), union(...), ...)]`), which
# templatefile() would wrongly try to interpret as Terraform `${...}`. It has no Terraform
# interpolation, so file() passes it through verbatim. Resource-group scoped, matching
# `az deployment group create`.
resource "azurerm_resource_group_template_deployment" "role" {
  name                = "ringleader-onboarding"
  resource_group_name = var.resource_group_name
  deployment_mode     = "Incremental"

  template_content = file("${path.module}/../arm/azuredeploy.json")

  parameters_content = jsonencode({
    principalId                 = { value = azuread_service_principal.workstations.object_id }
    roleName                    = { value = var.role_name }
    enableWorkstationIdentities = { value = var.enable_workstation_identities }
  })
}

# --- Optional network landing pad (egress out; inbound only via ssh_source_ranges) ---

resource "azurerm_virtual_network" "workstations" {
  count               = var.create_network ? 1 : 0
  name                = "ringleader-vnet"
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

# Inbound SSH -- the difference between a workstation that COMES UP and one you can actually USE.
#
# Azure's default rules already allow intra-VNet traffic and DENY inbound from the Internet, so a
# subnet with no NSG is not "open" -- it is unreachable from outside the VNet. Ringleader's config
# traffic is fine with that (a workstation only needs EGRESS to reach the Ringleader control plane,
# which the NAT gateway below provides). But `rl shell`, `rl tmux`, port-forwards and VS Code Web
# all dial the workstation on TCP 22 directly -- Ringleader ships no bastion, no proxy and no SSH
# tunnel -- so without a rule the workstation comes up healthy, reports Ready, and nobody can get
# into it.
#
# Leave ssh_source_ranges EMPTY and only the NSG (with Azure's defaults) is created: choose that
# only if you reach the VNet privately (VPN / ExpressRoute / peering) from wherever you run `rl`.
resource "azurerm_network_security_group" "workstations" {
  count               = var.create_network ? 1 : 0
  name                = "ringleader-workstations-nsg"
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

resource "azurerm_subnet_network_security_group_association" "workstations" {
  count                     = var.create_network ? 1 : 0
  subnet_id                 = azurerm_subnet.workstations[0].id
  network_security_group_id = azurerm_network_security_group.workstations[0].id
}

resource "azurerm_public_ip" "nat" {
  count               = var.create_network ? 1 : 0
  name                = "ringleader-nat-pip"
  location            = var.location
  resource_group_name = var.resource_group_name
  allocation_method   = "Static"
  sku                 = "Standard"
}

resource "azurerm_nat_gateway" "workstations" {
  count               = var.create_network ? 1 : 0
  name                = "ringleader-nat"
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
