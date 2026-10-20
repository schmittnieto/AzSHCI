# Offboarding Script to Clean Up Configurations

<#
.SYNOPSIS
    Removes the whole lab, or only the Azure Local node while keeping the domain controller.

.DESCRIPTION
    Two modes are available, selected with -Mode or interactively at startup:

    1 / All       Removes the node and DC VMs with their disks and HgsGuardians, the NAT,
                  the IP addresses on the virtual switch interface, the virtual switch,
                  the ICMP firewall rules and the whole lab folder.
    2 / NodeOnly  Removes only the Azure Local node VM, its disks (OS and S2D), its
                  HgsGuardian and its VM folder. The DC VM, the networking, the firewall
                  rules and the rest of the lab folder stay in place. Redeploy the node with
                  00_Infra_AzHCI.ps1 (it skips the existing switch, NAT and DC) and 02_Cluster.ps1.

    Neither mode touches Azure resources or Active Directory objects.

.PARAMETER Mode
    All or NodeOnly. When omitted, the script asks.

.EXAMPLE
    .\99_Offboarding.ps1
    Shows the menu and asks what to remove.

.EXAMPLE
    .\99_Offboarding.ps1 -Mode NodeOnly
    Removes only the Azure Local node and keeps the domain controller.

.NOTES
    - Designed by Cristian Schmitt Nieto. For more information and usage, visit: https://schmitt-nieto.com/blog/azure-local-demolab/
    - Run this script with administrative privileges.
    - Ensure the Execution Policy allows the script to run. To set the execution policy, you can run:
      Set-ExecutionPolicy RemoteSigned -Scope CurrentUser
#>

param(
    [ValidateSet('All', 'NodeOnly')]
    [string]$Mode
)

#region Variables

# Load the lab configuration into this session if it has not been loaded yet.
# These values must match the ones used during deployment so teardown targets
# the right objects. Run scripts\01Lab\Set-LabEnv.ps1 once per session to set
# everything from scripts\01Lab\.env.
if ($env:AZSHCI_ENV_LOADED -ne '1') { & "$PSScriptRoot\Set-LabEnv.ps1" }

# Define VM Names
$HCIVMName = $env:AZSHCI_HCI_VM_NAME
$DCVMName = $env:AZSHCI_DC_VM_NAME

# Define Virtual Switch and NAT Configuration
$vSwitchName    = $env:AZSHCI_VSWITCH_NAME
$vSwitchNIC     = "vEthernet ($vSwitchName)"
$natName        = $env:AZSHCI_NAT_NAME
$vNetIPNetwork  = $env:AZSHCI_LAB_SUBNET

# Define Root Folder for VMs and Disks
$HCIRootFolder = $env:AZSHCI_LAB_ROOT_FOLDER
$HCIDiskFolder = Join-Path -Path $HCIRootFolder -ChildPath "Disk"
$HCIVMFolder   = Join-Path -Path $HCIRootFolder -ChildPath "VM"

# The S2D data disks created by 00_Infra_AzHCI.ps1 do not carry the VM name
$HCIExtraDiskPatterns = @("s2d*.vhdx")

$skipNetworking  = $false

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
}

# Returns $true when a path is inside the lab root folder (guards every file deletion)
function Test-InLabFolder {
    param ([string]$Path)
    $root = [System.IO.Path]::GetFullPath($HCIRootFolder).TrimEnd('\') + '\'
    return [System.IO.Path]::GetFullPath($Path).StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)
}

