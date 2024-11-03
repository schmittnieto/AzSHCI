# 20_SSHRDPArcVM.ps1
# Script to search ARC VMs in a Resource Group, ensure SSH extension is installed, and establish RDP over SSH connection

<#
.SYNOPSIS
    Searches for ARC VMs in a specified Resource Group, ensures the SSH extension is installed, and establishes an SSH connection.

.DESCRIPTION
    This script performs the following tasks:
    - Checks and installs Azure PowerShell modules Az.Compute and Az.ConnectedMachine if not installed.
    - Checks and installs Azure CLI and its SSH extension if not installed on the local machine.
    - Connects to Azure using device code authentication.
    - Allows the user to select a Subscription and Resource Group.
    - Retrieves ARC VMs from the selected Resource Group.
    - Checks if the selected ARC VM has the SSH extension installed; if not, installs it.
    - Establishes an SSH connection to the ARC VM using the specified local user.

.NOTES
    - Designed by Cristian Schmitt Nieto 
    - Based on Alexnder´s aproach: https://www.linkedin.com/pulse/azurearc-using-rdp-ssh-alexander-ortha-7sxae/
    - Ensure the script is run with administrative privileges.
    - Set the Execution Policy to allow script execution:
      Set-ExecutionPolicy RemoteSigned -Scope CurrentUser
#>

#region Variables

# Location for Azure resources
$Location = "westeurope"

# Local User for SSH Connection (Set this manually)
$LocalUser = "vmadmin" # <-- Replace 'username' with your actual local user

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
    if ($percent -gt 100) { $percent = 100 }
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

# Function to Install Az.ConnectedMachine Module if Not Installed
function Install-AzConnectedMachineModule {
    if (-not (Get-Module -ListAvailable -Name Az.ConnectedMachine)) {
        Write-Message "Az.ConnectedMachine module not found. Installing..." -Type "Info"
        try {
            Install-Module -Name Az.ConnectedMachine -Repository PSGallery -Force -AllowClobber -ErrorAction Stop
            Write-Message "Az.ConnectedMachine module installed successfully." -Type "Success"
        } catch {
            Write-Message "Failed to install Az.ConnectedMachine module. Error: $_" -Type "Error"
            exit 1
        }
    } else {
        Write-Message "Az.ConnectedMachine module is already installed." -Type "Info"
    }
}

# Function to Check and Install Azure CLI
function Ensure-AzCLI {
    if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
        Write-Message "Azure CLI not found. Installing..." -Type "Info"
        try {
            # Download and install Azure CLI
            Invoke-WebRequest -Uri https://aka.ms/installazurecliwindows -OutFile "$env:TEMP\AzureCLI.msi" -UseBasicParsing
            Start-Process msiexec.exe -Wait -ArgumentList "/I $env:TEMP\AzureCLI.msi /quiet"
            Remove-Item "$env:TEMP\AzureCLI.msi" -Force
            Write-Message "Azure CLI installed successfully." -Type "Success"
        } catch {
            Write-Message "Failed to install Azure CLI. Error: $_" -Type "Error"
            exit 1
        }
    } else {
        Write-Message "Azure CLI is already installed." -Type "Info"
    }
}

# Function to Install SSH ARC Extension for Azure CLI
function Ensure-AzureCLISshExtension {
    $azExtensions = az extension list --query "[].name" -o tsv
    if ($azExtensions -notcontains "ssh") {
        Write-Message "Azure CLI SSH extension not found. Installing..." -Type "Info"
        try {
            az extension add --name ssh --only-show-errors
            Write-Message "Azure CLI SSH extension installed successfully." -Type "Success"
        } catch {
            Write-Message "Failed to install Azure CLI SSH extension. Error: $_" -Type "Error"
            exit 1
        }
    } else {
        Write-Message "Azure CLI SSH extension is already installed." -Type "Info"
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

# Function to Retrieve ARC VMs from Azure using Az.ConnectedMachine
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
        $ARCVMs = $connectedMachines | Where-Object { $_.CloudMetadataProvider -ne "AzSHCI" }

        if ($ARCVMs.Count -eq 0) {
            Write-Message "No ARC VMs found in resource group '$ResourceGroupName'." -Type "Warning"
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
            $Extensions += @($extensions) # Ensure $extensions is treated as an array
        } catch {
            Write-Message "Failed to retrieve extensions for ARC VM '$($ARCVM.Name)'. Error: $_" -Type "Error"
            exit 1
        }
    }

    return $Extensions
}

