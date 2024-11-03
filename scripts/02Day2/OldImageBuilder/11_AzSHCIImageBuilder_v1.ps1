# AzureStackHCIImageDownloader.ps1
# Automates the process of pulling VM images from Azure and adding them as custom images to Azure Stack HCI.

<#
.SYNOPSIS
    Downloads selected VM images from Azure and adds them as custom images to Azure Stack HCI.

.DESCRIPTION
    This script performs the following tasks:
    - Installs necessary PowerShell modules and Azure CLI if not already installed.
    - Connects to Azure using device code authentication with retries.
    - Allows the user to select the Azure subscription and resource group.
    - Retrieves available VM images based on predefined publishers.
    - Allows the user to select images to download.
    - Downloads selected images using AzCopy to the Host's local `C:\HCI` directory.
    - Copies the downloaded VHDs from the Host to the VM Node using PowerShell remoting.
    - Converts downloaded VHDs to VHDX format and optimizes them on the VM Node.
    - Adds the converted images to the Azure Stack HCI library.

.NOTES
    - Ensure you run this script with administrative privileges.
    - Requires PowerShell 5.1 or later.
    - Ensure the Execution Policy allows the script to run. To set the execution policy, run:
      Set-ExecutionPolicy RemoteSigned -Scope CurrentUser
#>

#region Variables

# Configuration Settings
$region = "westeurope"
$nodeName = "NODE"
$LibraryVolumeName = "UserStorage_1"

# Credentials for accessing the cluster
$netBIOSName = "AZURESTACK"
$hcilcmuser = "hciadmin"
$hciadmin = "$netBIOSName\$hcilcmuser"
$hcipassword = "dgemsc#utquMHDHp3M"
$hciSecuredPassword = ConvertTo-SecureString $hcipassword -AsPlainText -Force
$hciCredentials = New-Object System.Management.Automation.PSCredential ($hciadmin, $hciSecuredPassword)

# Define required PowerShell modules
$ModuleNames = @("Az.Accounts", "Az.Compute", "Az.Resources", "Az.CustomLocation")

# Azure CLI Installer URL
$AzureCLIUrl = "https://aka.ms/installazurecliwindows"

# AzCopy URL
$AzCopyUrl = "https://aka.ms/downloadazcopy-v10-windows"

# Image Publishers
$Publishers = @(
    "MicrosoftWindowsServer",
    "microsoftwindowsdesktop",
    "Canonical",
    "Credativ",
    "Kinvolk",
    "RedHat",
    "RedHat-RHEL",
    "Oracle",
    "SuSE",
    "Suse.AzureHybridBenefit"
)

# Total number of steps for progress calculation
$totalSteps = 9
$currentStep = 0

# Host's local directory for initial VHD download
$HostDownloadPath = "C:\HCI"

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

# Function to Install Required PowerShell Modules
function Install-RequiredModules {
    Write-Message "Installing required PowerShell modules..." -Type "Info"

    # Set TLS 1.2 protocol
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    # Install NuGet provider if not installed
    if (-not (Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue)) {
        Write-Message "Installing NuGet package provider..." -Type "Info"
        try {
            Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -ErrorAction Stop
            Write-Message "NuGet package provider installed successfully." -Type "Success"
        } catch {
            Write-Message "Failed to install NuGet package provider. Error: $_" -Type "Error"
            exit 1
        }
    } else {
        Write-Message "NuGet package provider is already installed." -Type "Success"
    }

    # Install required modules
    foreach ($ModuleName in $ModuleNames) {
        if (-not (Get-Module -ListAvailable -Name $ModuleName)) {
            Write-Message "Installing module: $ModuleName" -Type "Info"
            try {
                Install-Module -Name $ModuleName -Force -AllowClobber -ErrorAction Stop
                Write-Message "Module $ModuleName installed successfully." -Type "Success"
            } catch {
                Write-Message "Failed to install module $ModuleName. Error: $_" -Type "Error"
                exit 1
            }
        } else {
            Write-Message "Module $ModuleName is already installed." -Type "Success"
        }
    }
}

