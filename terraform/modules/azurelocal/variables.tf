variable "adou_path" {
  type        = string
  description = "The Active Directory OU path."
}

variable "custom_location_name" {
  type        = string
  description = "The name of the custom location."
}

variable "default_gateway" {
  type        = string
  description = "The default gateway for the network."
}

variable "deployment_user" {
  type        = string
  description = "The username for the domain administrator account."
}

variable "deployment_user_password" {
  type        = string
  description = "The password for the domain administrator account."
  sensitive   = true
}

variable "dns_servers" {
  type        = list(string)
  description = "A list of DNS server IP addresses."
  nullable    = false
}

# deploymentSettings related variables
variable "domain_fqdn" {
  type        = string
  description = "The domain FQDN."
}

variable "ending_address" {
  type        = string
  description = "The ending IP address of the IP address range."
}

variable "keyvault_name" {
  type        = string
  description = "The name of the key vault."
}

variable "local_admin_password" {
  type        = string
  description = "The password for the local administrator account."
  sensitive   = true
}

variable "local_admin_user" {
  type        = string
  description = "The username for the local administrator account."
}

variable "location" {
  type        = string
  description = "Azure region where the resource should be deployed."
  nullable    = false
}

variable "name" {
  type        = string
  description = "The name of the HCI cluster. Must be the same as the name when preparing AD."

  validation {
    condition     = var.cluster_name != "" || (length(var.name) < 16 && length(var.name) > 0)
    error_message = "If 'cluster_name' is empty, 'name' must be between 1 and 16 characters."
  }
  validation {
    condition     = length(var.name) <= 40 && length(var.name) > 0
    error_message = "value of name should be less than 40 characters and greater than 0 characters"
  }
}

variable "resource_group_id" {
  type        = string
  description = "The resource id of resource group."
}

variable "servers" {
  type = list(object({
    name        = string
    ipv4Address = string
  }))
  description = "A list of servers with their names and IPv4 addresses."
}

variable "service_principal_id" {
  type        = string
  description = "The service principal ID for the Azure account."
}

variable "service_principal_secret" {
  type        = string
  description = "The service principal secret for the Azure account."
}

variable "site_id" {
  type        = string
  description = "A unique identifier for the site."

  validation {
    condition     = can(regex("^[a-zA-Z0-9-]{1,8}$", var.site_id))
    error_message = "value of site_id should be less than 9 characters and greater than 0 characters and only contain alphanumeric characters and hyphens, this is the requirement of name prefix in hci deploymentsetting"
  }
}

variable "starting_address" {
  type        = string
  description = "The starting IP address of the IP address range."
}

variable "account_replication_type" {
  type        = string
  default     = "ZRS"
  description = "The replication type for the storage account."
}

variable "allow_nested_items_to_be_public" {
  type        = bool
  default     = false
  description = "Indicates whether nested items can be public."
}

variable "azure_service_endpoint" {
  type        = string
  default     = "core.windows.net"
  description = "The Azure service endpoint."
}

variable "azure_stack_lcm_user_credential_content_type" {
  type        = string
  default     = null
  description = "(Optional) Content type of the azure stack lcm user credential."
}

variable "azure_stack_lcm_user_credential_expiration_date" {
  type        = string
  default     = null
  description = "(Optional) Expiration date of the azure stack lcm user credential."
}

variable "azure_stack_lcm_user_credential_tags" {
  type        = map(string)
  default     = null
  description = "(Optional) Tags of the azure stack lcm user credential."
}

variable "bitlocker_boot_volume" {
  type        = bool
  default     = true
  description = "When set to true, BitLocker XTS_AES 256-bit encryption is enabled for all data-at-rest on the OS volume of your Azure Stack HCI cluster. This setting is TPM-hardware dependent."
}

variable "bitlocker_data_volumes" {
  type        = bool
  default     = true
  description = "When set to true, BitLocker XTS-AES 256-bit encryption is enabled for all data-at-rest on your Azure Stack HCI cluster shared volumes."
}

variable "cluster_name" {
  type        = string
  default     = ""
  description = "The name of the HCI cluster."

  validation {
    condition     = length(var.cluster_name) < 16 && length(var.cluster_name) >= 0
    error_message = "The value of 'cluster_name' must be less than 16 characters"
  }
}

