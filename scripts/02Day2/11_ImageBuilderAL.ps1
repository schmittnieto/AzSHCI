# 11_ImageBuilderAzSHCI_Optimized.ps1
<#
.SYNOPSIS
    Downloads selected VM images from Azure and integrates them into Azure Stack HCI (optimized version).

.DESCRIPTION
    This script automates the process of retrieving VM images from Azure and adding them to Azure Stack HCI.
    It performs the following tasks:
      - Installs the required PowerShell modules.
      - Connects to Azure using device authentication with retries.
      - Allows you to select the Subscription and Resource Group.
      - Retrieves available VM images based on predefined publishers.
      - Lets you select the images you want to download.
      - Creates a subdirectory to avoid permission issues.
      - Downloads the images using AzCopy directly on the VM node.
      - Converts downloaded VHD files to VHDX and optimizes them on the VM node.

.NOTES
    Run this script with administrative privileges.
#>

#region Variables

$region            = "westeurope"
$nodeName          = "NODE"
$LibraryVolumeName = "UserStorage_1"
$SubDirectoryName  = "Images"

$netBIOSName        = "AZURESTACK"
$hcilcmuser         = "hciadmin"
$hciadmin           = "${netBIOSName}\${hcilcmuser}"
$hcipassword        = "dgemsc#utquMHDHp3M"
$hciSecuredPassword = ConvertTo-SecureString $hcipassword -AsPlainText -Force
$hciCredentials     = New-Object System.Management.Automation.PSCredential ($hciadmin, $hciSecuredPassword)

$ModuleNames = @("Az.Accounts", "Az.Compute", "Az.Resources", "Az.CustomLocation")
$AzCopyUrl   = "https://aka.ms/downloadazcopy-v10-windows"

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

# Escape backslashes for file paths
$RemoteSubDirectory = "C:\\ClusterStorage\\${LibraryVolumeName}\\${SubDirectoryName}"

$totalSteps  = 6
$currentStep = 0

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

    if (-not (Get-PSRepository -Name "PSGallery" -ErrorAction SilentlyContinue)) {
        Write-Message "PSGallery is not registered. Please register it manually if necessary." -Type "Warning"
    }

    foreach ($ModuleName in $ModuleNames) {
        if (-not (Get-Module -ListAvailable -Name $ModuleName)) {
            Write-Message "Installing module: $ModuleName" -Type "Info"
            try {
                Install-Module -Name $ModuleName -Force -AllowClobber -ErrorAction Stop
                Write-Message "Module $ModuleName installed successfully." -Type "Success"
            } catch {
                Write-Message "Error installing module $ModuleName. Error: $($_.Exception.Message)" -Type "Error"
                exit 1
            }
        } else {
            Write-Message "Module $ModuleName is already installed." -Type "Success"
        }
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
        if (-not $options) {
            Write-Message "No options found for command '$Command'." -Type "Warning"
            exit 1
        }
        $selectedOption = $options | Out-GridView -Title "Select $PropertyName" -OutputMode Single
        return $selectedOption.$PropertyName
    } catch {
        Write-Message "Error executing command '$Command'. Error: $($_.Exception.Message)" -Type "Error"
        exit 1
    }
}

