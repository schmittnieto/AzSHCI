# AzureStackHCIImageDownloader.ps1
# Automates the process of pulling VM images from Azure and adding them as custom images to Azure Stack HCI using ARM templates.

<#
.SYNOPSIS
    Downloads selected VM images from Azure and adds them as custom images to Azure Stack HCI using ARM templates.

.DESCRIPTION
    This script performs the following tasks:
    - Installs necessary PowerShell modules and Azure CLI if not already installed.
    - Connects to Azure using device code authentication with retries.
    - Allows the user to select the Azure subscription and resource group.
    - Retrieves available VM images based on predefined publishers.
    - Allows the user to select images to download.
    - Downloads selected images using AzCopy directly on the VM Node.
    - Converts downloaded VHDs to VHDX format and optimizes them on the VM Node.
    - Adds the converted images to the Azure Stack HCI library using an ARM template.

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
$hcipassword = "YourPasswordHere"  # Replace with your actual password
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

# Template and Parameters Paths
$TemplateDirectory = "C:\HCI"
$TemplateFile = Join-Path -Path $TemplateDirectory -ChildPath "template.json"
$ParameterFile = Join-Path -Path $TemplateDirectory -ChildPath "parameters.json"

#endregion

#region Functions

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

function Update-ProgressBar {
    param (
        [int]$CurrentStep,
        [int]$TotalSteps,
        [string]$StatusMessage
    )

    $percent = [math]::Round(($CurrentStep / $TotalSteps) * 100)
    Write-Progress -Id 1 -Activity "Overall Progress" -Status $StatusMessage -PercentComplete $percent
}

function Install-RequiredModules {
    Write-Message "Installing required PowerShell modules..." -Type "Info"

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

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

    $azPath = "C:\Program Files (x86)\Microsoft SDKs\Azure\CLI2\wbin"
    if ($Env:PATH -notlike "*$azPath*") {
        [System.Environment]::SetEnvironmentVariable('PATH', $Env:PATH + ";$azPath", [System.EnvironmentVariableTarget]::Process)
        Write-Message "Azure CLI path added to environment variables." -Type "Success"
    } else {
        Write-Message "Azure CLI is already in PATH." -Type "Success"
    }
}

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

        $selectedOption = $options | Out-GridView -Title "Select $PropertyName" -OutputMode Single
        return $selectedOption.$PropertyName
    } catch {
        Write-Message "Failed to execute command '$Command'. Error: $_" -Type "Error"
        exit 1
    }
}

