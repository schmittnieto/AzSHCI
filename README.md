# AzSHCI - Azure Stack HCI Deployment Scripts

**For detailed instructions on how to execute these scripts, please visit: [schmitt-nieto.com/blog/azure-stack-hci-demolab/](https://schmitt-nieto.com/blog/azure-stack-hci-demolab/)**

Welcome to the **AzSHCI** repository! This collection of PowerShell scripts is designed to simplify and streamline the deployment of **Azure Stack HCI** in testing and lab environments. Whether you're an IT professional, system administrator, or cloud enthusiast, these scripts will help you set up a functional Azure Stack HCI environment quickly and efficiently, without the need for extensive physical infrastructure.

---

## Repository Structure

```
AzSHCI/
│
├── scripts/
│   └── 01Lab/
│       ├── 00_Infra_AzHCI.ps1
│       ├── 01_DC.ps1
│       ├── 02_Cluster.ps1
│       ├── 03_TroubleshootingExtensions.ps1
│       ├── 99_Offboarding.ps1
│
├── README.md
└── LICENSE
```

---

## Scripts Overview

### 01Lab

#### 00_Infra_AzHCI.ps1

**Configuration and VM Creation Script**

- **Purpose:** Sets up virtual networking, creates necessary folder structures, and deploys both the HCI node and Domain Controller VMs.
- **Features:**
  - Configures an internal virtual switch with NAT.
  - Creates directories for VM and disk storage.
  - Automates VM creation and initial configuration.

#### 01_DC.ps1

**Domain Controller Configuration Script**

- **Purpose:** Configures the Domain Controller VM, including network settings and Active Directory setup.
- **Features:**
  - Removes ISO media from the VM.
  - Renames the VM and sets static IP.
  - Sets the time zone and installs necessary Windows features.
  - Promotes the server to a Domain Controller.
  - Configures DNS forwarders and creates Organizational Units (OUs) in Active Directory.

#### 02_Cluster.ps1

**Cluster Node Configuration Script**

- **Purpose:** Configures the Azure Stack HCI node VM.
- **Features:**
  - Removes ISO media from the VM.
  - Creates a setup user and renames the VM.
  - Configures network adapters with static IPs and RDMA.
  - Installs essential Windows features like Hyper-V and Failover Clustering.
  - Registers the node with Azure Arc and integrates Azure services.

#### 03_TroubleshootingExtensions.ps1

**Troubleshooting Azure Connected Machine Extensions**

- **Purpose:** Manages Azure Connected Machine extensions for the HCI nodes.
- **Features:**
  - Installs required PowerShell modules (`Az.Compute` and `Az.StackHCI`) if not already installed.
  - Connects to Azure using device code authentication and allows you to select a subscription and resource group.
  - Retrieves Azure Arc VMs from Azure using `Az.StackHCI`, filtering for machines with `CloudMetadataProvider` set to "AzSHCI".
  - Validates that required Azure Connected Machine extensions are installed.
  - Fixes any failed extensions by removing locks, deleting, and reinstalling them.
  - Adds any missing extensions based on a predefined list.

#### 99_Offboarding.ps1

**Offboarding Script to Clean Up Configurations**

- **Purpose:** Cleans up the deployment by removing VMs, associated VHD files, virtual switches, NAT settings, and designated folder structures.
- **Features:**
  - Stops and removes specified VMs.
  - Deletes associated virtual hard disk (VHD) files.
  - Removes virtual switches and NAT configurations.
  - Cleans up folder structures.

---

## Usage

### Prerequisites

- **Hardware Requirements:**
  - A computer with a **TPM chip**.
  - A **processor** capable of running Hyper-V.
  - **Recommended RAM:** 64 GB or more.
  - **Minimum RAM for Basic Testing:** 32 GB.

- **Software Requirements:**
  - **Azure Subscription:** With the necessary permissions.
  - **ISO Files:**
    - **Windows Server 2025 Evaluation:** [Download Here](https://www.microsoft.com/en-us/evalcenter/evaluate-windows-server-2025)
    - **Azure Stack HCI OS:** Download directly from the Azure Portal.

- **Directory Setup:**
  - Store your ISO files in `C:\ISO`.

### Running the Scripts

1. **Clone the Repository:**

   ```
   git clone https://github.com/schmittnieto/AzSHCI.git
   ```

2. **Navigate to the Scripts Directory:**

   ```
   cd AzSHCI/scripts/01Lab
   ```

3. **Set Execution Policy:**

   Ensure that your PowerShell execution policy allows script execution.

   ```
   Set-ExecutionPolicy RemoteSigned -Scope CurrentUser
   ```

4. **Modify Script Variables:**

   Before executing the scripts, modify the variables in each script to match your environment and requirements. Specifically, add your local administrator credentials to the `$defaultUser` and `$defaultPwd` variables within the scripts.

5. **Run the Scripts in Order:**

   - **Initialize Infrastructure and Create VMs:**

     ```
     .\00_Infra_AzHCI.ps1
     ```

   - **Configure Domain Controller:**

     Before running `01_DC.ps1`, ensure the VM is powered on and Windows Server is installed (no need to install any roles). Add your local administrator credentials to the `$defaultUser` and `$defaultPwd` variables in the script. Then you can run the script:

     ```
     .\01_DC.ps1
     ```

     This process will take approximately 20 minutes as it installs Windows Updates, creates Organizational Units (OUs), and sets up the necessary administrator for the cluster as defined in the script variables.

   - **Configure Cluster Node:**

     After successfully running `01_DC.ps1`, proceed to install the cluster node. After the installation, update the `$defaultUser` and `$defaultPwd` variables in `02_Cluster.ps1` with your local administrator credentials. Then you can run the script:

     ```
     .\02_Cluster.ps1
     ```

     This script will prompt you to register the node with Azure upon completion, approximately 4-5 minutes into the execution.

   - **Troubleshoot Azure Connected Machine Extensions (if needed):**

     ```
     .\03_TroubleshootingExtensions.ps1
     ```

   - **Cleanup and Offboarding (if errors occur during the process):**

     ```
     .\99_Offboarding.ps1
     ```

---

## Cluster Registration

Once the cluster node script completes, follow these steps to register your cluster in Azure:

1. **Verify Extensions Installation:**
   - Ensure that the node's extensions have been installed successfully. If not, use the troubleshooting script.

2. **Assign Required Rights:**

   - **Subscription Level:**
     - If not an Owner or Contributor, assign the following roles to the user performing the registration:
       - Azure Stack HCI Administrator
       - Reader

   - **Resource Group Level:**
     - Assign the following roles to the user within the Resource Group where deployment will occur:
       - Key Vault Data Access Administrator
       - Key Vault Secrets Officer
       - Key Vault Contributor
       - Storage Account Contributor

   - **Microsoft Entra Roles and Administrators:**
     - Assign the following role to the user performing the deployment:
       - Cloud Application Administrator

   *In the near future, I plan to automate this process (granting granular rights to a user for deployment) using a script.*

3. **Initial Cluster Registration:**

   - Use the Azure Portal for initial cluster registration: [Azure Stack HCI Deployment via Portal](https://learn.microsoft.com/en-us/azure-stack/hci/deploy/deploy-via-portal)

   - **Network Configuration:**
     - Apply the recommended network settings to the interfaces. Deactivate RDMA and use 1514 Packet Size.
     - Personally, I use specific IP configurations as outlined in my scripts.

   - **Custom Location and User Configuration:**
     - Configure users and custom locations as defined in the scripts (credentials are exposed in the scripts).

   - **Security Options:**
     - It's crucial to disable BitLocker to prevent excessive storage consumption (totaling 2.1 TB), which could render your system inoperable if you lack sufficient capacity.

   - **Finalize Configuration:**
     - Leave the remaining settings at default. The system will be ready for provisioning after the validation, which takes approximately 20 minutes.

4. **Perform Cloud Deployment:**

   - Initiate the cloud deployment and wait approximately 2 hours for the cluster to be ready for subsequent steps.

---

## Future Enhancements

In future updates, additional scripts and functionalities are planned for:

- **Azure Kubernetes Service (AKS)**
- **Azure Virtual Desktop (AVD)**
- **Azure Arc Managed VMs**

In the coming weeks, I will add more tests and case studies, providing detailed articles to cover these topics comprehensively.

Stay tuned for these updates!

---

## Contributing

Contributions are welcome! If you have suggestions, improvements, or bug fixes, feel free to fork the repository and submit a pull request.

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## Contact

For any questions or issues, please open an [issue](https://github.com/schmittnieto/AzSHCI/issues) in the repository.

---

Thank you for using **AzSHCI**! I hope these scripts simplify your Azure Stack HCI deployment process and enable efficient testing and development in your environment.
