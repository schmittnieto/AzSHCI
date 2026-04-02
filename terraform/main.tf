# Azure Local cluster deployment via Azure Verified Module (AVM)
#
# Deployment is a two-stage process controlled by the is_exported variable:
#
#   Stage 1 - Validate (is_exported = false, default)
#     terraform apply
#     Creates the Key Vault and witness storage account, then runs the Azure
#     Local deployment validation (~10 minutes). Review the result in the
#     Azure portal before proceeding.
#
#   Stage 2 - Deploy  (is_exported = true)
#     Change is_exported to true in terraform.tfvars, then:
#     terraform apply
#     Triggers the full cluster provisioning (~30-60 minutes).
#
# Module registry: https://registry.terraform.io/modules/Azure/avm-res-azurestackhci-cluster/azurerm/latest
# Module source:   https://github.com/Azure/terraform-azurerm-avm-res-azurestackhci-cluster

# ---------------------------------------------------------------------------
# Import block for existing deploymentSettings resource.
#
# deploymentSettings/default may already exist in Azure if a previous
# terraform apply created it but timed out before the state could be saved
# (e.g. "context deadline exceeded" during the long-running validation).
# When import_deployment_settings = true this block imports the resource so
# that the next apply does not fail with "Resource already exists".
#
# Set import_deployment_settings = false on a fresh environment where no
# prior apply has been attempted.
# ---------------------------------------------------------------------------

import {
  for_each = var.import_deployment_settings && var.enable_cluster_module ? { "default" = "default" } : {}
  id       = "/subscriptions/${var.subscription_id}/resourceGroups/${var.resource_group_name}/providers/Microsoft.AzureStackHCI/clusters/${var.cluster_name}/deploymentSettings/default"
  to       = module.azure_local_cluster[0].azapi_resource.validatedeploymentsetting
}

# ---------------------------------------------------------------------------
# Import block for existing machine resource-group role assignments.
#
# machine_rg_role_assign resources (DMR, INFRA) may already exist in Azure if
# a previous terraform apply created them but the state was lost before saving
# (results in 409 RoleAssignmentExists on the next apply).
# Populate import_machine_rg_role_assignment_ids with the GUIDs from the 409
# error message, run terraform apply, then reset the variable to {}.
# ---------------------------------------------------------------------------

import {
  for_each = var.enable_cluster_module ? var.import_machine_rg_role_assignment_ids : {}
  id       = "/subscriptions/${var.subscription_id}/resourceGroups/${var.resource_group_name}/providers/Microsoft.Authorization/roleAssignments/${each.value}"
  to       = module.azure_local_cluster[0].azurerm_role_assignment.machine_rg_role_assign[each.key]
}

# ---------------------------------------------------------------------------
# Data sources
# ---------------------------------------------------------------------------

data "azurerm_resource_group" "rg" {
  name = var.resource_group_name
}

# Used to set the Key Vault tenant ID to the current subscription tenant.
data "azurerm_client_config" "current" {}

# ---------------------------------------------------------------------------
# Random 4-digit suffix for globally unique resource names.
# Persisted in Terraform state so the same names are reused across applies.
# ---------------------------------------------------------------------------

resource "random_integer" "name_suffix" {
  min = 1000
  max = 9999
}

locals {
  kv_name = "${var.keyvault_name}${random_integer.name_suffix.result}"
  sa_name = "${var.witness_storage_account_name}${random_integer.name_suffix.result}"
}

# ---------------------------------------------------------------------------
# Key Vault
#
# Created before the AVM module runs so that it exists during both the
# Validate and Deploy stages. The module is told not to create its own
# Key Vault (create_key_vault = false) and will locate this one by name.
#
# purge_protection_enabled = false allows terraform destroy to permanently
# delete the vault. Combined with purge_soft_delete_on_destroy = true in
# providers.tf, the name is immediately available for reuse on the next apply.
# ---------------------------------------------------------------------------

resource "azurerm_key_vault" "deployment_keyvault" {
  name                       = local.kv_name
  location                   = data.azurerm_resource_group.rg.location
  resource_group_name        = data.azurerm_resource_group.rg.name
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  sku_name                   = "standard"
  soft_delete_retention_days = 7
  purge_protection_enabled   = false
  rbac_authorization_enabled = true
}

# ---------------------------------------------------------------------------
# Cloud witness storage account
#
# Created before the AVM module runs. The module is told not to create its
# own storage account (create_witness_storage_account = false) and will
# reference this one by name.
# ---------------------------------------------------------------------------

resource "azurerm_storage_account" "witness" {
  name                     = local.sa_name
  resource_group_name      = data.azurerm_resource_group.rg.name
  location                 = data.azurerm_resource_group.rg.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
  min_tls_version          = "TLS1_2"
}

# ---------------------------------------------------------------------------
# Azure Local cluster (AVM module)
# ---------------------------------------------------------------------------

module "azure_local_cluster" {
  count = var.enable_cluster_module ? 1 : 0

  # Local fork of Azure/avm-res-azurestackhci-cluster/azurerm v2.x with three additions:
  #   - networking_type and networking_pattern passed to hostNetwork (API 2025-09-15-preview)
  #   - use_dhcp, enable_storage_auto_ip, streaming_data_client, episodic_data_upload exposed
  #   - All three resource types upgraded to API version 2025-09-15-preview
  source = "./modules/azurelocal"