function Connect-AzAccountWithRetry {
    param(
        [int]$MaxRetries = 5,
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

function Import-Images {
    param (
        [array]$ImagesToDownload,
        [string]$SubscriptionID,
        [string]$ResourceGroupName
    )

    foreach ($ImageSKU in $ImagesToDownload) {
        Write-Message "Processing Image: $($ImageSKU.PublisherName) - $($ImageSKU.Offer) - $($ImageSKU.Skus)" -Type "Info"

        $LatestImage = Get-AzVMImage -Location $region -PublisherName $ImageSKU.PublisherName -Offer $ImageSKU.Offer -Skus $ImageSKU.Skus | Sort-Object Version -Descending | Select-Object -First 1
        if (-not $LatestImage) {
            Write-Message "No images found for $($ImageSKU.PublisherName) - $($ImageSKU.Offer) - $($ImageSKU.Skus). Skipping..." -Type "Warning"
            continue
        }

        # Clean up Disk Name to remove unnecessary characters
        $DiskNameOriginal = "$($LatestImage.Skus)$($LatestImage.Version)"
        $DiskName = $DiskNameOriginal -replace '[^a-zA-Z0-9]', ''
        Write-Message "Creating OS Disk: $DiskName" -Type "Info"
        try {
            $OSDiskConfig = New-AzDiskConfig -Location $region -CreateOption "FromImage" -ImageReference @{ Id = $LatestImage.Id }
            New-AzDisk -ResourceGroupName $ResourceGroupName -DiskName $DiskName -Disk $OSDiskConfig | Out-Null
            Write-Message "OS Disk $DiskName created successfully." -Type "Success"
        } catch {
            Write-Message "Failed to create OS Disk $DiskName. Error: $_" -Type "Error"
            continue
        }

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

        Write-Message "Downloading VHD directly to VM Node using AzCopy..." -Type "Info"
        try {
            Invoke-Command -VMName $nodeName -Credential $hciCredentials -ScriptBlock {
                param($AzCopyUrl)
                $azCopyPath = "C:\AzCopy\azcopy.exe"
                if (-not (Test-Path $azCopyPath)) {
                    Write-Host "AzCopy not found on VM Node. Installing AzCopy..." -ForegroundColor Cyan
                    New-Item -ItemType Directory -Path "C:\AzCopy" -Force | Out-Null
                    $azCopyZip = "C:\AzCopy\AzCopy.zip"
                    try {
                        Invoke-WebRequest -Uri $AzCopyUrl -OutFile $azCopyZip -UseBasicParsing
                        Expand-Archive -Path $azCopyZip -DestinationPath "C:\AzCopy" -Force
                        Remove-Item -Path $azCopyZip -Force

                        $azCopyExe = Get-ChildItem -Path "C:\AzCopy" -Filter "azcopy.exe" -Recurse | Select-Object -First 1
                        if ($azCopyExe) {
                            Move-Item -Path $azCopyExe.FullName -Destination "C:\AzCopy\azcopy.exe" -Force
                        } else {
                            Write-Host "Failed to locate azcopy.exe after extraction." -ForegroundColor Red
                            exit 1
                        }
                    } catch {
                        Write-Host "Failed to install AzCopy on VM Node. Error: $_" -ForegroundColor Red
                        exit 1
                    }
                } else {
                    Write-Host "AzCopy is already installed on VM Node." -ForegroundColor Green
                }
            } -ArgumentList $AzCopyUrl

            Invoke-Command -VMName $nodeName -Credential $hciCredentials -ScriptBlock {
                param($SAS, $DiskName, $LibraryVolumeName)
                $azCopyPath = "C:\AzCopy\azcopy.exe"
                $DestinationPath = "C:\ClusterStorage\$LibraryVolumeName\$DiskName.vhd"
                & $azCopyPath copy "$SAS" "$DestinationPath" --check-md5 NoCheck --cap-mbps 500
            } -ArgumentList $SAS, $DiskName, $LibraryVolumeName

            Write-Message "VHD downloaded to VM Node successfully." -Type "Success"
        } catch {
            Write-Message "Failed to download VHD on VM Node. Error: $_" -Type "Error"
            Revoke-AzDiskAccess -ResourceGroupName $ResourceGroupName -DiskName $DiskName -ErrorAction SilentlyContinue
            Remove-AzDisk -ResourceGroupName $ResourceGroupName -DiskName $DiskName -Force -ErrorAction SilentlyContinue
            continue
        }

        Write-Message "Revoking disk access and removing temporary disk..." -Type "Info"
        try {
            Revoke-AzDiskAccess -ResourceGroupName $ResourceGroupName -DiskName $DiskName
            Remove-AzDisk -ResourceGroupName $ResourceGroupName -DiskName $DiskName -Force | Out-Null
            Write-Message "Disk access revoked and temporary disk removed." -Type "Success"
        } catch {
            Write-Message "Failed to revoke access or remove disk $DiskName. Error: $_" -Type "Warning"
        }

        Write-Message "Converting VHD to VHDX and optimizing on VM Node..." -Type "Info"
        try {
            Invoke-Command -VMName $nodeName -Credential $hciCredentials -ScriptBlock {
                param($DiskName, $LibraryVolumeName)
                $SourcePath = "C:\ClusterStorage\$LibraryVolumeName\$DiskName.vhd"
                $DestPath = "C:\ClusterStorage\$LibraryVolumeName\$DiskName.vhdx"
                if (Test-Path $DestPath) {
                    Remove-Item -Path $DestPath -Force
                }
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

        # Prepare Image Name for Azure Stack HCI
        $ImageName = $DiskName
        Write-Message "Prepared Image Name: $ImageName" -Type "Info"

        # Correct osType determination
        $OSType = switch ($LatestImage.OsDiskImage.OperatingSystem.ToLower()) {
            "windows" { "Windows" }
            "linux"   { "Linux" }
            default   { "Unknown" }
        }

        Write-Message "Retrieving Custom Location ID..." -Type "Info"
        try {
            $CustomLocation = Get-AzCustomLocation -ResourceGroupName $ResourceGroupName
            if (-not $CustomLocation) {
                Write-Message "Custom location not found in resource group $ResourceGroupName. Skipping image $ImageName." -Type "Warning"
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

        # Ensure Template Directory Exists
        if (-not (Test-Path -Path $TemplateDirectory)) {
            try {
                New-Item -ItemType Directory -Path $TemplateDirectory -Force | Out-Null
                Write-Message "Created directory $TemplateDirectory." -Type "Success"
            } catch {
                Write-Message "Failed to create directory $TemplateDirectory. Error: $_" -Type "Error"
                continue
            }
        }

        # Define template and parameters as ordered hashtables with proper escaping
        $template = [ordered]@{
            "`$schema" = "https://schema.management.azure.com/schemas/2015-01-01/deploymentTemplate.json#"
            "contentVersion" = "1.0.0.0"
            "parameters" = @{
                "apiVersion" = @{
                    "type" = "string"
                }
                "customLocationId" = @{
                    "type" = "string"
                }
                "location" = @{
                    "type" = "string"
                }
                "imageName" = @{
                    "type" = "string"
                }
                "osType" = @{
                    "type" = "string"
                }
                "imagePath" = @{
                    "type" = "string"
                }
                "hyperVGeneration" = @{
                    "type" = "string"
                }
            }
            "resources" = @(
                [ordered]@{
                    "apiVersion" = "[parameters('apiVersion')]"
                    "extendedLocation" = @{
                        "name" = "[parameters('customLocationId')]"
                        "type" = "CustomLocation"
                    }
                    "location" = "[parameters('location')]"
                    "name" = "[parameters('imageName')]"
                    "properties" = @{
                        "osType" = "[parameters('osType')]"
                        "hyperVGeneration" = "[parameters('hyperVGeneration')]"
                        "imagePath" = "[parameters('imagePath')]"
                    }
                    "tags" = @{}
                    "type" = "microsoft.azurestackhci/galleryimages"
                }
            )
        }

        $parameters = [ordered]@{
            "`$schema" = "https://schema.management.azure.com/schemas/2015-01-01/deploymentParameters.json#"
            "contentVersion" = "1.0.0.0"
            "parameters" = @{
                "apiVersion" = @{
                    "value" = "2023-09-01-preview"
                }
                "customLocationId" = @{
                    "value" = $CustomLocationID
                }
                "location" = @{
                    "value" = $region
                }
                "imageName" = @{
                    "value" = $ImageName
                }
                "osType" = @{
                    "value" = $OSType
                }
                "imagePath" = @{
                    "value" = "C:\\ClusterStorage\\$LibraryVolumeName\\$DiskName.vhdx"
                }
                "hyperVGeneration" = @{
                    "value" = "V2"
                }
            }
        }

        # Write template and parameters to files
        try {
            $template | ConvertTo-Json -Depth 10 | Out-File -FilePath $TemplateFile -Encoding utf8 -Force
            $parameters | ConvertTo-Json -Depth 10 | Out-File -FilePath $ParameterFile -Encoding utf8 -Force
            Write-Message "ARM template and parameters files created at $TemplateFile and $ParameterFile." -Type "Success"
        } catch {
            Write-Message "Failed to write ARM template or parameters files. Error: $_" -Type "Error"
            continue
        }

        # Deploy the ARM template
        Write-Message "Deploying ARM template to create image $ImageName..." -Type "Info"
        try {
            $deploymentName = "CreateImage-$ImageName"
            New-AzResourceGroupDeployment -Name $deploymentName -ResourceGroupName $ResourceGroupName -TemplateFile $TemplateFile -TemplateParameterFile $ParameterFile -Verbose -ErrorAction Stop | Out-Null

            Write-Message "Image $ImageName added to Azure Stack HCI library successfully using ARM template." -Type "Success"

            # Remove template and parameter files after successful deployment
            try {
                Remove-Item -Path $TemplateFile -Force
                Remove-Item -Path $ParameterFile -Force
                Write-Message "Removed ARM template and parameters files." -Type "Success"
            } catch {
                Write-Message "Failed to remove ARM template or parameters files. Error: $_" -Type "Warning"
            }
        } catch {
            Write-Message "Failed to deploy ARM template for image $ImageName. Error: $_" -Type "Error"
            continue
        }
    }
}

#endregion

#region Script Execution

$currentStep++
Update-ProgressBar -CurrentStep $currentStep -TotalSteps $totalSteps -StatusMessage "Installing required PowerShell modules..."
Write-Message "Step $currentStep of $totalSteps : Installing required PowerShell modules." -Type "Info"
try {
    Install-RequiredModules
} catch {
    Write-Message "An error occurred during module installation. Error: $_" -Type "Error"
    exit 1
}

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

$currentStep++
Update-ProgressBar -CurrentStep $currentStep -TotalSteps $totalSteps -StatusMessage "Connecting to Azure..."
Write-Message "Step $currentStep of $totalSteps : Connecting to Azure." -Type "Info"
try {
    Connect-AzAccountWithRetry -MaxRetries 5 -DelaySeconds 20
} catch {
    Write-Message "An error occurred during Azure connection. Error: $_" -Type "Error"
    exit 1
}

$currentStep++
Update-ProgressBar -CurrentStep $currentStep -TotalSteps $totalSteps -StatusMessage "Selecting Subscription and Resource Group..."
Write-Message "Step $currentStep of $totalSteps : Selecting Subscription and Resource Group." -Type "Info"
try {
    $subscriptionName = Get-Option "Get-AzSubscription" "Name"
    Set-AzContext -SubscriptionName $subscriptionName -ErrorAction Stop
    Write-Message "Subscription set to: $subscriptionName" -Type "Success"

    $ResourceGroupName = Get-Option "Get-AzResourceGroup" "ResourceGroupName"
    Write-Message "Resource Group selected: $ResourceGroupName" -Type "Success"
} catch {
    Write-Message "An error occurred while selecting Subscription or Resource Group. Error: $_" -Type "Error"
    exit 1
}

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

$currentStep++
Update-ProgressBar -CurrentStep $currentStep -TotalSteps $totalSteps -StatusMessage "Importing and adding images..."
Write-Message "Step $currentStep of $totalSteps : Importing and adding images." -Type "Info"
try {
    Import-Images -ImagesToDownload $ImagesToDownload -SubscriptionID $SubscriptionID -ResourceGroupName $ResourceGroupName
} catch {
    Write-Message "An error occurred during the import and addition of images. Error: $_" -Type "Error"
    exit 1
}

$currentStep++
Update-ProgressBar -CurrentStep $currentStep -TotalSteps $totalSteps -StatusMessage "Completed."
Write-Message "Step $currentStep of $totalSteps : Completed." -Type "Success"
Write-Message "All selected images have been downloaded and added to Azure Stack HCI successfully." -Type "Success"

#endregion