# Function to Ensure Local Environment has Azure CLI and SSH Extension
function Ensure-LocalEnvironment {
    Write-Message "Ensuring local environment has Azure CLI and SSH extension installed..." -Type "Info"
    Ensure-AzCLI
    Ensure-AzureCLISshExtension
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

# Step 2: Install Az.ConnectedMachine Module
$currentStep++
Update-ProgressBar -CurrentStep $currentStep -TotalSteps $totalSteps -StatusMessage "Ensuring Az.ConnectedMachine module is installed..."
Write-Message "Checking for Az.ConnectedMachine module..." -Type "Info"
try {
    Install-AzConnectedMachineModule
} catch {
    Write-Message "An error occurred while ensuring Az.ConnectedMachine module is installed. Error: $_" -Type "Error"
    exit 1
}

# Step 3: Ensure Local Environment
$currentStep++
Update-ProgressBar -CurrentStep $currentStep -TotalSteps $totalSteps -StatusMessage "Ensuring local environment is set up..."
Write-Message "Checking local environment for Azure CLI and SSH extension..." -Type "Info"
try {
    Ensure-LocalEnvironment
} catch {
    Write-Message "An error occurred while setting up the local environment. Error: $_" -Type "Error"
    exit 1
}

# Step 4: Connect to Azure using Device Code Authentication
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

# Step 5: Select Subscription
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

# Step 6: Select Resource Group
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

# Step 7: Retrieve ARC VMs from Azure
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

# Step 8: Select ARC VM
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

    # Function to allow selection from the imported list
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

# Step 9: Validate and Add SSH Extension
$currentStep++
Update-ProgressBar -CurrentStep $currentStep -TotalSteps $totalSteps -StatusMessage "Validating SSH extension..."
Write-Message "Validating SSH extension on ARC VM '$($selectedARCVM.Name)'..." -Type "Info"
try {
    $SSHExtension = Get-AzConnectedMachineExtension -ResourceGroupName $ResourceGroupName -MachineName $selectedARCVM.Name | Where-Object { $_.Name -eq "WindowsOpenSSH" }

    if (-not $SSHExtension) {
        Write-Message "SSH extension not found on '$($selectedARCVM.Name)'. Installing..." -Type "Warning"
        try {
            New-AzConnectedMachineExtension -MachineName $selectedARCVM.Name `
                                            -Name "WindowsOpenSSH" `
                                            -ResourceGroupName $ResourceGroupName `
                                            -Location $Location `
                                            -Publisher "Microsoft.Azure.OpenSSH" `
                                            -ExtensionType "WindowsOpenSSH" `
                                            -ErrorAction Stop
            Write-Message "SSH extension installed successfully on '$($selectedARCVM.Name)'." -Type "Success"
        } catch {
            Write-Message "Failed to install SSH extension on '$($selectedARCVM.Name)'. Error: $_" -Type "Error"
            exit 1
        }
    } else {
        Write-Message "SSH extension is already installed on '$($selectedARCVM.Name)'." -Type "Info"
    }

} catch {
    Write-Message "An error occurred during SSH extension validation. Error: $_" -Type "Error"
    exit 1
}

# Step 10: Establish SSH Connection
$currentStep++
Update-ProgressBar -CurrentStep $currentStep -TotalSteps $totalSteps -StatusMessage "Establishing SSH connection..."
Write-Message "Establishing SSH connection to ARC VM '$($selectedARCVM.Name)'..." -Type "Info"
try {
    az ssh arc --resource-group $ResourceGroupName --name $selectedARCVM.Name --local-user $LocalUser --rdp
    Write-Message "SSH connection established successfully." -Type "Success"
} catch {
    Write-Message "Failed to establish SSH connection. Error: $_" -Type "Error"
    exit 1
}

# Complete the overall progress bar
Update-ProgressBar -CurrentStep $totalSteps -TotalSteps $totalSteps -StatusMessage "All tasks completed."

# Final success message
Write-Message "Azure ARC VM SSH setup and connection completed successfully." -Type "Success"

#endregion
