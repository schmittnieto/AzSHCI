# 00_Infra_AzHCI.ps1
# Configuration and VM Creation Script

<#
.SYNOPSIS
    Configures virtual networking, creates necessary folder structures, and deploys HCI Node and Domain Controller VMs.

.DESCRIPTION
    This script performs the following tasks:
    - Checks for required prerequisites.
    - Configures an internal virtual switch with NAT.
    - Ensures the required folder structures exist.
    - Creates two virtual machines: an HCI Node and a Domain Controller.
    - Configures networking, storage, and security settings for the VMs.

.NOTES
    - Designed by Cristian Schmitt Nieto. For more information and usage, visit: https://schmitt-nieto.com
    - Run this script with administrative privileges.
    - Ensure the ISO paths are correct before execution.
    - Execution Policy may need to be set to allow the script to run. To set the execution policy, you can run:
      Set-ExecutionPolicy RemoteSigned -Scope CurrentUser
    - Approved PowerShell Verb Usage:
      - Functions and cmdlets should use approved verbs. This script uses `New` for creating resources.
#>

#region Variables

# Virtual Switch and Network Configuration
$vSwitchName = "azurestackhci"
$vSwitchNIC = "vEthernet ($vSwitchName)"
$vNetIPNetwork = "172.19.19.0/24"
$vIPNetworkPrefixLength = ($vNetIPNetwork -split '/')[1]
$natName = "azurestackhci"
$HCIRootFolder = "C:\HCI"

# ISO Paths
$isoPath_HCI = "C:\ISO\HCI23H2.iso"    # Replace with the actual path to your HCI Node ISO
$isoPath_DC = "C:\ISO\WS2025.iso"      # Replace with the actual path to your Domain Controller ISO

# HCI Node VM Configuration
$HCIVMName = "NODE"
$HCI_Memory = 32GB
$HCI_Processors = 8
$HCI_Disks = @(
    @{ Path = "${HCIVMName}_C.vhdx"; Size = 127GB },
    @{ Path = "s2d1.vhdx"; Size = 1024GB },
    @{ Path = "s2d2.vhdx"; Size = 1024GB }
)
$HCI_NetworkAdapters = @("MGMT1", "MGMT2")

# Domain Controller VM Configuration
$DCVMName = "DC"
$DC_Memory = 4GB
$DC_Processors = 2
$DC_Disks = @(
    @{ Path = "${DCVMName}_C.vhdx"; Size = 60GB }
)
$DC_NetworkAdapters = @("MGMT1")

# Tasks for Progress Bar
$tasks = @(
    "Checking Prerequisites",
    "Configuring Virtual Switch and NAT",
    "Setting Up Folder Structures",
    "Creating HCI Node VM",
    "Creating Domain Controller VM"
)

$totalTasks = $tasks.Count
$currentTask = 0

#endregion

#region Functions

# Function to Display Messages with Colors
function Write-Message {
    param (
        [string]$Message,
        [ValidateSet("Info", "Success", "Warning", "Error")]
        [string]$Type = "Info"
    )

    switch ($Type) {
        "Info"    { Write-Host $Message -ForegroundColor Cyan }
        "Success" { Write-Host $Message -ForegroundColor Green }
        "Warning" { Write-Host $Message -ForegroundColor Yellow }
        "Error"   { Write-Host $Message -ForegroundColor Red }
    }

    # Optional: Log messages to a file
    # Add-Content -Path "C:\Path\To\Your\LogFile.txt" -Value "$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss')) [$Type] $Message"
}

# Function to Ensure the Folder Structure Exists
function Set-FolderStructure {
    param (
        [string]$BaseFolder
    )
    $vmFolder = Join-Path -Path $BaseFolder -ChildPath "VM"
    $diskFolder = Join-Path -Path $BaseFolder -ChildPath "Disk"

    try {
        if (-not (Test-Path -Path $BaseFolder)) {
            Write-Message "Base folder does not exist. Creating: $BaseFolder" -Type "Info"
            New-Item -Path $BaseFolder -ItemType Directory -Force | Out-Null
            Write-Message "Base folder created: $BaseFolder" -Type "Success"
        } else {
            Write-Message "Base folder already exists: $BaseFolder" -Type "Info"
        }

        if (-not (Test-Path -Path $vmFolder)) {
            Write-Message "VM folder does not exist. Creating: $vmFolder" -Type "Info"
            New-Item -Path $vmFolder -ItemType Directory -Force | Out-Null
            Write-Message "VM folder created: $vmFolder" -Type "Success"
        } else {
            Write-Message "VM folder already exists: $vmFolder" -Type "Info"
        }

        if (-not (Test-Path -Path $diskFolder)) {
            Write-Message "Disk folder does not exist. Creating: $diskFolder" -Type "Info"
            New-Item -Path $diskFolder -ItemType Directory -Force | Out-Null
            Write-Message "Disk folder created: $diskFolder" -Type "Success"
        } else {
            Write-Message "Disk folder already exists: $diskFolder" -Type "Info"
        }
    } catch {
        Write-Message "Failed to set up folder structure. Error: $_" -Type "Error"
        throw
    }
}

