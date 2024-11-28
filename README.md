# AzSHCI - Azure Stack HCI Deployment Scripts

<p align="center">
  <a href="https://github.com/schmittnieto/AzSHCI"><img src="https://img.shields.io/github/languages/top/schmittnieto/AzSHCI.svg"></a>
  <a href="https://github.com/schmittnieto/AzSHCI"><img src="https://img.shields.io/github/languages/code-size/schmittnieto/AzSHCI.svg"></a>
  <a href="https://github.com/schmittnieto/AzSHCI"><img src="https://img.shields.io/github/v/release/schmittnieto/AzSHCI"></a><br>
</p>

**For detailed instructions, visit: [schmitt-nieto.com/blog/azure-stack-hci-demolab/](https://schmitt-nieto.com/blog/azure-stack-hci-demolab/)**

Welcome to **AzSHCI**! This repository contains PowerShell scripts to help you deploy Azure Stack HCI in testing and lab environments quickly and efficiently.

---

## Repository Structure

´´´
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
´´´

---

## Scripts Overview

### 01Lab

- **00_Infra_AzHCI.ps1**: Sets up virtual networking, creates folder structures, and deploys HCI node and Domain Controller VMs. **Note:** Modify local credential parameters in the script.

- **01_DC.ps1**: Configures the Domain Controller VM, including network settings and Active Directory setup. **Note:** Modify local credential parameters in the script.

- **02_Cluster.ps1**: Configures the Azure Stack HCI node VM, installs necessary features, and registers the node with Azure Arc. **Note:** Modify local credential parameters in the script.

- **03_TroubleshootingExtensions.ps1**: Manages Azure Connected Machine extensions for HCI nodes.

- **99_Offboarding.ps1**: Cleans up the deployment by removing VMs, virtual switches, NAT settings, and folders.

### 02Day2

- **10_StartStopAzSHCI.ps1**: Starts or stops your Azure Stack HCI infrastructure by managing the DC and Cluster Node VMs in the correct order with progress indicators.

- **11_ImageBuilderAzSHCI.ps1**: Downloads selected VM images from Azure to Azure Stack HCI, converts them to VHDX format, and optimizes them. **Note:** Modify local credential parameters in the script.

### 03VMDeployment

- **20_SSHRDPArcVM.ps1**: Searches for Azure Arc VMs in a specified resource group, ensures the SSH extension is installed, and establishes an SSH connection.

---

## Usage

### Prerequisites

- **Hardware**:
  - TPM chip
  - Processor capable of running Hyper-V
  - **Recommended RAM**: 64 GB or more (32 GB minimum for basic testing)

- **Software**:
  - Azure Subscription with necessary permissions
  - **ISO Files** stored in `C:\ISO`:
    - Windows Server 2025 Evaluation
    - Azure Stack HCI OS

### Running the Scripts

1. **Clone the Repository**:

   ´´´
   git clone https://github.com/schmittnieto/AzSHCI.git
   ´´´

2. **Navigate to the Scripts Directory**:

   ´´´
   cd AzSHCI/scripts/01Lab
   ´´´

3. **Set Execution Policy**:

   ´´´
   Set-ExecutionPolicy RemoteSigned -Scope CurrentUser
   ´´´

4. **Modify Script Variables**:

   Update the local credential parameters (`$defaultUser` and `$defaultPwd`) in each script to match your environment.

5. **Run the Scripts in Order**:

   - **Initialize Infrastructure and Create VMs**:

     ´´´
     .\00_Infra_AzHCI.ps1
     ´´´

   - **Configure Domain Controller**:

     ´´´
     .\01_DC.ps1
     ´´´

   - **Configure Cluster Node**:

     ´´´
     .\02_Cluster.ps1
     ´´´

   - **Troubleshoot Extensions (if needed)**:

     ´´´
     .\03_TroubleshootingExtensions.ps1
     ´´´

   - **Cleanup and Offboarding (if needed)**:

     ´´´
     .\99_Offboarding.ps1
     ´´´

### Day 2 Operations

Navigate to `AzSHCI/scripts/02Day2` for the following scripts:

- **10_StartStopAzSHCI.ps1**: Start or stop your Azure Stack HCI infrastructure.

  ´´´
  .\10_StartStopAzSHCI.ps1
  ´´´

- **11_ImageBuilderAzSHCI.ps1**: Download and prepare VM images from Azure.

  ´´´
  .\11_ImageBuilderAzSHCI.ps1
  ´´´

  **Note:** Modify local credential parameters in the script.

### VM Deployment

Navigate to `AzSHCI/scripts/03VMDeployment`:

- **20_SSHRDPArcVM.ps1**: Connect to Azure Arc VMs via SSH.

  ´´´
  .\20_SSHRDPArcVM.ps1
  ´´´

---

## Future Enhancements

Planned additions:

- **Azure Kubernetes Service (AKS)**
- **Azure Virtual Desktop (AVD)**
- **Azure Arc Managed VMs**

Stay tuned for updates!

---

## Contributing

Contributions are welcome! Please fork the repository and submit a pull request.

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## Contact

For questions or issues, open an [issue](https://github.com/schmittnieto/AzSHCI/issues) in the repository.

---

Thank you for using **AzSHCI**! I hope these scripts simplify your Azure Stack HCI deployment process.

---
