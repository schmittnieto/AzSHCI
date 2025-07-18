# 02_Cluster.ps1
# Cluster Node Creation Script

<#
.SYNOPSIS
    Configures the cluster node VM, sets up network settings, installs required features, and registers the node with Azure Arc.

.DESCRIPTION
    This script performs the following tasks:
    - Sets up credentials and network configurations.
    - Removes the ISO from the node VM.
    - Renames the node VM.
    - Configures network adapters with static IP settings.
    - Installs required Windows features.
    - Registers the node with Azure Arc.

.NOTES
    - Designed by Cristian Schmitt Nieto. For more information and usage, visit: https://schmitt-nieto.com/blog/azure-stack-hci-demolab/
    - Run this script with administrative privileges.
    - Ensure the Execution Policy allows the script to run. To set the execution policy, you can run:
      Set-ExecutionPolicy RemoteSigned -Scope CurrentUser
    - Updates:
        - 2024/11/28: Changing Module Versions and ISO for 2411
        - 2025/07/01: Update the scripts for version 2505
        - 2025/07/03: Update the scripts for version 2506
#>

#region Variables

# Credentials and User Configuration
$defaultUser = "Administrator"
$defaultPwd = "Start#1234"
$DefaultSecuredPassword = ConvertTo-SecureString $defaultPwd -AsPlainText -Force
$DefaultCredentials = New-Object System.Management.Automation.PSCredential ($defaultUser, $DefaultSecuredPassword)

$setupUser = "Setupuser"
$setupPwd = "dgemsc#utquMHDHp3M"

# Node Configuration
$nodeName = "NODE"
$NIC1 = "MGMT1"
$NIC2 = "MGMT2"
$nic1IP = "172.19.19.10"
$nic1GW = "172.19.19.1"
$nic1DNS = "172.19.19.2"

# Azure Configuration
$Location = "westeurope"
$Cloud = "AzureCloud"
$SubscriptionID = "000000-00000-000000-00000-0000000"  # Replace with your actual Subscription ID
$resourceGroupName = "YourResourceGroupName"  # Replace with your actual Resource Group Name

# Sleep durations in seconds
$SleepRestart = 60    # Sleep after VM restart
$SleepFeatures = 60   # Sleep after feature installation and restart
$SleepModules = 60    # Sleep after module installation

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

# Function to Format MAC Addresses
function Format-MacAddress {
    param (
        [string]$mac
    )
    return $mac.Insert(2,"-").Insert(5,"-").Insert(8,"-").Insert(11,"-").Insert(14,"-").ToUpper()
}

# Function to Update Progress Bar (Main Progress)
function Update-ProgressBar {
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
        if ([Console]::KeyAvailable) {
            $key = [Console]::ReadKey($true)
            if ($key.Key -eq 'Spacebar') {
                Write-Message "Sleep skipped by user." -Type "Warning"
                break
            }
        }

        $percent = [math]::Round(($i / $Seconds) * 100)
        Write-Progress -Id 2 -Activity "Sleep Progress" -Status "$Activity : $i/$Seconds seconds elapsed... Use Spacebar to Break" -PercentComplete $percent
        Start-Sleep -Seconds 1
    }

    Write-Progress -Id 2 -Activity "Sleep Progress" -Completed
    Write-Message "$Activity : Completed." -Type "Success"
} 

#endregion

#region Script Execution

# Total number of steps for progress calculation
$totalSteps = 5
$currentStep = 0

# Step 1: Remove ISO from VM
$currentStep++
Update-ProgressBar -CurrentStep $currentStep -TotalSteps $totalSteps -StatusMessage "Removing ISO from VM..."
Write-Message "Removing ISO from VM '$nodeName'..." -Type "Info"
try {
    Get-VMDvdDrive -VMName $nodeName | Where-Object { $_.DvdMediaType -eq "ISO" } | Remove-VMDvdDrive -ErrorAction Stop -WarningAction SilentlyContinue | Out-Null
    Write-Message "ISO removed from VM '$nodeName'." -Type "Success"
} catch {
    Write-Message "Failed to remove ISO from VM '$nodeName'. Error: $_" -Type "Error"
    exit 1
}

