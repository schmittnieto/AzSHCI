output "arc_settings" {
  description = "Arc settings instance after HCI connected."
  value       = data.azapi_resource.arc_settings
}

output "arcbridge" {
  description = "Arc resource bridge instance after HCI connected."
  value       = data.azapi_resource.arcbridge
}

output "cluster" {
  description = "HCI Cluster instance"
  value       = azapi_resource.cluster
}

output "customlocation" {
  description = "Custom location instance after HCI connected."
  value       = data.azapi_resource.customlocation
}

output "keyvault" {
  description = "Keyvault instance that stores deployment secrets."
  value       = local.key_vault
}

# Module owners should include the full resource via a 'resource' output
# https://azure.github.io/Azure-Verified-Modules/specs/terraform/#id-tffr2---category-outputs---additional-terraform-outputs
output "resource_id" {
  description = "This is the full output for the resource."
  value       = azapi_resource.cluster.id
}

output "user_storages" {
  description = "User storage instances after HCI connected."
  value       = local.owned_user_storages
}

output "v_switch_name" {
  description = "The name of the virtual switch that is used by the network."
  value       = local.converged ? "ConvergedSwitch(${lower(var.intent_name)})" : "ConvergedSwitch(${lower(var.compute_intent_name)})"
}
