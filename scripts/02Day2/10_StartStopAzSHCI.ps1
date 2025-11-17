<#
.SYNOPSIS
    Manages the start and stop operations of the HCI infrastructure by controlling the Domain Controller (DC) and Cluster Node VMs.

.DESCRIPTION
    This script allows you to start or stop your Hyper-Converged Infrastructure (HCI) by managing the Domain Controller (DC) and Cluster Node VMs in a controlled manner. It ensures that operations are performed in the correct order with appropriate delays and progress indicators.

    - **Stopping the Infrastructure:**
        1. Connect to the Cluster Node VM and stop the Cluster service.
        2. Shut down the Cluster Node VM.
        3. Shut down the Domain Controller VM.

    - **Starting the Infrastructure:**
        1. Start the Domain Controller VM and wait for services to become available.
        2. Start the Cluster Node VM.
        3. Start the Cluster service on the Cluster Node VM.

.NOTES
    - Designed by Cristian Schmitt Nieto. For more information and usage, visit: https://schmitt-nieto.com/blog/azure-stack-hci-day2/
    - Run this script with administrative privileges.
    - Ensure the Execution Policy allows the script to run. To set the execution policy, you can run:
      Set-ExecutionPolicy RemoteSigned -Scope CurrentUser
    - Update the credentials and VM names as per your environment before executing the script.
#>

#region Variables

# Domain Variables
$netBIOSName = "AZURESTACK"

# Credentials for HCI Cluster Node
$hcilcmuser = "hciadmin"
$hciadmin = "$netBIOSName\$hcilcmuser"
$hcipassword = "dgemsc#utquMHDHp3M"
$hciSecuredPassword = ConvertTo-SecureString $hcipassword -AsPlainText -Force
$hciCredentials = New-Object System.Management.Automation.PSCredential ($hciadmin, $hciSecuredPassword)

# Credentials for Domain Controller
$dcAdminUser = "Administrator"
$dcPassword = "Start#1234"
$dcDomAdminUser = "$netBIOSName\$dcAdminUser"
$dcSecuredPassword = ConvertTo-SecureString $dcPassword -AsPlainText -Force
$dcCredentials = New-Object System.Management.Automation.PSCredential ($dcDomAdminUser , $dcSecuredPassword)

# VM Names
$nodeName = "AZLNODE01"
$dcName = "DC"

# Sleep durations in seconds
$SleepDCStart = 120  # Sleep time after starting DC VM
$SleepNodeStart = 60  # Sleep time after starting Node VM
$SleepShutdown = 20  # Sleep time during shutdown progress

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
        Write-Progress -Id 2 -Activity $Activity -Status "$Status : $i/$Seconds seconds elapsed... Press Spacebar to skip" -PercentComplete $percent
        Start-Sleep -Seconds 1
    }

    Write-Progress -Id 2 -Activity $Activity -Completed
    Write-Message "$Activity : Completed." -Type "Success"
}

# Function to Stop the HCI Infrastructure
function Stop-HCIInfrastructure {
    Write-Message "Starting shutdown of HCI infrastructure..." -Type "Info"

    # Step 1: Stop Cluster Service on Node
    Write-Message "Connecting to Cluster Node VM: $nodeName..." -Type "Info"
    try {
        Invoke-Command -VMName $nodeName -Credential $hciCredentials -ScriptBlock {
            Write-Host "Stopping Cluster Service..." -ForegroundColor Yellow
            Stop-Cluster -Force
        }
        Write-Message "Cluster service stopped on $nodeName." -Type "Success"
    } catch {
        Write-Message "Error stopping Cluster service on $nodeName : $_" -Type "Error"
        exit 1
    }

    # Step 2: Shutdown Cluster Node VM
    Write-Message "Shutting down Cluster Node VM: $nodeName..." -Type "Info"
    try {
        Invoke-Command -VMName $nodeName -Credential $hciCredentials -ScriptBlock {
            shutdown.exe /s /t 0
        }
        Start-SleepWithProgress -Seconds $SleepShutdown -Activity "Shutting down Node VM" -Status "Shutting down $nodeName"
        Write-Message "$nodeName has been shut down." -Type "Success"
    } catch {
        Write-Message "Error shutting down $nodeName : $_" -Type "Error"
        exit 1
    }

    # Step 3: Shutdown Domain Controller VM
    Write-Message "Shutting down Domain Controller VM: $dcName..." -Type "Info"
    try {
        Invoke-Command -VMName $dcName -Credential $dcCredentials -ScriptBlock {
            shutdown.exe /s /t 0
        }
        Start-SleepWithProgress -Seconds $SleepShutdown -Activity "Shutting down Domain Controller VM" -Status "Shutting down $dcName"
        Write-Message "$dcName has been shut down." -Type "Success"
    } catch {
        Write-Message "Error shutting down $dcName : $_" -Type "Error"
        exit 1
    }

    Write-Message "HCI infrastructure has been successfully shut down." -Type "Success"
}

# Function to Start the HCI Infrastructure
function Start-HCIInfrastructure {
    Write-Message "Starting up HCI infrastructure..." -Type "Info"

    # Step 1: Start Domain Controller VM
    Write-Message "Starting Domain Controller VM: $dcName..." -Type "Info"
    try {
        Start-VM -Name $dcName
        Start-SleepWithProgress -Seconds $SleepDCStart -Activity "Starting Domain Controller VM" -Status "Waiting for $dcName to start and services to become available"
        Write-Message "$dcName has been started." -Type "Success"
    } catch {
        Write-Message "Error starting $dcName : $_" -Type "Error"
        exit 1
    }

    # Step 2: Start Cluster Node VM
    Write-Message "Starting Cluster Node VM: $nodeName..." -Type "Info"
    try {
        Start-VM -Name $nodeName
        Start-SleepWithProgress -Seconds $SleepNodeStart -Activity "Starting Cluster Node VM" -Status "Waiting for $nodeName to start"
        Write-Message "$nodeName has been started." -Type "Success"
    } catch {
        Write-Message "Error starting $nodeName : $_" -Type "Error"
        exit 1
    }

    # Step 3: Start Cluster Service on Node
    Write-Message "Starting Cluster Service on Cluster Node VM: $nodeName..." -Type "Info"
    try {
        Invoke-Command -VMName $nodeName -Credential $hciCredentials -ScriptBlock {
            Write-Host "Starting Cluster Service..." -ForegroundColor Yellow
            Start-Cluster
            Sync-AzureStackHCI
        }
        Write-Message "Cluster service started on $nodeName." -Type "Success"
    } catch {
        Write-Message "Error starting Cluster service on $nodeName : $_" -Type "Error"
        exit 1
    }

    Write-Message "HCI infrastructure has been successfully started." -Type "Success"
}

#endregion

#region Script Execution

# Prompt user for action
$action = Read-Host "Do you want to start or stop the infrastructure? (start/stop)"

switch ($action.ToLower()) {
    "stop" {
        Stop-HCIInfrastructure
    }
    "start" {
        Start-HCIInfrastructure
    }
    default {
        Write-Message "Invalid option selected. Please run the script again and choose 'start' or 'stop'." -Type "Error"
        exit 1
    }
}

#endregion
