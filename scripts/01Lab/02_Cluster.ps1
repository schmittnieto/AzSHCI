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
    - Designed by Cristian Schmitt Nieto. For more information and usage, visit: https://schmitt-nieto.com
    - Run this script with administrative privileges.
    - Ensure the Execution Policy allows the script to run. To set the execution policy, you can run:
      Set-ExecutionPolicy RemoteSigned -Scope CurrentUser
#>

#region Variables

# Credentials and User Configuration
$defaultUser = "Administrator"
$defaultPwd = "Start#1234"
$DefaultSecuredPassword = ConvertTo-SecureString $defaultPwd -AsPlainText -Force
$DefaultCredentials = New-Object System.Management.Automation.PSCredential ($defaultUser, $DefaultSecuredPassword)

$setupUser = "Setupuser"
$setupPwd = "dgemsc#utquMHDHp3M"
$SecuredSetupPassword = ConvertTo-SecureString $setupPwd -AsPlainText -Force
$SetupCredentials = New-Object System.Management.Automation.PSCredential ($setupUser, $SecuredSetupPassword)

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

# Sleep durations in seconds
$SleepRestart = 60    # Sleep after VM restart
$SleepFeatures = 90   # Sleep after feature installation and restart

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
        # Check if a key has been pressed
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

# Function to Allow Selection from a List
function Get-Option ($cmd, $filterproperty) {
    $items = @("")
    $selection = $null
    $filteredItems = @()
    $i = 0
    Invoke-Expression -Command $cmd | Sort-Object $filterproperty | ForEach-Object -Process {
        $items += "{0}. {1}" -f $i, $_.$filterproperty
        $i++
    }
    $filteredItems += $items | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    $filteredItems | Format-Wide { $_ } -Column 4 -Force | Out-Host
    do {
        $r = Read-Host "Select by number"
        if ($r -match '^\d+$' -and $r -lt $filteredItems.Count) {
            $selection = $filteredItems[$r] -split "\.\s" | Select-Object -Last 1
            Write-Host "Selecting $($filteredItems[$r])" -ForegroundColor Green
        } else {
            Write-Host "You must make a valid selection" -ForegroundColor Red
            $selection = $null
        }
    } until ($null -ne $selection)
    return $selection
}

# Function to Attempt Azure Login with Retries
function Connect-AzAccountWithRetry {
    param(
        [int]$MaxRetries = 3,
        [int]$DelaySeconds = 20  # Increased from 10 to 20 seconds
    )

    $attempt = 0
    while ($attempt -lt $MaxRetries) {
        try {
            Connect-AzAccount -UseDeviceAuthentication -ErrorAction Stop
            Write-Message "Successfully connected to Azure." -Type "Success"
            return
        } catch {
            $attempt++
            Write-Message "Azure login attempt $attempt failed. Retrying in $DelaySeconds seconds..." -Type "Warning"
            Start-Sleep -Seconds $DelaySeconds
        }
    }

    Write-Message "Failed to connect to Azure after $MaxRetries attempts." -Type "Error"
    exit 1
}

#endregion

#region Script Execution

# Total number of steps for progress calculation
$totalSteps = 8
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
        $ErrorActionPreference = 'Stop'
        $WarningPreference = 'SilentlyContinue'
        $VerbosePreference = 'SilentlyContinue'
        $ProgressPreference = 'SilentlyContinue'
        $InformationPreference = 'SilentlyContinue'

        # Suppress all non-essential outputs
        Try {
            # Create local user
            New-LocalUser -Name $setupUser -Password (ConvertTo-SecureString $setupPwd -AsPlainText -Force) -FullName $setupUser -Description "Setup user" -ErrorAction Stop | Out-Null
            Write-Host "User $setupUser created successfully." -ForegroundColor Green | Out-Null

            # Add user to Administrators group
            Add-LocalGroupMember -Group "Administrators" -Member $setupUser -ErrorAction Stop | Out-Null
            Write-Host "User $setupUser added to Administrators group." -ForegroundColor Green | Out-Null
        } Catch {
            Write-Host "Error occurred: $_" -ForegroundColor Red | Out-Null
            throw $_
        }

        # Rename computer
        Rename-Computer -NewName $nodeName -Force -ErrorAction Stop | Out-Null

        # Restart computer
        Restart-Computer -Force -ErrorAction Stop | Out-Null
    } -ArgumentList $setupUser, $setupPwd, $nodeName -ErrorAction Stop -WarningAction SilentlyContinue -Verbose:$false | Out-Null
    Write-Message "Setup user created and VM '$nodeName' is restarting..." -Type "Success"
    Start-SleepWithProgress -Seconds $SleepRestart -Activity "Restarting VM" -Status "Waiting for VM to restart" # 20 Seconds
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
    Write-Message "Failed to retrieve or format MAC addresses for VM '$nodeName'. Error: $_" -Type "Error"
    exit 1
}