# Step 2: Create setup user and rename the node
$currentStep++
Update-ProgressBar -CurrentStep $currentStep -TotalSteps $totalSteps -StatusMessage "Creating setup user and renaming VM..."
Write-Message "Creating setup user and renaming VM '$nodeName'..." -Type "Info"
try {
    Invoke-Command -VMName $nodeName -Credential $DefaultCredentials -ScriptBlock {
        param($setupUser, $setupPwd, $nodeName)
        $ErrorActionPreference = 'Stop'; $WarningPreference = 'SilentlyContinue'; $VerbosePreference = 'SilentlyContinue'; $ProgressPreference = 'SilentlyContinue'; $InformationPreference = 'SilentlyContinue'
        Try {
            New-LocalUser -Name $setupUser -Password (ConvertTo-SecureString $setupPwd -AsPlainText -Force) -FullName $setupUser -Description "Setup user" -ErrorAction Stop | Out-Null
            Write-Host "User $setupUser created." -ForegroundColor Green | Out-Null
            Add-LocalGroupMember -Group "Administrators" -Member $setupUser -ErrorAction Stop | Out-Null
            Write-Host "User $setupUser added to Administrators." -ForegroundColor Green | Out-Null
        } Catch {
            Write-Host "Error occurred: $_" -ForegroundColor Red | Out-Null; throw $_
        }
        Rename-Computer -NewName $nodeName -Force -ErrorAction Stop | Out-Null
        Restart-Computer -ErrorAction Stop | Out-Null
    } -ArgumentList $setupUser, $setupPwd, $nodeName -ErrorAction Stop -WarningAction SilentlyContinue | Out-Null
    Write-Message "Setup user created and VM '$nodeName' is restarting..." -Type "Success"
    Start-SleepWithProgress -Seconds $SleepRestart -Activity "Restarting VM" -Status "Waiting for VM to restart"
} catch {
    Write-Message "Failed to create setup user or rename VM '$nodeName'. Error: $_" -Type "Error"
    exit 1
}

# Step 3: Retrieve and format MAC addresses of network adapters
$currentStep++
Update-ProgressBar -CurrentStep $currentStep -TotalSteps $totalSteps -StatusMessage "Retrieving and formatting MAC addresses..."
Write-Message "Retrieving and formatting MAC addresses for VM '$nodeName'..." -Type "Info"
try {
    $nodeMacNIC1 = Get-VMNetworkAdapter -VMName $nodeName -Name $NIC1 -ErrorAction Stop
    $nodeMacNIC1Address = Format-MacAddress $nodeMacNIC1.MacAddress
    $nodeMacNIC2 = Get-VMNetworkAdapter -VMName $nodeName -Name $NIC2 -ErrorAction Stop
    $nodeMacNIC2Address = Format-MacAddress $nodeMacNIC2.MacAddress
    Write-Message "MAC addresses formatted successfully." -Type "Success"
} catch {
    Write-Message "Failed to retrieve or format MAC addresses. Error: $_" -Type "Error"
    exit 1
}

# Step 4: Configure Network Settings
$currentStep++
Update-ProgressBar -CurrentStep $currentStep -TotalSteps $totalSteps -StatusMessage "Configuring network settings..."
Write-Message "Configuring network settings for VM '$nodeName'..." -Type "Info"
try {
    Invoke-Command -VMName $nodeName -Credential $DefaultCredentials -ScriptBlock {
        param($NIC1, $NIC2, $nodeMacNIC1Address, $nodeMacNIC2Address, $nic1IP, $nic1GW, $nic1DNS)
        $ErrorActionPreference = 'Stop'; $WarningPreference = 'SilentlyContinue'; $VerbosePreference = 'SilentlyContinue'; $ProgressPreference = 'SilentlyContinue'; $InformationPreference = 'SilentlyContinue'
        Get-NetAdapter -Physical | Where-Object { $_.MacAddress -eq $nodeMacNIC1Address } | Rename-NetAdapter -NewName $NIC1 -ErrorAction Stop | Out-Null
        Get-NetAdapter -Physical | Where-Object { $_.MacAddress -eq $nodeMacNIC2Address } | Rename-NetAdapter -NewName $NIC2 -ErrorAction Stop | Out-Null
        foreach ($nic in @($NIC1, $NIC2)) {
            Set-NetIPInterface -InterfaceAlias $nic -Dhcp Disabled -ErrorAction Stop | Out-Null
            Enable-NetAdapterRdma -Name $nic -ErrorAction Stop | Out-Null
        }
        New-NetIPAddress -InterfaceAlias $NIC1 -IPAddress $nic1IP -PrefixLength 24 -DefaultGateway $nic1GW -ErrorAction Stop | Out-Null
        Set-DnsClientServerAddress -InterfaceAlias $NIC1 -ServerAddresses $nic1DNS -ErrorAction Stop | Out-Null
        w32tm /config /manualpeerlist:$nic1DNS /syncfromflags:manual /update | Out-Null
        Restart-Service w32time -Force | Out-Null
        w32tm /resync | Out-Null
        Set-TimeZone -Id "UTC"
        Write-Host "Network settings configured." -ForegroundColor Green | Out-Null
        Restart-Computer -ErrorAction Stop | Out-Null
    } -ArgumentList $NIC1, $NIC2, $nodeMacNIC1Address, $nodeMacNIC2Address, $nic1IP, $nic1GW, $nic1DNS -ErrorAction Stop | Out-Null
    Write-Message "VM '$nodeName' is restarting..." -Type "Success"
    Start-SleepWithProgress -Seconds $SleepFeatures -Activity "Restarting VM" -Status "Waiting for VM to restart"
    Write-Message "Network settings configured successfully for VM '$nodeName'." -Type "Success"
} catch {
    Write-Message "Failed to configure network settings for VM '$nodeName'. Error: $_" -Type "Error"
    exit 1
}

