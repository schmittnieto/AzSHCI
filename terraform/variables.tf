# ---------------------------------------------------------------------------
# Azure subscription and resource group
# ---------------------------------------------------------------------------

variable "subscription_id" {
  type        = string
  description = "Azure subscription ID used to authenticate the azurerm provider."
}

variable "resource_group_name" {
  type        = string
  description = "Name of the existing resource group that will contain all cluster resources."
  default     = "rg-azlocal-lab"
}

# ---------------------------------------------------------------------------
# Cluster identity
# ---------------------------------------------------------------------------

variable "cluster_name" {
  type        = string
  description = "Name of the Azure Local cluster resource (1-40 characters)."
  default     = "azlocal-cluster"
}

variable "site_id" {
  type        = string
  description = "Unique site identifier (1-8 alphanumeric characters or hyphens)."
  default     = "site1"
}

variable "custom_location_name" {
  type        = string
  description = "Name for the Arc custom location resource created by the module."
  default     = "azlocal-customlocation"
}

# ---------------------------------------------------------------------------
# Active Directory
# ---------------------------------------------------------------------------

variable "domain_fqdn" {
  type        = string
  description = "Fully qualified domain name of the AD forest, e.g. azurelocal.local."
}

variable "adou_path" {
  type        = string
  description = "Distinguished name of the OU pre-created by New-HciAdObjectsPreCreation in 01_DC.ps1."
}

# ---------------------------------------------------------------------------
# Credentials
# ---------------------------------------------------------------------------

variable "deployment_user" {
  type        = string
  description = "Domain account used by LCM for cluster deployment. Must already exist in AD (created by 01_DC.ps1)."
  default     = "hciadmin"
}

variable "deployment_user_password" {
  type        = string
  sensitive   = true
  description = "Password for the LCM deployment user."
}

variable "local_admin_user" {
  type        = string
  description = "Local administrator account name on the Azure Local node. In this lab it is the Setupuser created by 02_Cluster.ps1."
  default     = "Setupuser"
}

variable "local_admin_password" {
  type        = string
  sensitive   = true
  description = "Password for the local administrator account on the Azure Local node."
}

# ---------------------------------------------------------------------------
# Network
# ---------------------------------------------------------------------------

variable "default_gateway" {
  type        = string
  description = "Default gateway IP for the lab subnet. Must match the gateway configured on the node by 02_Cluster.ps1."
  default     = "172.19.18.1"
}

variable "dns_servers" {
  type        = list(string)
  description = "List of DNS server IP addresses. Typically the DC IP in the lab (172.19.18.2)."
  default     = ["172.19.18.2"]
}

variable "starting_address" {
  type        = string
  description = "First IP address of the range reserved for Azure Local infrastructure (load balancer VIPs, management IPs). Must not overlap with any statically assigned node IP."
  default     = "172.19.18.20"
}

variable "ending_address" {
  type        = string
  description = "Last IP address of the infrastructure IP range."
  default     = "172.19.18.30"
}

variable "subnet_mask" {
  type        = string
  description = "Subnet mask for the lab network."
  default     = "255.255.255.0"
}

# ---------------------------------------------------------------------------
# Servers
# ---------------------------------------------------------------------------

variable "servers" {
  type = list(object({
    name        = string
    ipv4Address = string
  }))
  description = "List of Azure Local nodes already registered with Arc. Each entry requires the node hostname and its management IP address."
  default = [
    {
      name        = "AZLN01"
      ipv4Address = "172.19.18.10"
    }
  ]
}

# ---------------------------------------------------------------------------
# Service principals
# ---------------------------------------------------------------------------

variable "service_principal_id" {
  type        = string
  description = "Application (client) ID of the SPN created by 00_AzurePreRequisites.ps1 for Arc and HCI operations."
}

variable "service_principal_secret" {
  type        = string
  sensitive   = true
  description = "Client secret of the SPN."
}

variable "rp_service_principal_object_id" {
  type        = string
  description = <<-EOT
    Object ID of the built-in Microsoft.AzureStackHCI resource provider service principal.
    Retrieve it with:
      (Get-AzADServicePrincipal -ApplicationId "1412d89f-b8a8-4111-b4fd-e82905cbd85d").Id
  EOT
}

# ---------------------------------------------------------------------------
# Key Vault and cloud witness
# ---------------------------------------------------------------------------

variable "keyvault_name" {
  type        = string
  description = "Name of the Key Vault created before the AVM module runs. Must be globally unique. purge_protection_enabled is set to false so the vault can be deleted and recreated with the same name."
  default     = "kv-azlocal-lab"
}

variable "witness_storage_account_name" {
  type        = string
  description = "Name of the cloud witness storage account created before the AVM module runs. Must be globally unique and 3-24 lowercase alphanumeric characters."
  default     = "saazlocallab"
}

# ---------------------------------------------------------------------------
# Network adapters
# ---------------------------------------------------------------------------

variable "management_adapters" {
  type        = list(string)
  description = "Names of the network adapters used for management and compute traffic. Must match the NIC names configured inside the Azure Local OS by 02_Cluster.ps1."
  default     = ["MGMT1", "MGMT2"]
}

variable "rdma_enabled" {
  type        = bool
  description = <<-EOT
    Enable RDMA on all network adapters (management, compute and storage intents).
    For single-node lab deployments RDMA is not required:
    - There is no cross-node storage traffic (switchless storage).
    - The lab NICs (MGMT1, MGMT2) are virtual adapters in a nested Hyper-V VM
      and do not support hardware RDMA.
    Set to true only for physical multi-node deployments with RDMA-capable NICs.
  EOT
  default     = false
}

