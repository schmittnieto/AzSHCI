# 00_Infra_AzHCI.ps1
# Configuration and VM Creation Script

<#
.SYNOPSIS
    Configures virtual networking, creates required folder structures, and deploys HCI Node and Domain Controller VMs.

.DESCRIPTION
    This script performs the following tasks:
    - Checks required prerequisites.
    - Configures an internal virtual switch with NAT.
    - Ensures the required folder structures exist.
    - Creates two virtual machines: an HCI Node and a Domain Controller.
    - Configures networking, storage, security, and boot settings for the VMs.

.NOTES
    - Designed by Cristian Schmitt Nieto. For details: https://schmitt-nieto.com/blog/azure-stack-hci-demolab/
    - Run this script with administrative privileges.
    - Ensure ISO paths are correct before execution.
    - Execution Policy may need to allow script execution:
    - Set-ExecutionPolicy RemoteSigned -Scope CurrentUser
    - Approved PowerShell verb usage:
    - Functions and cmdlets use approved verbs such as `New` for creation.
    - Updates:
        - 2025/11/10: Adding ICMP allow rule to permit pinging the NAT gateway from VMs. 
#>

#region Variables

# Virtual Switch and Network Configuration
$vSwitchName = "azurelocal"
$vSwitchNIC = "vEthernet ($vSwitchName)"
$vNetIPNetwork = "172.19.18.0/24"
$vIPNetworkPrefixLength = ($vNetIPNetwork -split '/')[1]
$natName = "azurelocal"
$HCIRootFolder = "C:\HCI"

# ISO Paths
$isoPath_HCI = "D:\ISO\AzureLocal24H2.iso"    # Replace with the actual path to your HCI Node ISO
$isoPath_DC  = "D:\ISO\WS2025.iso"      # Replace with the actual path to your Domain Controller ISO