# Function to Create or Verify the Internal VMSwitch
function Invoke-InternalVMSwitch {
    param (
        [string]$VMSwitchName
    )

    try {
        $existingSwitch = Get-VMSwitch -Name $VMSwitchName -ErrorAction SilentlyContinue
        if ($null -ne $existingSwitch) {
            Write-Message "The internal VM Switch '$VMSwitchName' already exists." -Type "Success"
        } else {
            Write-Message "The internal VM Switch '$VMSwitchName' does not exist. Creating it now..." -Type "Info"
            New-VMSwitch -Name $VMSwitchName -SwitchType Internal -ErrorAction Stop | Out-Null
            Write-Message "Internal VM Switch '$VMSwitchName' created successfully!" -Type "Success"
        }
    } catch {
        Write-Message "Failed to create internal VM Switch '$VMSwitchName'. Error: $_" -Type "Error"
        throw
    }
}

# Function to Calculate the Gateway (First Usable Address in the Subnet)
function Get-Gateway {
    param (
        [string]$IPNetwork
    )
    try {
        $ip, $cidr = $IPNetwork -split '/'
        $networkAddress = [System.Net.IPAddress]::Parse($ip)
        $addressBytes = $networkAddress.GetAddressBytes()
        $addressBytes[3] += 1  # Increment the last octet by 1
        $gateway = [System.Net.IPAddress]::new($addressBytes)
        return $gateway
    } catch {
        Write-Message "Invalid IP network format: $IPNetwork. Error: $_" -Type "Error"
        throw
    }
}

