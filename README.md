# AzSHCI - Azure Local Deployment Scripts

<p align="center">
  <a href="https://github.com/schmittnieto/AzSHCI"><img src="https://badgen.net/https/raw.githubusercontent.com/schmittnieto/AzSHCI/refs/heads/main/lastdeployment.json?cache=300"></a><br>
  <a href="https://github.com/schmittnieto/AzSHCI"><img src="https://img.shields.io/github/languages/top/schmittnieto/AzSHCI.svg"></a>
  <a href="https://github.com/schmittnieto/AzSHCI"><img src="https://img.shields.io/github/languages/code-size/schmittnieto/AzSHCI.svg"></a>
  <a href="https://github.com/schmittnieto/AzSHCI"><img src="https://img.shields.io/github/v/release/schmittnieto/AzSHCI"></a><br>
</p>

Welcome to **AzSHCI** a set of PowerShell scripts to deploy, configure and manage **Azure Local** for testing, lab or proof-of-concept scenarios.

For a deeper walkthrough and best practices, see: https://schmitt-nieto.com/blog/azure-local-demolab/

---

## Repository Structure

```plaintext
AzSHCI/
├── scripts/
│   ├── 01Lab/
│   │   ├── 00_Infra_AzHCI.ps1
│   │   ├── 01_DC.ps1
│   │   ├── 02_Cluster.ps1
│   │   ├── 03_TroubleshootingExtensions.ps1
│   │   ├── 99_Offboarding.ps1
│   │   └── Old version/              # Archived (reference only)
│   ├── 02Day2/
│   │   ├── 10_StartStopAzSHCI.ps1
│   │   ├── 11_ImageBuilderAzSHCI.ps1
│   │   ├── 11_ImageBuilderAL.ps1
│   │   ├── 12_AKSArcServiceToken.ps1
│   │   ├── 13_VHDXOptimization.ps1
│   │   └── OldImageBuilder/           # Archived (reference only)
│   └── 03VMDeployment/
│       └── 20_SSHRDPArcVM.ps1
├── README.md
└── LICENSE
```

Each folder under `scripts/` is dedicated to a lifecycle phase of your Azure Local environment:

- **01Lab**: Infrastructure setup, cluster creation, domain configuration, troubleshooting, and environment cleanup.
- **02Day2**: Day-two operations (start/stop routines, image import/build, image optimization, AKS Arc helpers).
- **03VMDeployment**: Scripts for VM access and Azure Arc interactions.

---

## Default Lab Assumptions (Important)

These scripts are opinionated. Before running anything, review and adjust the variables inside the scripts to match your environment.

Common defaults (as currently coded):

- **Host paths**: lab files under `E:\AzureLocalLab` and ISOs under `E:\ISO\...` (see `scripts/01Lab/00_Infra_AzHCI.ps1`).
- **Networking**: internal vSwitch + NAT named `azurelocal` with subnet `172.19.18.0/24` and gateway `.1`.
- **VM names**: Node VM `AZLN01`, Domain Controller VM `DC`.

If your machine does not have an `E:` drive (very common), you must change these values before running.

---

## Detailed Script Breakdown

### 01Lab

1. **00_Infra_AzHCI.ps1**
   - Provisions virtual switch + NAT, and creates folder structures.
   - Creates the Azure Local Node VM and the Domain Controller VM.
   - Configures VM security (vTPM/Key Protector) and data disks.

2. **01_DC.ps1**
   - Configures the Domain Controller VM: network settings, time zone, AD DS installation, DNS forwarders.
   - Creates foundational OUs and prepares AD for Azure Local.

3. **02_Cluster.ps1**
   - Configures the Node VM (rename, networking, required roles/features).
   - Registers the node with Azure Arc (uses `Invoke-AzStackHciArcInitialization`).

4. **03_TroubleshootingExtensions.ps1**
   - Helps manage Azure Connected Machine (Arc) extensions: remove failed extensions, reinstall required ones.

5. **99_Offboarding.ps1**
   - Removes VMs, vSwitch/NAT, and deletes the lab folder.

### 02Day2

1. **10_StartStopAzSHCI.ps1**
   - Starts/stops the whole lab in order (DC first on start; cluster service stop before node shutdown).

2. **11_ImageBuilderAzSHCI.ps1**
   - Downloads selected Azure marketplace images into Azure Local storage.
   - Uses AzCopy and converts VHD → VHDX.
   - Uses `Out-GridView` for interactive selection.

3. **11_ImageBuilderAL.ps1**
   - An alternative/optimized image builder workflow with similar goals.

4. **12_AKSArcServiceToken.ps1**
   - Fetches AKS Arc kubeconfig and creates a service account/token for programmatic access.
   - Can (optionally) install dependencies interactively (Azure CLI, kubectl) using `winget`.

