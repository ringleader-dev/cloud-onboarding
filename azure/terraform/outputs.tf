output "target_app_client_id" {
  value       = azuread_application.workstations.client_id
  description = "Hand back to Ringleader: the app client id it authenticates as (the target principal)."
}

output "service_principal_object_id" {
  value       = azuread_service_principal.workstations.object_id
  description = "The service principal's object id (used for the role assignment; informational)."
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

output "gateway_subnet_id" {
  value       = var.create_network && var.create_gateway_subnet ? azurerm_subnet.gateway[0].id : null
  description = "Subnet reserved for the future DNS / HTTPS proxy VM (only when create_gateway_subnet = true)."
}

output "gateway_subnet_prefix" {
  value       = var.create_network && var.create_gateway_subnet ? var.gateway_subnet_prefix : null
  description = "The gateway subnet's prefix. This is what an egress allowlist names to let workstations reach the proxy, so it is worth recording."
}

output "role_extras_granted" {
  description = "Optional action sets folded into the custom role, for audit. The base action list is in ../arm/azuredeploy.json."
  value = concat(
    var.enable_workstation_identities ? ["Microsoft.ManagedIdentity CRUD + assign, Microsoft.Authorization roleAssignments -- workstation runtime identities"] : [],
    var.enable_egress_control ? ["Microsoft.Network/networkSecurityGroups (+ securityRules) read/write/delete and join/action -- egress control"] : [],
  )
}

output "handoff" {
  description = "Everything to hand back to Ringleader, in one place. Add your tenant id (az account show --query tenantId -o tsv)."
  value = {
    target_app_client_id = azuread_application.workstations.client_id
    subscription_id      = var.subscription_id
    resource_group_name  = var.resource_group_name
    subnet_id            = var.create_network ? azurerm_subnet.workstations[0].id : null
  }
}