# Function to Create VMs
function New-VMCreation {
    param (
        [string]$VMName,
        [string]$VMFolder,
        [string]$DiskFolder,
        [string]$ISOPath,
        [long]$Memory,
        [int]$Processors,
        [array]$Disks,
        [array]$NetworkAdapters
    )

    try {
        # Create virtual hard disk for the OS
        $VHDName = $Disks[0].Path
        $VHDPath = Join-Path -Path $DiskFolder -ChildPath $VHDName
        if (-not (Test-Path -Path $VHDPath)) {
            New-VHD -Path $VHDPath -SizeBytes $Disks[0].Size -ErrorAction Stop | Out-Null
            Write-Message "VHD created at '$VHDPath'." -Type "Success"
        } else {
            Write-Message "VHD already exists at '$VHDPath'. Skipping creation." -Type "Warning"
        }

        # Create the VM
        if (-not (Get-VM -Name $VMName -ErrorAction SilentlyContinue)) {
            New-VM -Name $VMName -MemoryStartupBytes $Memory -VHDPath $VHDPath -Generation 2 -Path $VMFolder -ErrorAction Stop | Out-Null
            Write-Message "VM '$VMName' created successfully." -Type "Success"
        } else {
            Write-Message "VM '$VMName' already exists. Skipping creation." -Type "Warning"
            return
        }

        # Configure memory and processors
        Set-VMMemory -VMName $VMName -DynamicMemoryEnabled $false -ErrorAction Stop | Out-Null
        Set-VMProcessor -VMName $VMName -Count $Processors -ErrorAction Stop | Out-Null
        Write-Message "Memory and processor settings configured for VM '$VMName'." -Type "Success"

        # Disable checkpoints
        Set-VM -VMName $VMName -CheckpointType Disabled -ErrorAction Stop | Out-Null
        Write-Message "Checkpoints disabled for VM '$VMName'." -Type "Success"

        # Remove default network adapter
        Get-VMNetworkAdapter -VMName $VMName | Remove-VMNetworkAdapter -ErrorAction Stop | Out-Null
        Write-Message "Default network adapter removed from VM '$VMName'." -Type "Success"

        # Add network adapters and connect them to the VMSwitch
        foreach ($nic in $NetworkAdapters) {
            Add-VMNetworkAdapter -VMName $VMName -Name $nic -ErrorAction Stop | Out-Null
            Connect-VMNetworkAdapter -VMName $VMName -Name $nic -SwitchName $vSwitchName -ErrorAction Stop | Out-Null
            Write-Message "Network adapter '$nic' added and connected to '$vSwitchName' for VM '$VMName'." -Type "Success"
        }

        # Enable MAC spoofing
        Get-VMNetworkAdapter -VMName $VMName | Set-VMNetworkAdapter -MacAddressSpoofing On -ErrorAction Stop | Out-Null
        Write-Message "MAC spoofing enabled for VM '$VMName'." -Type "Success"

        # Configure Key Protector and vTPM
        $GuardianName = $VMName
        $existingGuardian = Get-HgsGuardian -Name $GuardianName -ErrorAction SilentlyContinue
        if ($null -ne $existingGuardian) {
            Write-Message "HgsGuardian '$GuardianName' already exists. Deleting and recreating..." -Type "Warning"
            Remove-HgsGuardian -Name $GuardianName -ErrorAction Stop | Out-Null
            Write-Message "HgsGuardian '$GuardianName' deleted." -Type "Success"
        } else {
            Write-Message "HgsGuardian '$GuardianName' does not exist. Creating it now..." -Type "Info"
        }

        $newGuardian = New-HgsGuardian -Name $GuardianName -GenerateCertificates -ErrorAction Stop
        Write-Message "HgsGuardian '$GuardianName' created successfully!" -Type "Success"

        $kp = New-HgsKeyProtector -Owner $newGuardian -AllowUntrustedRoot -ErrorAction Stop
        Set-VMKeyProtector -VMName $VMName -KeyProtector $kp.RawData -ErrorAction Stop | Out-Null
        Enable-VMTPM -VMName $VMName -ErrorAction Stop | Out-Null
        Write-Message "KeyProtector and vTPM applied to VM '$VMName'." -Type "Success"

        # Create and attach additional disks
        for ($i = 1; $i -lt $Disks.Count; $i++) {
            $disk = $Disks[$i]
            $diskPath = Join-Path -Path $DiskFolder -ChildPath $disk.Path
            if (-not (Test-Path -Path $diskPath)) {
                New-VHD -Path $diskPath -SizeBytes $disk.Size -ErrorAction Stop | Out-Null
                Write-Message "Additional VHD created at '$diskPath'." -Type "Success"
            } else {
                Write-Message "Additional VHD already exists at '$diskPath'. Skipping creation." -Type "Warning"
            }
            Add-VMHardDiskDrive -VMName $VMName -Path $diskPath -ErrorAction Stop | Out-Null
            Write-Message "Additional disk '$disk.Path' attached to VM '$VMName'." -Type "Success"
        }

        # Enable nested virtualization
        Set-VMProcessor -VMName $VMName -ExposeVirtualizationExtensions $true -ErrorAction Stop | Out-Null
        Write-Message "Nested virtualization enabled for VM '$VMName'." -Type "Success"

        # Add boot ISO
        Add-VMDvdDrive -VMName $VMName -Path $ISOPath -ErrorAction Stop | Out-Null
        Write-Message "ISO '$ISOPath' mounted as DVD drive for VM '$VMName'." -Type "Success"

        # Set boot order to prioritize the DVD drive first
        $bootOrder = Get-VMFirmware -VMName $VMName -ErrorAction Stop
        $dvdBoot = ($bootOrder.BootOrder | Where-Object { $_.Device -like '*Dvd*' })[0]
        if ($dvdBoot) {
            Set-VMFirmware -VMName $VMName -FirstBootDevice $dvdBoot -ErrorAction Stop | Out-Null
            Write-Message "Boot order set to prioritize DVD drive for VM '$VMName'." -Type "Success"
        } else {
            Write-Message "DVD drive not found in boot order for VM '$VMName'." -Type "Warning"
        }

        # Configure VM to shut down when the host shuts down
        Set-VM -Name $VMName -AutomaticStopAction ShutDown -ErrorAction Stop | Out-Null
        Write-Message "Configured VM '$VMName' to shut down when the host shuts down." -Type "Success"

        # Configure VM to take no action when the host starts
        Set-VM -Name $VMName -AutomaticStartAction Nothing -ErrorAction Stop | Out-Null
        Write-Message "Configured VM '$VMName' to take no action on host start." -Type "Success"

    } catch {
        Write-Message "Failed to create or configure VM '$VMName'. Error: $_" -Type "Error"
        throw
    }
}