5. **13_VHDXOptimization.ps1**
   - Contains a `Compress-Vhdx` helper to compact VHDX files using `Optimize-VHD`.
   - Includes an example invocation at the bottom of the script.

### 03VMDeployment

1. **20_SSHRDPArcVM.ps1**
   - Finds Azure Arc connected machines in a resource group.
   - Ensures the Azure CLI SSH extension is installed.
   - Establishes SSH connectivity (can be used for SSH-based RDP tunneling).

---

## Prerequisites

### Hardware

- **TPM**: required for VM-based security features (vTPM, Key Protector).
- **Hyper-V capable CPU**: required for nested virtualization.
- **Memory**: minimum 32 GB (64+ GB recommended; some defaults allocate more).
- **Disk**: sufficient space for multiple VHDX files + ISO storage.

### Software

- **Windows with Hyper-V** (Windows 11 / Windows Server with Hyper-V role installed).
- **PowerShell**: Windows PowerShell 5.1 is recommended.
- **Azure subscription**: required for Azure Arc registration and image workflows.
- **ISOs** (defaults in scripts; adjust paths as needed):
  - Windows Server 2025 ISO (for DC)
  - Azure Local ISO

### Optional dependencies (script-specific)

- `Out-GridView` (interactive pickers): required by image builder selection UI.
- Azure PowerShell modules: `Az.Accounts`, `Az.Compute`, `Az.Resources`, `Az.CustomLocation`, `Az.ConnectedMachine`.
- Azure CLI (`az`): required by `scripts/02Day2/12_AKSArcServiceToken.ps1` and `scripts/03VMDeployment/20_SSHRDPArcVM.ps1`.
- `kubectl`: required by `scripts/02Day2/12_AKSArcServiceToken.ps1`.
- `winget`: used to install dependencies interactively (where supported).
- AzCopy: downloaded/used by image builder scripts.

---

## Usage (Recommended: run from repo root)

1. **Clone the repository**
   ```plaintext
   git clone https://github.com/schmittnieto/AzSHCI.git
   cd AzSHCI
   ```

2. **Set the Execution Policy** (if needed)
   ```powershell
   Set-ExecutionPolicy RemoteSigned -Scope CurrentUser
   ```

3. **Review and edit variables before running**

   At minimum, check these files:

   - `scripts/01Lab/00_Infra_AzHCI.ps1` (paths, VM sizing, ISO locations, subnet)
   - `scripts/01Lab/01_DC.ps1` and `scripts/01Lab/02_Cluster.ps1` (credentials, subscription IDs, RG)

4. **Run lab deployment scripts (in order)**
   ```powershell
   .\scripts\01Lab\00_Infra_AzHCI.ps1
   .\scripts\01Lab\01_DC.ps1
   .\scripts\01Lab\02_Cluster.ps1
   .\scripts\01Lab\03_TroubleshootingExtensions.ps1  # optional
   ```

5. **Day-2 operations**

   - Start/stop the lab:
     ```powershell
     .\scripts\02Day2\10_StartStopAzSHCI.ps1
     ```

   - Build/import images:
     ```powershell
     .\scripts\02Day2\11_ImageBuilderAzSHCI.ps1
     # or
     .\scripts\02Day2\11_ImageBuilderAL.ps1
     ```

   - AKS Arc kubeconfig + service token:
     ```powershell
     .\scripts\02Day2\12_AKSArcServiceToken.ps1
     ```

   - VHDX compaction helper:
     ```powershell
     .\scripts\02Day2\13_VHDXOptimization.ps1
     ```

6. **VM access & Arc interactions**

   - SSH/RDP over SSH to Arc VMs:
     ```powershell
     .\scripts\03VMDeployment\20_SSHRDPArcVM.ps1
     ```

---

## Safety & Security Notes

- **Credentials**: several scripts include example/hardcoded usernames and passwords. Change them before running and never commit real secrets.
- **Host changes**: the lab setup creates a Hyper-V vSwitch + NAT and configures a fixed IP range (`172.19.18.0/24`). Ensure it does not conflict with your environment.
- **Offboarding is destructive**: `scripts/01Lab/99_Offboarding.ps1` removes VMs, NAT, vSwitch, and deletes the configured lab folder (default `E:\AzureLocalLab`). Review the script before executing.

---

## Roadmap

- Additional automation around Azure Local + Arc scenarios.
- More end-to-end templates (e.g., AVD-style patterns) as the repo evolves.

---

## Contributing

Contributions are welcome:

- Fork the repository and open pull requests.
- Use GitHub Issues for bugs/ideas: https://github.com/schmittnieto/AzSHCI/issues

---

## License

This project is licensed under the [MIT License](LICENSE).

---

## Contact & Further Information

- **Author**: Cristian Schmitt Nieto
- **Blog**: https://schmitt-nieto.com/blog/azure-local-demolab/
- **Issues**: https://github.com/schmittnieto/AzSHCI/issues