  # Core identifiers
  name              = var.cluster_name
  location          = data.azurerm_resource_group.rg.location
  resource_group_id = data.azurerm_resource_group.rg.id

  # Active Directory
  domain_fqdn = var.domain_fqdn
  adou_path   = var.adou_path

  # Credentials
  # deployment_user / deployment_user_password must match the LCM user
  # created by 01_DC.ps1 (default: hciadmin).
  # local_admin_user / local_admin_password must match the local
  # administrator account on the Azure Local node (default: Setupuser,
  # created by 02_Cluster.ps1).
  deployment_user          = var.deployment_user
  deployment_user_password = var.deployment_user_password
  local_admin_user         = var.local_admin_user
  local_admin_password     = var.local_admin_password

  # Network — values must match the static IP configuration applied by
  # 02_Cluster.ps1. The starting/ending address range is reserved for
  # infrastructure IPs (management VIPs, load balancer, etc.) and must not
  # overlap with any statically assigned node IP (default node: 172.19.18.10).
  default_gateway  = var.default_gateway
  dns_servers      = var.dns_servers
  starting_address = var.starting_address
  ending_address   = var.ending_address
  subnet_mask      = var.subnet_mask

  # Servers — one entry per Arc-registered node.
  servers = var.servers

  # Service principals
  # service_principal_id / service_principal_secret come from the SPN
  # created by scripts/01Lab/00_AzurePreRequisites.ps1.
  # rp_service_principal_object_id is the object ID of the built-in
  # Microsoft.AzureStackHCI resource provider SPN:
  #   (Get-AzADServicePrincipal -ApplicationId "1412d89f-b8a8-4111-b4fd-e82905cbd85d").Id
  service_principal_id           = var.service_principal_id
  service_principal_secret       = var.service_principal_secret
  rp_service_principal_object_id = var.rp_service_principal_object_id

  # Key Vault and cloud witness storage account.
  # Both are pre-created above; the module performs data lookups by name.
  create_key_vault               = false
  keyvault_name                  = local.kv_name
  create_witness_storage_account = false
  witness_storage_account_name   = local.sa_name

  # Custom location and site
  custom_location_name = var.custom_location_name
  site_id              = var.site_id

  # Network adapters.
  # management_adapters must match the NIC names configured inside the
  # Azure Local OS by 02_Cluster.ps1 (MGMT1 and MGMT2 in the default lab).
  management_adapters = var.management_adapters

  # RDMA — disabled for this single-node lab. Single-node deployments with
  # switchless storage have no cross-node storage traffic, so RDMA provides
  # no benefit. Setting all three flags explicitly to false ensures no RDMA
  # configuration is applied regardless of converged or separate intent mode.
  rdma_enabled         = var.rdma_enabled
  compute_rdma_enabled = var.rdma_enabled
  storage_rdma_enabled = var.rdma_enabled

  # Storage networking.
  # Single-node labs use switchless storage (no cross-node traffic).
  # storage_networks is empty; Express configuration mode handles
  # converged intent for management, compute and storage on the same adapters.
  storage_connectivity_switchless = var.storage_connectivity_switchless
  storage_networks                = var.storage_networks

  # Deployment mode — controlled by is_exported:
  #   false (default) → deploymentMode = "Validate"  (Stage 1)
  #   true            → deploymentMode = "Deploy"     (Stage 2)
  is_exported = var.is_exported

  # Deployment configuration mode.
  # Express is recommended for single-node lab deployments.
  configuration_mode = var.configuration_mode

  # Security — BitLocker disabled for lab deployments on thin-provisioned
  # VHDX disks inside a nested VM. credentialGuardEnforced matches the
  # portal's Customized security settings.
  bitlocker_boot_volume     = var.bitlocker_boot_volume
  bitlocker_data_volumes    = var.bitlocker_data_volumes
  credential_guard_enforced = var.credential_guard_enforced

  # Observability — euLocation must be true for EU-region deployments.
  eu_location = var.eu_location

  # Quorum witness. The portal ARM template for single-node uses witness_type = ""
  # (no witness). The module always passes cloudAccountName to the API even when
  # witness_type is empty — this is a known AVM module limitation.
  witness_type = var.witness_type

  # Network intent — name and traffic types match the portal's single-node
  # managementComputeOnly pattern (Compute_Management intent, no Storage traffic).
  intent_name  = var.intent_name
  traffic_type = var.traffic_type

  # Networking type and pattern — fields introduced in API 2025-09-15-preview.
  # The portal uses "singleServerDeployment" + "managementComputeOnly" for single-node.
  # Set to "" to omit the field and let Azure infer (backwards compatible with 2024 API behaviour).
  networking_type    = var.networking_type
  networking_pattern = var.networking_pattern

  # resource names are managed explicitly; no random suffix needed.
  random_suffix = false

  resource_group_location = data.azurerm_resource_group.rg.location

  enable_telemetry = var.enable_telemetry

  # Post-deployment resource reads — only enable after a successful full deployment.
  deployment_completed = var.deployment_completed

  depends_on = [
    azurerm_key_vault.deployment_keyvault,
    azurerm_storage_account.witness
  ]
}
