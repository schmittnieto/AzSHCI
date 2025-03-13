# AzSHCI - Azure Local Deployment Scripts

<p align="center">
  <a href="https://github.com/schmittnieto/AzSHCI"><img src="https://badgen.net/https/raw.githubusercontent.com/schmittnieto/AzSHCI/refs/heads/main/lastdeployment.json?"></a><br>
  <a href="https://github.com/schmittnieto/AzSHCI"><img src="https://img.shields.io/github/languages/top/schmittnieto/AzSHCI.svg"></a>
  <a href="https://github.com/schmittnieto/AzSHCI"><img src="https://img.shields.io/github/languages/code-size/schmittnieto/AzSHCI.svg"></a>
  <a href="https://github.com/schmittnieto/AzSHCI"><img src="https://img.shields.io/github/v/release/schmittnieto/AzSHCI"></a><br>
</p>

Welcome to **AzSHCI**, your comprehensive set of PowerShell scripts to deploy, configure and manage Azure Local for testing, lab, or proof-of-concept scenarios. This repository brings together multiple scripts, each with its own purpose and structure, allowing you to spin up a fully functioning Azure Stack HCI environment quickly.

For a deeper walk-through and best practices, check out the blog post: [schmitt-nieto.com/blog/azure-stack-hci-demolab/](https://schmitt-nieto.com/blog/azure-stack-hci-demolab/)

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
│   ├── 02Day2/
│   │   ├── 10_StartStopAzSHCI.ps1
│   │   ├── 11_ImageBuilderAzSHCI.ps1
│   └── 03VMDeployment/
│       ├── 20_SSHRDPArcVM.ps1
├── README.md
└── LICENSE
```

Each folder under `scripts/` is dedicated to a specific lifecycle phase of your Azure Stack HCI environment:

- **01Lab**: Infrastructure setup, cluster creation, domain configuration, and environment cleanup.
- **02Day2**: Day-two operations (e.g., start/stop routines, image import/build).
- **03VMDeployment**: Scripts related to deploying and managing VMs (including SSH connectivity and Azure Arc integration).

---

## Detailed Script Breakdown

### 01Lab

1. **00_Infra_AzHCI.ps1**  
   - Provisions virtual switches, NAT networking, and folder structures.  
   - Creates the Azure Stack HCI Node VM and the Domain Controller VM.  
   - Ensures TPM checks and Hyper-V prerequisites are met.

2. **01_DC.ps1**  
   - Configures the Domain Controller VM: network settings, time zone, Active Directory installation, and DNS setup.  
   - Creates foundational OUs and prepares AD for Azure Stack HCI.  

3. **02_Cluster.ps1**  
   - Renames and reconfigures the Node VM.  
   - Installs Windows features needed for clustering and Arc integration.  
   - Registers the node with Azure Arc for management.

4. **03_TroubleshootingExtensions.ps1**  
   - Manages Azure Connected Machine (Arc) extensions for your Azure Stack HCI environment.  
   - Removes failed extensions, reinstalls them, and ensures required extensions are present.

5. **99_Offboarding.ps1**  
   - Cleans up the entire lab environment by removing VMs, NAT settings, virtual switches, and associated folder structures.  

### 02Day2

1. **10_StartStopAzSHCI.ps1**  
   - A simple script to stop or start your entire Azure Stack HCI lab environment in an orderly sequence.  
   - Ensures the Domain Controller is turned on or off before the Node, and gracefully shuts down cluster services.

2. **11_ImageBuilderAzSHCI.ps1**  
   - Automates downloading official Azure VM images (Windows or Linux) and storing them in your Azure Stack HCI environment.  
   - Uses AzCopy for high-speed transfers, converts the retrieved VHD into VHDX, and optimizes it for deployment.  

### 03VMDeployment

1. **20_SSHRDPArcVM.ps1**  
   - Searches for Azure Arc-connected VMs in a specified resource group.  
   - Validates the presence of SSH extensions and, if necessary, installs them.  
   - Initiates an SSH connection to your Arc-enabled VMs, enabling RDP tunneling or direct SSH.

---

## Prerequisites

### Hardware

- **TPM Chip**: Required for VM-based security features (vTPM, Key Protector).
- **Hyper-V Capable Processor**: Essential for nested virtualization.
- **Minimum 32 GB RAM** (64 GB or more recommended for advanced scenarios).
- **Sufficient Disk Space** for VM data and ISO files.

### Software

- **Active Azure Subscription** to register the node(s) with Azure Arc and deploy HCI.  
- **Windows Server 2025 Evaluation ISO** (or later), placed in `C:\ISO\WS2025.iso`.
- **Azure Stack HCI OS ISO**, placed in `C:\ISO\HCI23H2.iso`.
- **PowerShell** running with administrative privileges and Execution Policy set to `RemoteSigned` or `Bypass`.

---

## Usage

1. **Clone the Repository**  
   ```plaintext
   git clone https://github.com/schmittnieto/AzSHCI.git
   ```

2. **Navigate to the Scripts Directory**  
   ```plaintext
   cd AzSHCI/scripts/01Lab
   ```

3. **Set the Execution Policy** (If needed)  
   ```powershell
   Set-ExecutionPolicy RemoteSigned -Scope CurrentUser
   ```

4. **Edit Script Variables**  
   - Update credentials: `$defaultUser`, `$defaultPwd` in each script if you use different local admin accounts.  
   - Place your ISO images in `C:\ISO\` or modify the paths in the scripts accordingly.

5. **Run the Scripts in Order**  
   ```powershell
   .\00_Infra_AzHCI.ps1      # Creates infrastructure, Node VM, DC VM
   .\01_DC.ps1               # Configures Domain Controller
   .\02_Cluster.ps1          # Sets up the cluster node & Arc registration
   .\03_TroubleshootingExtensions.ps1  # Optional troubleshooting
   # Use .\99_Offboarding.ps1 when you want to remove everything
   ```

### Day-2 Operations

- **Start/Stop**:  
  ```powershell
  .\scripts\02Day2\10_StartStopAzSHCI.ps1
  ```
  Ensures an orderly start or shutdown of your environment.

- **Image Building**:  
  ```powershell
  .\scripts\02Day2\11_ImageBuilderAzSHCI.ps1
  ```
  Pulls images from Azure, converts them, and stores them as VHDX for local deployment.

### VM Deployment & Arc Integration

- **SSH or RDP to Arc VMs**:  
  ```powershell
  .\scripts\03VMDeployment\20_SSHRDPArcVM.ps1
  ```
  Ensures the SSH extension is present on your Arc VMs and then establishes a secure connection.

---

## Advanced Features & Roadmap

- **Azure Kubernetes Service (AKS) on Azure Stack HCI**: Planned integration scripts for a hybrid K8s setup.
- **Azure Virtual Desktop (AVD)**: Future templates to deploy AVD in conjunction with Azure Stack HCI.  
- **Azure Arc Enhancements**: Extended support for policy, monitoring, and DevOps pipelines.

Stay tuned for additional automation scripts and integration points!

---

## Contributing

We welcome all contributors—your insights, bug fixes, and feature requests are invaluable. Feel free to:
- Fork the repository and make pull requests.
- Open [issues](https://github.com/schmittnieto/AzSHCI/issues) for suggestions or bugs.
- Contact us directly if you have specialized requirements or questions.

---

## License

This project is under the [MIT License](LICENSE). Refer to the license file for usage details.

---

## Contact & Further Information

- **Author**: Cristian Schmitt Nieto  
- **Blog**: [schmitt-nieto.com/blog/azure-stack-hci-demolab/](https://schmitt-nieto.com/blog/azure-stack-hci-demolab/)  
- **Issues**: [GitHub Issues](https://github.com/schmittnieto/AzSHCI/issues)

Thank you for using **AzSHCI**! We hope these scripts accelerate your Azure Stack HCI journey.
