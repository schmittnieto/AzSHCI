data "azuread_service_principal" "hci_rp" {
  count = var.rp_service_principal_object_id == "" ? 1 : 0

  client_id = "1412d89f-b8a8-4111-b4fd-e82905cbd85d"
}

resource "azurerm_role_assignment" "service_principal_role_assign" {
  for_each = local.rp_roles

  principal_id         = var.rp_service_principal_object_id == "" ? data.azuread_service_principal.hci_rp[0].object_id : var.rp_service_principal_object_id
  scope                = var.resource_group_id
  role_definition_name = each.value

  depends_on = [data.azuread_service_principal.hci_rp]
}

resource "azurerm_role_assignment" "machine_role_assign" {
  for_each = {
    for idx, assignment in local.role_assignments :
    "${assignment.server_name}_${assignment.role_key}" => assignment
  }

  principal_id         = each.value.principal_id
  scope                = replace(local.key_vault.id, var.keyvault_name, lower(var.keyvault_name))
  role_definition_name = each.value.role_name

  depends_on = [
    azurerm_key_vault.deployment_keyvault,
    data.azurerm_key_vault.key_vault
  ]
}
