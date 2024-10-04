# 01_DC.ps1
# Domain Controller Configuration Script

<#
.SYNOPSIS
    Configures the Domain Controller VM, sets network settings, promotes it to a Domain Controller, installs updates, and sets up Active Directory Organizational Units.

.DESCRIPTION
    This script performs the following tasks:
    - Sets up credentials and network configurations.
    - Removes the ISO from the DC VM.
    - Renames the Domain Controller VM.
    - Configures network adapters with static IP settings.
    - Sets the time zone.
    - Promotes the VM to a Domain Controller.
    - Installs Windows Updates.
    - Configures DNS forwarders.
    - Creates Organizational Units (OUs) in Active Directory.
    - Installs necessary modules and creates Azure Stack HCI AD objects.

.NOTES
    - Designed by Cristian Schmitt Nieto. For more information and usage, visit: https://schmitt-nieto.com
    - Run this script with administrative privileges.
    - Ensure the Execution Policy allows the script to run. To set the execution policy, you can run:
      Set-ExecutionPolicy RemoteSigned -Scope CurrentUser
#>

#region Variables

# Define credentials and variables
$defaultUser = "Administrator"
$defaultPwd = "D0m41nC0ntr0LL3r"
$DefaultSecuredPassword = ConvertTo-SecureString $defaultPwd -AsPlainText -Force
$DefaultCredentials = New-Object System.Management.Automation.PSCredential ($defaultUser, $DefaultSecuredPassword)

# VM and Domain Variables
$dcVMName  = "DC"
$domainName = "azurestack.local"
$netBIOSName = "AZURESTACK"

$NIC1 = "MGMT1"
$nic1IP = "172.19.19.2"
$nic1GW = "172.19.19.1"
$nic1DNS = "172.19.19.2"

# Variables for DNS forwarder and time zone
$dnsForwarder = "8.8.8.8"
$timeZone = "W. Europe Standard Time" # Use "Get-TimeZone -ListAvailable" to get a list of available Time Zones

# User for Azure Stack HCI LCM User (to be used later)
$setupUser = "hciadmin"
$setupPwd = "dgemsc#utquMHDHp3M"

# Sleep durations in seconds
$SleepRename = 20     # Sleep Timer for after PC Renaming
$SleepDomain = 360    # Sleep Timer for after Domain Making
$SleepUpdates = 240   # Sleep Timer for after Update Installation
# $SleepADServices = 30 # Increased Sleep Timer after DC promotion before configuring AD

# Total number of steps for progress calculation
$totalSteps = 12
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
    # $LogFile = "C:\HCI\DeploymentLogs\01_DC_Log_$(Get-Date -Format 'yyyyMMdd_HHmmss').txt"
    # New-Item -Path (Split-Path $LogFile) -ItemType Directory -Force | Out-Null
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
        Write-Progress -Id 2 -Activity "Sleep Progress" -Status "$Activity : $i/$Seconds seconds elapsed... Use Spacebar to Skip" -PercentComplete $percent
        Start-Sleep -Seconds 1
    }

    Write-Progress -Id 2 -Activity "Sleep Progress" -Completed
    Write-Message "$Activity : Completed." -Type "Success"
}

# Function to Wait Until Active Directory is Ready
function Wait-UntilADReady {
    param(
        [string]$VMName,
        [int]$Timeout = 600 # Timeout in seconds (10 minutes)
    )

    $elapsed = 0
    $interval = 10

    Write-Message "Checking if Active Directory services are operational on VM '$VMName'..." -Type "Info"

    while ($elapsed -lt $Timeout) {
        try {
            Invoke-Command -VMName $VMName -Credential $DomainAdminCredentials -ScriptBlock {
                Get-ADDomain -ErrorAction Stop
            } -ErrorAction Stop -WarningAction SilentlyContinue | Out-Null

            Write-Message "Active Directory services are operational on VM '$VMName'." -Type "Success"
            return
        } catch {
            Write-Message "Active Directory services not ready yet. Waiting..." -Type "Info"
            Start-Sleep -Seconds $interval
            $elapsed += $interval
        }
    }

    Write-Message "Active Directory services did not become operational within the expected time." -Type "Error"
    exit 1
}