# Step 5: Invoke Azure Local Arc Initialization on the node
$currentStep++
Update-ProgressBar -CurrentStep $currentStep -TotalSteps $totalSteps -StatusMessage "Registering node with Azure Arc..."
Write-Message "Registering VM '$nodeName' with Azure Arc..." -Type "Info"
try {
    Start-SleepWithProgress -Seconds $SleepModules -Activity "Waiting for PowerShell Modules" -Status "Preparing to register"
    Invoke-Command -VMName $nodeName -Credential $DefaultCredentials -ScriptBlock {
        param($Cloud, $Location, $SubscriptionID, $resourceGroupName)

        <# Install required modules
        $requiredModules = @("Az.Accounts")        
        foreach ($module in $requiredModules) {
            if (-not (Get-Module -Name $module -ListAvailable)) {
                Write-Host "Installing module: $module 4.0.2" -ForegroundColor Cyan
                Install-Module -Name $module -RequiredVersion 4.0.2 -Force -ErrorAction Stop | Out-Null
              } else {
                Write-Host "Module $module is already installed." -ForegroundColor Green
            }
        }
        #>
        # Connect and select resource group
        Start-Sleep -Seconds 2
        Connect-AzAccount -UseDeviceAuthentication -Subscription $SubscriptionID -ErrorAction Stop
        Start-Sleep -Seconds 1
        $TenantID = (Get-AzContext).Tenant.Id
        $SubscriptionID = (Get-AzContext).Subscription.Id
        $ARMToken = (Get-AzAccessToken).Token
        $AccountId = (Get-AzContext).Account.Id
        Start-Sleep -Seconds 10
        
        $task = Get-ScheduledTask -TaskName ImageCustomizationScheduledTask
        if ($task.State -eq 'Ready') {
            Start-ScheduledTask -InputObject $task
            Write-Host "ImageCustomizationScheduledTask was in 'Ready' state and has been started." -ForegroundColor Cyan
        } else {
            Write-Host "ImageCustomizationScheduledTask is not in 'Ready' state (current state: $($task.State)). Skipping start." -ForegroundColor Yellow
        }
        # Ensure the Azure Arc module is available
        Start-Sleep -Seconds 40
        # Invoke Arc initialization
        Invoke-AzStackHciArcInitialization -SubscriptionID $SubscriptionID `
                                           -ResourceGroup $resourceGroupName `
                                           -TenantID $TenantID `
                                           -Cloud $Cloud `
                                           -Region $Location `
                                           -ArmAccessToken $ARMToken `
                                           -AccountID $AccountId -ErrorAction Stop | Out-Null

        Write-Host "VM '$env:COMPUTERNAME' registered with Azure Arc successfully." -ForegroundColor Green
    } -ArgumentList $Cloud, $Location, $SubscriptionID, $resourceGroupName -ErrorAction Stop
} catch {
    Write-Message "Version 2506 it´s a false postive error message: Failed to register VM '$nodeName' with Azure Arc. Error: $_" -Type "Error"
    exit 1
}

# Complete the overall progress bar
Update-ProgressBar -CurrentStep $totalSteps -TotalSteps $totalSteps -StatusMessage "All tasks completed."
Write-Message "Cluster node configuration completed successfully." -Type "Success"

#endregion
