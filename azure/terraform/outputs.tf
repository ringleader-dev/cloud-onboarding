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

output "handoff" {
  description = "Everything to hand back to Ringleader, in one place. Add your tenant id (az account show --query tenantId -o tsv)."
  value = {
    target_app_client_id = azuread_application.workstations.client_id
    subscription_id      = var.subscription_id
    resource_group_name  = var.resource_group_name
    subnet_id            = var.create_network ? azurerm_subnet.workstations[0].id : null
  }
}
