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
# only from the CIDRs you name (ssh_source_ranges) -- plus, if you ask for it, the SECONDARY
# SSH port some workstation types use (secondary_ssh_source_ranges, off by default).
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
#
# WHY THE TEMPLATE LOOKS SPARE: Azure stores its OWN normalized copy of a template and echoes THAT
# back, and this resource compares the echo against the file. Anything Azure rewrites therefore
# shows up as a permanent diff -- `terraform plan` reporting changes on every run, forever, on a
# step nobody touched -- so azuredeploy.json is authored in the form Azure stores. Three rules,
# and breaking one costs no apply and no error, only a config that can never be quiet again:
#
#   1. no top-level `metadata` block           (Azure drops it; the prose lives in ../arm/README.md)
#   2. no `outputs` block                      (one less surface Azure rewrites)
#   3. no parameter with a defaultValue that this resource does not pass explicitly -- Azure
#      materializes the default into the stored parameters while the file leaves it unset. Hence
#      the role definition's GUID is a template VARIABLE, not a parameter.
#   4. every parameter `type` in ARM's CANONICAL CASING -- "String", "Bool", "Int", "Object",
#      "Array", "SecureString", "SecureObject". ARM accepts the lowercase spellings and the docs
#      use them, but Azure STORES the capitalized form, so a lowercase `"type": "string"` in this
#      file is a permanent one-line diff per parameter. Verify what Azure holds with
#      `az deployment group export -g <rg> -n ringleader-onboarding`.
#
# Deliberately NO `lifecycle { ignore_changes = [template_content, ...] }`: that would silence the
# noise by also silencing a real edit to the action list, so bumping the module version would
# quietly not re-deploy the role.
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

locals {
  # The SECONDARY SSH port (see the rule below). Fixed by Ringleader, so it is a constant here and
  # NOT a variable: you never have to know the number, and it cannot drift from the port Ringleader
  # actually dials. A wrong value would be a rule that exists, reads correctly in the portal, and
  # admits nothing.
  secondary_ssh_port = 2222
}

# A SECOND SSH port -- created only if you ask for it.
#
# Some Ringleader workstation types run their OWN SSH daemon on a secondary port inside the VM,
# while the VM's own sshd keeps 22. For such a workstation `rl shell` dials THAT port, so it needs
# an inbound rule of its own; a workstation that does not use one is unaffected either way.
# Ringleader tells you whether the workstations you intend to run need it -- if in doubt, leave
# secondary_ssh_source_ranges empty.
#
# EMPTY IS THE DEFAULT AND CREATES NOTHING. A configuration that does not set this variable plans
# and applies exactly as it did before the variable existed: no rule, no diff, no change in what
# your VNet admits.
#
# THE SOURCE RANGES ARE THE ONLY NARROWING AVAILABLE HERE, and that is Azure, not a shortcut: an
# NSG attaches to the SUBNET and Azure has no per-VM tag for a rule to match, so this admits the
# port to every VM on the workstations subnet. (The GCP module scopes the same rule to a network
# tag, so only the workstations carrying it are reachable on the port.) If that is too broad,
# put the workstations that need this port on a subnet of their own with its own NSG.
resource "azurerm_network_security_rule" "secondary_ssh" {
  count                       = var.create_network && length(var.secondary_ssh_source_ranges) > 0 ? 1 : 0
  name                        = "AllowRingleaderSecondarySSHInbound"
  resource_group_name         = var.resource_group_name
  network_security_group_name = azurerm_network_security_group.workstations[0].name
  priority                    = 1010
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = tostring(local.secondary_ssh_port)
  source_address_prefixes     = var.secondary_ssh_source_ranges
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
