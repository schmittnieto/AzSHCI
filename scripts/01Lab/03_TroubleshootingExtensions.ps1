# 03_TroubleshootingExtensions.ps1
# Troubleshooting Azure Connected Machine Extensions for ARC VMs

<#
.SYNOPSIS
    Troubleshoots and manages Azure Connected Machine extensions for ARC VMs.

.DESCRIPTION
    This script performs the following tasks:
    - Installs the Az.Compute and Az.StackHCI modules if not already installed.
    - Connects to Azure using device code authentication and allows the user to select a Subscription and Resource Group.
    - Retrieves ARC VMs from Azure using Az.StackHCI, filtering for ARC Machines with CloudMetadataProvider "AzSHCI".
    - Validates that required Azure Connected Machine extensions are installed.
    - Fixes any failed extensions by removing locks, deleting, and reinstalling them.
    - Adds any missing extensions based on a predefined list.

.NOTES
    - Designed by Cristian Schmitt Nieto. For more information and usage, visit: https://schmitt-nieto.com
    - Run this script with administrative privileges.
    - Ensure the Execution Policy allows the script to run. To set the execution policy, you can run:
      Set-ExecutionPolicy RemoteSigned -Scope CurrentUser
#>

#region Variables

# Extension Settings
$Location = "westeurope"

$Settings = @{ 
    "CloudName" = "AzureCloud"; 
    "RegionName" = $Location; 
    "DeviceType" = "AzureEdge" 
}

$ExtensionList = @(
    @{ Name = "AzureEdgeTelemetryAndDiagnostics"; Publisher = "Microsoft.AzureStack.Observability"; MachineExtensionType = "TelemetryAndDiagnostics" },
    @{ Name = "AzureEdgeDeviceManagement"; Publisher = "Microsoft.Edge"; MachineExtensionType = "DeviceManagementExtension" },
    @{ Name = "AzureEdgeLifecycleManager"; Publisher = "Microsoft.AzureStack.Orchestration"; MachineExtensionType = "LcmController" },
    @{ Name = "AzureEdgeRemoteSupport"; Publisher = "Microsoft.AzureStack.Observability"; MachineExtensionType = "EdgeRemoteSupport" }
)

# Total number of steps for progress calculation
$totalSteps = 9
$currentStep = 0

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
    # Uncomment and configure the following lines to enable logging
    # $LogFile = "C:\Path\To\Your\LogFile.txt"
    # Add-Content -Path $LogFile -Value "$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss')) [$Type] $Message"
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

# Function to Install Az.Compute Module if Not Installed
function Install-AzComputeModule {
    if (-not (Get-Module -ListAvailable -Name Az.Compute)) {
        Write-Message "Az.Compute module not found. Installing..." -Type "Info"
        try {
            Install-Module -Name Az.Compute -Repository PSGallery -Force -AllowClobber -ErrorAction Stop
            Write-Message "Az.Compute module installed successfully." -Type "Success"
        } catch {
            Write-Message "Failed to install Az.Compute module. Error: $_" -Type "Error"
            exit 1
        }
    } else {
        Write-Message "Az.Compute module is already installed." -Type "Info"
    }
}

# Function to Install Az.StackHCI Module if Not Installed
function Install-AzStackHCIModule {
    if (-not (Get-Module -ListAvailable -Name Az.StackHCI)) {
        Write-Message "Az.StackHCI module not found. Installing..." -Type "Info"
        try {
            Install-Module -Name Az.StackHCI -Repository PSGallery -Force -AllowClobber -ErrorAction Stop
            Write-Message "Az.StackHCI module installed successfully." -Type "Success"
        } catch {
            Write-Message "Failed to install Az.StackHCI module. Error: $_" -Type "Error"
            exit 1
        }
    } else {
        Write-Message "Az.StackHCI module is already installed." -Type "Info"
    }
}

