# 11_ImageBuilderAzSHCI.ps1
# Automates the process of pulling VM images from Azure and adding them to Azure Stack HCI.

<#
.SYNOPSIS
    Downloads selected VM images from Azure to Azure Stack HCI.

.DESCRIPTION
    This script performs the following tasks:
    - Installs necessary PowerShell modules if not already installed.
    - Connects to Azure using device code authentication with retries.
    - Allows the user to select the Azure subscription and resource group.
    - Retrieves available VM images based on predefined publishers.
    - Allows the user to select images to download.
    - Downloads selected images using AzCopy directly on the VM Node.
    - Converts downloaded VHDs to VHDX format and optimizes them on the VM Node.

.NOTES
    - Based on Jaromir´s aproach: https://github.com/DellGEOS/AzureStackHOLs/tree/main/tips%26tricks/09-PullingImageFromAzure
    - Designed by Cristian Schmitt Nieto. For more information and usage, visit: https://schmitt-nieto.com/blog/azure-stack-hci-day2/
    - Ensure you run this script with administrative privileges.
    - Requires PowerShell 5.1 or later.
    - Ensure the Execution Policy allows the script to run. To set the execution policy, run:
      Set-ExecutionPolicy RemoteSigned -Scope CurrentUser
#>

#region Variables

$region = "westeurope"
$nodeName = "NODE"
$LibraryVolumeName = "UserStorage_1"

$netBIOSName = "AZURESTACK"
$hcilcmuser = "hciadmin"
$hciadmin = "$netBIOSName\$hcilcmuser"
$hcipassword = "dgemsc#utquMHDHp3M"
$hciSecuredPassword = ConvertTo-SecureString $hcipassword -AsPlainText -Force
$hciCredentials = New-Object System.Management.Automation.PSCredential ($hciadmin, $hciSecuredPassword)

$ModuleNames = @("Az.Accounts", "Az.Compute", "Az.Resources", "Az.CustomLocation")

$AzCopyUrl = "https://aka.ms/downloadazcopy-v10-windows"

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

$DiskPaths = @()

$totalSteps = 6
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

    if (-not (Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue)) {
        Write-Message "Installing NuGet package provider..." -Type "Info"
        try {
            # Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -ErrorAction Stop
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
                return $DestPath
            } -ArgumentList $DiskName, $LibraryVolumeName
            Write-Message "VHD converted to VHDX and optimized successfully." -Type "Success"
            $DiskPaths += $DestPath
        } catch {
            Write-Message "Failed to convert or optimize VHD for $DiskName on VM Node. Error: $_" -Type "Error"
            Invoke-Command -VMName $nodeName -Credential $hciCredentials -ScriptBlock {
                param($LibraryVolumeName, $DiskName)
                Remove-Item -Path "C:\ClusterStorage\$LibraryVolumeName\$DiskName.vhd" -Force -ErrorAction SilentlyContinue
            } -ArgumentList $LibraryVolumeName, $DiskName
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
Update-ProgressBar -CurrentStep $currentStep -TotalSteps $totalSteps -StatusMessage "Selecting Subscription and Resource Group..."
Write-Message "Step $currentStep of $totalSteps : Selecting Subscription and Resource Group." -Type "Info"
try {
    $selectedSubscription = Get-AzContext -ErrorAction Stop
    $SubscriptionName = $selectedSubscription.Subscription.Name
    $SubscriptionId = $selectedSubscription.Subscription.Id
    Write-Message "Subscription selected: $SubscriptionName " -Type "Success"
    $ResourceGroupName = Get-Option "Get-AzResourceGroup" "ResourceGroupName"
    Write-Message "Resource Group selected: $ResourceGroupName" -Type "Success"
} catch {
    Write-Message "An error occurred while selecting Subscription or Resource Group. Error: $_" -Type "Error"
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

if ($DiskPaths.Count -gt 0) {
    Write-Message "Your disks are located at the following paths:" -Type "Success"
    foreach ($path in $DiskPaths) {
        Write-Message $path -Type "Info"
    }
} else {
    Write-Message "No disks were processed." -Type "Warning"
}

#endregion
