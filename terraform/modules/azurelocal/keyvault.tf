data "azurerm_client_config" "current" {
  count = var.tenant_id == "" ? 1 : 0
}

resource "azurerm_key_vault" "deployment_keyvault" {
  count = var.create_key_vault ? 1 : 0

  location                        = var.key_vault_location == "" ? local.resource_group_location : var.key_vault_location
  name                            = var.random_suffix ? "${var.keyvault_name}-${random_integer.random_suffix.result}" : var.keyvault_name
  resource_group_name             = local.resource_group_name
  sku_name                        = "standard"
  tenant_id                       = var.tenant_id == "" ? data.azurerm_client_config.current[0].tenant_id : var.tenant_id
  enable_rbac_authorization       = true
  enabled_for_deployment          = true
  enabled_for_disk_encryption     = true
  enabled_for_template_deployment = true
  public_network_access_enabled   = true
  purge_protection_enabled        = var.keyvault_purge_protection_enabled
  # arm template has enableSoftDelete": false, but terraform can't disable it after version 2.42.
  soft_delete_retention_days = var.keyvault_soft_delete_retention_days
  tags                       = var.keyvault_tags
}

data "azurerm_key_vault" "key_vault" {
  count = var.create_key_vault ? 0 : 1

  name                = var.keyvault_name
  resource_group_name = var.key_vault_resource_group == "" ? local.resource_group_name : var.key_vault_resource_group
}

resource "azurerm_key_vault_secret" "azure_stack_lcm_user_credential" {
  key_vault_id    = local.key_vault.id
  name            = local.keyvault_secret_names["AzureStackLCMUserCredential"]
  value           = base64encode("${var.deployment_user}:${var.deployment_user_password}")
  content_type    = one(flatten([var.azure_stack_lcm_user_credential_content_type]))
  expiration_date = var.azure_stack_lcm_user_credential_expiration_date
  tags            = var.azure_stack_lcm_user_credential_tags

  depends_on = [
    azurerm_key_vault.deployment_keyvault,
    data.azurerm_key_vault.key_vault,
  ]
}

resource "azurerm_key_vault_secret" "local_admin_credential" {
  key_vault_id    = local.key_vault.id
  name            = local.keyvault_secret_names["LocalAdminCredential"]
  value           = base64encode("${var.local_admin_user}:${var.local_admin_password}")
  content_type    = one(flatten([var.local_admin_credential_content_type]))
  expiration_date = var.local_admin_credential_expiration_date
  tags            = var.local_admin_credential_tags

  depends_on = [
    azurerm_key_vault.deployment_keyvault,
    data.azurerm_key_vault.key_vault,
  ]
}

resource "azurerm_key_vault_secret" "default_arb_application" {
  key_vault_id    = local.key_vault.id
  name            = local.keyvault_secret_names["DefaultARBApplication"]
  value           = base64encode("${var.service_principal_id}:${var.service_principal_secret}")
  content_type    = one(flatten([var.default_arb_application_content_type]))
  expiration_date = var.default_arb_application_expiration_date
  tags            = var.default_arb_application_tags

  depends_on = [
    azurerm_key_vault.deployment_keyvault,
    data.azurerm_key_vault.key_vault,
  ]
}

resource "azurerm_key_vault_secret" "witness_storage_key" {
  count = lower(var.witness_type) == "cloud" ? 1 : 0

  key_vault_id    = local.key_vault.id
  name            = local.keyvault_secret_names["WitnessStorageKey"]
  value           = base64encode(var.create_witness_storage_account ? azurerm_storage_account.witness[0].primary_access_key : data.azurerm_storage_account.witness[0].primary_access_key)
  content_type    = one(flatten([var.witness_storage_key_content_type]))
  expiration_date = var.witness_storage_key_expiration_date
  tags            = var.witness_storage_key_tags

  depends_on = [
    azurerm_key_vault.deployment_keyvault,
    data.azurerm_key_vault.key_vault,
    azurerm_storage_account.witness,
    data.azurerm_storage_account.witness,
  ]
}