# Step 4: Configure Network Settings
$currentStep++
Update-ProgressBar -CurrentStep $currentStep -TotalSteps $totalSteps -StatusMessage "Configuring network settings..."
Write-Message "Configuring network settings for VM '$nodeName'..." -Type "Info"
try {
    Invoke-Command -VMName $nodeName -Credential $SetupCredentials -ScriptBlock {
        param($NIC1, $NIC2, $nodeMacNIC1Address, $nodeMacNIC2Address, $nic1IP, $nic1GW, $nic1DNS)
        $ErrorActionPreference = 'Stop'
        $WarningPreference = 'SilentlyContinue'
        $VerbosePreference = 'SilentlyContinue'
        $ProgressPreference = 'SilentlyContinue'
        $InformationPreference = 'SilentlyContinue'

        # Suppress all non-essential outputs

        # Rename network adapters based on MAC addresses
        Get-NetAdapter -Physical | Where-Object { $_.MacAddress -eq $nodeMacNIC1Address } | Rename-NetAdapter -NewName $NIC1 -ErrorAction Stop | Out-Null
        Get-NetAdapter -Physical | Where-Object { $_.MacAddress -eq $nodeMacNIC2Address } | Rename-NetAdapter -NewName $NIC2 -ErrorAction Stop | Out-Null

        # Disable DHCP and enable RDMA on both NICs
        foreach ($nic in @($NIC1, $NIC2)) {
            Set-NetIPInterface -InterfaceAlias $nic -Dhcp Disabled -ErrorAction Stop | Out-Null
            Enable-NetAdapterRdma -Name $nic -ErrorAction Stop | Out-Null
        }

        # Configure static IP on NIC1
        New-NetIPAddress -InterfaceAlias $NIC1 -IPAddress $nic1IP -PrefixLength 24 -AddressFamily IPv4 -DefaultGateway $nic1GW -ErrorAction Stop | Out-Null
        Set-DnsClientServerAddress -InterfaceAlias $NIC1 -ServerAddresses $nic1DNS -ErrorAction Stop | Out-Null

        # Configure time synchronization
        w32tm /config /manualpeerlist:$nic1DNS /syncfromflags:manual /update | Out-Null
        Restart-Service w32time -Force | Out-Null
        w32tm /resync | Out-Null

        Write-Host "Network settings configured successfully." -ForegroundColor Green | Out-Null
    } -ArgumentList $NIC1, $NIC2, $nodeMacNIC1Address, $nodeMacNIC2Address, $nic1IP, $nic1GW, $nic1DNS -ErrorAction Stop -WarningAction SilentlyContinue -Verbose:$false | Out-Null
    Write-Message "Network settings configured successfully for VM '$nodeName'." -Type "Success"
} catch {
    Write-Message "Failed to configure network settings for VM '$nodeName'. Error: $_" -Type "Error"
    exit 1
}

# Step 5: Install required Windows Features
$currentStep++
Update-ProgressBar -CurrentStep $currentStep -TotalSteps $totalSteps -StatusMessage "Installing required Windows features..."
Write-Message "Installing required Windows features on VM '$nodeName'..." -Type "Info"
try {
    Invoke-Command -VMName $nodeName -Credential $SetupCredentials -ScriptBlock {
        $ErrorActionPreference = 'Stop'
        $WarningPreference = 'SilentlyContinue'
        $VerbosePreference = 'SilentlyContinue'
        $ProgressPreference = 'SilentlyContinue'
        $InformationPreference = 'SilentlyContinue'

        # Suppress all non-essential outputs

        # Enable Hyper-V
        Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V -All -NoRestart -ErrorAction Stop | Out-Null

        # Install additional features
        Install-WindowsFeature -Name Hyper-V, Failover-Clustering, Data-Center-Bridging, BitLocker, FS-FileServer, RSAT-Clustering-PowerShell, FS-Data-Deduplication -IncludeAllSubFeature -IncludeManagementTools -ErrorAction Stop | Out-Null

        # Restart to apply changes
        Restart-Computer -Force -ErrorAction Stop | Out-Null
    } -ErrorAction Stop -WarningAction SilentlyContinue -Verbose:$false | Out-Null
    Write-Message "Required Windows features installed and VM '$nodeName' is restarting..." -Type "Success"
    Start-SleepWithProgress -Seconds $SleepFeatures -Activity "Restarting VM" -Status "Waiting for VM to restart" # 40 Seconds
} catch {
    Write-Message "Failed to install Windows features on VM '$nodeName'. Error: $_" -Type "Error"
    exit 1
}

