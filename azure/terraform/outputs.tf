output "target_app_client_id" {
  value       = local.target_client_id
  description = "Hand back to Ringleader: the app client id it authenticates as (the target principal). With create_identity = false this echoes the id you passed in, so every region reports the ONE identity Ringleader uses."
}

output "service_principal_object_id" {
  value       = local.principal_object_id
  description = "The service principal's object id, which the role assignment names. Record it: it is what a SECOND region passes as existing_principal_object_id."
}

output "subscription_id" {
  value       = var.subscription_id
  description = "Hand back to Ringleader: the subscription your workstations run in."
}

output "resource_group_name" {
  value       = var.resource_group_name
  description = "Hand back to Ringleader: the resource group your workstations run in."
}

output "subnet_id" {
  value       = var.create_network ? azurerm_subnet.workstations[0].id : null
  description = "Hand back to Ringleader (only when create_network = true; otherwise supply your own subnet)."
}

output "vnet_address_space" {
  value       = var.create_network ? local.vnet_address_space : null
  description = <<-EOT
    The range this region's VNet took, derived from region_indexes unless you set
    vnet_address_space. Worth recording: it is what the NEXT region has to stay clear of, and
    what a global VNet peering will one day have to join.
  EOT
}

output "subnet_prefix" {
  value       = var.create_network ? local.subnet_prefix : null
  description = "The workstations subnet's prefix, carved out of vnet_address_space."
}

output "gateway_subnet_id" {
  value       = var.create_network && var.create_gateway_subnet ? azurerm_subnet.gateway[0].id : null
  description = "Subnet the egress gateway VM runs in (only when create_gateway_subnet = true). Hand it back as spec.subnet on the EgressGateway -- Ringleader builds no gateway until you do, because a gateway placed in the subnet it steers routes its own egress into itself. NOT governed_subnet_id, which is the workstations'."
}

output "gateway_subnet_prefix" {
  value       = var.create_network && var.create_gateway_subnet ? local.gateway_subnet_prefix : null
  description = "The gateway subnet's prefix. This is what an egress allowlist names to let workstations reach the proxy, so it is worth recording."
}

output "governed_subnet_id" {
  value       = var.create_network && var.create_governed_subnet ? azurerm_subnet.governed[0].id : null
  description = "Subnet for the workstations a gateway governs (only when create_governed_subnet = true). Hand it back as providerConfig.azure.subnetId on the workstations that carry an egress policy -- placing a box in it is what makes it gateway-governed."
}

output "governed_subnet_prefix" {
  value       = var.create_network && var.create_governed_subnet ? local.governed_subnet_prefix : null
  description = "The governed subnet's prefix. Worth recording: it is the source range the gateway keys its policies on."
}

output "role_extras_granted" {
  description = "Optional action sets folded into the custom role, for audit. The base action list is in ../arm/azuredeploy.json."
  value = concat(
    var.enable_workstation_identities ? ["Microsoft.ManagedIdentity CRUD + assign, Microsoft.Authorization roleAssignments -- workstation runtime identities"] : [],
    var.enable_egress_control ? ["Microsoft.Network/networkSecurityGroups (+ securityRules) and routeTables (+ routes) read/write/delete and join/action, plus virtualNetworks/subnets/write and delete -- egress control"] : [],
    # Listed on its own because it is the one egress action outside Microsoft.Network, and the one
    # a hand-rolled role is most likely to omit: the sweep that collects a leaked egress gateway
    # reads the resource group's generic `resources` collection. Without it that sweep collects
    # NOTHING -- including the VM half, which needs no such action -- and a billed gateway VM and
    # its static public IP are left behind. Built-in Contributor covers it; a narrower role must
    # name it. See ../README.md, "Optional: egress control".
    var.enable_egress_control ? ["Microsoft.Resources/subscriptions/resourcegroups/resources/read -- the leaked-gateway sweep's object listing"] : [],
  )
}

output "handoff" {
  description = <<-EOT
    Everything to hand back to Ringleader, in one place. Add your tenant id
    (az account show --query tenantId -o tsv).

    THREE subnet ids, and they are not interchangeable: a workstation that carries an egress
    policy goes in governed_subnet_id, every other one in subnet_id, and gateway_subnet_id
    goes on the EgressGateway itself as spec.subnet -- the gateway VM cannot sit in a subnet
    it steers.
  EOT
  value = {
    target_app_client_id = local.target_client_id
    subscription_id      = var.subscription_id
    resource_group_name  = var.resource_group_name
    subnet_id            = var.create_network ? azurerm_subnet.workstations[0].id : null
    governed_subnet_id   = var.create_network && var.create_governed_subnet ? azurerm_subnet.governed[0].id : null
    gateway_subnet_id    = var.create_network && var.create_gateway_subnet ? azurerm_subnet.gateway[0].id : null
  }
}