# Function to Test for TPM Chip
function Test-TPM {
    try {
        $tpm = Get-TPM -ErrorAction SilentlyContinue
        if ($null -eq $tpm) {
            Write-Message "TPM chip not found on the host. A TPM is required for the Key Protector and vTPM." -Type "Error"
            exit 1
        } elseif (-not $tpm.TpmEnabled) {
            Write-Message "TPM chip is present but not enabled. Please enable TPM in the BIOS/UEFI settings." -Type "Error"
            exit 1
        } else {
            Write-Message "TPM chip is present and enabled." -Type "Success"
        }
    } catch {
        Write-Message "Failed to check TPM status. Error: $_" -Type "Error"
        exit 1
    }
}

# Function to Test for Hyper-V Role
function Test-HyperV {
    try {
        # Query Win32_OptionalFeature for Hyper-V
        $hyperVFeature = Get-CimInstance -ClassName Win32_OptionalFeature -Filter "Name='Microsoft-Hyper-V-All'" -ErrorAction Stop

        if ($hyperVFeature.InstallState -eq 1) {
            Write-Message "Hyper-V role is already installed on the host." -Type "Success"
        }
        else {
            Write-Message "Hyper-V role is not installed on the host. Installing Hyper-V role and management tools..." -Type "Info"

            # Determine OS type
            $os = Get-CimInstance -ClassName Win32_OperatingSystem
            $productType = $os.ProductType
            # ProductType 1 = Workstation, 2 = Domain Controller, 3 = Server

            if ($productType -eq 1) {
                # Client OS - use Enable-WindowsOptionalFeature
                Write-Message "Detected Client Operating System. Installing Hyper-V using Enable-WindowsOptionalFeature..." -Type "Info"
                Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All -All -NoRestart -ErrorAction Stop
            }
            else {
                # Server OS - use DISM
                Write-Message "Detected Server Operating System. Installing Hyper-V using DISM..." -Type "Info"
                dism.exe /Online /Enable-Feature /All /FeatureName:Microsoft-Hyper-V /IncludeManagementTools /NoRestart | Out-Null
            }

            Write-Message "Hyper-V role and management tools installed successfully. A restart is required." -Type "Success"

            # Optional: Implement a progress bar or sleep before restarting
            Start-SleepWithProgress -Seconds 60 -Activity "Restarting Host" -Status "Please wait while the host restarts..."

            # Restart the computer to apply changes
            Restart-Computer -Force
        }
    }
    catch {
        Write-Message "Failed to check or install Hyper-V role. Error: $_" -Type "Error"
        exit 1
    }
}

# Function to Update Progress Bar (Main Progress)
function Update-ProgressBarMain {
    param (
        [int]$CurrentStep,
        [int]$TotalSteps,
        [string]$StatusMessage
    )

    $percent = [math]::Round(($CurrentStep / $TotalSteps) * 100)
    Write-Progress -Id 1 -Activity "Overall Progress" -Status $StatusMessage -PercentComplete $percent
}

# Function to Start Sleep with Progress Message and Additional Progress Bar (Subtask)
function Start-SleepWithProgress {
    param(
        [int]$Seconds,
        [string]$Activity = "Waiting",
        [string]$Status = "Please wait..."
    )

    Write-Message "$Activity : $Status" -Type "Info"

    for ($i = 1; $i -le $Seconds; $i++) {
        $percent = [math]::Round(($i / $Seconds) * 100)
        Write-Progress -Id 2 -Activity "Sleep Progress" -Status "$Activity : $i/$Seconds seconds elapsed..." -PercentComplete $percent
        Start-Sleep -Seconds 1
    }

    Write-Progress -Id 2 -Activity "Sleep Progress" -Completed
    Write-Message "$Activity : Completed." -Type "Success"
}

#endregion

#region Script Execution