# Step 6: Register PSGallery as a trusted repository on the node
$currentStep++
Update-ProgressBar -CurrentStep $currentStep -TotalSteps $totalSteps -StatusMessage "Registering PSGallery on VM..."
Write-Message "Registering PSGallery as a trusted repository on VM '$nodeName'..." -Type "Info"
try {
    Invoke-Command -VMName $nodeName -Credential $SetupCredentials -ScriptBlock {
        param($NIC1)

        $ErrorActionPreference = 'Stop'
        $WarningPreference = 'SilentlyContinue'
        $VerbosePreference = 'SilentlyContinue'
        $ProgressPreference = 'SilentlyContinue'
        $InformationPreference = 'SilentlyContinue'

        # Suppress all non-essential outputs

        if (-not (Get-PSRepository -Name "PSGallery" -ErrorAction SilentlyContinue)) {
            Register-PSRepository -Default -ErrorAction Stop | Out-Null
        }
        Set-PSRepository -Name "PSGallery" -InstallationPolicy Trusted -ErrorAction Stop | Out-Null
        Write-Host "PSGallery registered as a trusted repository." -ForegroundColor Green | Out-Null
    } -ArgumentList $NIC1 -ErrorAction Stop -WarningAction SilentlyContinue -Verbose:$false | Out-Null
    Write-Message "PSGallery registered successfully on VM '$nodeName'." -Type "Success"
} catch {
    Write-Message "Failed to register PSGallery on VM '$nodeName'. Error: $_" -Type "Error"
    exit 1
}

# Step 7: Install required PowerShell modules on the node for Azure Arc registration
$currentStep++
Update-ProgressBar -CurrentStep $currentStep -TotalSteps $totalSteps -StatusMessage "Installing required PowerShell modules..."
Write-Message "Installing required PowerShell modules on VM '$nodeName'..." -Type "Info"
try {
    Invoke-Command -VMName $nodeName -Credential $SetupCredentials -ScriptBlock {
        param($NIC1)

        $ErrorActionPreference = 'Stop'
        $WarningPreference = 'SilentlyContinue'
        $VerbosePreference = 'SilentlyContinue'
        $ProgressPreference = 'SilentlyContinue'
        $InformationPreference = 'SilentlyContinue'

        # Suppress all non-essential outputs

        # Install required modules
        Install-Module Az.Accounts -RequiredVersion 3.0.0 -Force -ErrorAction Stop | Out-Null
        Install-Module Az.Resources -RequiredVersion 6.12.0 -Force -ErrorAction Stop | Out-Null
        Install-Module Az.ConnectedMachine -RequiredVersion 0.8.0 -Force -ErrorAction Stop | Out-Null
        Install-Module AzsHCI.ArcInstaller -Force -ErrorAction Stop | Out-Null

        Write-Host "Required PowerShell modules installed successfully." -ForegroundColor Green | Out-Null
    } -ErrorAction Stop -WarningAction SilentlyContinue -Verbose:$false | Out-Null
    Write-Message "PowerShell modules installed successfully on VM '$nodeName'." -Type "Success"
} catch {
    Write-Message "Failed to install PowerShell modules on VM '$nodeName'. Error: $_" -Type "Error"
    exit 1
}

# Step 8: Invoke Azure Stack HCI Arc Initialization on the node
$currentStep++
Update-ProgressBar -CurrentStep $currentStep -TotalSteps $totalSteps -StatusMessage "Registering node with Azure Arc..."
Write-Message "Registering VM '$nodeName' with Azure Arc..." -Type "Info"