# Function to Allow Selection from a List
function Get-Option {
    param (
        [string]$cmd,
        [string]$filterproperty
    )

    $items = @("")
    $selection = $null
    $filteredItems = @()
    $i = 0
    try {
        $cmdOutput = Invoke-Expression -Command $cmd | Sort-Object $filterproperty
        foreach ($item in $cmdOutput) {
            $items += "{0}. {1}" -f $i, $item.$filterproperty
            $i++
        }
    } catch {
        Write-Message "Failed to execute command '$cmd'. Error: $_" -Type "Error"
        exit 1
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

# Function to Retrieve ARC VMs from Azure using Az.StackHCI
function Get-ARCVMsFromAzure {
    param(
        [string]$SubscriptionId,
        [string]$ResourceGroupName
    )

    try {
        # Retrieve all connected machines in the resource group
        $connectedMachines = Get-AzConnectedMachine -ResourceGroupName $ResourceGroupName -ErrorAction Stop

        if ($connectedMachines.Count -eq 0) {
            Write-Message "No connected machines found in resource group '$ResourceGroupName'." -Type "Warning"
            return @()
        }

        # Filter connected machines where CloudMetadataProvider is "AzSHCI"
        $ARCVMs = $connectedMachines | Where-Object { $_.CloudMetadataProvider -eq "AzSHCI" }

        if ($ARCVMs.Count -eq 0) {
            Write-Message "No ARC VMs (Machines with CloudMetadataProvider 'AzSHCI') found in resource group '$ResourceGroupName'." -Type "Warning"
        } else {
            Write-Message "Retrieved $($ARCVMs.Count) ARC VM(s) from Azure." -Type "Success"
        }

        return $ARCVMs
    } catch {
        Write-Message "Failed to retrieve ARC VMs from Azure. Error: $_" -Type "Error"
        exit 1
    }
}

# Function to Validate Installed Extensions
function Test-Extensions {
    param(
        [array]$ARCVMs,
        [string]$ResourceGroupName
    )

    $Extensions = @()
    foreach ($ARCVM in $ARCVMs) {
        try {
            $extensions = Get-AzConnectedMachineExtension -ResourceGroupName $ResourceGroupName -MachineName $ARCVM.Name -ErrorAction Stop
            $Extensions += $extensions
        } catch {
            Write-Message "Failed to retrieve extensions for ARC VM '$($ARCVM.Name)'. Error: $_" -Type "Error"
            exit 1
        }
    }

    return $Extensions
}

#endregion

#region Script Execution

# Step 1: Install Az.Compute Module
$currentStep++
Update-ProgressBar -CurrentStep $currentStep -TotalSteps $totalSteps -StatusMessage "Ensuring Az.Compute module is installed..."
Write-Message "Checking for Az.Compute module..." -Type "Info"
try {
    Install-AzComputeModule
} catch {
    Write-Message "An error occurred while ensuring Az.Compute module is installed. Error: $_" -Type "Error"
    exit 1
}

# Step 2: Install Az.StackHCI Module
$currentStep++
Update-ProgressBar -CurrentStep $currentStep -TotalSteps $totalSteps -StatusMessage "Ensuring Az.StackHCI module is installed..."
Write-Message "Checking for Az.StackHCI module..." -Type "Info"
try {
    Install-AzStackHCIModule
} catch {
    Write-Message "An error occurred while ensuring Az.StackHCI module is installed. Error: $_" -Type "Error"
    exit 1
}

# Step 3: Connect to Azure using Device Code Authentication
$currentStep++
Update-ProgressBar -CurrentStep $currentStep -TotalSteps $totalSteps -StatusMessage "Connecting to Azure using device code authentication..."
Write-Message "Connecting to Azure..." -Type "Info"
try {
    Connect-AzAccount -UseDeviceAuthentication -ErrorAction Stop
    Write-Message "Connected to Azure successfully." -Type "Success"
} catch {
    Write-Message "Failed to connect to Azure using device code authentication. Error: $_" -Type "Error"
    exit 1
}

# Step 4: Select Subscription
$currentStep++
Update-ProgressBar -CurrentStep $currentStep -TotalSteps $totalSteps -StatusMessage "Selecting Azure Subscription..."
Write-Message "Retrieving available Azure Subscriptions..." -Type "Info"
try {
    $subscription = Get-Option "Get-AzSubscription" "Name"
    Set-AzContext -SubscriptionName $subscription -ErrorAction Stop
    $selectedSubscription = Get-AzContext -ErrorAction Stop
    $SubscriptionId = $selectedSubscription.Subscription.Id
    Write-Message "Selected Subscription: $($selectedSubscription.Subscription.Name)" -Type "Success"
} catch {
    Write-Message "Failed to select or set Azure Subscription. Error: $_" -Type "Error"
    exit 1
}

# Step 5: Select Resource Group
$currentStep++
Update-ProgressBar -CurrentStep $currentStep -TotalSteps $totalSteps -StatusMessage "Selecting Resource Group..."
Write-Message "Retrieving available Resource Groups in Subscription '$($selectedSubscription.Subscription.Name)'..." -Type "Info"
try {
    $resourceGroup = Get-Option "Get-AzResourceGroup" "ResourceGroupName"
    $ResourceGroupName = $resourceGroup
    Write-Message "Selected Resource Group: $ResourceGroupName" -Type "Success"
} catch {
    Write-Message "Failed to select Resource Group. Error: $_" -Type "Error"
    exit 1
}

# Step 6: Retrieve ARC VMs from Azure
$currentStep++
Update-ProgressBar -CurrentStep $currentStep -TotalSteps $totalSteps -StatusMessage "Retrieving ARC VMs from Azure..."
Write-Message "Retrieving ARC VMs from Azure..." -Type "Info"
try {
    $ARCVMs = Get-ARCVMsFromAzure -SubscriptionId $SubscriptionId -ResourceGroupName $ResourceGroupName
    if ($ARCVMs.Count -eq 0) {
        Write-Message "No ARC VMs found. Exiting script." -Type "Error"
        exit 1
    }
} catch {
    Write-Message "An error occurred while retrieving ARC VMs. Error: $_" -Type "Error"
    exit 1
}

# Step 7: Select ARC VM
$currentStep++
Update-ProgressBar -CurrentStep $currentStep -TotalSteps $totalSteps -StatusMessage "Selecting ARC VM..."
Write-Message "Selecting an ARC VM..." -Type "Info"
try {
    # Prepare the list for selection
    $arcVmNames = $ARCVMs | Select-Object -ExpandProperty Name

    # Construct the command string for Get-Option
    # Create a temporary array to hold objects with Name property
    $tempList = @()
    foreach ($arcVm in $ARCVMs) {
        $tempList += [PSCustomObject]@{ Name = $arcVm.Name }
    }

    # Export the temporary list to a temporary file
    $tempList | Export-Clixml -Path "$env:TEMP\ARCVMList.xml"

    # Use Get-Option by importing the temporary list
    function Get-Option-FromList {
        param (
            [string]$filterproperty
        )
        $items = @("")
        $selection = $null
        $filteredItems = @()
        $i = 0
        $cmdOutput = Import-Clixml -Path "$env:TEMP\ARCVMList.xml" | Sort-Object $filterproperty
        foreach ($item in $cmdOutput) {
            $items += "{0}. {1}" -f $i, $item.$filterproperty
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

    # Allow user to select an ARC VM
    $selectedARCVMName = Get-Option-FromList "Name"

    # Find the selected ARC VM object
    $selectedARCVM = $ARCVMs | Where-Object { $_.Name -eq $selectedARCVMName }

    if (-not $selectedARCVM) {
        Write-Message "No ARC VM selected. Exiting script." -Type "Error"
        exit 1
    } else {
        Write-Message "Selected ARC VM: $($selectedARCVM.Name)" -Type "Success"
    }

    # Remove temporary XML file
    Remove-Item -Path "$env:TEMP\ARCVMList.xml" -Force -ErrorAction SilentlyContinue

} catch {
    Write-Message "An error occurred while selecting ARC VM. Error: $_" -Type "Error"
    exit 1
}

# Step 8: Validate Installed Extensions
$currentStep++
Update-ProgressBar -CurrentStep $currentStep -TotalSteps $totalSteps -StatusMessage "Validating installed extensions..."
Write-Message "Validating installed Azure Connected Machine extensions on ARC VM '$($selectedARCVM.Name)'..." -Type "Info"
try {
    $Extensions = Test-Extensions -ARCVMs @($selectedARCVM) -ResourceGroupName $ResourceGroupName
    Write-Message "Extension validation completed." -Type "Success"
} catch {
    Write-Message "An error occurred during extension validation. Error: $_" -Type "Error"
    exit 1
}

# Step 9: Fix Failed Extensions and Add Missing Extensions
$currentStep++
Update-ProgressBar -CurrentStep $currentStep -TotalSteps $totalSteps -StatusMessage "Fixing failed extensions and adding missing ones..."
Write-Message "Identifying and fixing failed extensions, then adding any missing extensions on ARC VM '$($selectedARCVM.Name)'..." -Type "Info"
try {
    # Fix failed extensions
    $FailedExtensions = $Extensions | Where-Object ProvisioningState -eq "Failed"

    if ($FailedExtensions.Count -eq 0) {
        Write-Message "No failed extensions found." -Type "Success"
    } else {
        foreach ($FailedExtension in $FailedExtensions) {
            $Server = $FailedExtension.MachineName
            Write-Message "Processing failed extension '$($FailedExtension.Name)' on server '$Server'..." -Type "Info"
            
            # Remove lock first
            $Locks = Get-AzResourceLock -ResourceGroupName $ResourceGroupName | Where-Object ResourceID -like "*HybridCompute/machines/$Server*"
            if ($Locks.Count -gt 0) {
                foreach ($lock in $Locks) {
                    Write-Message "Removing lock '$($lock.Name)' from server '$Server'..." -Type "Info"
                    Remove-AzResourceLock -LockId $lock.LockId -Force -ErrorAction Stop
                }
                Write-Message "Locks removed from server '$Server'." -Type "Success"
            }

            # Remove the failed extension
            Write-Message "Removing failed extension '$($FailedExtension.Name)' from server '$Server'..." -Type "Info"
            Remove-AzConnectedMachineExtension -Name $FailedExtension.Name -ResourceGroupName $FailedExtension.ResourceGroupName -MachineName $Server -ErrorAction Stop
            Write-Message "Failed extension '$($FailedExtension.Name)' removed from server '$Server'." -Type "Success"

            # Re-add the extension
            Write-Message "Reinstalling extension '$($FailedExtension.Name)' on server '$Server'..." -Type "Info"
            New-AzConnectedMachineExtension -Name $FailedExtension.Name `
                                            -ResourceGroupName $FailedExtension.ResourceGroupName `
                                            -MachineName $Server `
                                            -Location $FailedExtension.Location `
                                            -Publisher $FailedExtension.Publisher `
                                            -Settings $Settings `
                                            -ExtensionType $FailedExtension.MachineExtensionType `
                                            -ErrorAction Stop
            Write-Message "Extension '$($FailedExtension.Name)' reinstalled on server '$Server'." -Type "Success"
        }
    }

    # Add missing extensions
    Write-Message "Adding any missing Azure Connected Machine extensions..." -Type "Info"
    foreach ($Extension in $ExtensionList) {
        # Check if the extension is already installed on the ARC VM
        $isInstalled = $Extensions | Where-Object { $_.Name -eq $Extension.Name -and $_.MachineName -eq $selectedARCVM.Name }

        if (-not $isInstalled) {
            Write-Message "Installing missing extension '$($Extension.Name)' on server '$($selectedARCVM.Name)'..." -Type "Info"
            New-AzConnectedMachineExtension -Name $Extension.Name `
                                            -ResourceGroupName $ResourceGroupName `
                                            -MachineName $selectedARCVM.Name `
                                            -Location $Location `
                                            -Publisher $Extension.Publisher `
                                            -Settings $Settings `
                                            -ExtensionType $Extension.MachineExtensionType `
                                            -ErrorAction Stop
            Write-Message "Extension '$($Extension.Name)' installed successfully on server '$($selectedARCVM.Name)'." -Type "Success"
        } else {
            Write-Message "Extension '$($Extension.Name)' already installed on server '$($selectedARCVM.Name)'. Skipping." -Type "Info"
        }
    }
} catch {
    Write-Message "An error occurred while fixing failed extensions or adding missing ones. Error: $_" -Type "Error"
    exit 1
}

# Complete the overall progress bar
Update-ProgressBar -CurrentStep $totalSteps -TotalSteps $totalSteps -StatusMessage "All tasks completed."

# Final success message
Write-Message "Azure Connected Machine extensions troubleshooting completed successfully." -Type "Success"

#endregion
