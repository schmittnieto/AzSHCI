output "cluster_resource_id" {
  description = "Azure resource ID of the Azure Local cluster."
  value       = var.enable_cluster_module ? module.azure_local_cluster[0].resource_id : null
}

output "key_vault_id" {
  description = "Azure resource ID of the Key Vault pre-created for cluster deployment secrets."
  value       = azurerm_key_vault.deployment_keyvault.id
}

output "key_vault_uri" {
  description = "URI of the Key Vault (vault_uri), used by the deployment settings as secrets location."
  value       = azurerm_key_vault.deployment_keyvault.vault_uri
}

output "witness_storage_account_id" {
  description = "Azure resource ID of the cloud witness storage account."
  value       = azurerm_storage_account.witness.id
}

output "custom_location_id" {
  description = "Azure resource ID of the Arc custom location. null until deployment_completed = true."
  value       = var.enable_cluster_module && module.azure_local_cluster[0].customlocation != null ? module.azure_local_cluster[0].customlocation.id : null
}