try {
    # Connect to Azure and set context
    Connect-AzAccountWithRetry -MaxRetries 5 -DelaySeconds 20  # Increased DelaySeconds to 20

    # Allow user to select Subscription
    $subscription = Get-Option "Get-AzSubscription" "Name"
    Set-AzContext -SubscriptionName $subscription -ErrorAction Stop

    # Allow user to select Resource Group
    $resourceGroup = Get-Option "Get-AzResourceGroup" "ResourceGroupName"

    $TenantID = (Get-AzContext).Tenant.Id
    $SubscriptionID = (Get-AzContext).Subscription.Id
    $ARMToken = (Get-AzAccessToken).Token
    $AccountId = (Get-AzContext).Account.Id

    # Prepare the script to run on the node
    $ArcInitScript = @'
param($SubscriptionID, $ResourceGroupName, $TenantID, $Cloud, $Location, $ARMToken, $AccountId)

# Import modules
Import-Module Az.Accounts -RequiredVersion 3.0.0 -ErrorAction Stop
Import-Module Az.Resources -RequiredVersion 6.12.0 -ErrorAction Stop
Import-Module Az.ConnectedMachine -RequiredVersion 0.8.0 -ErrorAction Stop
Import-Module AzsHCI.ArcInstaller -ErrorAction Stop

# Suppress all non-essential outputs
$ErrorActionPreference = 'Stop'
$WarningPreference = 'SilentlyContinue'
$VerbosePreference = 'SilentlyContinue'
$InformationPreference = 'SilentlyContinue'

# Invoke Arc Initialization
Invoke-AzStackHciArcInitialization -SubscriptionID $SubscriptionID `
                                   -ResourceGroup $ResourceGroupName `
                                   -TenantID $TenantID `
                                   -Cloud $Cloud `
                                   -Region $Location `
                                   -ArmAccessToken $ARMToken `
                                   -AccountID $AccountId -ErrorAction Stop | Out-Null

Write-Host "VM '$env:COMPUTERNAME' registered with Azure Arc successfully." -ForegroundColor Green | Out-Null
'@

    # Copy the script to the node
    $ScriptPath = "C:\Temp\ArcInitScript.ps1"
    Invoke-Command -VMName $nodeName -Credential $SetupCredentials -ScriptBlock {
        param($ScriptContent, $ScriptPath)
        $ErrorActionPreference = 'Stop'
        $WarningPreference = 'SilentlyContinue'
        $VerbosePreference = 'SilentlyContinue'
        $ProgressPreference = 'SilentlyContinue'
        $InformationPreference = 'SilentlyContinue'

        # Suppress all non-essential outputs

        New-Item -Path (Split-Path $ScriptPath) -ItemType Directory -Force | Out-Null
        Set-Content -Path $ScriptPath -Value $ScriptContent -Force | Out-Null
    } -ArgumentList $ArcInitScript, $ScriptPath -ErrorAction Stop -WarningAction SilentlyContinue -Verbose:$false | Out-Null

    # Run the script locally on the node
    Invoke-Command -VMName $nodeName -Credential $SetupCredentials -ScriptBlock {
        param($ScriptPath, $SubscriptionID, $ResourceGroupName, $TenantID, $Cloud, $Location, $ARMToken, $AccountId)
        $ErrorActionPreference = 'Stop'
        $WarningPreference = 'SilentlyContinue'
        $VerbosePreference = 'SilentlyContinue'
        $ProgressPreference = 'SilentlyContinue'
        $InformationPreference = 'SilentlyContinue'

        # Suppress all non-essential outputs

        # Execute the script locally
        & $ScriptPath -SubscriptionID $SubscriptionID -ResourceGroupName $ResourceGroupName -TenantID $TenantID -Cloud $Cloud -Location $Location -ARMToken $ARMToken -AccountId $AccountId | Out-Null
    } -ArgumentList $ScriptPath, $SubscriptionID, $resourceGroup, $TenantID, $Cloud, $Location, $ARMToken, $AccountId -ErrorAction Stop -WarningAction SilentlyContinue -Verbose:$false | Out-Null

    # Write-Message "VM '$nodeName' registered successfully with Azure Arc." -Type "Success"
} catch {
    Write-Message "Failed to register VM '$nodeName' with Azure Arc. Error: $_" -Type "Error"
    exit 1
}

# Complete the overall progress bar
Update-ProgressBar -CurrentStep $totalSteps -TotalSteps $totalSteps -StatusMessage "All tasks completed."

# Write-Host "Cluster node configuration completed successfully." -ForegroundColor Green
Write-Message "Cluster node configuration completed successfully." -Type "Success"

#endregion
