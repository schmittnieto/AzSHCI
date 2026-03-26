# AzSHCI - Azure Local Deployment Scripts

<p align="center">
  <a href="https://github.com/schmittnieto/AzSHCI"><img src="https://badgen.net/https/raw.githubusercontent.com/schmittnieto/AzSHCI/refs/heads/main/lastdeployment.json?cache=300"></a><br>
  <a href="https://github.com/schmittnieto/AzSHCI"><img src="https://img.shields.io/github/languages/top/schmittnieto/AzSHCI.svg"></a>
  <a href="https://github.com/schmittnieto/AzSHCI"><img src="https://img.shields.io/github/languages/code-size/schmittnieto/AzSHCI.svg"></a>
  <a href="https://github.com/schmittnieto/AzSHCI"><img src="https://img.shields.io/github/v/release/schmittnieto/AzSHCI"></a><br>
</p>

**AzSHCI** is a collection of PowerShell scripts to deploy, configure and manage **Azure Local** (formerly Azure Stack HCI) in testing, lab and proof-of-concept environments running on a single Hyper-V host.

For a detailed walkthrough, visit: https://schmitt-nieto.com/blog/azure-local-demolab/

---

## Repository Structure

```plaintext
AzSHCI/
├── .github/
│   └── workflows/
│       └── copy-to-blog.yml           # Syncs repo to blog on push to main
├── scripts/
│   ├── 01Lab/
│   │   ├── 00_AzurePreRequisites.ps1  # Azure subscription prep + SPN/RBAC setup
│   │   ├── 00_Infra_AzHCI.ps1         # Host networking + VM provisioning
│   │   ├── 01_DC.ps1                  # Domain Controller configuration
│   │   ├── 02_Cluster.ps1             # Cluster node setup + Arc registration
│   │   ├── 03_TroubleshootingExtensions.ps1  # Arc extension pre-staging (required for Terraform deployment)
│   │   ├── 99_Offboarding.ps1         # Full lab teardown
│   │   └── Old version/              # Archived (reference only)
│   │       └── 02_Cluster.ps1
│   ├── 02Day2/
│   │   ├── 10_StartStopAzSHCI.ps1     # Ordered start/stop of the lab
│   │   ├── 11_ImageBuilderAzSHCI.ps1  # Azure Marketplace image downloader
│   │   ├── 11_ImageBuilderAL.ps1      # Optimized image downloader variant
│   │   ├── 12_AKSArcServiceToken.ps1  # AKS Arc kubeconfig + service token
│   │   ├── 13_VHDXOptimization.ps1    # VHDX compaction helper
│   │   └── OldImageBuilder/          # Archived (reference only)
│   │       ├── 11_AzSHCIImageBuilder_v1.ps1
│   │       ├── 11_AzSHCIImageBuilder_v2.ps1
│   │       ├── 11_AzSHCIImageBuilder_v3.ps1
│   │       ├── 11_AzSHCIImageBuilder_v4.ps1
│   │       ├── 11_AzSHCIImageBuilder_v5.ps1
│   │       ├── 11_ImageBuilderAzSHCI_v6.ps1
│   │       └── 11_ImageBuilderAzSHCI_v7.ps1
│   └── 03VMDeployment/
│       └── 20_SSHRDPArcVM.ps1         # SSH/RDP to Arc-managed VMs
├── terraform/
│   ├── providers.tf                   # Terraform and provider version constraints
│   ├── main.tf                        # AVM module call
│   ├── variables.tf                   # Input variable definitions
│   ├── outputs.tf                     # Key resource ID outputs
│   └── terraform.tfvars.example       # Example variable values for this lab
├── .gitignore
├── lastdeployment.json
├── README.md
└── LICENSE
```

Each folder under `scripts/` covers a distinct lifecycle phase:

- **01Lab**: Initial infrastructure build, networking, VM creation, domain promotion, Arc registration and full teardown.
- **02Day2**: Ongoing operations, lab start/stop, image management, AKS Arc access, disk optimization.
- **03VMDeployment**: Remote access to workload VMs running on top of the Azure Local cluster.