variable "cluster_tags" {
  type        = map(string)
  default     = null
  description = "(Optional) Tags of the cluster."
}

variable "compute_intent_name" {
  type        = string
  default     = "ManagementCompute"
  description = "The name of compute intent."
}

variable "compute_override_adapter_property" {
  type        = bool
  default     = true
  description = "Indicates whether to override adapter property for compute."
}

variable "compute_override_qos_policy" {
  type        = bool
  default     = false
  description = "Indicates whether to override qos policy for compute network."
}

variable "compute_qos_policy_overrides" {
  type = object({
    priorityValue8021Action_SMB     = string
    priorityValue8021Action_Cluster = string
    bandwidthPercentage_SMB         = string
  })
  default = {
    priorityValue8021Action_SMB     = ""
    priorityValue8021Action_Cluster = ""
    bandwidthPercentage_SMB         = ""
  }
  description = "QoS policy overrides for network settings with required properties for compute."
}

variable "compute_rdma_enabled" {
  type        = bool
  default     = false
  description = "Indicates whether RDMA is enabled for compute."
}

variable "compute_rdma_jumbo_packet" {
  type        = string
  default     = "9014"
  description = "The jumbo packet size for RDMA of compute network."
}

variable "compute_rdma_protocol" {
  type        = string
  default     = "RoCEv2"
  description = "The RDMA protocol of compute network."
}

variable "compute_traffic_type" {
  type = list(string)
  default = [
    "Management",
    "Compute"
  ]
  description = "Traffic type of compute."
}

variable "configuration_mode" {
  type        = string
  default     = "Express"
  description = "The configuration mode for the storage."
}

variable "create_hci_rp_role_assignments" {
  type        = bool
  default     = false
  description = "Indicates whether to create role assignments for the HCI resource provider service principal."
}

variable "create_key_vault" {
  type        = bool
  default     = true
  description = "Set to true to create the key vault, or false to skip it"

  validation {
    condition     = !var.use_legacy_key_vault_model || var.create_key_vault
    error_message = "create_key_vault must be true when use_legacy_key_vault_model is true."
  }
}

variable "create_witness_storage_account" {
  type        = bool
  default     = true
  description = "Set to true to create the witness storage account, or false to skip it"
}

variable "credential_guard_enforced" {
  type        = bool
  default     = false
  description = "When set to true, Credential Guard is enabled on your Azure HCI cluster."
}

variable "cross_tenant_replication_enabled" {
  type        = bool
  default     = false
  description = "Indicates whether cross-tenant replication is enabled."
}

variable "default_arb_application_content_type" {
  type        = string
  default     = null
  description = "(Optional) Content type of the default arb application."
}

variable "default_arb_application_expiration_date" {
  type        = string
  default     = null
  description = "(Optional) Expiration date of the default arb application."
}

variable "default_arb_application_tags" {
  type        = map(string)
  default     = null
  description = "(Optional) Tags of the default arb application."
}

variable "deployment_configuration_version" {
  type        = string
  default     = null
  description = "The version of deployment configuration. Latest version will be used if not specified."
}

variable "drift_control_enforced" {
  type        = bool
  default     = true
  description = "When set to true, the security baseline is re-applied regularly."
}

variable "drtm_protection" {
  type        = bool
  default     = true
  description = "By default, Secure Boot is enabled on your Azure HCI cluster. This setting is hardware dependent."
}

variable "enable_storage_auto_ip" {
  type        = bool
  default     = true
  description = "When true, Azure Local automatically assigns IP addresses to storage adapters. Matches the portal default (enableStorageAutoIp = true)."
}

variable "enable_telemetry" {
  type        = bool
  default     = true
  description = <<DESCRIPTION
This variable controls whether or not telemetry is enabled for the module.
For more information see <https://aka.ms/avm/telemetryinfo>.
If it is set to false, then no telemetry will be collected.
DESCRIPTION
  nullable    = false
}

variable "episodic_data_upload" {
  type        = bool
  default     = true
  description = "When true, diagnostic data is uploaded episodically to Microsoft. Matches the portal default."
}

variable "eu_location" {
  type        = bool
  default     = false
  description = "Indicates whether the location is in EU."
}

variable "hvci_protection" {
  type        = bool
  default     = true
  description = "By default, Hypervisor-protected Code Integrity is enabled on your Azure HCI cluster."
}