# HCI Node VM Configuration
$HCIVMName = "AZLN01"
$HCI_Memory = 48GB
$HCI_Processors = 16
$HCI_Disks = @(
    @{ Path = "${HCIVMName}_C.vhdx"; Size = 127GB },
    @{ Path = "s2d1.vhdx";            Size = 1024GB },
    @{ Path = "s2d2.vhdx";            Size = 1024GB }
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

function Write-Message {
    param(
        [string]$Message,
        [ValidateSet("Info","Success","Warning","Error")]
        [string]$Type = "Info"
    )
    switch ($Type) {
        "Info"    { Write-Host $Message -ForegroundColor Cyan }
        "Success" { Write-Host $Message -ForegroundColor Green }
        "Warning" { Write-Host $Message -ForegroundColor Yellow }
        "Error"   { Write-Host $Message -ForegroundColor Red }
    }
    # Optional: log to file
    # Add-Content -Path "C:\Path\To\LogFile.txt" -Value "$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss')) [$Type] $Message"
}

function Set-FolderStructure {
    param(
        [string]$BaseFolder
    )

    $vmFolder   = Join-Path -Path $BaseFolder -ChildPath "VM"
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

function Invoke-InternalVMSwitch {
    param(
        [string]$VMSwitchName
    )
    try {
        $existingSwitch = Get-VMSwitch -Name $VMSwitchName -ErrorAction SilentlyContinue
        if ($null -ne $existingSwitch) {
            Write-Message "Internal VM switch '$VMSwitchName' already exists." -Type "Success"
        } else {
            Write-Message "Internal VM switch '$VMSwitchName' does not exist. Creating it..." -Type "Info"
            New-VMSwitch -Name $VMSwitchName -SwitchType Internal -ErrorAction Stop | Out-Null
            Write-Message "Internal VM switch '$VMSwitchName' created." -Type "Success"
        }
    } catch {
        Write-Message "Failed to create internal VM switch '$VMSwitchName'. Error: $_" -Type "Error"
        throw
    }
}

function Get-Gateway {
    param(
        [string]$IPNetwork
    )
    try {
        $ip, $cidr = $IPNetwork -split '/'
        $base = [System.Net.IPAddress]::Parse($ip)
        $bytes = $base.GetAddressBytes()
        $bytes[3] += 1
        return [System.Net.IPAddress]::new($bytes)
    } catch {
        Write-Message "Invalid IP network format: $IPNetwork. Error: $_" -Type "Error"
        throw
    }
}

function New-VMCreation {
    param(
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
        # OS disk
        $VHDName = $Disks[0].Path
        $VHDPath = Join-Path -Path $DiskFolder -ChildPath $VHDName
        if (-not (Test-Path -Path $VHDPath)) {
            New-VHD -Path $VHDPath -SizeBytes $Disks[0].Size -ErrorAction Stop | Out-Null
            Write-Message "VHD created at '$VHDPath'." -Type "Success"
        } else {
            Write-Message "VHD already exists at '$VHDPath'. Skipping." -Type "Warning"
        }

        # VM
        if (-not (Get-VM -Name $VMName -ErrorAction SilentlyContinue)) {
            New-VM -Name $VMName -MemoryStartupBytes $Memory -VHDPath $VHDPath -Generation 2 -Path $VMFolder -ErrorAction Stop | Out-Null
            Write-Message "VM '$VMName' created." -Type "Success"
        } else {
            Write-Message "VM '$VMName' already exists. Skipping creation." -Type "Warning"
            return
        }

        # Memory and CPU
        Set-VMMemory   -VMName $VMName -DynamicMemoryEnabled $false -ErrorAction Stop | Out-Null
        Set-VMProcessor -VMName $VMName -Count $Processors -ErrorAction Stop | Out-Null
        Write-Message "Memory and processors configured for '$VMName'." -Type "Success"

        # Disable checkpoints
        Set-VM -VMName $VMName -CheckpointType Disabled -ErrorAction Stop | Out-Null
        Write-Message "Checkpoints disabled for '$VMName'." -Type "Success"

        # Remove default NIC
        Get-VMNetworkAdapter -VMName $VMName | Remove-VMNetworkAdapter -ErrorAction Stop | Out-Null
        Write-Message "Default NIC removed from '$VMName'." -Type "Success"

        # Add NICs and connect
        foreach ($nic in $NetworkAdapters) {
            Add-VMNetworkAdapter -VMName $VMName -Name $nic -ErrorAction Stop | Out-Null
            Connect-VMNetworkAdapter -VMName $VMName -Name $nic -SwitchName $vSwitchName -ErrorAction Stop | Out-Null
            Write-Message "NIC '$nic' added and connected to '$vSwitchName' for '$VMName'." -Type "Success"
        }

        # Enable MAC spoofing
        Get-VMNetworkAdapter -VMName $VMName | Set-VMNetworkAdapter -MacAddressSpoofing On -ErrorAction Stop | Out-Null
        Write-Message "MAC spoofing enabled for '$VMName'." -Type "Success"

        # Key Protector and vTPM
        $GuardianName = $VMName
        $existingGuardian = Get-HgsGuardian -Name $GuardianName -ErrorAction SilentlyContinue
        if ($null -ne $existingGuardian) {
            Write-Message "HgsGuardian '$GuardianName' exists. Deleting and recreating..." -Type "Warning"
            Remove-HgsGuardian -Name $GuardianName -ErrorAction Stop | Out-Null
            Write-Message "HgsGuardian '$GuardianName' deleted." -Type "Success"
        } else {
            Write-Message "Creating HgsGuardian '$GuardianName'..." -Type "Info"
        }

        $newGuardian = New-HgsGuardian -Name $GuardianName -GenerateCertificates -ErrorAction Stop
        Write-Message "HgsGuardian '$GuardianName' created." -Type "Success"

        $kp = New-HgsKeyProtector -Owner $newGuardian -AllowUntrustedRoot -ErrorAction Stop
        Set-VMKeyProtector -VMName $VMName -KeyProtector $kp.RawData -ErrorAction Stop | Out-Null
        Enable-VMTPM        -VMName $VMName -ErrorAction Stop | Out-Null
        Write-Message "Key Protector and vTPM applied to '$VMName'." -Type "Success"

        # Additional data disks
        for ($i = 1; $i -lt $Disks.Count; $i++) {
            $disk = $Disks[$i]
            $diskPath = Join-Path -Path $DiskFolder -ChildPath $disk.Path
            if (-not (Test-Path -Path $diskPath)) {
                New-VHD -Path $diskPath -SizeBytes $disk.Size -ErrorAction Stop | Out-Null
                Write-Message "Additional VHD created at '$diskPath'." -Type "Success"
            } else {
                Write-Message "Additional VHD already exists at '$diskPath'. Skipping." -Type "Warning"
            }
            Add-VMHardDiskDrive -VMName $VMName -Path $diskPath -ErrorAction Stop | Out-Null
            Write-Message "Additional disk '$($disk.Path)' attached to '$VMName'." -Type "Success"
        }

        # Nested virtualization
        Set-VMProcessor -VMName $VMName -ExposeVirtualizationExtensions $true -ErrorAction Stop | Out-Null
        Write-Message "Nested virtualization enabled for '$VMName'." -Type "Success"

        # Boot media
        Add-VMDvdDrive -VMName $VMName -Path $ISOPath -ErrorAction Stop | Out-Null
        Write-Message "ISO '$ISOPath' mounted for '$VMName'." -Type "Success"

        # Boot order
        $firm = Get-VMFirmware -VMName $VMName -ErrorAction Stop
        $dvdBoot = ($firm.BootOrder | Where-Object { $_.Device -like '*Dvd*' })[0]
        if ($dvdBoot) {
            Set-VMFirmware -VMName $VMName -FirstBootDevice $dvdBoot -ErrorAction Stop | Out-Null
            Write-Message "Boot order set to DVD first for '$VMName'." -Type "Success"
        } else {
            Write-Message "DVD device not found in boot order for '$VMName'." -Type "Warning"
        }

        # Host start and stop actions
        Set-VM -Name $VMName -AutomaticStopAction ShutDown  -ErrorAction Stop | Out-Null
        Set-VM -Name $VMName -AutomaticStartAction Nothing  -ErrorAction Stop | Out-Null
        Write-Message "Start and stop actions configured for '$VMName'." -Type "Success"

    } catch {
        Write-Message "Failed to create or configure VM '$VMName'. Error: $_" -Type "Error"
        throw
    }
}

function Test-TPM {
    try {
        $tpm = Get-TPM -ErrorAction SilentlyContinue
        if ($null -eq $tpm) {
            Write-Message "TPM not found on host. A TPM is required for Key Protector and vTPM." -Type "Error"
            exit 1
        } elseif (-not $tpm.TpmEnabled) {
            Write-Message "TPM is present but not enabled. Enable it in BIOS or UEFI." -Type "Error"
            exit 1
        } else {
            Write-Message "TPM is present and enabled." -Type "Success"
        }
    } catch {
        Write-Message "Failed to check TPM status. Error: $_" -Type "Error"
        exit 1
    }
}

function Test-HyperV {
    try {
        $feature = Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V -ErrorAction Stop
        if ($feature.State -eq "Enabled") {
            Write-Message "Hyper-V role already installed." -Type Success
            return
        }
        Write-Message "Installing Hyper-V role and management tools..." -Type Info
        Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V -All -NoRestart -ErrorAction Stop | Out-Null
        Write-Message "Hyper-V installed. Please reboot and run the script again." -Type Warning
        exit 0
    } catch {
        Write-Message "Failed to install Hyper-V. $($_)" -Type Error
        exit 1
    }
}

function Update-ProgressBarMain {
    param(
        [int]$CurrentStep,
        [int]$TotalSteps,
        [string]$StatusMessage
    )
    $percent = [math]::Round(($CurrentStep / $TotalSteps) * 100)
    Write-Progress -Id 1 -Activity "Overall Progress" -Status $StatusMessage -PercentComplete $percent
}

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

<# ============================================================
   NEW: Allow ICMP ping to the NAT gateway on the host interface
   ============================================================ #>
function Enable-GatewayIcmp {
    param(
        [Parameter(Mandatory = $true)][string]$InterfaceAlias,
        [Parameter(Mandatory = $true)][string]$Gateway,
        [Parameter(Mandatory = $true)][string]$SubnetCidr
    )
    try {
        # Ensure Private profile for that interface (helps avoid profile-based blocks)
        $netprofile = Get-NetConnectionProfile -InterfaceAlias $InterfaceAlias -ErrorAction SilentlyContinue
        if ($netprofile -and $netprofile.NetworkCategory -ne 'Private') {
            Set-NetConnectionProfile -InterfaceAlias $InterfaceAlias -NetworkCategory Private | Out-Null
            Write-Message "Network profile for '$InterfaceAlias' set to Private." -Type "Info"
        }

        $ruleName = "Allow-ICMPv4-$InterfaceAlias-$Gateway"
        $existing = Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue
        if (-not $existing) {
            New-NetFirewallRule `
                -DisplayName  $ruleName `
                -Direction    Inbound `
                -Action       Allow `
                -Protocol     ICMPv4 `
                -IcmpType     8 `
                -InterfaceAlias $InterfaceAlias `
                -LocalAddress $Gateway `
                -RemoteAddress $SubnetCidr `
                -Profile Any | Out-Null

            Write-Message "Firewall rule created to allow ICMPv4 Echo to $Gateway on '$InterfaceAlias' from $SubnetCidr." -Type "Success"
        } else {
            Write-Message "Firewall rule '$ruleName' already exists." -Type "Info"
        }
    } catch {
        Write-Message "Could not configure ICMP rule. Error: $_" -Type "Error"
        throw
    }
}

# Misspelling-friendly alias so both names work
Set-Alias -Name Enable-GetawayIcmp -Value Enable-GatewayIcmp -ErrorAction SilentlyContinue

#endregion

#region Script Execution

foreach ($task in $tasks) {
    $currentTask++
    Update-ProgressBarMain -CurrentStep $currentTask -TotalSteps $totalTasks -StatusMessage "$task..."

    switch ($task) {
        "Checking Prerequisites" {
            Write-Message "Checking prerequisites..." -Type "Info"
            Test-TPM
            Test-HyperV
            Write-Message "Prerequisite checks completed successfully." -Type "Success"
        }

        "Configuring Virtual Switch and NAT" {
            Write-Message "Configuring virtual switch and NAT settings..." -Type "Info"

            Invoke-InternalVMSwitch -VMSwitchName $vSwitchName
            Start-Sleep -Seconds 3

            # Calculate gateway address, assign IP to host vSwitch NIC, and create NAT
            try {
                $vIPNetworkGW = Get-Gateway -IPNetwork $vNetIPNetwork
                Write-Message "Calculated gateway: $vIPNetworkGW" -Type "Info"
            } catch {
                Write-Message "Failed to calculate gateway. Exiting." -Type "Error"
                exit 1
            }

            try {
                # Assign IP address to host vSwitch interface
                $existingIPAddress = Get-NetIPAddress -IPAddress $vIPNetworkGW -InterfaceAlias $vSwitchNIC -ErrorAction SilentlyContinue
                if ($null -eq $existingIPAddress) {
                    Write-Message "Assigning $vIPNetworkGW to $vSwitchNIC" -Type "Info"
                    New-NetIPAddress -IPAddress $vIPNetworkGW -PrefixLength $vIPNetworkPrefixLength -InterfaceAlias $vSwitchNIC -ErrorAction Stop | Out-Null
                    Write-Message "Assigned $vIPNetworkGW to $vSwitchNIC." -Type "Success"
                } else {
                    Write-Message "IP $vIPNetworkGW already present on $vSwitchNIC. Skipping assignment." -Type "Warning"
                }

                # Create NAT if missing
                $existingNat = Get-NetNat -Name $natName -ErrorAction SilentlyContinue
                if ($null -eq $existingNat) {
                    Write-Message "Creating NAT '$natName' for $vNetIPNetwork" -Type "Info"
                    New-NetNat -Name $natName -InternalIPInterfaceAddressPrefix $vNetIPNetwork -ErrorAction Stop | Out-Null
                    Write-Message "NAT '$natName' created." -Type "Success"
                } else {
                    Write-Message "NAT '$natName' already exists. Skipping creation." -Type "Warning"
                }
            } catch {
                Write-Message "Failed to configure IP or NAT. Error: $_" -Type "Error"
                exit 1
            }

            # Allow ICMP echo to the gateway on the host interface for VMs in the lab subnet
            try {
                Enable-GatewayIcmp -InterfaceAlias $vSwitchNIC -Gateway "$vIPNetworkGW" -SubnetCidr $vNetIPNetwork
            } catch {
                Write-Message "Failed to enable ICMP echo to gateway. Error: $_" -Type "Error"
                exit 1
            }

            Start-Sleep -Seconds 3
            Write-Message "Virtual switch and NAT configuration completed." -Type "Success"
        }

        "Setting Up Folder Structures" {
            Write-Message "Setting up folder structures..." -Type "Info"
            try {
                Set-FolderStructure -BaseFolder $HCIRootFolder
                $HCIDiskFolder = Join-Path -Path $HCIRootFolder -ChildPath "Disk"
                $HCIVMFolder   = Join-Path -Path $HCIRootFolder -ChildPath "VM"
                Write-Message "Folder structures ready." -Type "Success"
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

                # Disable time synchronization integration service
                Get-VMIntegrationService -VMName $HCIVMName | Where-Object { $_.Name -like "*Sync*" } | Disable-VMIntegrationService -ErrorAction Stop | Out-Null
                Write-Message "Time synchronization disabled for '$HCIVMName'." -Type "Success"
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

                # Disable time synchronization integration service
                Get-VMIntegrationService -VMName $DCVMName | Where-Object { $_.Name -like "*Sync*" } | Disable-VMIntegrationService -ErrorAction Stop | Out-Null
                Write-Message "Time synchronization disabled for '$DCVMName'." -Type "Success"
            } catch {
                Write-Message "Failed to create Domain Controller VM '$DCVMName'. Error: $_" -Type "Error"
                exit 1
            }
        }
    }
}

Write-Progress -Id 1 -Activity "Configuring Infrastructure and Creating VMs" -Completed -Status "All tasks completed."
Write-Message "All configurations and VM creations completed successfully." -Type "Success"

#endregion