The `terraform/` folder provides an Infrastructure-as-Code alternative to the manual portal deployment step. It uses the [Azure Verified Module for Azure Local](https://github.com/Azure/terraform-azurerm-avm-res-azurestackhci-cluster) to deploy the cluster after the node has been registered with Arc by `02_Cluster.ps1`.

---

## Default Lab Configuration

These scripts are opinionated and ship with hardcoded defaults. **Review and adjust every variable section before running.** The table below summarises the most critical defaults.

| Setting | Default value |
|---|---|
| Lab root folder | `E:\AzureLocalLab` (subfolders `VM\` and `Disk\`) |
| HCI Node ISO | `E:\ISO\AzureLocal24H2.iso` |
| Domain Controller ISO | `E:\ISO\WS2025.iso` |
| vSwitch / NAT name | `azurelocal` |
| Lab subnet | `172.19.18.0/24` |
| NAT gateway (host) | `172.19.18.1` |
| **HCI Node VM** name | `AZLN01` |
| HCI Node RAM / vCPUs | 96 GB / 32 |
| HCI Node disks | 127 GB OS + 2 × 1 TB S2D (all VHDX, thin provisioned) |
| HCI Node NICs | `MGMT1`, `MGMT2` |
| HCI Node IP | `172.19.18.10` |
| **Domain Controller VM** name | `DC` |
| DC RAM / vCPUs | 4 GB / 4 |
| DC disk | 60 GB OS |
| DC NIC | `MGMT1` |
| DC IP | `172.19.18.2` |
| AD domain | `azurelocal.local` (NetBIOS: `AZURELOCAL`) |
| LCM / setup user | `hciadmin` |
| DNS forwarder | `8.8.8.8` |
| Time zone (DC) | `W. Europe Standard Time` |
| Azure region | `westeurope` |

> **Important**: If your machine does not have an `E:` drive, change the path variables in `00_Infra_AzHCI.ps1` and `99_Offboarding.ps1` before running anything.

---

## Script Reference

### 01Lab, Initial Lab Deployment

#### 1. `00_Infra_AzHCI.ps1`, Infrastructure and VM provisioning

Runs entirely on the Hyper-V host. Performs these steps in order:

1. **Prerequisite checks**, verifies TPM is present and enabled; installs Hyper-V if missing (requires reboot).
2. **Virtual switch + NAT**, creates an internal vSwitch named `azurelocal`, assigns IP `172.19.18.1` to the host interface, creates the NAT object and adds an inbound ICMPv4 firewall rule so VMs can ping the gateway.
3. **Folder structure**, creates `E:\AzureLocalLab\VM\` and `E:\AzureLocalLab\Disk\`.
4. **HCI Node VM (`AZLN01`)**, creates VHDX files (127 GB OS + 2 × 1 TB S2D), creates a Gen 2 VM with 96 GB static RAM, 32 vCPUs, two NICs (`MGMT1`, `MGMT2`) with MAC spoofing enabled, attaches a vTPM via HgsGuardian + Key Protector, enables nested virtualization, mounts the Azure Local ISO and sets DVD as first boot device.
5. **Domain Controller VM (`DC`)**, same process with 4 GB RAM, 4 vCPUs, one NIC (`MGMT1`) and the Windows Server 2025 ISO.

Both VMs have time synchronisation disabled and automatic stop action set to `ShutDown`.

Key variables to adjust: `$HCIRootFolder`, `$isoPath_HCI`, `$isoPath_DC`, all memory/CPU/disk values.

---

#### 2. `01_DC.ps1`, Domain Controller configuration

> **Before running this script**: start the `DC` VM, complete the Windows Server 2025 manual installation and reach the desktop. The initial local administrator username and password must match the values set in the `$defaultUser` and `$defaultPwd` variables at the top of the script. Adjust those variables if you used different credentials during OS setup.

Runs against the `DC` VM over Hyper-V PowerShell Direct. Steps:

1. Removes the mounted ISO.
2. Retrieves the MAC address of `MGMT1`, renames the VM's computer account to `DC` and restarts.
3. Configures a static IP: `172.19.18.2/24`, gateway `172.19.18.1`, DNS pointing to itself.
4. Sets the time zone (`W. Europe Standard Time`).
5. Installs RSAT tools for Failover Clustering and Hyper-V, then promotes to a new AD DS forest (`azurelocal.local`).
6. Waits for AD services, then:
   - Configures DNS forwarder to `8.8.8.8`.
   - Syncs time from `europe.pool.ntp.org`.
   - Enables RDP with NLA.
   - Installs Windows Updates via `PSWindowsUpdate`.
7. Creates a full AD OU structure under `_LAB`:
   - `Users` → Administrative, Technical, Financial, Workers
   - `Servers` → Windows, Linux, HCI
   - `Groups` → Security, Distribution
   - `Computers` → Desktops, Laptops, AVD
8. Installs `AsHciADArtifactsPreCreationTool` from PSGallery and runs `New-HciAdObjectsPreCreation` to pre-create the AD objects required by Azure Local LCM, placing them in `OU=HCI,OU=Servers,OU=_LAB`.

Key variables to adjust: `$defaultPwd`, `$setupUser`, `$setupPwd`, `$timeZone`, `$dnsForwarder`.

---

#### 3. `02_Cluster.ps1`, Cluster node setup and Arc registration

> **Before running this script**: start the `AZLN01` VM, complete the Azure Local manual installation and reach the desktop. The initial local administrator username and password must match the values set in the `$defaultUser` and `$defaultPwd` variables at the top of the script. Adjust those variables if you used different credentials during OS setup.

The script prompts for an execution mode at startup:

| Mode | When to use |
|---|---|
| **1 — Full setup** | First run: ISO removal, user creation, NIC configuration and Arc registration. |
| **2 — Arc only** | Retry the Arc registration step after a failed full setup without repeating node configuration. |

Runs against the `AZLN01` VM over Hyper-V PowerShell Direct. Full setup steps:

1. Removes the mounted ISO.
2. Creates a local administrator account (`Setupuser`), renames the VM to `AZLN01` and restarts.
3. Retrieves MAC addresses for both NICs, then configures:
   - `MGMT1`: static IP `172.19.18.10/24`, gateway `172.19.18.1`, DNS `172.19.18.2`, RDMA enabled.
   - `MGMT2`: DHCP disabled, RDMA enabled.
   - Time zone set to UTC; time synced from the DC.
4. Optionally triggers the `ImageCustomizationScheduledTask` if present (Azure Local OEM image).
5. Calls `Invoke-AzStackHciArcInitialization` on the node. If `$SPNAppId` and `$SPNSecret` are set, the script authenticates via SPN, obtains an ARM access token with `Get-AzAccessToken`, and passes it to `Invoke-AzStackHciArcInitialization` using `-AccountId` and `-ArmAccessToken` (the cmdlet does not use the current Az session). Otherwise the node falls back to an interactive device code login. A retry loop handles the transient `BootstrapOobeService` connection error (up to `$ArcRetryCount` attempts, `$SleepBootstrap` seconds apart).

**You must update these variables before running:**

```powershell
$SubscriptionID    = "000000-00000-000000-00000-0000000"
$resourceGroupName = "rg-azlocal-lab"
$TenantID          = "000000-00000-000000-00000-0000000"
$Location          = "westeurope"   # Azure region
$Cloud             = "AzureCloud"
```

**Optional — SPN authentication** (recommended; avoids an interactive device code prompt on the node):

```powershell
$SPNAppId  = "application-client-id-from-00_AzurePreRequisites"
$SPNSecret = "client-secret-from-00_AzurePreRequisites"
```

Leave both empty to fall back to device code login.

---

#### 4. `03_TroubleshootingExtensions.ps1`, Arc extension pre-staging

> **Required before Terraform deployment.** When deploying via the Azure portal wizard, the three mandatory Arc extensions are installed automatically during the cluster creation flow. Terraform does not handle this step — the extensions must be present on the node **before** `terraform apply` is run or the `validatedeploymentsetting` step will fail with `ValidationFailed: Could not find any edge device... Please verify that the Device Management Extension is successfully installed`.

> When deploying through the portal wizard only, this script is not needed.

It is an interactive tool that connects to Azure, retrieves Arc-connected machines with `CloudMetadataProvider = "AzSHCI"`, removes locks on failed extensions, reinstalls them and adds any missing ones from the required set (`TelemetryAndDiagnostics`, `DeviceManagementExtension`, `LcmController` and `EdgeRemoteSupport`).

---

#### 5. `99_Offboarding.ps1`, Lab teardown

**Destructive, review before running.** Removes the entire lab in order:

1. Stops and removes `AZLN01` (deletes all `AZLN01*.vhdx` files and its HgsGuardian).
2. Stops and removes `DC` (deletes all `DC*.vhdx` files and its HgsGuardian).
3. Removes the NAT object `azurelocal`.
4. Removes all IP addresses from the `vEthernet (azurelocal)` interface.
5. Removes the vSwitch `azurelocal`.
6. Deletes the entire folder tree at `E:\AzureLocalLab`.

---

### 02Day2, Day-Two Operations

#### 1. `10_StartStopAzSHCI.ps1`, Ordered lab start/stop

Prompts for `start` or `stop` at runtime.

**Stop sequence** (safe cluster shutdown):
1. Connects to `AZLN01` and runs `Stop-Cluster -Force`.
2. Shuts down `AZLN01`.
3. Shuts down `DC`.

**Start sequence**:
1. Starts `DC` and waits 120 seconds for AD/DNS services.
2. Starts `AZLN01` and waits 60 seconds.
3. Connects to `AZLN01` and runs `Start-Cluster` followed by `Sync-AzureStackHCI`.

Sleep timers can be skipped by pressing Spacebar.

Key variables to adjust: `$netBIOSName`, `$hcipassword`, `$dcPassword`, `$SleepDCStart`, `$SleepNodeStart`.

---

#### 2. `11_ImageBuilderAzSHCI.ps1` and `11_ImageBuilderAL.ps1`, Azure Marketplace image downloader

Both scripts automate pulling VM images from Azure Marketplace into the Azure Local cluster storage. `11_ImageBuilderAL.ps1` is the optimized variant. Both share the same core workflow:

1. Install required PowerShell modules (`Az.Accounts`, `Az.Compute`, `Az.Resources`, `Az.CustomLocation`).
2. Connect to Azure (device code, with retry).
3. Select Subscription and Resource Group via `Out-GridView`.
4. Enumerate image SKUs from a predefined list of publishers (MicrosoftWindowsServer, microsoftwindowsdesktop, Canonical, RedHat, Oracle, SuSE and others).
5. Present a multi-select `Out-GridView` to choose images.
6. For each selected image:
   - Creates a temporary managed disk from the Marketplace image.
   - Grants SAS access (1 hour).
   - Downloads the VHD to `C:\ClusterStorage\<LibraryVolumeName>\Images\` on the node using AzCopy (auto-installed if missing).
   - Revokes SAS and deletes the temporary disk.
   - Converts VHD → VHDX (dynamic) and runs `Optimize-VHD -Mode Full` on the node.
7. Prints the VHDX paths so you can register them as Custom Local Images from the Azure portal.

Key variables to adjust: `$region`, `$nodeName`, `$LibraryVolumeName`, `$netBIOSName`, `$hcipassword`.

> **Note**: `$nodeName` defaults to `"NODE"` in these scripts; change it to `"AZLN01"` (or your actual node name) if using in this lab.

---

#### 3. `12_AKSArcServiceToken.ps1`, AKS Arc kubeconfig and service token

A fully parameterised script for obtaining programmatic access to an AKS Arc (connectedClusters) cluster.

> **Network requirement**: the machine running this script needs direct network connectivity to the AKS Arc Control Plane endpoint. Ensure that the host can reach the cluster API server before running.

**Key capabilities:**
- Validates and optionally installs Azure CLI (`az`) and `kubectl` via `winget`.
- Manages the `aksarc` az extension (install or update, with prompt).
- Supports interactive and fully automated modes via parameters.
- Interactive or device-code Azure login; supports `-ForceAzReauth` to clear cached credentials.
- Interactive selection of Subscription, Resource Group and Cluster (or pass them as parameters).
- Creates a Kubernetes service account with `cluster-admin` ClusterRoleBinding.
- Retrieves a token via the TokenRequest API, with fallback to a secret-based token.
- Writes kubeconfig to `$env:USERPROFILE\.kube\AzSHCI\aks-arc-kube-config` and the token to `<user>-<namespace>-token.txt`.

**Usage examples:**

```powershell
# Fully interactive
.\12_AKSArcServiceToken.ps1

# Automated
.\12_AKSArcServiceToken.ps1 `
    -SubscriptionName "MySubscription" `
    -ResourceGroupName "MyRG" `
    -ClusterName "my-aks-arc" `
    -AdminUser "my-admin"

# Force re-authentication and skip extension updates
.\12_AKSArcServiceToken.ps1 -ForceAzReauth -SkipAzExtensionUpdate
```

---

#### 4. `13_VHDXOptimization.ps1`, VHDX compaction

Provides a `Compress-Vhdx` helper function that discovers and compacts VHDX files using `Optimize-VHD -Mode Full`. Reports initial size, final size and space saved for each file.

```powershell
# Load and run the example (compacts all VHDXs under E:\AzureLocalLab recursively)
.\13_VHDXOptimization.ps1

# Or dot-source and call directly
. .\13_VHDXOptimization.ps1
Compress-Vhdx -Path "E:\AzureLocalLab" -IncludeSubfolders -Verbose
```

> VMs must be shut down (VHDs not in use) for `Optimize-VHD` to work.

---

### 03VMDeployment, VM Access

#### 1. `20_SSHRDPArcVM.ps1`, SSH/RDP to Arc VMs

Automates SSH or RDP-over-SSH connectivity to workload VMs managed by Azure Arc (not Azure Local nodes themselves, those are filtered out).

Steps:

1. Installs `Az.Compute` and `Az.ConnectedMachine` PowerShell modules if missing.
2. Checks for Azure CLI; downloads and installs via MSI if absent. Installs the `ssh` az extension if missing.
3. Connects to Azure via device code authentication.
4. Interactive selection of Subscription and Resource Group.
5. Retrieves Arc-connected machines (excludes nodes with `CloudMetadataProvider = "AzSHCI"`).
6. Prompts to select a VM.
7. Checks for the `WindowsOpenSSH` extension; installs it if missing.
8. Opens the connection via `az ssh arc --rdp`.

Key variable to adjust: `$LocalUser` (the local user account on the target VM; defaults to `"vmadmin"`).

---

## Terraform Deployment

> **Work in progress — not yet validated end-to-end.**
> The Terraform path is still being tested and consolidated. No blog article will be published until a fully stable version is confirmed. Use the Azure portal wizard as the primary deployment method until further notice.

The `terraform/` folder contains an Infrastructure-as-Code deployment for the Azure Local cluster using the [Azure Verified Module (AVM)](https://github.com/Azure/terraform-azurerm-avm-res-azurestackhci-cluster). It is a direct alternative to clicking through the Azure portal after Arc registration completes.

### Pre-requisites before running Terraform

The Azure portal wizard installs the mandatory Arc extensions automatically during the deployment wizard flow. When deploying via Terraform those extensions must be present on the node **before** `terraform apply` is run. The three required extensions are:

- `TelemetryAndDiagnostics`
- `DeviceManagementExtension`
- `LcmController`

Run `scripts/01Lab/03_TroubleshootingExtensions.ps1` against the Arc-registered node to install them. Terraform will fail at the `validatedeploymentsetting` step with a `ValidationFailed` error if any of these extensions are missing.

### What it creates

Terraform creates the following resources directly (before the AVM module runs):

- **Key Vault** — stores deployment secrets and certificates. Created with `purge_protection_enabled = false` so it can be destroyed and recreated with the same name without a 90-day wait.
- **Cloud witness storage account** — used by the cluster as a cloud witness for quorum.

The AVM module then creates and wires together:

- Azure Local cluster resource (`Microsoft.AzureStackHCI/clusters`)
- Arc settings and Arc extensions
- Custom location and resource bridge

### Prerequisites for Terraform

| Requirement | Notes |
|---|---|
| Terraform | >= 1.9, < 2.0 |
| Azure provider | `hashicorp/azurerm ~> 4.0` |
| Azure API provider | `azure/azapi ~> 2.4` |
| Azure AD provider | `hashicorp/azuread ~> 2.50` |
| Node Arc-registered | `02_Cluster.ps1` must have completed successfully |
| SPN with required RBAC | Created by `00_AzurePreRequisites.ps1` |

### Files

| File | Purpose |
|---|---|
| `providers.tf` | Terraform version constraint and provider configuration |
| `main.tf` | Key Vault, storage account and AVM module call with annotated parameters |
| `variables.tf` | All input variable definitions with descriptions and defaults |
| `outputs.tf` | Exports cluster ID, Key Vault ID and URI, custom location ID and witness storage account ID |
| `terraform.tfvars.example` | Ready-to-use example pre-filled with the lab defaults |

### Configuration

Copy `terraform.tfvars.example` to `terraform.tfvars` and set every value marked `TODO`:

```hcl
subscription_id                = "your-subscription-id"
service_principal_id           = "appid-from-00_AzurePreRequisites-output"
service_principal_secret       = "secret-from-00_AzurePreRequisites-output"
rp_service_principal_object_id = "object-id-of-azurestackhci-rp-spn"
```

To retrieve the resource provider SPN object ID (run once per subscription):

```powershell
(Get-AzADServicePrincipal -ApplicationId "1412d89f-b8a8-4111-b4fd-e82905cbd85d").Id
```

All other values default to the lab configuration (subnet `172.19.18.0/24`, node `AZLN01` at `172.19.18.10`, domain `azurelocal.local`, OU `OU=HCI,OU=Servers,OU=_LAB,...`). Adjust them only if you changed the corresponding variables in the PowerShell scripts.

### Authentication

Terraform requires an active Azure session before running `plan` or `apply`. Three options are available.

**Option A — Azure CLI interactive (recommended for first-time use)**

```powershell
az login --tenant <your-tenant-id>
az account set --subscription <your-subscription-id>
```

Terraform picks up the CLI session automatically. No extra provider configuration is needed.

**Option B — Azure CLI with Service Principal (non-interactive)**

Use the SPN created by `scripts/01Lab/00_AzurePreRequisites.ps1`:

```powershell
az login --service-principal `
  --username <appid-from-00_AzurePreRequisites-output> `
  --password <secret-from-00_AzurePreRequisites-output> `
  --tenant   <your-tenant-id>
az account set --subscription <your-subscription-id>
```

Terraform uses the resulting CLI session — no changes to `providers.tf` are needed.

**Option C — Environment variables (CI/CD or fully scripted runs)**

```powershell
$env:ARM_CLIENT_ID       = "appid-from-00_AzurePreRequisites-output"
$env:ARM_CLIENT_SECRET   = "secret-from-00_AzurePreRequisites-output"
$env:ARM_TENANT_ID       = "your-tenant-id"
$env:ARM_SUBSCRIPTION_ID = "your-subscription-id"
```

Terraform reads the `ARM_*` environment variables automatically — no changes to `providers.tf` are needed.

---

### Two-stage deployment

The Azure Local deployment runs in two stages controlled by the `is_exported` variable.

**Stage 1 — Validate** (`is_exported = false`, the default)

```powershell
cd terraform

terraform init
terraform plan   # review what will be created before committing
terraform apply
```

Terraform creates the Key Vault and storage account, then submits the deployment configuration for validation. The node is checked for readiness and any configuration errors are surfaced (~10 minutes). Review the result in the Azure portal before proceeding.

**Stage 2 — Deploy** (`is_exported = true`)

After a successful validation, change `is_exported` in `terraform.tfvars`:

```hcl
is_exported = true
```

Then plan and apply again:

```powershell
terraform plan   # confirm only the deployment mode changes
terraform apply
```

This triggers the full cluster provisioning (~30-60 minutes). Monitor progress in the Azure portal under the resource group.

### RDMA

`rdma_enabled` is set to `false` for this single-node lab. There is no cross-node storage traffic (switchless storage) and the NICs (`MGMT1`, `MGMT2`) are virtual adapters in a nested Hyper-V VM that do not support hardware RDMA. Setting this to `false` disables RDMA in all three network intents (management, compute and storage).

### Security notes

- `terraform.tfvars` is listed in `.gitignore`. Never commit the populated file.
- BitLocker is disabled by default (`bitlocker_boot_volume = false`, `bitlocker_data_volumes = false`) because the lab uses thin-provisioned VHDX disks in a nested VM without a hardware TPM chain.
- The default lab credentials (`dgemsc#utquMHDHp3M`) in the example file are intentional lab defaults. Replace them before running.
- On `terraform destroy`, the provider purges the Key Vault immediately (`purge_soft_delete_on_destroy = true`) so the same name can be reused on the next deployment.
- `resource_provider_registrations = "none"` is set in `providers.tf`. Terraform's azurerm provider would otherwise attempt to auto-register dozens of unrelated providers (ContainerInstance, Databricks, EventGrid...) at subscription scope, requiring `*/register/action` permission. All providers needed for Azure Local are already registered by `00_AzurePreRequisites.ps1`, so this is both safe and avoids over-privileging the SPN.

---

## Prerequisites

### Hardware

| Requirement | Notes |
|---|---|
| TPM 2.0 | Required for vTPM / Key Protector on VMs |
| Hyper-V capable CPU | Nested virtualisation required for the HCI node |
| RAM | 32 GB minimum (the lab works with less, though performance will be limited); 96 GB+ recommended for a comfortable experience |
| Disk | All VM disks are thin-provisioned VHDX files so the real footprint is much smaller than the declared sizes. BitLocker is not required or used in this lab. A host with ~500 GB of free disk space is sufficient for the full deployment, plus space for the ISOs. |

### Software

| Requirement | Notes |
|---|---|
| Windows with Hyper-V | Windows 11 Pro/Enterprise or Windows Server with Hyper-V role |
| PowerShell 5.1 | Recommended; all scripts target Windows PowerShell |
| Azure subscription | Required for Arc registration and all Day-2 scripts |
| Azure Local ISO | Default: `E:\ISO\AzureLocal24H2.iso` |
| Windows Server 2025 ISO | Default: `E:\ISO\WS2025.iso` |

### Optional / script-specific dependencies

| Dependency | Required by |
|---|---|
| `Az.Accounts`, `Az.Compute`, `Az.Resources`, `Az.CustomLocation` | Image builder scripts |
| `Az.Compute`, `Az.StackHCI`, `Az.ConnectedMachine` | `03_TroubleshootingExtensions.ps1` |
| `Az.Compute`, `Az.ConnectedMachine` | `20_SSHRDPArcVM.ps1` |
| Azure CLI (`az`) + `aksarc` extension | `12_AKSArcServiceToken.ps1` |
| Azure CLI (`az`) + `ssh` extension | `20_SSHRDPArcVM.ps1` |
| `kubectl` | `12_AKSArcServiceToken.ps1` |
| `winget` | Optional, used by `12_AKSArcServiceToken.ps1` to install CLI tools interactively |
| AzCopy | Downloaded automatically to `C:\AzCopy\` on the node by the image builder scripts |
| `PSWindowsUpdate` module | `01_DC.ps1` (installed at runtime) |
| `AsHciADArtifactsPreCreationTool` module | `01_DC.ps1` (installed at runtime) |

---

## Usage

### 1. Clone the repository

```plaintext
git clone https://github.com/schmittnieto/AzSHCI.git
cd AzSHCI
```

### 2. Set the execution policy (if needed)

```powershell
Set-ExecutionPolicy RemoteSigned -Scope CurrentUser
```

### 3. Review and customise variables

At minimum, open and adjust:

- `scripts/01Lab/00_Infra_AzHCI.ps1`, paths, ISO locations, VM sizing
- `scripts/01Lab/01_DC.ps1`, passwords, time zone, DNS forwarder
- `scripts/01Lab/02_Cluster.ps1`, `$SubscriptionID`, `$TenantID`, `$resourceGroupName`, `$Location`

### 4. Run the lab deployment scripts in order

```powershell
# Step 1, provision host networking and VMs
.\scripts\01Lab\00_Infra_AzHCI.ps1

# Step 2, configure and promote the Domain Controller
#   Start the DC VM manually first, wait for Windows Setup to finish, then run:
.\scripts\01Lab\01_DC.ps1

# Step 3, configure the cluster node and register with Azure Arc
#   Start the AZLN01 VM manually first, wait for Windows Setup to finish, then run:
.\scripts\01Lab\02_Cluster.ps1

# Required ONLY if deploying with Terraform (not needed for portal wizard deployments)
# Run this BEFORE terraform apply to pre-stage the mandatory Arc extensions on AZLN01
# .\scripts\01Lab\03_TroubleshootingExtensions.ps1
```

> After `02_Cluster.ps1` completes the Arc registration, deploy the cluster from the Azure portal or use the Terraform configuration described in the next step.

### 4b. Deploy the cluster with Terraform (optional alternative to the portal)

```powershell
cd terraform

# Copy the example file and fill in every TODO value
Copy-Item terraform.tfvars.example terraform.tfvars
notepad terraform.tfvars

# Initialise providers and module
terraform init

# Stage 1: validate (is_exported = false, the default)
terraform apply
# Review the validation result in the Azure portal, then set is_exported = true

# Stage 2: deploy (is_exported = true)
terraform apply
```

See the [Terraform Deployment](#terraform-deployment) section below for full details.

### 5. Day-2 operations

```powershell
# Start or stop the full lab in the correct order
.\scripts\02Day2\10_StartStopAzSHCI.ps1

# Download and import Azure Marketplace images
.\scripts\02Day2\11_ImageBuilderAzSHCI.ps1
# or the optimized variant
.\scripts\02Day2\11_ImageBuilderAL.ps1

# Generate AKS Arc kubeconfig and service token
.\scripts\02Day2\12_AKSArcServiceToken.ps1

# Compact VHDX files on the host
.\scripts\02Day2\13_VHDXOptimization.ps1
```

### 6. VM access

```powershell
# SSH or RDP to an Arc-managed workload VM
.\scripts\03VMDeployment\20_SSHRDPArcVM.ps1
```

### 7. Teardown

```powershell
# Remove all lab VMs, networking and files, IRREVERSIBLE
.\scripts\01Lab\99_Offboarding.ps1
```

---

## CI/CD: GitHub Actions

`.github/workflows/copy-to-blog.yml` runs on every push to `main`. It checks out both this repository and `schmittnieto/schmittnieto.github.io`, then rsync-copies the repo contents to `/assets/repo/AzSHCI/` in the blog repository and pushes the result. It also purges Camo image caches. Requires a `GH_PAT` repository secret with write access to the blog repo.

---

## Safety and Security Notes

- **Hardcoded credentials**: the default passwords (`Start#1234`, `dgemsc#utquMHDHp3M`) are intentional lab defaults. Change them before running and never commit real credentials.
- **Host-level changes**: the scripts create a Hyper-V vSwitch, a NAT object and firewall rules on the host. Verify the `172.19.18.0/24` subnet does not conflict with your environment.
- **Offboarding is destructive**: `99_Offboarding.ps1` deletes VMs, VHDs, network objects and the entire lab folder without further prompting. Review the script and the variables before executing.
- **Azure costs**: managed disks are created temporarily during image download and deleted immediately after. Verify no orphaned disks remain in your resource group if a script is interrupted.

---

## Roadmap

- Additional end-to-end automation scenarios (AVD on Azure Local, AKS Arc lifecycle).
- Multi-node lab variant (two HCI nodes).
- Automated post-deployment validation checks.

---

## Contributing

Contributions are welcome:

- Fork the repository and open a pull request.
- Use GitHub Issues for bugs and feature requests: https://github.com/schmittnieto/AzSHCI/issues

---

## License

This project is licensed under the [MIT License](LICENSE).

---

## Contact

- **Author**: Cristian Schmitt Nieto
- **Blog**: https://schmitt-nieto.com/blog/azure-local-demolab/
- **Issues**: https://github.com/schmittnieto/AzSHCI/issues