variable "intent_name" {
  type        = string
  default     = "ManagementComputeStorage"
  description = "The name of intent."
}

variable "is_exported" {
  type        = bool
  default     = false
  description = "Indicate whether the resource is exported"
}

variable "key_vault_location" {
  type        = string
  default     = ""
  description = "The location of the key vault."
}

variable "key_vault_resource_group" {
  type        = string
  default     = ""
  description = "The resource group of the key vault."
}

variable "keyvault_purge_protection_enabled" {
  type        = bool
  default     = true
  description = "Indicates whether purge protection is enabled."
}

variable "keyvault_secrets" {
  type = list(object({
    eceSecretName = string
    secretSuffix  = string
  }))
  default     = []
  description = "A list of key vault secrets."

  validation {
    condition     = var.use_legacy_key_vault_model || length(var.keyvault_secrets) == 0 || (var.witness_type == null || var.witness_type == "" && length(var.keyvault_secrets) == 3) || (var.witness_type != null && var.witness_type != "" && length(var.keyvault_secrets) == 4)
    error_message = "When use_legacy_key_vault_model is false and keyvault_secrets is provided, it must contain exactly 3 secrets (AzureStackLCMUserCredential, LocalAdminCredential, DefaultARBApplication) if witness_type is not specified (null or empty), or 4 secrets (including WitnessStorageKey) if witness_type is specified."
  }
  validation {
    condition     = var.use_legacy_key_vault_model || length(var.keyvault_secrets) == 0 || alltrue([for secret in var.keyvault_secrets : contains(["AzureStackLCMUserCredential", "LocalAdminCredential", "DefaultARBApplication", "WitnessStorageKey"], secret.eceSecretName)])
    error_message = "keyvault_secrets must be provided when use_legacy_key_vault_model is false. EceSecretNames are AzureStackLCMUserCredential, LocalAdminCredential, DefaultARBApplication, WitnessStorageKey."
  }
}

variable "keyvault_soft_delete_retention_days" {
  type        = number
  default     = 30
  description = "The number of days that items should be retained for soft delete."
}

variable "keyvault_tags" {
  type        = map(string)
  default     = null
  description = "(Optional) Tags of the keyvault."
}

variable "local_admin_credential_content_type" {
  type        = string
  default     = null
  description = "(Optional) Content type of the local admin credential."
}

variable "local_admin_credential_expiration_date" {
  type        = string
  default     = null
  description = "(Optional) Expiration date of the local admin credential."
}

variable "local_admin_credential_tags" {
  type        = map(string)
  default     = null
  description = "(Optional) Tags of the local admin credential."
}

variable "lock" {
  type = object({
    kind = string
    name = optional(string, null)
  })
  default     = null
  description = <<DESCRIPTION
Controls the Resource Lock configuration for this resource. The following properties can be specified:

- `kind` - (Required) The type of lock. Possible values are `"CanNotDelete"` and `"ReadOnly"`.
- `name` - (Optional) The name of the lock. If not specified, a name will be generated based on the `kind` value. Changing this forces the creation of a new resource.
DESCRIPTION

  validation {
    condition     = var.lock != null ? contains(["CanNotDelete", "ReadOnly"], var.lock.kind) : true
    error_message = "The lock level must be one of: 'None', 'CanNotDelete', or 'ReadOnly'."
  }
}

variable "management_adapters" {
  type        = list(string)
  default     = []
  description = "A list of management adapters."
  nullable    = false
}

variable "min_tls_version" {
  type        = string
  default     = "TLS1_2"
  description = "The minimum TLS version."
}

variable "naming_prefix" {
  type        = string
  default     = ""
  description = "The naming prefix in HCI deployment settings. Site id will be used if not provided."
}

variable "networking_pattern" {
  type        = string
  default     = ""
  description = <<-EOT
    The networking pattern for the deployment. When non-empty, passed as networkingPattern in hostNetwork.
    Values supported by the API:
      ""                       - field omitted (let Azure infer)
      "hyperConverged"         - management, compute and storage on shared adapters
      "convergedManagementCompute" - management and compute converged, storage separate
      "convergedComputeStorage"    - compute and storage converged, management separate
      "managementComputeOnly"      - management and compute only, no storage traffic (single-node)
      "custom"                 - custom pattern
    For single-node lab deployments the portal uses "managementComputeOnly".
  EOT
}

