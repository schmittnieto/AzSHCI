# Offboarding Script to Clean Up Configurations

<#
.SYNOPSIS
    Cleans up VM configurations, virtual switches, NAT settings, and associated folders.

.DESCRIPTION
    This script performs the following tasks:
    - Stops and removes specified VMs.
    - Deletes associated VHD files.
    - Removes HgsGuardian entries.
    - Deletes virtual switches and NAT configurations.
    - Removes designated folder structures.

.NOTES
    - Designed by Cristian Schmitt Nieto. For more information and usage, visit: https://schmitt-nieto.com
    - Run this script with administrative privileges.
    - Ensure the Execution Policy allows the script to run. To set the execution policy, you can run:
      Set-ExecutionPolicy RemoteSigned -Scope CurrentUser
#>

#region Variables

# Define VM Names
$HCIVMName = "NODE"
$DCVMName = "DC"

# Define Virtual Switch and NAT Configuration
$vSwitchName = "azurestackhci"
$vSwitchNIC = "vEthernet ($vSwitchName)"
$natName = "azurestackhci"

# Define Root Folder for VMs and Disks
$HCIRootFolder = "C:\HCI"
$HCIDiskFolder = Join-Path -Path $HCIRootFolder -ChildPath "Disk"

# Define Tasks for Progress Bar
$tasks = @(
    "Stopping and Removing HCI Node VM",
    "Stopping and Removing Domain Controller VM",
    "Removing NAT Configuration",
    "Removing IP Addresses from Virtual Switch Interface",
    "Removing Virtual Switch",
    "Removing Folder Structures"
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
}

# Function to Remove VMs and Associated Resources
function Remove-VMResources {
    param (
        [string]$VMName,
        [string]$DiskFolder
    )

    # Suppress non-critical outputs within the function
    $ErrorActionPreference = 'Stop'
    $WarningPreference = 'SilentlyContinue'
    $VerbosePreference = 'SilentlyContinue'
    $ProgressPreference = 'SilentlyContinue'

    # Stop and remove the VM if it exists
    $vm = Get-VM -Name $VMName -ErrorAction SilentlyContinue
    if ($null -ne $vm) {
        if ($vm.State -in @('Running', 'Paused', 'Suspended')) {
            try {
                Stop-VM -Name $VMName -Force -ErrorAction Stop | Out-Null
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

        # Remove VHD files
        $vhdFiles = Get-ChildItem -Path $DiskFolder -Filter "$VMName*.vhdx" -Recurse -ErrorAction SilentlyContinue
        foreach ($vhd in $vhdFiles) {
            try {
                Remove-Item -Path $vhd.FullName -Force -ErrorAction Stop | Out-Null
                Write-Message "VHD file '$($vhd.FullName)' deleted." -Type "Success"
            } catch {
                Write-Message "Failed to delete VHD file '$($vhd.FullName)'. Error: $_" -Type "Error"
            }
        }

        # Remove HgsGuardian if it exists
        try {
            Remove-HgsGuardian -Name $VMName -ErrorAction SilentlyContinue -WarningAction SilentlyContinue | Out-Null
            Write-Message "HgsGuardian '$VMName' removed." -Type "Success"
        } catch {
            Write-Message "Failed to remove HgsGuardian '$VMName'. Error: $_" -Type "Error"
        }
    } else {
        Write-Message "VM '$VMName' does not exist. Skipping removal." -Type "Warning"
    }

    # Reset preferences to default
    $ErrorActionPreference = 'Continue'
    $WarningPreference = 'Continue'
    $VerbosePreference = 'Continue'
    $ProgressPreference = 'Continue'
}

#endregion

#region Script Execution

foreach ($task in $tasks) {
    $currentTask++
    Write-Progress -Activity "Cleaning Up Configurations" -Status "$task..." -PercentComplete (($currentTask / $totalTasks) * 100)

    switch ($task) {
        "Stopping and Removing HCI Node VM" {
            Remove-VMResources -VMName $HCIVMName -DiskFolder $HCIDiskFolder
        }
        "Stopping and Removing Domain Controller VM" {
            Remove-VMResources -VMName $DCVMName -DiskFolder $HCIDiskFolder
        }
        "Removing NAT Configuration" {
            Write-Message "Removing NAT configuration '$natName'..." -Type "Info"
            try {
                Remove-NetNat -Name $natName -Confirm:$false -ErrorAction Stop | Out-Null
                Write-Message "NAT '$natName' removed." -Type "Success"
            } catch [System.Management.Automation.ItemNotFoundException] {
                Write-Message "NAT '$natName' does not exist. Skipping removal." -Type "Warning"
            } catch {
                Write-Message "Failed to remove NAT '$natName'. Error: $_" -Type "Error"
            }
        }
        "Removing IP Addresses from Virtual Switch Interface" {
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
        "Removing Virtual Switch" {
            Write-Message "Removing virtual switch '$vSwitchName'..." -Type "Info"
            try {
                Remove-VMSwitch -Name $vSwitchName -Force -ErrorAction Stop | Out-Null
                Write-Message "Virtual switch '$vSwitchName' removed." -Type "Success"
            } catch [System.Management.Automation.ItemNotFoundException] {
                Write-Message "Virtual switch '$vSwitchName' does not exist. Skipping removal." -Type "Warning"
            } catch {
                Write-Message "Failed to remove virtual switch '$vSwitchName'. Error: $_" -Type "Error"
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

Write-Message "Cleanup completed successfully." -Type "Success"

#endregion