# Function to Test if Azure CLI is Installed
function Test-AzCLIInstall {
    Write-Message "Checking if Azure CLI is installed..." -Type "Info"
    try {
        az --version > $null 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Message "Azure CLI is already installed." -Type "Success"
            return $true
        } else {
            Write-Message "Azure CLI is not installed." -Type "Warning"
            return $false
        }
    } catch {
        Write-Message "Azure CLI is not installed." -Type "Warning"
        return $false
    }
}

# Function to Install Azure CLI
function Install-AzCLI {
    Write-Message "Installing Azure CLI..." -Type "Info"
    $azCliPath = "$env:USERPROFILE\Downloads\AzureCLI.msi"
    if (-not (Test-Path $azCliPath)) {
        Write-Message "Downloading Azure CLI installer..." -Type "Info"
        try {
            Start-BitsTransfer -Source $AzureCLIUrl -Destination $azCliPath
            Write-Message "Azure CLI installer downloaded." -Type "Success"
        } catch {
            Write-Message "Failed to download Azure CLI installer. Error: $_" -Type "Error"
            exit 1
        }
    } else {
        Write-Message "Azure CLI installer already exists at $azCliPath." -Type "Success"
    }

    Write-Message "Installing Azure CLI silently..." -Type "Info"
    try {
        Start-Process msiexec.exe -Wait -ArgumentList "/I `"$azCliPath`" /quiet" -NoNewWindow -ErrorAction Stop
        Write-Message "Azure CLI installed successfully." -Type "Success"
    } catch {
        Write-Message "Failed to install Azure CLI. Error: $_" -Type "Error"
        exit 1
    }

    # Add Azure CLI to PATH
    $azPath = "C:\Program Files (x86)\Microsoft SDKs\Azure\CLI2\wbin"
    if ($Env:PATH -notlike "*$azPath*") {
        [System.Environment]::SetEnvironmentVariable('PATH', $Env:PATH + ";$azPath", [System.EnvironmentVariableTarget]::Process)
        Write-Message "Azure CLI path added to environment variables." -Type "Success"
    } else {
        Write-Message "Azure CLI is already in PATH." -Type "Success"
    }
}

# Function to Get Option from Azure PowerShell Commands
function Get-Option {
    param (
        [string]$Command,
        [string]$PropertyName
    )

    try {
        $results = Invoke-Expression $Command
        $options = $results | Select-Object -Property $PropertyName
        if ($options.Count -eq 0) {
            Write-Message "No options found for command '$Command'." -Type "Warning"
            exit 1
        }

        # Display options in Out-GridView for selection
        $selectedOption = $options | Out-GridView -Title "Select $PropertyName" -OutputMode Single
        return $selectedOption.$PropertyName
    } catch {
        Write-Message "Failed to execute command '$Command'. Error: $_" -Type "Error"
        exit 1
    }
}

# Function to Connect to Azure with Retry
function Connect-AzAccountWithRetry {
    param(
        [int]$MaxRetries = 3,
        [int]$DelaySeconds = 20
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

# Function to Add Azure Extensions
function Add-AzExtensions {
    Write-Message "Adding Azure extensions..." -Type "Info"
    try {
        az extension add --name "stack-hci" | Out-Null
        az extension add --name "stack-hci-vm" --version "1.1.20" | Out-Null
        Write-Message "Azure extensions added successfully." -Type "Success"
        
        # Validate extension versions on the cluster
        Write-Message "Validating extension versions on the cluster..." -Type "Info"
        $AZVersions = Invoke-Command -VMName $nodeName -Credential $hciCredentials -ScriptBlock { az version | ConvertFrom-Json }
        $AZVersions.extensions | Format-Table
    } catch {
        Write-Message "Failed to add or validate Azure extensions. Error: $_" -Type "Error"
        exit 1
    }
}

# Function to Retrieve Subscription ID
function Get-SubscriptionID {
    Write-Message "Retrieving Azure Subscription ID..." -Type "Info"
    try {
        $account = az account show | ConvertFrom-Json
        return $account.id
    } catch {
        Write-Message "Failed to retrieve Azure Subscription ID. Error: $_" -Type "Error"
        exit 1
    }
}

# Function to Select Images to Download
function Select-ImagesToDownload {
    Write-Message "Retrieving available VM image offers from publishers..." -Type "Info"
    try {
        $ImageOffers = @()
        foreach ($Publisher in $Publishers) {
            $ImageOffers += Get-AzVMImageOffer -Location $region -PublisherName $Publisher
        }

        $ImageSKUs = @()
        foreach ($ImageOffer in $ImageOffers) {
            $ImageSKUs += Get-AzVMImageSku -Location $region -PublisherName $ImageOffer.PublisherName -Offer $ImageOffer.Offer
        }

        Write-Message "Please select the images you want to download." -Type "Info"
        $SelectedImages = $ImageSKUs | Out-GridView -OutputMode Multiple -Title "Select Images to Download"

        return $SelectedImages
    } catch {
        Write-Message "Failed to retrieve VM images. Error: $_" -Type "Error"
        exit 1
    }
}

# Function to Import and Add Images
function Import-Images {
    param (
        [array]$ImagesToDownload,
        [string]$SubscriptionID,
        [string]$ResourceGroupName
    )

    foreach ($ImageSKU in $ImagesToDownload) {
        Write-Message "Processing Image: $($ImageSKU.PublisherName) - $($ImageSKU.Offer) - $($ImageSKU.Skus)" -Type "Info"

        # Get Latest Image
        $LatestImage = Get-AzVMImage -Location $region -PublisherName $ImageSKU.PublisherName -Offer $ImageSKU.Offer -Skus $ImageSKU.Skus | Sort-Object Version -Descending | Select-Object -First 1
        if (-not $LatestImage) {
            Write-Message "No images found for $($ImageSKU.PublisherName) - $($ImageSKU.Offer) - $($ImageSKU.Skus). Skipping..." -Type "Warning"
            continue
        }

        # Export OS Disk
        $DiskName = "$($LatestImage.Skus).$($LatestImage.Version)"
        Write-Message "Creating OS Disk: $DiskName" -Type "Info"
        try {
            $OSDiskConfig = New-AzDiskConfig -Location $region -CreateOption "FromImage" -ImageReference @{ Id = $LatestImage.Id }
            New-AzDisk -ResourceGroupName $ResourceGroupName -DiskName $DiskName -Disk $OSDiskConfig | Out-Null
            Write-Message "OS Disk $DiskName created successfully." -Type "Success"
        } catch {
            Write-Message "Failed to create OS Disk $DiskName. Error: $_" -Type "Error"
            continue
        }

        # Grant Access and Get SAS Token
        Write-Message "Granting access to disk $DiskName..." -Type "Info"
        try {
            $DiskAccess = Grant-AzDiskAccess -ResourceGroupName $ResourceGroupName -DiskName $DiskName -Access 'Read' -DurationInSecond 3600
            $SAS = $DiskAccess.AccessSas
            Write-Message "Access granted. SAS Token acquired." -Type "Success"
        } catch {
            Write-Message "Failed to grant access to disk $DiskName. Error: $_" -Type "Error"
            Remove-AzDisk -ResourceGroupName $ResourceGroupName -DiskName $DiskName -Force | Out-Null
            continue
        }

        # Download VHD using AzCopy to Host's local directory
        Write-Message "Downloading VHD using AzCopy to Host's local directory..." -Type "Info"
        $azCopyPath = "$env:UserProfile\Downloads\azcopy.exe"
        if (-not (Test-Path $azCopyPath)) {
            Write-Message "AzCopy not found. Downloading AzCopy..." -Type "Info"
            try {
                $azCopyZip = "$env:UserProfile\Downloads\AzCopy.zip"
                Start-BitsTransfer -Source $AzCopyUrl -Destination $azCopyZip
                Expand-Archive -Path $azCopyZip -DestinationPath "$env:UserProfile\Downloads\AZCopy" -Force
                $azCopyExe = Get-ChildItem -Path "$env:UserProfile\Downloads\AZCopy" -Filter "azcopy.exe" -Recurse | Select-Object -First 1
                Move-Item -Path $azCopyExe.FullName -Destination $azCopyPath
                Remove-Item -Path "$env:UserProfile\Downloads\AZCopy" -Recurse -Force
                Remove-Item -Path $azCopyZip -Force
                Write-Message "AzCopy downloaded and installed successfully." -Type "Success"
            } catch {
                Write-Message "Failed to download or install AzCopy. Error: $_" -Type "Error"
                Revoke-AzDiskAccess -ResourceGroupName $ResourceGroupName -DiskName $DiskName
                Remove-AzDisk -ResourceGroupName $ResourceGroupName -DiskName $DiskName -Force | Out-Null
                continue
            }
        }

        # Ensure the HostDownloadPath exists
        if (-not (Test-Path -Path $HostDownloadPath)) {
            New-Item -ItemType Directory -Path $HostDownloadPath -Force | Out-Null
        }

        $LocalVHDPath = Join-Path -Path $HostDownloadPath -ChildPath "$DiskName.vhd"

        Write-Message "Downloading VHD to $LocalVHDPath..." -Type "Info"
        try {
            & $azCopyPath copy "$SAS" "$LocalVHDPath" --check-md5 NoCheck --cap-mbps 500
            Write-Message "VHD downloaded successfully to $LocalVHDPath." -Type "Success"
        } catch {
            Write-Message "Failed to download VHD to $LocalVHDPath. Error: $_" -Type "Error"
            Revoke-AzDiskAccess -ResourceGroupName $ResourceGroupName -DiskName $DiskName
            Remove-AzDisk -ResourceGroupName $ResourceGroupName -DiskName $DiskName -Force | Out-Null
            continue
        }

        # Revoke Disk Access and Remove Disk
        Write-Message "Revoking disk access and removing temporary disk..." -Type "Info"
        try {
            Revoke-AzDiskAccess -ResourceGroupName $ResourceGroupName -DiskName $DiskName
            Remove-AzDisk -ResourceGroupName $ResourceGroupName -DiskName $DiskName -Force | Out-Null
            Write-Message "Disk access revoked and temporary disk removed." -Type "Success"
        } catch {
            Write-Message "Failed to revoke access or remove disk $DiskName. Error: $_" -Type "Warning"
        }

        # Copy VHD from Host to VM Node using PowerShell remoting
        Write-Message "Copying VHD from Host to VM Node using PowerShell remoting..." -Type "Info"
        try {
            $session = New-PSSession -VMName $nodeName -Credential $hciCredentials
            Copy-Item -Path $LocalVHDPath -Destination "C:\ClusterStorage\$LibraryVolumeName\$DiskName.vhd" -ToSession $session -Force
            Remove-PSSession $session
            Write-Message "VHD copied to VM Node successfully." -Type "Success"
        } catch {
            Write-Message "Failed to copy VHD to VM Node using PowerShell remoting. Error: $_" -Type "Error"
            Remove-Item -Path $LocalVHDPath -Force -ErrorAction SilentlyContinue
            continue
        }

        # Remove local VHD file
        Remove-Item -Path $LocalVHDPath -Force -ErrorAction SilentlyContinue

        # Convert VHD to VHDX and Optimize on VM Node
        Write-Message "Converting VHD to VHDX and optimizing on VM Node..." -Type "Info"
        try {
            Invoke-Command -VMName $nodeName -Credential $hciCredentials -ScriptBlock {
                param($DiskName, $LibraryVolumeName)
                $SourcePath = "C:\ClusterStorage\$LibraryVolumeName\$DiskName.vhd"
                $DestPath = "C:\ClusterStorage\$LibraryVolumeName\$DiskName.vhdx"
                Convert-VHD -Path $SourcePath -DestinationPath $DestPath -VHDType Dynamic -DeleteSource
                Optimize-VHD -Path $DestPath -Mode Full
            } -ArgumentList $DiskName, $LibraryVolumeName
            Write-Message "VHD converted to VHDX and optimized successfully." -Type "Success"
        } catch {
            Write-Message "Failed to convert or optimize VHD for $DiskName on VM Node. Error: $_" -Type "Error"
            Invoke-Command -VMName $nodeName -Credential $hciCredentials -ScriptBlock {
                param($LibraryVolumeName, $DiskName)
                Remove-Item -Path "C:\ClusterStorage\$LibraryVolumeName\$DiskName.vhd" -Force -ErrorAction SilentlyContinue
            } -ArgumentList $LibraryVolumeName, $DiskName
            continue
        }

        # Prepare Disk Name for Azure Stack HCI
        $DiskNameNew = $DiskName -replace "windows","win" -replace "\.","-"

        # Determine OS Type
        $OSType = if ($LatestImage.PublisherName -like "*Windows*") { "Windows" } else { "Linux" }

        # Get Custom Location ID
        Write-Message "Retrieving Custom Location ID..." -Type "Info"
        try {
            $CustomLocation = Get-AzCustomLocation -ResourceGroupName $ResourceGroupName
            if (-not $CustomLocation) {
                Write-Message "Custom location not found in resource group $ResourceGroupName. Skipping image $DiskNameNew." -Type "Warning"
                Invoke-Command -VMName $nodeName -Credential $hciCredentials -ScriptBlock {
                    param($LibraryVolumeName, $DiskName)
                    Remove-Item -Path "C:\ClusterStorage\$LibraryVolumeName\$DiskName.vhdx" -Force -ErrorAction SilentlyContinue
                } -ArgumentList $LibraryVolumeName, $DiskName
                continue
            }
            $CustomLocationID = $CustomLocation.ID
            Write-Message "Custom Location ID retrieved: $CustomLocationID" -Type "Success"
        } catch {
            Write-Message "Failed to retrieve Custom Location ID. Error: $_" -Type "Error"
            Invoke-Command -VMName $nodeName -Credential $hciCredentials -ScriptBlock {
                param($LibraryVolumeName, $DiskName)
                Remove-Item -Path "C:\ClusterStorage\$LibraryVolumeName\$DiskName.vhdx" -Force -ErrorAction SilentlyContinue
            } -ArgumentList $LibraryVolumeName, $DiskName
            continue
        }

        # Add Image to Azure Stack HCI Library
        Write-Message "Adding image $DiskNameNew to Azure Stack HCI library..." -Type "Info"
        try {
            az stack-hci-vm image create `
                --subscription $SubscriptionID `
                --resource-group $ResourceGroupName `
                --custom-location $CustomLocationID `
                --location $region `
                --image-path "C:\ClusterStorage\$LibraryVolumeName\$DiskName.vhdx" `
                --name $DiskNameNew `
                --os-type $OSType `
                --offer $LatestImage.Offer `
                --publisher $LatestImage.PublisherName `
                --version $LatestImage.Version | Out-Null
            Write-Message "Image $DiskNameNew added to Azure Stack HCI library successfully." -Type "Success"
        } catch {
            Write-Message "Failed to add image $DiskNameNew to Azure Stack HCI library. Error: $_" -Type "Error"
            Invoke-Command -VMName $nodeName -Credential $hciCredentials -ScriptBlock {
                param($LibraryVolumeName, $DiskName)
                Remove-Item -Path "C:\ClusterStorage\$LibraryVolumeName\$DiskName.vhdx" -Force -ErrorAction SilentlyContinue
            } -ArgumentList $LibraryVolumeName, $DiskName
            continue
        }
    }
}

#endregion

#region Script Execution

# Step 1: Install Required PowerShell Modules
$currentStep++
Update-ProgressBar -CurrentStep $currentStep -TotalSteps $totalSteps -StatusMessage "Installing required PowerShell modules..."
Write-Message "Step $currentStep of $totalSteps : Installing required PowerShell modules." -Type "Info"
try {
    Install-RequiredModules
} catch {
    Write-Message "An error occurred during module installation. Error: $_" -Type "Error"
    exit 1
}

# Step 2: Install Azure CLI if Not Installed
$currentStep++
Update-ProgressBar -CurrentStep $currentStep -TotalSteps $totalSteps -StatusMessage "Ensuring Azure CLI is installed..."
Write-Message "Step $currentStep of $totalSteps : Ensuring Azure CLI is installed." -Type "Info"
try {
    $azInstalled = Test-AzCLIInstall
    if (-not $azInstalled) {
        Install-AzCLI
    } else {
        Write-Message "Azure CLI is already installed. Skipping installation." -Type "Info"
    }
} catch {
    Write-Message "An error occurred during Azure CLI installation check. Error: $_" -Type "Error"
    exit 1
}

# Step 3: Connect to Azure
$currentStep++
Update-ProgressBar -CurrentStep $currentStep -TotalSteps $totalSteps -StatusMessage "Connecting to Azure..."
Write-Message "Step $currentStep of $totalSteps : Connecting to Azure." -Type "Info"
try {
    Connect-AzAccountWithRetry -MaxRetries 5 -DelaySeconds 20
} catch {
    Write-Message "An error occurred during Azure connection. Error: $_" -Type "Error"
    exit 1
}

# Step 4: Allow User to Select Subscription and Resource Group
$currentStep++
Update-ProgressBar -CurrentStep $currentStep -TotalSteps $totalSteps -StatusMessage "Selecting Subscription and Resource Group..."
Write-Message "Step $currentStep of $totalSteps : Selecting Subscription and Resource Group." -Type "Info"
try {
    # Allow user to select Subscription
    $subscriptionName = Get-Option "Get-AzSubscription" "Name"
    Set-AzContext -SubscriptionName $subscriptionName -ErrorAction Stop
    Write-Message "Subscription set to: $subscriptionName" -Type "Success"

    # Allow user to select Resource Group
    $ResourceGroupName = Get-Option "Get-AzResourceGroup" "ResourceGroupName"
    Write-Message "Resource Group selected: $ResourceGroupName" -Type "Success"
} catch {
    Write-Message "An error occurred while selecting Subscription or Resource Group. Error: $_" -Type "Error"
    exit 1
}

# Step 5: Add Azure Extensions
$currentStep++
Update-ProgressBar -CurrentStep $currentStep -TotalSteps $totalSteps -StatusMessage "Adding Azure extensions..."
Write-Message "Step $currentStep of $totalSteps : Adding Azure extensions." -Type "Info"
try {
    Add-AzExtensions
} catch {
    Write-Message "An error occurred while adding Azure extensions. Error: $_" -Type "Error"
    exit 1
}

# Step 6: Retrieve Subscription ID
$currentStep++
Update-ProgressBar -CurrentStep $currentStep -TotalSteps $totalSteps -StatusMessage "Retrieving Subscription ID..."
Write-Message "Step $currentStep of $totalSteps : Retrieving Subscription ID." -Type "Info"
try {
    $SubscriptionID = Get-SubscriptionID
    Write-Message "Retrieved Subscription ID: $SubscriptionID" -Type "Success"
} catch {
    Write-Message "An error occurred while retrieving Subscription ID. Error: $_" -Type "Error"
    exit 1
}

# Step 7: Select Images to Download
$currentStep++
Update-ProgressBar -CurrentStep $currentStep -TotalSteps $totalSteps -StatusMessage "Selecting images to download..."
Write-Message "Step $currentStep of $totalSteps : Selecting images to download." -Type "Info"
try {
    $ImagesToDownload = Select-ImagesToDownload
    if ($ImagesToDownload.Count -eq 0) {
        Write-Message "No images selected for download. Exiting script." -Type "Warning"
        exit 0
    }
} catch {
    Write-Message "An error occurred while selecting images to download. Error: $_" -Type "Error"
    exit 1
}

# Step 8: Import and Add Images
$currentStep++
Update-ProgressBar -CurrentStep $currentStep -TotalSteps $totalSteps -StatusMessage "Importing and adding images..."
Write-Message "Step $currentStep of $totalSteps : Importing and adding images." -Type "Info"
try {
    Import-Images -ImagesToDownload $ImagesToDownload -SubscriptionID $SubscriptionID -ResourceGroupName $ResourceGroupName
} catch {
    Write-Message "An error occurred during the import and addition of images. Error: $_" -Type "Error"
    exit 1
}

# Step 9: Completion
$currentStep++
Update-ProgressBar -CurrentStep $currentStep -TotalSteps $totalSteps -StatusMessage "Completed."
Write-Message "Step $currentStep of $totalSteps : Completed." -Type "Success"
Write-Message "All selected images have been downloaded and added to Azure Stack HCI successfully." -Type "Success"

#endregion