#endregion

#region Script Execution

# Step 1: Remove ISO from DC VM
$currentStep++
Update-ProgressBar -CurrentStep $currentStep -TotalSteps $totalSteps -StatusMessage "Removing ISO from VM..."
Write-Message "Removing ISO from DC VM '$dcVMName'..." -Type "Info"
try {
    Get-VMDvdDrive -VMName $dcVMName | Where-Object { $_.DvdMediaType -eq "ISO" } | Remove-VMDvdDrive -ErrorAction Stop -WarningAction SilentlyContinue | Out-Null
    Write-Message "ISO removed from VM '$dcVMName'." -Type "Success"
} catch {
    Write-Message "Failed to remove ISO from VM '$dcVMName'. Error: $_" -Type "Error"
    exit 1
}

# Step 2: Retrieve and format MAC address
$currentStep++
Update-ProgressBar -CurrentStep $currentStep -TotalSteps $totalSteps -StatusMessage "Retrieving MAC address..."
Write-Message "Retrieving MAC address for network adapter '$NIC1' on VM '$dcVMName'..." -Type "Info"
try {
    $dcMacNIC1 = Get-VMNetworkAdapter -VMName $dcVMName -Name $NIC1 -ErrorAction Stop -WarningAction SilentlyContinue
    $dcMacNIC1Address = $dcMacNIC1.MacAddress
    $dcFinalMacNIC1 = $dcMacNIC1Address.Insert(2,"-").Insert(5,"-").Insert(8,"-").Insert(11,"-").Insert(14,"-").ToUpper()
    Write-Message "Formatted MAC address for '$NIC1': $dcFinalMacNIC1" -Type "Success"
} catch {
    Write-Message "Failed to retrieve MAC address for '$NIC1'. Error: $_" -Type "Error"
    exit 1
}

# Step 3: Rename the DC VM
$currentStep++
Update-ProgressBar -CurrentStep $currentStep -TotalSteps $totalSteps -StatusMessage "Renaming VM..."
Write-Message "Renaming VM '$dcVMName'..." -Type "Info"
try {
    Invoke-Command -VMName $dcVMName -Credential $DefaultCredentials -ScriptBlock {
        param($dcVMName)
        $ErrorActionPreference = 'Stop'
        $WarningPreference = 'SilentlyContinue'
        $VerbosePreference = 'SilentlyContinue'
        $ProgressPreference = 'SilentlyContinue'

        # Rename computer
        Rename-Computer -NewName $dcVMName -Force -ErrorAction Stop

        # Restart computer
        Restart-Computer -Force -ErrorAction Stop
    } -ArgumentList $dcVMName -ErrorAction Stop -WarningAction SilentlyContinue -Verbose:$false | Out-Null
    Write-Message "VM '$dcVMName' has been renamed and will restart to apply changes." -Type "Success"

    # Restart the DC VM to apply changes
    Write-Message "VM '$dcVMName' is restarting..." -Type "Info"
    Start-SleepWithProgress -Seconds $SleepRename -Activity "Restarting VM" -Status "Waiting for VM to restart" # 20 Seconds
} catch {
    Write-Message "Failed to rename or restart VM '$dcVMName'. Error: $_" -Type "Error"
    exit 1
}