variable "storage_connectivity_switchless" {
  type        = bool
  description = "Set to true for single-node deployments where no cross-node storage traffic exists."
  default     = true
}

variable "storage_networks" {
  type = list(object({
    name               = string
    networkAdapterName = string
    vlanId             = string
  }))
  description = <<-EOT
    Storage network adapters passed to the AVM module.
    For a single-node converged lab, list the same NICs as management_adapters
    (MGMT1 and MGMT2 with vlanId "0"). The module sets converged = true only
    when storage_adapters equals management_adapters, producing a single combined
    intent. With an empty list the module generates two separate intents where
    the storage intent has zero adapters, which fails Azure Local schema validation.
  EOT
  default = [
    { name = "MGMT1", networkAdapterName = "MGMT1", vlanId = "711" },
    { name = "MGMT2", networkAdapterName = "MGMT2", vlanId = "712" }
  ]
}

# ---------------------------------------------------------------------------
# Deployment mode
# ---------------------------------------------------------------------------

variable "is_exported" {
  type        = bool
  description = <<-EOT
    Controls the Azure Local deployment stage:
      false (default) → deploymentMode = "Validate"
        Run terraform apply with this value first. The Key Vault and storage
        account are created and the deployment configuration is validated
        against the Arc-registered node (~10 minutes). Check the result in
        the Azure portal before proceeding.
      true → deploymentMode = "Deploy"
        After a successful validation, change this to true and run
        terraform apply again to trigger the full cluster provisioning
        (~30-60 minutes).
  EOT
  default     = false
}

# ---------------------------------------------------------------------------
# Deployment options
# ---------------------------------------------------------------------------

variable "configuration_mode" {
  type        = string
  description = "Azure Local deployment configuration mode. Express is recommended for single-node lab environments."
  default     = "Express"

  validation {
    condition     = contains(["Express", "InfraOnly", "KeepStorage"], var.configuration_mode)
    error_message = "configuration_mode must be Express, InfraOnly or KeepStorage."
  }
}

variable "bitlocker_boot_volume" {
  type        = bool
  description = "Enable BitLocker on the OS boot volume. Disabled by default for lab deployments on thin-provisioned VHDX disks."
  default     = false
}

variable "bitlocker_data_volumes" {
  type        = bool
  description = "Enable BitLocker on data volumes. Disabled by default for lab deployments."
  default     = false
}

variable "enable_telemetry" {
  type        = bool
  description = "Allow the AVM module to send telemetry to Microsoft."
  default     = true
}

variable "eu_location" {
  type        = bool
  description = "Set to true when the deployment is in an EU region for data-residency compliance. Matches the portal's euLocation setting."
  default     = false
}

variable "credential_guard_enforced" {
  type        = bool
  description = "When true, Windows Defender Credential Guard is enabled on the cluster. The portal enables this by default under Customized security settings."
  default     = false
}

variable "witness_type" {
  type        = string
  description = <<-EOT
    Quorum witness type. Use \"Cloud\" for cloud witness (requires witness_storage_account_name)
    or \"\" for no witness (single-node lab without quorum). The portal ARM template uses no
    witness for single-node deployments. Note: the AVM module always passes cloudAccountName
    to the API even when witness_type is empty — this is a module limitation.
  EOT
  default     = "Cloud"
}

variable "intent_name" {
  type        = string
  description = "Name of the converged network intent. The portal uses Compute_Management for single-node deployments."
  default     = "ManagementComputeStorage"
}

variable "traffic_type" {
  type        = list(string)
  description = "Traffic types assigned to the converged network intent. The portal uses [Compute, Management] (no Storage) for single-node managementComputeOnly deployments."
  default     = ["Management", "Compute", "Storage"]
}

variable "networking_type" {
  type        = string
  description = <<-EOT
    The networking type passed to hostNetwork in the deploymentSettings body (API 2025-09-15-preview).
    Leave empty to omit the field. The portal uses "singleServerDeployment" for single-node labs.
    Allowed values: "", "switchedMultiServerDeployment", "switchlessMultiServerDeployment", "singleServerDeployment".
  EOT
  default     = ""
}

variable "networking_pattern" {
  type        = string
  description = <<-EOT
    The networking pattern passed to hostNetwork in the deploymentSettings body (API 2025-09-15-preview).
    Leave empty to omit the field. The portal uses "managementComputeOnly" for single-node labs.
    Allowed values: "", "hyperConverged", "convergedManagementCompute", "convergedComputeStorage", "managementComputeOnly", "custom".
  EOT
  default     = ""
}

variable "import_edge_devices" {
  type        = bool
  default     = true
  description = <<-EOT
    When true, Terraform imports the existing Microsoft.AzureStackHCI/edgeDevices/default resource
    for each Arc machine instead of creating it. Set to true if the edge device already exists in
    Azure (e.g. from a prior portal or ARM template deployment). Set to false on a completely fresh
    environment where no deployment has been attempted before.
  EOT
}

variable "import_deployment_settings" {
  type        = bool
  default     = false
  description = <<-EOT
    When true, Terraform imports the existing deploymentSettings/default resource instead of
    creating it. Set to true when a previous terraform apply created the resource in Azure but
    timed out before saving it to state (e.g. context deadline exceeded during validation).
    Set to false on a fresh environment where deploymentSettings does not yet exist.
  EOT
}

variable "deployment_completed" {
  type        = bool
  default     = false
  description = <<-EOT
    Set to true only after a successful full deployment (Stage 2 Deploy finished without errors).
    Controls whether Terraform reads post-deployment resources that are created by the Azure
    deployment engine (arcbridge, customlocation). Keep false while deploying or retrying a
    failed deployment — these resources do not exist until all deployment steps complete.
  EOT
}
