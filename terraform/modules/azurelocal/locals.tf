locals {
  adapter_properties = {
    jumboPacket             = ""
    networkDirect           = "Disabled"
    networkDirectTechnology = ""
  }
  auto_generated_secrets = (var.witness_type == null || var.witness_type == "") ? local.base_secrets : concat(local.base_secrets, [local.witness_secret])
  base_secrets = [
    {
      eceSecretName = "AzureStackLCMUserCredential"
      secretSuffix  = "AzureStackLCMUserCredential"
    },
    {
      eceSecretName = "LocalAdminCredential"
      secretSuffix  = "LocalAdminCredential"
    },
    {
      eceSecretName = "DefaultARBApplication"
      secretSuffix  = "DefaultARBApplication"
    }
  ]
  combined_adapters         = setintersection(toset(var.management_adapters), toset(local.storage_adapters))
  combined_keyvault_secrets = length(var.keyvault_secrets) != 0 ? var.keyvault_secrets : local.auto_generated_secrets
  compute_rdma_adapter_properties = {
    jumboPacket             = var.compute_rdma_jumbo_packet
    networkDirect           = "Enabled"
    networkDirectTechnology = var.compute_rdma_protocol
  }
  converged = (length(local.combined_adapters) == length(var.management_adapters)) && (length(local.combined_adapters) == length(local.storage_adapters))
  converged_intents = [{
    name                               = var.intent_name,
    trafficType                        = var.traffic_type,
    adapter                            = flatten(var.management_adapters),
    overrideVirtualSwitchConfiguration = false,
    virtualSwitchConfigurationOverrides = {
      enableIov              = "",
      loadBalancingAlgorithm = ""
    },
    overrideQosPolicy        = var.override_qos_policy,
    qosPolicyOverrides       = var.qos_policy_overrides,
    overrideAdapterProperty  = var.override_adapter_property,
    adapterPropertyOverrides = var.rdma_enabled ? local.rdma_adapter_properties : local.adapter_properties
  }]
  decoded_user_storages            = data.azapi_resource_list.user_storages.output.value
  deployment_configuration_version = var.deployment_configuration_version != null ? var.deployment_configuration_version : (var.operation_type == "ClusterUpgrade" ? "10.1.0.0" : "10.0.0.0")
  deployment_data = {
    securitySettings = local.security_settings
    observability = {
      streamingDataClient = var.streaming_data_client
      euLocation          = var.eu_location
      episodicDataUpload  = var.episodic_data_upload
    }
    cluster = {
      name                 = var.cluster_name == "" ? azapi_resource.cluster.name : var.cluster_name
      witnessType          = var.witness_type
      witnessPath          = var.witness_path
      cloudAccountName     = var.create_witness_storage_account ? azurerm_storage_account.witness[0].name : var.witness_storage_account_name
      azureServiceEndpoint = var.azure_service_endpoint
    }
    storage = {
      configurationMode = var.configuration_mode
    }
    namingPrefix          = var.naming_prefix == "" ? var.site_id : var.naming_prefix
    domainFqdn            = var.domain_fqdn
    infrastructureNetwork = local.infrastructure_network
    physicalNodes         = flatten(var.servers)
    hostNetwork           = local.host_network
    adouPath              = var.adou_path
    secretsLocation       = var.use_legacy_key_vault_model ? local.secrets_location : (var.secrets_location == "" ? null : var.secrets_location)
    secrets               = var.use_legacy_key_vault_model ? null : local.keyvault_secrets
    optionalServices = {
      customLocation = var.custom_location_name
    }
  }
  deployment_data_omit_null = { for k, v in local.deployment_data : k => v if v != null }
  deployment_setting_properties = {
    arcNodeResourceIds = flatten([for server in data.azurerm_arc_machine.arcservers : server.id])
    deploymentMode     = var.is_exported ? "Deploy" : "Validate"
    deploymentConfiguration = {
      version = local.deployment_configuration_version
      scaleUnits = [
        {
          deploymentData = local.deployment_data_omit_null
          # sbePartnerInfo is present in the ARM QuickStart template even when
          # no OEM / Solution Builder Extension (SBE) partner is involved. Omitting
          # it causes Azure to push an incomplete LcmController extension settings
          # object (non-null publicSettings with empty Payload) which prevents the
          # node's DownloadDeploymentPackage from falling through to the cloud
          # manifest fallback path. Sending an explicit empty block matches the
          # ARM template exactly and ensures the deployment control-plane behaves
          # identically to a portal/ARM deployment.
          sbePartnerInfo = {
            sbeDeploymentInfo = {
              version                 = ""
              family                  = ""
              publisher               = ""
              sbeManifestSource       = ""
              sbeManifestCreationDate = null
            }
            partnerProperties = []
            credentialList    = []
          }
        }
      ]
    }
  }
  deployment_setting_properties_omit_null = { for k, v in local.deployment_setting_properties : k => v if v != null }
  host_network = var.operation_type == "ClusterUpgrade" ? null : merge(
    {
      enableStorageAutoIp           = var.enable_storage_auto_ip
      intents                       = local.converged ? local.converged_intents : local.seperate_intents
      storageNetworks               = local.storage_networks
      storageConnectivitySwitchless = var.storage_connectivity_switchless
    },
    var.networking_type    != "" ? { networkingType    = var.networking_type    } : {},
    var.networking_pattern != "" ? { networkingPattern = var.networking_pattern } : {}
  )
  infrastructure_network = [{
    useDhcp    = var.use_dhcp
    subnetMask = var.subnet_mask
    gateway    = var.default_gateway
    ipPools = [
      {
        startingAddress = var.starting_address
        endingAddress   = var.ending_address
      }
    ]
    dnsServers = flatten(var.dns_servers)
  }]
  key_vault = var.create_key_vault ? azurerm_key_vault.deployment_keyvault[0] : data.azurerm_key_vault.key_vault[0]
  keyvault_secret_names = var.use_legacy_key_vault_model ? {
    "AzureStackLCMUserCredential" = "AzureStackLCMUserCredential"
    "LocalAdminCredential"        = "LocalAdminCredential"
    "DefaultARBApplication"       = "DefaultARBApplication"
    "WitnessStorageKey"           = "WitnessStorageKey"
    } : {
    for secret in local.combined_keyvault_secrets : secret.eceSecretName => "${var.name}-${secret.secretSuffix}"
  }
  keyvault_secrets = [
    for secret in local.combined_keyvault_secrets : {
      secretName     = local.keyvault_secret_names[secret.eceSecretName]
      eceSecretName  = secret.eceSecretName
      secretLocation = "${local.secrets_location}secrets/${local.keyvault_secret_names[secret.eceSecretName]}"
    }
  ]
  owned_user_storages = var.deployment_completed ? [for storage in local.decoded_user_storages : storage if lower(storage.extendedLocation.name) == lower(data.azapi_resource.customlocation[0].id)] : []
  rdma_adapter_properties = {
    jumboPacket             = var.rdma_jumbo_packet
    networkDirect           = "Enabled"
    networkDirectTechnology = var.rdma_protocol
  }
  resource_group_location = var.resource_group_location == "" ? var.location : var.resource_group_location
  # The resource group name is the last element of the split result
  resource_group_name = element(local.resource_group_parts, length(local.resource_group_parts) - 1)
  # Split the resource group ID into parts based on '/'
  resource_group_parts = split("/", var.resource_group_id)
  role_assignments = flatten([
    for server_key, arcserver in data.azurerm_arc_machine.arcservers : [
      for role_key, role_name in local.roles : {
        server_name  = server_key
        principal_id = arcserver.identity[0].principal_id
        role_name    = role_name
        role_key     = role_key
      }
    ]
  ])
  rg_role_assignments = flatten([
    for server_key, arcserver in data.azurerm_arc_machine.arcservers : [
      for role_key, role_id in local.rg_roles : {
        server_name = server_key
        principal_id = arcserver.identity[0].principal_id
        role_id      = "/subscriptions/${local.subscription_id}/providers/Microsoft.Authorization/roleDefinitions/${role_id}"
        role_key     = role_key
      }
    ]
  ])
  role_definition_resource_substring = "/providers/Microsoft.Authorization/roleDefinitions"
  roles = {
    KVSU = "Key Vault Secrets User",
  }
  # Roles assigned to the Arc machine identity at resource group scope.
  # Required by the HCI deployment control plane — present in the ARM QuickStart template
  # but absent from the upstream AVM module rolebindings.
  rg_roles = {
    DMR   = "865ae368-6a45-4bd1-8fbf-0d5151f56fc1" # Azure Stack HCI Device Management Role
    INFRA = "c99c945f-8bd1-4fb1-a903-01460aae6068" # Azure Stack HCI Connected InfraVMs
  }
  rp_roles = var.create_hci_rp_role_assignments ? {
    ACMRM = "Azure Connected Machine Resource Manager",
  } : {}
  subscription_id = local.resource_group_parts[2]
  secrets_location = var.secrets_location == "" ? local.key_vault.vault_uri : var.secrets_location
  security_settings = var.operation_type == "ClusterUpgrade" ? null : {
    hvciProtection                = var.hvci_protection
    drtmProtection                = var.drtm_protection
    driftControlEnforced          = var.drift_control_enforced
    credentialGuardEnforced       = var.credential_guard_enforced
    smbSigningEnforced            = var.smb_signing_enforced
    smbClusterEncryption          = var.smb_cluster_encryption
    sideChannelMitigationEnforced = var.side_channel_mitigation_enforced
    bitlockerBootVolume           = var.bitlocker_boot_volume
    bitlockerDataVolumes          = var.bitlocker_data_volumes
    wdacEnforced                  = var.wdac_enforced
  }
  seperate_intents = [{
    name                               = var.compute_intent_name,
    trafficType                        = var.compute_traffic_type,
    adapter                            = flatten(var.management_adapters)
    overrideVirtualSwitchConfiguration = false,
    overrideQosPolicy                  = var.compute_override_qos_policy,
    overrideAdapterProperty            = var.compute_override_adapter_property,
    virtualSwitchConfigurationOverrides = {
      enableIov              = "",
      loadBalancingAlgorithm = ""
    },
    qosPolicyOverrides       = var.compute_qos_policy_overrides,
    adapterPropertyOverrides = var.compute_rdma_enabled ? local.compute_rdma_adapter_properties : local.adapter_properties
    },
    {
      name                               = var.storage_intent_name,
      trafficType                        = var.storage_traffic_type,
      adapter                            = local.storage_adapters,
      overrideVirtualSwitchConfiguration = false,
      overrideQosPolicy                  = var.storage_override_qos_policy,
      overrideAdapterProperty            = var.storage_override_adapter_property,
      virtualSwitchConfigurationOverrides = {
        enableIov              = "",
        loadBalancingAlgorithm = ""
      },
      qosPolicyOverrides       = var.storage_qos_policy_overrides,
      adapterPropertyOverrides = var.storage_rdma_enabled ? local.storage_rdma_adapter_properties : local.adapter_properties
  }]
  storage_adapters = flatten([for storageNetwork in var.storage_networks : storageNetwork.networkAdapterName])
  storage_networks = var.storage_adapter_ip_info == null ? flatten(var.storage_networks) : [
    for storageNetwork in var.storage_networks : {
      name                 = storageNetwork.name
      networkAdapterName   = storageNetwork.networkAdapterName
      vlanId               = storageNetwork.vlanId
      storageAdapterIPInfo = var.storage_adapter_ip_info[storageNetwork.name]
    }
  ]
  storage_rdma_adapter_properties = {
    jumboPacket             = var.storage_rdma_jumbo_packet
    networkDirect           = "Enabled"
    networkDirectTechnology = var.storage_rdma_protocol
  }
  witness_secret = {
    eceSecretName = "WitnessStorageKey"
    secretSuffix  = "WitnessStorageKey"
  }
  witness_storage_account_resource_group_name = var.witness_storage_account_resource_group_name == "" ? local.resource_group_name : var.witness_storage_account_resource_group_name
}