# Step 4: Configure Network Settings
$currentStep++
Update-ProgressBar -CurrentStep $currentStep -TotalSteps $totalSteps -StatusMessage "Configuring network settings..."
Write-Message "Configuring network settings for VM '$dcVMName'..." -Type "Info"
try {
    Invoke-Command -VMName $dcVMName -Credential $DefaultCredentials -ScriptBlock {
        param($NIC1, $nic1IP, $nic1GW, $nic1DNS, $dcFinalMacNIC1)
        $ErrorActionPreference = 'Stop'
        $WarningPreference = 'SilentlyContinue'
        $VerbosePreference = 'SilentlyContinue'
        $ProgressPreference = 'SilentlyContinue'

        # Rename network adapter based on MAC address
        Get-NetAdapter -Physical | Where-Object { $_.MacAddress -eq $dcFinalMacNIC1 } | Rename-NetAdapter -NewName $NIC1 -ErrorAction Stop -WarningAction SilentlyContinue | Out-Null

        # Disable DHCP and set static IP
        Set-NetIPInterface -InterfaceAlias $NIC1 -Dhcp Disabled -ErrorAction Stop -WarningAction SilentlyContinue | Out-Null
        New-NetIPAddress -InterfaceAlias $NIC1 -IPAddress $nic1IP -PrefixLength 24 -DefaultGateway $nic1GW -ErrorAction Stop -WarningAction SilentlyContinue | Out-Null
        Set-DnsClientServerAddress -InterfaceAlias $NIC1 -ServerAddresses $nic1DNS -ErrorAction Stop -WarningAction SilentlyContinue | Out-Null
    } -ArgumentList $NIC1, $nic1IP, $nic1GW, $nic1DNS, $dcFinalMacNIC1 -ErrorAction Stop -WarningAction SilentlyContinue -Verbose:$false | Out-Null

    Write-Message "The IP address of NIC '$NIC1' is $nic1IP." -Type "Success"
} catch {
    Write-Message "Failed to configure network settings for VM '$dcVMName'. Error: $_" -Type "Error"
    exit 1
}

# Step 5: Set the time zone
$currentStep++
Update-ProgressBar -CurrentStep $currentStep -TotalSteps $totalSteps -StatusMessage "Setting time zone..."
Write-Message "Setting time zone for VM '$dcVMName'..." -Type "Info"
try {
    Invoke-Command -VMName $dcVMName -Credential $DefaultCredentials -ScriptBlock {
        param($timeZone)
        $ErrorActionPreference = 'Stop'
        $WarningPreference = 'SilentlyContinue'
        $VerbosePreference = 'SilentlyContinue'
        $ProgressPreference = 'SilentlyContinue'

        # Set the time zone
        Set-TimeZone -Name $timeZone -ErrorAction Stop -WarningAction SilentlyContinue | Out-Null
    } -ArgumentList $timeZone -ErrorAction Stop -WarningAction SilentlyContinue -Verbose:$false | Out-Null

    Write-Message "Time zone set to '$timeZone' for VM '$dcVMName'." -Type "Success"
} catch {
    Write-Message "Failed to set time zone for VM '$dcVMName'. Error: $_" -Type "Error"
    exit 1
}