foreach ($task in $tasks) {
    $currentTask++
    Update-ProgressBarMain -CurrentStep $currentTask -TotalSteps $totalTasks -StatusMessage "$task..."

    switch ($task) {
        "Checking Prerequisites" {
            Write-Message "Checking prerequisites..." -Type "Info"
            # Test for TPM
            Test-TPM

            # Test for Hyper-V role and management tools
            Test-HyperV

            Write-Message "Prerequisite checks completed successfully." -Type "Success"
        }
        "Configuring Virtual Switch and NAT" {
            Write-Message "Configuring virtual switch and NAT settings..." -Type "Info"

            # Create internal VMSwitch
            Invoke-InternalVMSwitch -VMSwitchName $vSwitchName
            Start-Sleep -Seconds 3

            # Calculate Gateway
            try {
                $vIPNetworkGW = Get-Gateway -IPNetwork $vNetIPNetwork
                Write-Message "Calculated gateway: $vIPNetworkGW" -Type "Info"
            } catch {
                Write-Message "Failed to calculate gateway. Exiting script." -Type "Error"
                exit 1
            }

            # Assign IP and NAT
            try {
                # Assign the IP address to the host's vSwitch interface
                $existingIPAddress = Get-NetIPAddress -IPAddress $vIPNetworkGW -InterfaceAlias $vSwitchNIC -ErrorAction SilentlyContinue
                if ($null -eq $existingIPAddress) {
                    Write-Message "Assigning IP address $vIPNetworkGW to interface $vSwitchNIC" -Type "Info"
                    New-NetIPAddress -IPAddress $vIPNetworkGW -PrefixLength $vIPNetworkPrefixLength -InterfaceAlias $vSwitchNIC -ErrorAction Stop | Out-Null
                    Write-Message "IP address $vIPNetworkGW assigned successfully to $vSwitchNIC." -Type "Success"
                } else {
                    Write-Message "IP address $vIPNetworkGW already exists on interface $vSwitchNIC. Skipping assignment." -Type "Warning"
                }

                # Create NAT configuration if it doesn't exist
                $existingNat = Get-NetNat -Name $natName -ErrorAction SilentlyContinue
                if ($null -eq $existingNat) {
                    Write-Message "Creating new NAT with name: $natName" -Type "Info"
                    New-NetNat -Name $natName -InternalIPInterfaceAddressPrefix $vNetIPNetwork -ErrorAction Stop | Out-Null
                    Write-Message "NAT '$natName' created successfully." -Type "Success"
                } else {
                    Write-Message "A NAT with the name '$natName' already exists. Skipping creation." -Type "Warning"
                }
            } catch {
                Write-Message "Failed to configure IP address or NAT. Error: $_" -Type "Error"
                exit 1
            }

            Start-Sleep -Seconds 3

            Write-Message "Virtual switch and NAT configuration completed successfully!" -Type "Success"
        }
        "Setting Up Folder Structures" {
            Write-Message "Setting up folder structures..." -Type "Info"
            try {
                Set-FolderStructure -BaseFolder $HCIRootFolder
                $HCIDiskFolder = Join-Path -Path $HCIRootFolder -ChildPath "Disk"
                $HCIVMFolder = Join-Path -Path $HCIRootFolder -ChildPath "VM"
                Write-Message "Folder structures set up successfully." -Type "Success"
            } catch {
                Write-Message "Failed to set up folder structures. Error: $_" -Type "Error"
                exit 1
            }
        }
        "Creating HCI Node VM" {
            Write-Message "Creating HCI Node VM..." -Type "Info"
            try {
                New-VMCreation -VMName $HCIVMName `
                              -VMFolder $HCIVMFolder `
                              -DiskFolder $HCIDiskFolder `
                              -ISOPath $isoPath_HCI `
                              -Memory $HCI_Memory `
                              -Processors $HCI_Processors `
                              -Disks $HCI_Disks `
                              -NetworkAdapters $HCI_NetworkAdapters

                # Disable time synchronization on the HCI Node VM
                Get-VMIntegrationService -VMName $HCIVMName | Where-Object { $_.Name -like "*Sync*" } | Disable-VMIntegrationService -ErrorAction Stop | Out-Null
                Write-Message "Time synchronization disabled for VM '$HCIVMName'." -Type "Success"
            } catch {
                Write-Message "Failed to create HCI Node VM '$HCIVMName'. Error: $_" -Type "Error"
                exit 1
            }
        }
        "Creating Domain Controller VM" {
            Write-Message "Creating Domain Controller VM..." -Type "Info"
            try {
                New-VMCreation -VMName $DCVMName `
                              -VMFolder $HCIVMFolder `
                              -DiskFolder $HCIDiskFolder `
                              -ISOPath $isoPath_DC `
                              -Memory $DC_Memory `
                              -Processors $DC_Processors `
                              -Disks $DC_Disks `
                              -NetworkAdapters $DC_NetworkAdapters
                # Disable time synchronization on the DC VM
                Get-VMIntegrationService -VMName $DCVMName | Where-Object { $_.Name -like "*Sync*" } | Disable-VMIntegrationService -ErrorAction Stop | Out-Null
                Write-Message "Time synchronization disabled for VM '$DCVMName'." -Type "Success"
            } catch {
                Write-Message "Failed to create Domain Controller VM '$DCVMName'. Error: $_" -Type "Error"
                exit 1
            }
        }
    }
}

# Complete the Progress Bar
Write-Progress -Id 1 -Activity "Configuring Infrastructure and Creating VMs" -Completed -Status "All tasks completed."

Write-Message "All configurations and VM creations completed successfully." -Type "Success"

#endregion
