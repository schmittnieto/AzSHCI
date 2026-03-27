data "azapi_resource" "arcbridge" {
  type      = "Microsoft.ResourceConnector/appliances@2022-10-27"
  name      = "${var.name}-arcbridge"
  parent_id = var.resource_group_id

  depends_on = [azapi_update_resource.deploymentsetting]
}

data "azapi_resource" "customlocation" {
  type      = "Microsoft.ExtendedLocation/customLocations@2021-08-15"
  name      = var.custom_location_name
  parent_id = var.resource_group_id

  depends_on = [azapi_update_resource.deploymentsetting]
}

data "azapi_resource_list" "user_storages" {
  parent_id              = var.resource_group_id
  type                   = "Microsoft.AzureStackHCI/storagecontainers@2022-12-15-preview"
  response_export_values = ["*"]

  depends_on = [azapi_update_resource.deploymentsetting]
}

data "azapi_resource" "arc_settings" {
  type      = "Microsoft.AzureStackHCI/clusters/ArcSettings@2024-04-01"
  name      = "default"
  parent_id = azapi_resource.cluster.id

  depends_on = [azapi_update_resource.deploymentsetting]
}

resource "azapi_resource" "cluster" {
  type = "Microsoft.AzureStackHCI/clusters@2026-03-01-preview"
  body = {
    properties = {}
  }
  location  = var.location
  name      = var.name
  parent_id = var.resource_group_id
  tags      = var.cluster_tags

  identity {
    type = "SystemAssigned"
  }

  depends_on = [azurerm_role_assignment.service_principal_role_assign]

  lifecycle {
    ignore_changes = [
      body.properties,
      identity[0]
    ]
  }
}

# Generate random integer suffix for storage account and key vault
resource "random_integer" "random_suffix" {
  max = 99
  min = 10
}

# required AVM resources interfaces
resource "azurerm_management_lock" "this" {
  count = var.lock != null ? 1 : 0

  lock_level = var.lock.kind
  name       = coalesce(var.lock.name, "lock-${var.lock.kind}")
  scope      = azapi_resource.cluster.id
  notes      = var.lock.kind == "CanNotDelete" ? "Cannot delete the resource or its child resources." : "Cannot delete or modify the resource or its child resources."
}

resource "azurerm_role_assignment" "this" {
  for_each = var.role_assignments

  principal_id                           = each.value.principal_id
  scope                                  = azapi_resource.cluster.id
  condition                              = each.value.condition
  condition_version                      = each.value.condition_version
  delegated_managed_identity_resource_id = each.value.delegated_managed_identity_resource_id
  role_definition_id                     = strcontains(lower(each.value.role_definition_id_or_name), lower(local.role_definition_resource_substring)) ? each.value.role_definition_id_or_name : null
  role_definition_name                   = strcontains(lower(each.value.role_definition_id_or_name), lower(local.role_definition_resource_substring)) ? null : each.value.role_definition_id_or_name
  skip_service_principal_aad_check       = each.value.skip_service_principal_aad_check
}