# Step 6: Promote the DC VM to a Domain Controller
$currentStep++
Update-ProgressBar -CurrentStep $currentStep -TotalSteps $totalSteps -StatusMessage "Promoting to Domain Controller..."
Write-Message "Promoting VM '$dcVMName' to a Domain Controller..." -Type "Info"
try {
    Invoke-Command -VMName $dcVMName -Credential $DefaultCredentials -ScriptBlock {
        param($domainName, $netBIOSName, $defaultPwd)
        $ErrorActionPreference = 'Stop'
        $WarningPreference = 'SilentlyContinue'
        $VerbosePreference = 'SilentlyContinue'
        $ProgressPreference = 'SilentlyContinue'

        # Install Active Directory Domain Services
        Install-WindowsFeature -Name AD-Domain-Services -IncludeManagementTools -ErrorAction Stop | Out-Null

        # Import the ADDSDeployment module after installing the feature
        Import-Module ADDSDeployment -ErrorAction Stop | Out-Null

        # Secure password for DSRM
        $SecureDSRMPassword = ConvertTo-SecureString $defaultPwd -AsPlainText -Force

        # Promote to Domain Controller
        Install-ADDSForest `
            -DomainName $domainName `
            -DomainNetbiosName $netBIOSName `
            -SafeModeAdministratorPassword $SecureDSRMPassword `
            -InstallDns `
            -Force:$true `
            -Confirm:$false `
            -ErrorAction Stop | Out-Null
    } -ArgumentList $domainName, $netBIOSName, $defaultPwd -ErrorAction Stop -WarningAction SilentlyContinue -Verbose:$false | Out-Null

    Write-Message "Domain Controller promotion initiated for VM '$dcVMName'." -Type "Success"

    # Wait for DC promotion to complete
    Write-Message "Waiting for Domain Controller promotion to complete..." -Type "Info"
    Start-SleepWithProgress -Seconds $SleepDomain -Activity "Waiting for DC promotion" -Status "Waiting for VM to restart and apply domain changes" # 360 Seconds (6 Minutes)
} catch {
    Write-Message "Failed to promote VM '$dcVMName' to a Domain Controller. Error: $_" -Type "Error"
    exit 1
}

# Step 7: Update credentials to use the domain Administrator account
$currentStep++
Update-ProgressBar -CurrentStep $currentStep -TotalSteps $totalSteps -StatusMessage "Updating credentials..."
Write-Message "Updating credentials to use the domain Administrator account..." -Type "Info"
try {
    $domainAdminUser = "$netBIOSName\$defaultUser"
    $DomainAdminCredentials = New-Object System.Management.Automation.PSCredential ($domainAdminUser, $DefaultSecuredPassword)
    Write-Message "Credentials updated successfully." -Type "Success"
} catch {
    Write-Message "Failed to update credentials. Error: $_" -Type "Error"
    exit 1
}

# Step 8: Configure DNS Forwarder and Time Server
$currentStep++
Update-ProgressBar -CurrentStep $currentStep -TotalSteps $totalSteps -StatusMessage "Configuring DNS forwarder..."
Write-Message "Configuring DNS forwarder on VM '$dcVMName'..." -Type "Info"
try {
    Invoke-Command -VMName $dcVMName -Credential $DomainAdminCredentials -ScriptBlock {
        param($dnsForwarder)
        $ErrorActionPreference = 'Stop'
        $WarningPreference = 'SilentlyContinue'
        $VerbosePreference = 'SilentlyContinue'
        $ProgressPreference = 'SilentlyContinue'

        # Import DNS Server module
        Import-Module DNSServer -ErrorAction Stop -WarningAction SilentlyContinue | Out-Null

        # Add DNS forwarder
        Add-DnsServerForwarder -IPAddress $dnsForwarder -ErrorAction Stop -WarningAction SilentlyContinue | Out-Null

        # Configure time synchronization
        w32tm /config /manualpeerlist:europe.pool.ntp.org /syncfromflags:manual /reliable:yes /update | Out-Null
        Restart-Service w32time -Force | Out-Null
        w32tm /resync | Out-Null

    } -ArgumentList $dnsForwarder -ErrorAction Stop -WarningAction SilentlyContinue -Verbose:$false | Out-Null

    Write-Message "DNS forwarder to $dnsForwarder added successfully on VM '$dcVMName'." -Type "Success"
} catch {
    Write-Message "Failed to configure DNS forwarder on VM '$dcVMName'. Error: $_" -Type "Error"
    exit 1
}

# Step 9: Install Windows Updates
$currentStep++
Update-ProgressBar -CurrentStep $currentStep -TotalSteps $totalSteps -StatusMessage "Installing Windows Updates..."
Write-Message "Installing Windows Updates on VM '$dcVMName'..." -Type "Info"
try {
    Invoke-Command -VMName $dcVMName -Credential $DomainAdminCredentials -ScriptBlock {
        $ErrorActionPreference = 'Stop'
        $WarningPreference = 'SilentlyContinue'
        $VerbosePreference = 'SilentlyContinue'
        $ProgressPreference = 'Continue'

        # Import the PSWindowsUpdate module
        Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -ErrorAction Stop -WarningAction SilentlyContinue | Out-Null
        Install-Module PSWindowsUpdate -Force -ErrorAction Stop -WarningAction SilentlyContinue | Out-Null
        Import-Module PSWindowsUpdate -ErrorAction Stop -WarningAction SilentlyContinue | Out-Null

        # Install available updates
        Install-WindowsUpdate -MicrosoftUpdate -AcceptAll -AutoReboot -IgnoreReboot -ErrorAction Stop -WarningAction SilentlyContinue | Out-Null
    } -ErrorAction Stop -WarningAction SilentlyContinue -Verbose:$false | Out-Null

    Write-Message "Windows Updates installation initiated on VM '$dcVMName'." -Type "Success"

    # Wait for the DC VM to restart after updates
    Write-Message "Waiting for the Domain Controller to restart after updates..." -Type "Info"
    Start-SleepWithProgress -Seconds $SleepUpdates -Activity "Waiting for VM to restart" -Status "Waiting for VM to restart and apply updates" # 240 Seconds (4 Minutes)
} catch {
    Write-Message "Failed to install Windows Updates on VM '$dcVMName'. Error: $_" -Type "Error"
    exit 1
}

# Step 10: Create Organizational Units (OUs)
$currentStep++
Update-ProgressBar -CurrentStep $currentStep -TotalSteps $totalSteps -StatusMessage "Creating Organizational Units..."
Write-Message "Creating Organizational Units (OUs) in Active Directory on VM '$dcVMName'..." -Type "Info"
try {
    # Wait until AD is ready
    Wait-UntilADReady -VMName $dcVMName -Timeout 600 # 10 minutes

    # Proceed to create OUs
    Invoke-Command -VMName $dcVMName -Credential $DomainAdminCredentials -ScriptBlock {
        param($netBIOSName, $domainName)
        $ErrorActionPreference = 'Stop'
        $WarningPreference = 'SilentlyContinue'
        $VerbosePreference = 'SilentlyContinue'
        $ProgressPreference = 'SilentlyContinue'

        try {
            # Import Active Directory module
            Import-Module ActiveDirectory -ErrorAction Stop -WarningAction SilentlyContinue | Out-Null

            # Get the current domain
            $domainDN = (Get-ADDomain).DistinguishedName

            # Define the root OU path
            $rootOU = "OU=_LAB,$domainDN"

            # Create the root OU "_LAB" (if it doesn't exist)
            if (-not (Get-ADOrganizationalUnit -Filter { Name -eq "_LAB" } -SearchBase $domainDN -ErrorAction SilentlyContinue )) {
                New-ADOrganizationalUnit -Name "_LAB" -Path $domainDN -ErrorAction Stop | Out-Null
                Write-Host "Created root OU '_LAB'."
            }

            # Create sub-OUs for Users
            $userOUs = @("Users", "Administrative", "Technical", "Financial", "Workers")
            foreach ($ou in $userOUs) {
                if ($ou -eq "Users") {
                    $path = $rootOU
                } else {
                    $path = "OU=Users,$rootOU"
                }

                if (-not (Get-ADOrganizationalUnit -Filter { Name -eq $ou } -SearchBase $path -ErrorAction SilentlyContinue )) {
                    New-ADOrganizationalUnit -Name $ou -Path $path -ErrorAction Stop | Out-Null
                    Write-Host "Created OU '$ou' under '$path'."
                }
            }

            # Create sub-OUs for Servers
            $serverOUs = @("Servers", "Windows", "Linux", "HCI")
            foreach ($ou in $serverOUs) {
                if ($ou -eq "Servers") {
                    $path = $rootOU
                } else {
                    $path = "OU=Servers,$rootOU"
                }

                if (-not (Get-ADOrganizationalUnit -Filter { Name -eq $ou } -SearchBase $path -ErrorAction SilentlyContinue )) {
                    New-ADOrganizationalUnit -Name $ou -Path $path -ErrorAction Stop | Out-Null
                    Write-Host "Created OU '$ou' under '$path'."
                }
            }

            # Create sub-OUs for Groups
            $groupOUs = @("Groups", "Security", "Distribution")
            foreach ($ou in $groupOUs) {
                if ($ou -eq "Groups") {
                    $path = $rootOU
                } else {
                    $path = "OU=Groups,$rootOU"
                }

                if (-not (Get-ADOrganizationalUnit -Filter { Name -eq $ou } -SearchBase $path -ErrorAction SilentlyContinue )) {
                    New-ADOrganizationalUnit -Name $ou -Path $path -ErrorAction Stop | Out-Null
                    Write-Host "Created OU '$ou' under '$path'."
                }
            }

            # Create sub-OUs for Computers
            $computerOUs = @("Computers", "Desktops", "Laptops", "AVD")
            foreach ($ou in $computerOUs) {
                if ($ou -eq "Computers") {
                    $path = $rootOU
                } else {
                    $path = "OU=Computers,$rootOU"
                }

                if (-not (Get-ADOrganizationalUnit -Filter { Name -eq $ou } -SearchBase $path -ErrorAction SilentlyContinue )) {
                    New-ADOrganizationalUnit -Name $ou -Path $path -ErrorAction Stop | Out-Null
                    Write-Host "Created OU '$ou' under '$path'."
                }
            }
        } catch {
            Write-Error "An error occurred while creating OUs: $_"
            throw $_
        }
    } -ArgumentList $netBIOSName, $domainName -ErrorAction Stop -WarningAction SilentlyContinue -Verbose:$false | Out-Null

    Write-Message "Organizational Units (OUs) created successfully in Active Directory." -Type "Success"
} catch {
    Write-Message "Failed to create Organizational Units (OUs) in Active Directory. Error: $_" -Type "Error"
    exit 1
}

# Step 11: Install Azure Stack HCI AD Artifacts
$currentStep++
Update-ProgressBar -CurrentStep $currentStep -TotalSteps $totalSteps -StatusMessage "Installing Azure Stack HCI AD Artifacts..."
Write-Message "Installing Azure Stack HCI AD Artifacts Pre-Creation Tool and creating AD objects..." -Type "Info"
try {
    Invoke-Command -VMName $dcVMName -Credential $DomainAdminCredentials -ScriptBlock {
        param($setupUser, $setupPwd)
        $ErrorActionPreference = 'Stop'
        $WarningPreference = 'SilentlyContinue'
        $VerbosePreference = 'SilentlyContinue'
        $ProgressPreference = 'SilentlyContinue'

        # Suppress informational messages
        $InformationPreference = 'SilentlyContinue'

        # Import Active Directory module
        Import-Module ActiveDirectory -ErrorAction Stop -WarningAction SilentlyContinue | Out-Null

        # Suppress confirmation prompts
        $ConfirmPreferenceBackup = $ConfirmPreference
        $ConfirmPreference = 'None'

        try {
            # Install the NuGet package provider if not already installed
            if (-not (Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue)) {
                Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -ErrorAction Stop -WarningAction SilentlyContinue | Out-Null
            }

            # Install the AsHciADArtifactsPreCreationTool module from PSGallery
            if (-not (Get-Module -ListAvailable -Name AsHciADArtifactsPreCreationTool)) {
                Install-Module AsHciADArtifactsPreCreationTool -Repository PSGallery -Force -ErrorAction Stop -WarningAction SilentlyContinue | Out-Null
            }

            # Define the OU path for Azure Stack HCI
            $AsHciOUPath = "OU=HCI,OU=Servers,OU=_LAB," + (Get-ADDomain).DistinguishedName

            # Secure credentials for Azure Stack HCI user
            $SecurePassword = ConvertTo-SecureString $setupPwd -AsPlainText -Force
            $AzureStackLCMUserCredential = New-Object System.Management.Automation.PSCredential ($setupUser, $SecurePassword)

            # Create the AD objects and suppress all outputs
            New-HciAdObjectsPreCreation -AzureStackLCMUserCredential $AzureStackLCMUserCredential -AsHciOUName $AsHciOUPath -ErrorAction Stop -WarningAction SilentlyContinue | Out-Null
        } catch {
            throw $_
        } finally {
            # Restore the original ConfirmPreference
            $ConfirmPreference = $ConfirmPreferenceBackup
        }
    } -ArgumentList $setupUser, $setupPwd -ErrorAction Stop -WarningAction SilentlyContinue -Verbose:$false | Out-Null

    Write-Message "Azure Stack HCI AD objects created successfully." -Type "Success"
} catch {
    Write-Message "Failed to create Azure Stack HCI AD objects. Error: $_" -Type "Error"
    exit 1
}

# Step 12: Final Completion
$currentStep++
Update-ProgressBar -CurrentStep $currentStep -TotalSteps $totalSteps -StatusMessage "Finalizing..."
Write-Message "Domain Controller configuration completed successfully." -Type "Success"

# Complete the overall progress bar
$currentStep = $totalSteps
Update-ProgressBar -CurrentStep $currentStep -TotalSteps $totalSteps -StatusMessage "All tasks completed."

#endregion
