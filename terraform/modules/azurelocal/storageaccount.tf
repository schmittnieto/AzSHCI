resource "azurerm_storage_account" "witness" {
  count = (lower(var.witness_type) == "cloud" && var.create_witness_storage_account) ? 1 : 0

  account_replication_type         = var.account_replication_type
  account_tier                     = "Standard"
  location                         = local.resource_group_location
  name                             = var.random_suffix ? "${var.witness_storage_account_name}${random_integer.random_suffix.result}" : var.witness_storage_account_name
  resource_group_name              = local.witness_storage_account_resource_group_name
  allow_nested_items_to_be_public  = var.allow_nested_items_to_be_public
  cross_tenant_replication_enabled = var.cross_tenant_replication_enabled
  min_tls_version                  = var.min_tls_version
  tags                             = var.storage_tags
}

data "azurerm_storage_account" "witness" {
  count = (lower(var.witness_type) == "cloud" && !var.create_witness_storage_account) ? 1 : 0

  name                = var.witness_storage_account_name
  resource_group_name = local.witness_storage_account_resource_group_name
}