variable "networking_type" {
  type        = string
  default     = ""
  description = <<-EOT
    The networking type for the deployment. When non-empty, passed as networkingType in hostNetwork.
    Values supported by the API:
      ""                            - field omitted (let Azure infer)
      "switchedMultiServerDeployment"   - multi-node with switches
      "switchlessMultiServerDeployment" - multi-node switchless storage
      "singleServerDeployment"          - single-node deployment
    For single-node lab deployments the portal uses "singleServerDeployment".
  EOT
}

variable "operation_type" {
  type        = string
  default     = "ClusterProvisioning"
  description = "The intended operation for a cluster."

  validation {
    condition     = contains(["ClusterProvisioning", "ClusterUpgrade"], var.operation_type == null ? "ClusterProvisioning" : var.operation_type)
    error_message = "operation_type must be either 'ClusterProvisioning' or 'ClusterUpgrade'."
  }
}

variable "override_adapter_property" {
  type        = bool
  default     = true
  description = "Indicates whether to override adapter property."
}

variable "override_qos_policy" {
  type        = bool
  default     = false
  description = "Indicates whether to override qos policy for converged network."
}

variable "qos_policy_overrides" {
  type = object({
    priorityValue8021Action_SMB     = string
    priorityValue8021Action_Cluster = string
    bandwidthPercentage_SMB         = string
  })
  default = {
    priorityValue8021Action_SMB     = ""
    priorityValue8021Action_Cluster = ""
    bandwidthPercentage_SMB         = ""
  }
  description = "QoS policy overrides for network settings with required properties."
}

variable "random_suffix" {
  type        = bool
  default     = true
  description = "Indicate whether to add random suffix"
}

variable "rdma_enabled" {
  type        = bool
  default     = false
  description = "Enables RDMA when set to true. In a converged network configuration, this will make the network use RDMA. In a dedicated storage network configuration, enabling this will enable RDMA on the storage network."
}

variable "rdma_jumbo_packet" {
  type        = string
  default     = "9014"
  description = "The jumbo packet size for RDMA of converged network."
}

variable "rdma_protocol" {
  type        = string
  default     = "RoCEv2"
  description = "The RDMA protocol of converged network."
}

variable "resource_group_location" {
  type        = string
  default     = ""
  description = "The location of resource group."
}

variable "role_assignments" {
  type = map(object({
    role_definition_id_or_name             = string
    principal_id                           = string
    description                            = optional(string, null)
    skip_service_principal_aad_check       = optional(bool, false)
    condition                              = optional(string, null)
    condition_version                      = optional(string, null)
    delegated_managed_identity_resource_id = optional(string, null)
    principal_type                         = optional(string, null)
  }))
  default     = {}
  description = <<DESCRIPTION
A map of role assignments to create on this resource. The map key is deliberately arbitrary to avoid issues where map keys maybe unknown at plan time.

- `role_definition_id_or_name` - The ID or name of the role definition to assign to the principal.
- `principal_id` - The ID of the principal to assign the role to.
- `description` - The description of the role assignment.
- `skip_service_principal_aad_check` - If set to true, skips the Azure Active Directory check for the service principal in the tenant. Defaults to false.
- `condition` - The condition which will be used to scope the role assignment.
- `condition_version` - The version of the condition syntax. Valid values are '2.0'.

> Note: only set `skip_service_principal_aad_check` to true if you are assigning a role to a service principal.
DESCRIPTION
  nullable    = false
}

variable "rp_service_principal_object_id" {
  type        = string
  default     = ""
  description = "The object ID of the HCI resource provider service principal."
}

variable "secrets_location" {
  type        = string
  default     = ""
  description = "Secrets location for the deployment."
}

variable "side_channel_mitigation_enforced" {
  type        = bool
  default     = true
  description = "When set to true, all the side channel mitigations are enabled."
}

variable "smb_cluster_encryption" {
  type        = bool
  default     = false
  description = "When set to true, cluster east-west traffic is encrypted."
}

variable "smb_signing_enforced" {
  type        = bool
  default     = true
  description = "When set to true, the SMB default instance requires sign in for the client and server services."
}

variable "storage_adapter_ip_info" {
  type = map(list(object({
    physicalNode = string
    ipv4Address  = string
    subnetMask   = string
  })))
  default     = null
  description = "The IP information for the storage networks. Key is the storage network name."
}