# Function to Remove VMs and Associated Resources
function Remove-VMResources {
    param (
        [string]$VMName,
        [string]$DiskFolder,
        [string]$VMFolder,
        [string[]]$ExtraDiskPatterns = @()
    )

    # Suppress non-critical outputs within the function
    $ErrorActionPreference = 'Stop'
    $WarningPreference = 'SilentlyContinue'
    $VerbosePreference = 'SilentlyContinue'
    $ProgressPreference = 'SilentlyContinue'

    # Stop and remove the VM if it exists
    $diskPaths = @()
    $vm = Get-VM -Name $VMName -ErrorAction SilentlyContinue
    if ($null -ne $vm) {
        # Record the attached disks before the VM is removed, so every one of them is deleted
        $diskPaths = @(Get-VMHardDiskDrive -VMName $VMName -ErrorAction SilentlyContinue | Where-Object { $_.Path } | ForEach-Object { $_.Path })

        if ($vm.State -in @('Running', 'Paused', 'Suspended')) {
            try {
                Stop-VM -Name $VMName -TurnOff -ErrorAction Stop | Out-Null
                Write-Message "VM '$VMName' stopped." -Type "Success"
            } catch {
                Write-Message "Failed to stop VM '$VMName'. Error: $_" -Type "Error"
                return
            }
        }

        # Remove the VM
        try {
            Remove-VM -Name $VMName -Force -ErrorAction Stop | Out-Null
            Write-Message "VM '$VMName' removed." -Type "Success"
        } catch {
            Write-Message "Failed to remove VM '$VMName'. Error: $_" -Type "Error"
            return
        }
    } else {
        Write-Message "VM '$VMName' does not exist. Checking for leftover disks and folders." -Type "Warning"
    }

    # Remove VHD files: the disks that were attached, plus files matching the lab naming convention
    $patterns = @("$VMName*.vhdx") + $ExtraDiskPatterns
    foreach ($pattern in $patterns) {
        $diskPaths += @(Get-ChildItem -Path $DiskFolder -Filter $pattern -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
    }
    foreach ($path in ($diskPaths | Sort-Object -Unique)) {
        if (-not (Test-InLabFolder $path)) {
            Write-Message "Disk '$path' is outside '$HCIRootFolder'. Not deleted; remove it manually if needed." -Type "Warning"
            continue
        }
        if (-not (Test-Path -LiteralPath $path)) { continue }
        try {
            Remove-Item -LiteralPath $path -Force -ErrorAction Stop | Out-Null
            Write-Message "VHD file '$path' deleted." -Type "Success"
        } catch {
            Write-Message "Failed to delete VHD file '$path'. Error: $_" -Type "Error"
        }
    }

    # Remove the VM folder created by New-VM -Path
    if ($VMFolder) {
        $vmPath = Join-Path -Path $VMFolder -ChildPath $VMName
        if ((Test-Path -LiteralPath $vmPath) -and (Test-InLabFolder $vmPath)) {
            try {
                Remove-Item -LiteralPath $vmPath -Recurse -Force -ErrorAction Stop | Out-Null
                Write-Message "VM folder '$vmPath' deleted." -Type "Success"
            } catch {
                Write-Message "Failed to delete VM folder '$vmPath'. Error: $_" -Type "Error"
            }
        }
    }

    # Remove HgsGuardian if it exists
    if (Get-HgsGuardian -Name $VMName -ErrorAction SilentlyContinue) {
        try {
            Remove-HgsGuardian -Name $VMName -ErrorAction Stop -WarningAction SilentlyContinue | Out-Null
            Write-Message "HgsGuardian '$VMName' removed." -Type "Success"
        } catch {
            Write-Message "Failed to remove HgsGuardian '$VMName'. Error: $_" -Type "Error"
        }
    }
}

#endregion

#region Mode Selection

if (-not $Mode) {
    Write-Host ""
    Write-Message "Select what to remove:" -Type "Info"
    Write-Message "  1  Everything  (VMs '$HCIVMName' and '$DCVMName', NAT, virtual switch, firewall rules and '$HCIRootFolder')" -Type "Info"
    Write-Message "  2  Node only   (VM '$HCIVMName' with its disks and folder; DC '$DCVMName', networking and the lab folder stay)" -Type "Info"
    Write-Message "  0  Cancel" -Type "Info"
    Write-Host ""

    do {
        $modeInput = Read-Host "Enter choice (0, 1 or 2)"
    } while ($modeInput -notin @("0","1","2"))

    if ($modeInput -eq "0") {
        Write-Message "Offboarding cancelled. Nothing was changed." -Type "Warning"
        return
    }
    $Mode = if ($modeInput -eq "1") { 'All' } else { 'NodeOnly' }
}

if ($Mode -eq 'NodeOnly' -and $HCIVMName -eq $DCVMName) {
    throw "The node and DC names are the same ('$HCIVMName'). Check AZSHCI_HCI_VM_NAME and AZSHCI_DC_VM_NAME in .env."
}

if ($Mode -eq 'All') {
    Write-Message "Mode: Everything selected." -Type "Success"
    $tasks = @(
        "Stopping and Removing HCI Node VM",
        "Stopping and Removing Domain Controller VM",
        "Removing NAT Configuration",
        "Removing IP Addresses from Virtual Switch Interface",
        "Removing Virtual Switch",
        "Removing Firewall Rules",
        "Removing Folder Structures"
    )
} else {
    Write-Message "Mode: Node only selected. '$DCVMName', networking and '$HCIRootFolder' are kept." -Type "Success"
    $tasks = @(
        "Stopping and Removing HCI Node VM"
    )
}
Write-Host ""

$totalTasks  = $tasks.Count
$currentTask = 0

#endregion

#region Script Execution

foreach ($task in $tasks) {
    $currentTask++
    Write-Progress -Activity "Cleaning Up Configurations" -Status "$task..." -PercentComplete (($currentTask / $totalTasks) * 100)

    switch ($task) {
        "Stopping and Removing HCI Node VM" {
            Remove-VMResources -VMName $HCIVMName -DiskFolder $HCIDiskFolder -VMFolder $HCIVMFolder -ExtraDiskPatterns $HCIExtraDiskPatterns
        }
        "Stopping and Removing Domain Controller VM" {
            Remove-VMResources -VMName $DCVMName -DiskFolder $HCIDiskFolder -VMFolder $HCIVMFolder
        }
        "Removing NAT Configuration" {
            # Check if the switch is still attached to any VM before touching networking
            $attachedVMs = @(
                Get-VM -ErrorAction SilentlyContinue | Where-Object {
                    (Get-VMNetworkAdapter -VMName $_.Name -ErrorAction SilentlyContinue).SwitchName -contains $vSwitchName
                }
            )
            if ($attachedVMs.Count -gt 0) {
                $vmNames = ($attachedVMs | Select-Object -ExpandProperty Name) -join ', '
                Write-Message "Virtual switch '$vSwitchName' is still in use by: $vmNames." -Type "Warning"
                Write-Message "NAT, IP addresses and virtual switch will not be removed. Stop or remove those VMs first." -Type "Warning"
                $skipNetworking = $true
            } else {
                $skipNetworking = $false
                Write-Message "Checking NAT configuration '$natName'..." -Type "Info"
                $nat = Get-NetNat -Name $natName -ErrorAction SilentlyContinue
                if ($null -eq $nat) {
                    Write-Message "NAT '$natName' does not exist. Skipping removal." -Type "Warning"
                } else {
                    try {
                        Remove-NetNat -Name $natName -Confirm:$false -ErrorAction Stop | Out-Null
                        Write-Message "NAT '$natName' removed." -Type "Success"
                    } catch {
                        Write-Message "Failed to remove NAT '$natName'. Error: $_" -Type "Error"
                    }
                }
            }
        }
        "Removing IP Addresses from Virtual Switch Interface" {
            if ($skipNetworking) {
                Write-Message "Skipping IP address removal (switch still in use)." -Type "Warning"
            } else {
                Write-Message "Removing IP addresses from interface '$vSwitchNIC'..." -Type "Info"
                try {
                    $ipAddresses = Get-NetIPAddress -InterfaceAlias $vSwitchNIC -ErrorAction Stop
                    foreach ($ip in $ipAddresses) {
                        try {
                            Remove-NetIPAddress -InterfaceAlias $vSwitchNIC -IPAddress $ip.IPAddress -Confirm:$false -ErrorAction Stop | Out-Null
                            Write-Message "IP address '$($ip.IPAddress)' removed from interface '$vSwitchNIC'." -Type "Success"
                        } catch {
                            Write-Message "Failed to remove IP address '$($ip.IPAddress)' from interface '$vSwitchNIC'. Error: $_" -Type "Error"
                        }
                    }
                } catch [System.Management.Automation.ItemNotFoundException] {
                    Write-Message "No IP addresses found on interface '$vSwitchNIC'. Skipping removal." -Type "Warning"
                } catch {
                    Write-Message "Failed to retrieve IP addresses from interface '$vSwitchNIC'. Error: $_" -Type "Error"
                }
            }
        }
        "Removing Virtual Switch" {
            if ($skipNetworking) {
                Write-Message "Skipping virtual switch removal (switch still in use)." -Type "Warning"
            } else {
                Write-Message "Checking virtual switch '$vSwitchName'..." -Type "Info"
                $switch = Get-VMSwitch -Name $vSwitchName -ErrorAction SilentlyContinue
                if ($null -eq $switch) {
                    Write-Message "Virtual switch '$vSwitchName' does not exist. Skipping removal." -Type "Warning"
                } else {
                    try {
                        Remove-VMSwitch -Name $vSwitchName -Force -ErrorAction Stop | Out-Null
                        Write-Message "Virtual switch '$vSwitchName' removed." -Type "Success"
                    } catch {
                        Write-Message "Failed to remove virtual switch '$vSwitchName'. Error: $_" -Type "Error"
                    }
                }
            }
        }
        "Removing Firewall Rules" {
            Write-Message "Removing ICMP firewall rules created by the lab setup..." -Type "Info"
            try {
                $ip, $cidr = $vNetIPNetwork -split '/'
                $bytes = ([System.Net.IPAddress]::Parse($ip)).GetAddressBytes()
                $bytes[3] += 1
                $gatewayIP = [System.Net.IPAddress]::new($bytes).ToString()

                # Current rule name (without interface alias)
                $ruleName    = "Allow-ICMPv4-$gatewayIP"
                # Legacy rule name (with interface alias, created before the fix)
                $legacyRuleName = "Allow-ICMPv4-$vSwitchNIC-$gatewayIP"

                foreach ($name in @($ruleName, $legacyRuleName)) {
                    $rule = Get-NetFirewallRule -DisplayName $name -ErrorAction SilentlyContinue
                    if ($null -ne $rule) {
                        Remove-NetFirewallRule -DisplayName $name -ErrorAction Stop | Out-Null
                        Write-Message "Firewall rule '$name' removed." -Type "Success"
                    } else {
                        Write-Message "Firewall rule '$name' does not exist. Skipping." -Type "Warning"
                    }
                }
            } catch {
                Write-Message "Failed to remove firewall rules. Error: $_" -Type "Error"
            }
        }
        "Removing Folder Structures" {
            Write-Message "Removing folder structures at '$HCIRootFolder'..." -Type "Info"
            if (Test-Path -Path $HCIRootFolder) {
                try {
                    Remove-Item -Path $HCIRootFolder -Recurse -Force -ErrorAction Stop | Out-Null
                    Write-Message "Folder '$HCIRootFolder' and all its contents have been deleted." -Type "Success"
                } catch {
                    Write-Message "Failed to delete folder '$HCIRootFolder'. Error: $_" -Type "Error"
                }
            } else {
                Write-Message "Folder '$HCIRootFolder' does not exist. Skipping removal." -Type "Warning"
            }
        }
    }
}

# Complete the Progress Bar
Write-Progress -Activity "Cleaning Up Configurations" -Completed -Status "All tasks completed."

if ($Mode -eq 'NodeOnly') {
    Write-Message "Node '$HCIVMName' removed. Kept: DC '$DCVMName', virtual switch '$vSwitchName', NAT '$natName', firewall rules and '$HCIRootFolder'." -Type "Success"
    Write-Message "Azure resources and the node's Active Directory and DNS records were not touched." -Type "Info"
    Write-Message "To redeploy the node, run 00_Infra_AzHCI.ps1 (it skips the existing switch, NAT and DC) and then 02_Cluster.ps1." -Type "Info"
} else {
    Write-Message "Cleanup completed successfully." -Type "Success"
}

#endregion