function Connect-AzAccountWithRetry {
    param (
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

function Select-ImagesToDownload {
    Write-Message "Retrieving VM image offers from publishers..." -Type "Info"
    try {
        $ImageOffers = $Publishers | ForEach-Object {
            Get-AzVMImageOffer -Location $region -PublisherName $_ -ErrorAction SilentlyContinue
        } | Where-Object { $_ -ne $null }

        $ImageSKUs = $ImageOffers | ForEach-Object {
            Get-AzVMImageSku -Location $region -PublisherName $_.PublisherName -Offer $_.Offer -ErrorAction SilentlyContinue
        } | Where-Object { $_ -ne $null }

        Write-Message "Please select the images you want to download." -Type "Info"
        $SelectedImages = $ImageSKUs | Out-GridView -Title "Select Images to Download" -OutputMode Multiple
        return $SelectedImages
    } catch {
        Write-Message "Error retrieving VM images. Error: $($_.Exception.Message)" -Type "Error"
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

        $LatestImage = Get-AzVMImage -Location $region -PublisherName $ImageSKU.PublisherName -Offer $ImageSKU.Offer -Skus $ImageSKU.Skus -ErrorAction SilentlyContinue |
                       Sort-Object Version -Descending | Select-Object -First 1
        if (-not $LatestImage) {
            Write-Message "No image found for $($ImageSKU.PublisherName) - $($ImageSKU.Offer) - $($ImageSKU.Skus). Skipping..." -Type "Warning"
            continue
        }

        $DiskNameOriginal = "$($LatestImage.Skus)$($LatestImage.Version)"
        $DiskName = ($DiskNameOriginal -replace '[^a-zA-Z0-9]', '')
        Write-Message "Creating OS Disk: $DiskName" -Type "Info"

        try {
            $OSDiskConfig = New-AzDiskConfig -Location $region -CreateOption "FromImage" -ImageReference @{ Id = $LatestImage.Id }
            New-AzDisk -ResourceGroupName $ResourceGroupName -DiskName $DiskName -Disk $OSDiskConfig | Out-Null
            Write-Message "OS Disk $DiskName created successfully." -Type "Success"
        } catch {
            Write-Message "Error creating OS Disk $DiskName. Error: $($_.Exception.Message)" -Type "Error"
            continue
        }

        Write-Message "Granting access to disk $DiskName..." -Type "Info"
        try {
            $DiskAccess = Grant-AzDiskAccess -ResourceGroupName $ResourceGroupName -DiskName $DiskName -Access 'Read' -DurationInSecond 3600 -ErrorAction Stop
            $SAS = $DiskAccess.AccessSas
            Write-Message "Access granted. SAS Token acquired." -Type "Success"
        } catch {
            Write-Message "Error granting access to disk $DiskName. Error: $($_.Exception.Message)" -Type "Error"
            Remove-AzDisk -ResourceGroupName $ResourceGroupName -DiskName $DiskName -Force | Out-Null
            continue
        }

        Write-Message "Downloading VHD directly to the VM Node using AzCopy..." -Type "Info"
        try {
            Invoke-Command -VMName $nodeName -Credential $hciCredentials -ArgumentList $AzCopyUrl, "C:\\ClusterStorage\\${LibraryVolumeName}\\${SubDirectoryName}", $SAS, $DiskName -ScriptBlock {
                param($AzCopyUrl, $SubDirectoryPath, $SAS, $DiskName)
                $azCopyExe = "C:\\AzCopy\\azcopy.exe"
                if (-not (Test-Path $azCopyExe)) {
                    Write-Output "AzCopy not found. Installing..."
                    New-Item -ItemType Directory -Path "C:\\AzCopy" -Force | Out-Null
                    $azCopyZip = "C:\\AzCopy\\AzCopy.zip"
                    try {
                        Invoke-WebRequest -Uri $AzCopyUrl -OutFile $azCopyZip -UseBasicParsing -ErrorAction Stop
                        Expand-Archive -Path $azCopyZip -DestinationPath "C:\\AzCopy" -Force
                        Remove-Item -Path $azCopyZip -Force
                        $azCopyFound = Get-ChildItem -Path "C:\\AzCopy" -Filter "azcopy.exe" -Recurse | Select-Object -First 1
                        if ($azCopyFound) {
                            Move-Item -Path $azCopyFound.FullName -Destination $azCopyExe -Force
                            Write-Output "AzCopy installed successfully."
                        } else {
                            throw "azcopy.exe not found after extraction."
                        }
                    } catch {
                        throw "Error installing AzCopy: $($_.Exception.Message)"
                    }
                } else {
                    Write-Output "AzCopy is already installed."
                }
                if (-not (Test-Path $SubDirectoryPath)) {
                    New-Item -ItemType Directory -Path $SubDirectoryPath -Force | Out-Null
                    Write-Output "Subdirectory created: $SubDirectoryPath"
                } else {
                    Write-Output "Subdirectory exists: $SubDirectoryPath"
                }
                $DestinationPath = "C:\\ClusterStorage\\${LibraryVolumeName}\\${SubDirectoryName}\\${DiskName}.vhd"
                & $azCopyExe copy "$SAS" "$DestinationPath" --check-md5 NoCheck --cap-mbps 500
            }
            Write-Message "VHD downloaded successfully on the VM Node." -Type "Success"
        } catch {
            Write-Message "Error downloading VHD on the VM Node. Error: $($_.Exception.Message)" -Type "Error"
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
            Write-Message "Warning: Could not revoke access or remove disk $DiskName. Error: $($_.Exception.Message)" -Type "Warning"
        }

        Write-Message "Converting VHD to VHDX and optimizing on the VM Node..." -Type "Info"
        try {
            $DestPath = Invoke-Command -VMName $nodeName -Credential $hciCredentials -ArgumentList $DiskName, $LibraryVolumeName, $SubDirectoryName -ScriptBlock {
                param($DiskName, $LibraryVolumeName, $SubDirectoryName)
                $SourcePath = "C:\\ClusterStorage\\${LibraryVolumeName}\\${SubDirectoryName}\\${DiskName}.vhd"
                $DestPath   = "C:\\ClusterStorage\\${LibraryVolumeName}\\${SubDirectoryName}\\${DiskName}.vhdx"
                if (Test-Path $DestPath) { Remove-Item -Path $DestPath -Force }
                Convert-VHD -Path $SourcePath -DestinationPath $DestPath -VHDType Dynamic -DeleteSource
                Optimize-VHD -Path $DestPath -Mode Full
                return $DestPath
            }
            Write-Message "VHD converted to VHDX and optimized successfully." -Type "Success"
        } catch {
            Write-Message "Error converting or optimizing VHD for $DiskName on the VM Node. Error: $($_.Exception.Message)" -Type "Error"
            Invoke-Command -VMName $nodeName -Credential $hciCredentials -ArgumentList $DiskName, $LibraryVolumeName, $SubDirectoryName -ScriptBlock {
                param($DiskName, $LibraryVolumeName, $SubDirectoryName)
                $vhdPath = "C:\\ClusterStorage\\${LibraryVolumeName}\\${SubDirectoryName}\\${DiskName}.vhd"
                if (Test-Path $vhdPath) { Remove-Item -Path $vhdPath -Force -ErrorAction SilentlyContinue }
            }
            continue
        }
    }
}

#endregion

#region Script Execution

try {
    # Step 1: Install required modules
    $currentStep++
    Update-ProgressBar -CurrentStep $currentStep -TotalSteps $totalSteps -StatusMessage "Installing required modules..."
    Write-Message "Step $currentStep of $totalSteps : Installing required modules." -Type "Info"
    Install-RequiredModules

    # Step 2: Connect to Azure
    $currentStep++
    Update-ProgressBar -CurrentStep $currentStep -TotalSteps $totalSteps -StatusMessage "Connecting to Azure..."
    Write-Message "Step $currentStep of $totalSteps : Connecting to Azure." -Type "Info"
    Connect-AzAccountWithRetry -MaxRetries 5 -DelaySeconds 20

    # Step 3: Select Subscription and Resource Group
    $currentStep++
    Update-ProgressBar -CurrentStep $currentStep -TotalSteps $totalSteps -StatusMessage "Selecting Subscription and Resource Group..."
    Write-Message "Step $currentStep of $totalSteps : Selecting Subscription and Resource Group." -Type "Info"
    $selectedContext = Get-AzContext -ErrorAction Stop
    $SubscriptionName = $selectedContext.Subscription.Name
    $SubscriptionId   = $selectedContext.Subscription.Id
    Write-Message "Subscription selected: $SubscriptionName" -Type "Success"
    $ResourceGroupName = Get-Option "Get-AzResourceGroup" "ResourceGroupName"
    Write-Message "Resource Group selected: $ResourceGroupName" -Type "Success"

    # Step 4: Select images to download
    $currentStep++
    Update-ProgressBar -CurrentStep $currentStep -TotalSteps $totalSteps -StatusMessage "Selecting images to download..."
    Write-Message "Step $currentStep of $totalSteps : Selecting images to download." -Type "Info"
    $ImagesToDownload = Select-ImagesToDownload
    if (-not $ImagesToDownload) {
        Write-Message "No images selected for download. Exiting script." -Type "Warning"
        exit 0
    }

    # Step 5: Import and add images
    $currentStep++
    Update-ProgressBar -CurrentStep $currentStep -TotalSteps $totalSteps -StatusMessage "Importing and adding images..."
    Write-Message "Step $currentStep of $totalSteps : Importing and adding images." -Type "Info"
    Import-Images -ImagesToDownload $ImagesToDownload -SubscriptionID $SubscriptionId -ResourceGroupName $ResourceGroupName

    # Step 6: Completion and list images
    $currentStep++
    Update-ProgressBar -CurrentStep $currentStep -TotalSteps $totalSteps -StatusMessage "Completed."
    Write-Message "Step $currentStep of $totalSteps : Completed." -Type "Success"

    try {
        $imageList = Invoke-Command -VMName $nodeName -Credential $hciCredentials -ArgumentList $RemoteSubDirectory -ScriptBlock {
            param($SubDirectoryPath)
            Get-ChildItem -Path $SubDirectoryPath -Filter "*.vhdx" |
                Sort-Object LastWriteTime -Descending |
                Select-Object -ExpandProperty FullName
        }
        if ($imageList) {
            Write-Message "The images can be added from the portal as Custom Local Images using the following paths:" -Type "Info"
            $imageList | ForEach-Object { Write-Message $_ -Type "Info" }
        } else {
            Write-Message "No disks were processed." -Type "Warning"
        }
    } catch {
        Write-Message "Error retrieving images from the VM Node. Error: $($_.Exception.Message)" -Type "Error"
    }
} catch {
    Write-Message "An error occurred during script execution. Error: $($_.Exception.Message)" -Type "Error"
    exit 1
}

#endregion