variable "storage_connectivity_switchless" {
  type        = bool
  default     = false
  description = "Indicates whether storage connectivity is switchless."
}

variable "storage_intent_name" {
  type        = string
  default     = "Storage"
  description = "The name of storage intent."
}

variable "storage_networks" {
  type = list(object({
    name               = string
    networkAdapterName = string
    vlanId             = string
  }))
  default     = []
  description = "A list of storage networks."
}

variable "storage_override_adapter_property" {
  type        = bool
  default     = true
  description = "Indicates whether to override adapter property for storage network."
}

variable "storage_override_qos_policy" {
  type        = bool
  default     = false
  description = "Indicates whether to override qos policy for storage network."
}

variable "storage_qos_policy_overrides" {
  type = object({
    priorityValue8021Action_SMB     = string
    priorityValue8021Action_Cluster = string
    bandwidthPercentage_SMB         = string
  })
  default = {
    priorityValue8021Action_SMB     = ""
    priorityValue8021Action_Cluster = ""
    bandwidthPercentage_SMB         = ""
  }
  description = "QoS policy overrides for network settings with required properties for storage."
}

variable "storage_rdma_enabled" {
  type        = bool
  default     = false
  description = "Indicates whether RDMA is enabled for storage. Storage RDMA will be enabled if either rdma_enabled or storage_rdma_enabled is set to true."
}

variable "storage_rdma_jumbo_packet" {
  type        = string
  default     = "9014"
  description = "The jumbo packet size for RDMA of storage network."
}

variable "storage_rdma_protocol" {
  type        = string
  default     = "RoCEv2"
  description = "The RDMA protocol of storage network."
}

variable "storage_tags" {
  type        = map(string)
  default     = null
  description = "(Optional) Tags of the storage."
}

variable "storage_traffic_type" {
  type = list(string)
  default = [
    "Storage"
  ]
  description = "Traffic type of storage."
}

variable "streaming_data_client" {
  type        = bool
  default     = true
  description = "When true, streaming telemetry data is sent to Microsoft. Matches the portal default."
}

variable "subnet_mask" {
  type        = string
  default     = "255.255.255.0"
  description = "The subnet mask for the network."
}

variable "tenant_id" {
  type        = string
  default     = ""
  description = "(Optional) Value of the tenant id"
}

variable "traffic_type" {
  type = list(string)
  default = [
    "Management",
    "Compute",
    "Storage"
  ]
  description = "Traffic type of intent."
}

variable "use_dhcp" {
  type        = bool
  default     = false
  description = "When true, DHCP is used for host and cluster IPs instead of static assignment. When true, default_gateway and dns_servers are not required by Azure Local."
}

variable "use_legacy_key_vault_model" {
  type        = bool
  default     = false
  description = "Indicates whether to use the legacy key vault model."
}

variable "wdac_enforced" {
  type        = bool
  default     = true
  description = "WDAC is enabled by default and limits the applications and the code that you can run on your Azure Stack HCI cluster."
}

variable "witness_path" {
  type        = string
  default     = "Cloud"
  description = "The path to the witness."
}

variable "witness_storage_account_name" {
  type        = string
  default     = ""
  description = "The name of the witness storage account."

  # Validation rule to ensure the variable is provided if witness_type is "Cloud"
  validation {
    condition     = lower(var.witness_type) != "cloud" || (lower(var.witness_type) == "cloud" && var.witness_storage_account_name != "")
    error_message = "The 'witness_storage_account_name' must be provided when 'witness_type' is set to 'Cloud'."
  }
}

variable "witness_storage_account_resource_group_name" {
  type        = string
  default     = ""
  description = "The resource group of the witness storage account. If not provided, 'resource_group_name' will be used as the storage account's resource group."
}

variable "witness_storage_key_content_type" {
  type        = string
  default     = null
  description = "(Optional) Content type of the witness storage key."
}

variable "witness_storage_key_expiration_date" {
  type        = string
  default     = null
  description = "(Optional) Expiration date of the witness storage key."
}

variable "witness_storage_key_tags" {
  type        = map(string)
  default     = null
  description = "(Optional) Tags of the witness storage key."
}

variable "witness_type" {
  type        = string
  default     = "Cloud"
  description = "The type of the witness."
}
