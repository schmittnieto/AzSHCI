# 00_AzurePreRequisites.ps1
# Azure Prerequisites Setup Script

<#
.SYNOPSIS
    Prepares an Azure subscription for an Azure Local lab deployment.

.DESCRIPTION
    This script performs the following tasks:
    - Checks and installs required Az PowerShell modules.
    - Verifies Azure authentication and prompts via device code login when no active session exists.
    - Lets you select a subscription interactively.
    - Lets you choose an existing resource group or create a new one (with a recommended name).
    - Lets you assign the required RBAC roles to an existing user or to a newly created Service Principal.
    - Registers all required Azure resource providers if they are not already registered.
    - Prints SPN connection details at the end if a Service Principal was created.

.NOTES
    - Designed by Cristian Schmitt Nieto. For more information and usage, visit: https://schmitt-nieto.com/blog/azure-local-demolab/
    - Run this script with administrative privileges.
    - Ensure the Execution Policy allows the script to run:
      Set-ExecutionPolicy RemoteSigned -Scope CurrentUser
#>

#region Variables

$RequiredModules = @(
    "Az.Accounts"
    "Az.Resources"
)

# Roles assigned at resource group scope
$RolesRG = @(
    "Azure Connected Machine Onboarding"
    "Azure Connected Machine Resource Administrator"
    "Key Vault Data Access Administrator"
    "Key Vault Secrets Officer"
    "Key Vault Contributor"
    "Storage Account Contributor"
)

# Roles assigned at subscription scope
$RolesSubscription = @(
    "Azure Stack HCI Administrator"
    "Reader"
)

$ResourceProviders = @(
    "Microsoft.HybridCompute"
    "Microsoft.GuestConfiguration"
    "Microsoft.HybridConnectivity"
    "Microsoft.AzureStackHCI"
    "Microsoft.Kubernetes"
    "Microsoft.KubernetesConfiguration"
    "Microsoft.ExtendedLocation"
    "Microsoft.ResourceConnector"
    "Microsoft.HybridContainerService"
    "Microsoft.Attestation"
    "Microsoft.Storage"
    "Microsoft.KeyVault"
    "Microsoft.Insights"
)

$RecommendedRGName      = "rg-azlocal-lab"
$SpnDisplayNameDefault  = "sp-azlocal-lab"

$CommonRegions = @(
    "westeurope"
    "northeurope"
    "eastus"
    "eastus2"
    "westus2"
    "australiaeast"
    "southeastasia"
    "uksouth"
)

$totalSteps  = 5
$currentStep = 0

#endregion

#region Functions

function Write-Message {
    param(
        [string]$Message,
        [ValidateSet("Info","Success","Warning","Error")]
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
    param(
        [int]$CurrentStep,
        [int]$TotalSteps,
        [string]$StatusMessage
    )
    $percent = [math]::Round(($CurrentStep / $TotalSteps) * 100)
    Write-Progress -Id 1 -Activity "Azure Prerequisites Setup" -Status $StatusMessage -PercentComplete $percent
}

function Get-SelectionFromList {
    param(
        [array]$Items,
        [string]$PropertyName,
        [string]$Prompt = "Select by number"
    )
    $i = 0
    foreach ($item in $Items) {
        Write-Host ("  {0,3}. {1}" -f $i, $item.$PropertyName)
        $i++
    }
    do {
        $r = Read-Host $Prompt
        if ($r -match '^\d+$' -and [int]$r -lt $Items.Count) {
            return $Items[[int]$r]
        }
        Write-Message "Invalid selection. Enter a number between 0 and $($Items.Count - 1)." -Type "Warning"
    } while ($true)
}

#endregion

#region Script Execution

# ---------------------------------------------------------------------------
# Step 1: Module check and install
# ---------------------------------------------------------------------------
$currentStep++
Update-ProgressBar -CurrentStep $currentStep -TotalSteps $totalSteps -StatusMessage "Checking required modules..."
Write-Message "Checking required Az modules..." -Type "Info"

foreach ($module in $RequiredModules) {
    if (-not (Get-Module -ListAvailable -Name $module)) {
        Write-Message "Module '$module' not found. Installing from PSGallery..." -Type "Info"
        try {
            Install-Module -Name $module -Scope CurrentUser -Force -ErrorAction Stop
            Write-Message "Module '$module' installed." -Type "Success"
        } catch {
            Write-Message "Failed to install module '$module'. Details: $_" -Type "Error"
            exit 1
        }
    } else {
        Write-Message "Module '$module' is available." -Type "Info"
    }
    try {
        Import-Module $module -ErrorAction Stop
    } catch {
        Write-Message "Failed to import module '$module'. Details: $_" -Type "Error"
        exit 1
    }
}

Write-Message "All required modules loaded." -Type "Success"

# ---------------------------------------------------------------------------
# Step 2: Azure authentication and subscription selection
# ---------------------------------------------------------------------------
$currentStep++
Update-ProgressBar -CurrentStep $currentStep -TotalSteps $totalSteps -StatusMessage "Checking Azure authentication..."

$context = Get-AzContext -ErrorAction SilentlyContinue
if ($context) {
    Write-Message "Active session: $($context.Account.Id) on subscription '$($context.Subscription.Name)'." -Type "Info"
    $reuse = Read-Host "Use this session? (Y/N)"
    if ($reuse -notmatch '^[Yy]') { $context = $null }
}

if (-not $context) {
    Write-Message "Starting device code login..." -Type "Info"
    try {
        Connect-AzAccount -UseDeviceAuthentication -ErrorAction Stop | Out-Null
        Write-Message "Authenticated to Azure." -Type "Success"
    } catch {
        Write-Message "Authentication failed. Details: $_" -Type "Error"
        exit 1
    }
}

Write-Message "Retrieving available subscriptions..." -Type "Info"
$subscriptions = @(Get-AzSubscription -ErrorAction Stop | Where-Object { $_.State -eq "Enabled" })

if ($subscriptions.Count -eq 0) {
    Write-Message "No enabled subscriptions found for this account." -Type "Error"
    exit 1
}

Write-Host ""
Write-Message "Select the subscription to use:" -Type "Info"
$selectedSubscription = Get-SelectionFromList -Items $subscriptions -PropertyName "Name" -Prompt "Select subscription"
Set-AzContext -SubscriptionId $selectedSubscription.Id -ErrorAction Stop | Out-Null

$SubscriptionId = $selectedSubscription.Id
$TenantId       = $selectedSubscription.TenantId
Write-Message "Using subscription '$($selectedSubscription.Name)' ($SubscriptionId)." -Type "Success"

# ---------------------------------------------------------------------------
# Step 3: Resource Group selection or creation
# ---------------------------------------------------------------------------
$currentStep++
Update-ProgressBar -CurrentStep $currentStep -TotalSteps $totalSteps -StatusMessage "Configuring resource group..."

Write-Host ""
Write-Message "Resource Group setup:" -Type "Info"
Write-Host "  1. Use an existing resource group"
Write-Host "  2. Create a new resource group"
do {
    $rgChoice = Read-Host "Select option (1 or 2)"
} while ($rgChoice -notin @("1","2"))

if ($rgChoice -eq "1") {
    $existingRGs = @(Get-AzResourceGroup -ErrorAction Stop)
    if ($existingRGs.Count -eq 0) {
        Write-Message "No resource groups found in this subscription. Switching to creation mode." -Type "Warning"
        $rgChoice = "2"
    } else {
        Write-Host ""
        Write-Message "Available resource groups:" -Type "Info"
        $selectedRG        = Get-SelectionFromList -Items $existingRGs -PropertyName "ResourceGroupName" -Prompt "Select resource group"
        $ResourceGroupName = $selectedRG.ResourceGroupName
        $Location          = $selectedRG.Location
        Write-Message "Using resource group '$ResourceGroupName' (location: $Location)." -Type "Success"
    }
}

if ($rgChoice -eq "2") {
    Write-Host ""
    Write-Message "Recommended resource group name: '$RecommendedRGName'" -Type "Info"
    $newRGName = Read-Host "Enter resource group name (press Enter to accept recommendation)"
    if ([string]::IsNullOrWhiteSpace($newRGName)) { $newRGName = $RecommendedRGName }

    Write-Host ""
    Write-Message "Select the Azure region for the new resource group:" -Type "Info"
    for ($i = 0; $i -lt $CommonRegions.Count; $i++) {
        Write-Host ("  {0,3}. {1}" -f $i, $CommonRegions[$i])
    }
    do {
        $regionInput = Read-Host "Enter a list number or type a region name directly"
        if ($regionInput -match '^\d+$' -and [int]$regionInput -lt $CommonRegions.Count) {
            $newLocation = $CommonRegions[[int]$regionInput]
        } else {
            $newLocation = $regionInput.Trim().ToLower() -replace '\s', ''
        }
    } while ([string]::IsNullOrWhiteSpace($newLocation))

    Write-Message "Creating resource group '$newRGName' in '$newLocation'..." -Type "Info"
    try {
        New-AzResourceGroup -Name $newRGName -Location $newLocation -ErrorAction Stop | Out-Null
        Write-Message "Resource group '$newRGName' created." -Type "Success"
    } catch {
        Write-Message "Failed to create resource group. Details: $_" -Type "Error"
        exit 1
    }
    $ResourceGroupName = $newRGName
    $Location          = $newLocation
}

$scopeRG           = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName"
$scopeSubscription = "/subscriptions/$SubscriptionId"

# ---------------------------------------------------------------------------
# Step 4: Principal setup and role assignments
# ---------------------------------------------------------------------------
$currentStep++
Update-ProgressBar -CurrentStep $currentStep -TotalSteps $totalSteps -StatusMessage "Configuring principal and role assignments..."

Write-Host ""
Write-Message "Select how to assign the required Azure RBAC roles:" -Type "Info"
Write-Host "  1. Assign to an existing user account"
Write-Host "  2. Create a new Service Principal and assign roles to it"
do {
    $principalChoice = Read-Host "Select option (1 or 2)"
} while ($principalChoice -notin @("1","2"))

$spnCreated  = $false
$spnDetails  = $null
$principalId = $null

if ($principalChoice -eq "1") {

    $UserPrincipalName = Read-Host "Enter the User Principal Name (e.g. user@domain.com)"
    Write-Message "Resolving user '$UserPrincipalName'..." -Type "Info"
    try {
        $principal = Get-AzADUser -UserPrincipalName $UserPrincipalName -ErrorAction Stop
        if (-not $principal) {
            Write-Message "User '$UserPrincipalName' was not found in the directory." -Type "Error"
            exit 1
        }
        Write-Message "User resolved. ObjectId: $($principal.Id)" -Type "Success"
    } catch {
        Write-Message "Failed to resolve user '$UserPrincipalName'. Details: $_" -Type "Error"
        exit 1
    }
    $principalId    = $principal.Id
    $principalLabel = $UserPrincipalName

} else {

    Write-Host ""
    Write-Message "Recommended SPN name: '$SpnDisplayNameDefault'" -Type "Info"
    $spnName = Read-Host "Enter SPN display name (press Enter to accept recommendation)"
    if ([string]::IsNullOrWhiteSpace($spnName)) { $spnName = $SpnDisplayNameDefault }

    Write-Message "Creating app registration '$spnName'..." -Type "Info"
    try {
        $app = New-AzADApplication -DisplayName $spnName -ErrorAction Stop
        Write-Message "App registration created. AppId: $($app.AppId)" -Type "Success"
    } catch {
        Write-Message "Failed to create app registration. Details: $_" -Type "Error"
        exit 1
    }

    Write-Message "Creating service principal..." -Type "Info"
    try {
        $sp = New-AzADServicePrincipal -ApplicationId $app.AppId -ErrorAction Stop
        Write-Message "Service principal created. ObjectId: $($sp.Id)" -Type "Success"
    } catch {
        Write-Message "Failed to create service principal. Details: $_" -Type "Error"
        exit 1
    }

    Write-Message "Generating client secret (valid for 2 years)..." -Type "Info"
    try {
        $startDate = Get-Date
        $endDate   = $startDate.AddYears(2)
        $cred      = New-AzADAppCredential -ApplicationId $app.AppId -StartDate $startDate -EndDate $endDate -ErrorAction Stop

        if ($cred.SecretText -is [System.Security.SecureString]) {
            $ptr    = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($cred.SecretText)
            $secret = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($ptr)
            [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)
        } else {
            $secret = $cred.SecretText
        }
        Write-Message "Client secret generated." -Type "Success"
    } catch {
        Write-Message "Failed to generate client secret. Details: $_" -Type "Error"
        exit 1
    }

    $principalId    = $sp.Id
    $principalLabel = $spnName
    $spnCreated     = $true
    $spnDetails     = [PSCustomObject]@{
        DisplayName    = $spnName
        TenantId       = $TenantId
        SubscriptionId = $SubscriptionId
        AppId          = $app.AppId
        Secret         = $secret
        SecretExpiry   = $endDate.ToString("yyyy-MM-dd")
    }

    Write-Message "Waiting 20 seconds for the SPN to propagate before assigning roles..." -Type "Info"
    Start-Sleep -Seconds 20
}

# Assign resource group scoped roles
Write-Host ""
Write-Message "Assigning resource group scoped roles to '$principalLabel'..." -Type "Info"
foreach ($role in $RolesRG) {
    $existing = Get-AzRoleAssignment -ObjectId $principalId -RoleDefinitionName $role -Scope $scopeRG -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Message "Role '$role' already assigned at RG scope. Skipping." -Type "Warning"
        continue
    }
    try {
        New-AzRoleAssignment -ObjectId $principalId -RoleDefinitionName $role -Scope $scopeRG -ErrorAction Stop | Out-Null
        Write-Message "Assigned '$role' at RG scope." -Type "Success"
    } catch {
        Write-Message "Failed to assign '$role' at RG scope. Details: $_" -Type "Warning"
    }
}

# Assign subscription scoped roles
Write-Host ""
Write-Message "Assigning subscription scoped roles to '$principalLabel'..." -Type "Info"
foreach ($role in $RolesSubscription) {
    $existing = Get-AzRoleAssignment -ObjectId $principalId -RoleDefinitionName $role -Scope $scopeSubscription -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Message "Role '$role' already assigned at subscription scope. Skipping." -Type "Warning"
        continue
    }
    try {
        New-AzRoleAssignment -ObjectId $principalId -RoleDefinitionName $role -Scope $scopeSubscription -ErrorAction Stop | Out-Null
        Write-Message "Assigned '$role' at subscription scope." -Type "Success"
    } catch {
        Write-Message "Failed to assign '$role' at subscription scope. Details: $_" -Type "Warning"
    }
}

# ---------------------------------------------------------------------------
# Step 5: Resource provider registration
# ---------------------------------------------------------------------------
$currentStep++
Update-ProgressBar -CurrentStep $currentStep -TotalSteps $totalSteps -StatusMessage "Registering resource providers..."
Write-Host ""
Write-Message "Checking and registering required resource providers..." -Type "Info"

foreach ($provider in $ResourceProviders) {
    try {
        $rp    = Get-AzResourceProvider -ProviderNamespace $provider -ErrorAction Stop
        $state = ($rp | Select-Object -First 1).RegistrationState
        if ($state -eq "Registered") {
            Write-Message "Provider '$provider' is already registered." -Type "Info"
        } else {
            Write-Message "Registering provider '$provider' (current state: $state)..." -Type "Info"
            Register-AzResourceProvider -ProviderNamespace $provider -ErrorAction Stop | Out-Null
            Write-Message "Registration initiated for '$provider'." -Type "Success"
        }
    } catch {
        Write-Message "Failed to check or register provider '$provider'. Details: $_" -Type "Warning"
    }
}

Write-Progress -Id 1 -Activity "Azure Prerequisites Setup" -Completed
Write-Host ""
Write-Message "Azure prerequisites setup completed." -Type "Success"
Write-Host ""
Write-Message "Summary:" -Type "Info"
Write-Host ("  Subscription : {0} ({1})" -f $selectedSubscription.Name, $SubscriptionId)
Write-Host ("  Resource Group: {0} (location: {1})"      -f $ResourceGroupName, $Location)
Write-Host ("  Principal    : {0}"                        -f $principalLabel)
Write-Host ""
Write-Message "Resource provider registrations may take a few minutes to show as 'Registered'." -Type "Warning"
Write-Message "You can check their status with: Get-AzResourceProvider -ProviderNamespace '<namespace>'" -Type "Info"

# ---------------------------------------------------------------------------
# SPN connection details output
# ---------------------------------------------------------------------------
if ($spnCreated -and $spnDetails) {
    Write-Host ""
    Write-Host "================================================================" -ForegroundColor Yellow
    Write-Host "  SERVICE PRINCIPAL CONNECTION DETAILS                         " -ForegroundColor Yellow
    Write-Host "  Save these values securely. The secret cannot be retrieved   " -ForegroundColor Yellow
    Write-Host "  again after this session ends.                               " -ForegroundColor Yellow
    Write-Host "================================================================" -ForegroundColor Yellow
    Write-Host ""
    Write-Host ("  Display Name    : {0}" -f $spnDetails.DisplayName)     -ForegroundColor Cyan
    Write-Host ("  Tenant ID       : {0}" -f $spnDetails.TenantId)        -ForegroundColor Cyan
    Write-Host ("  Subscription ID : {0}" -f $spnDetails.SubscriptionId)  -ForegroundColor Cyan
    Write-Host ("  App ID          : {0}" -f $spnDetails.AppId)           -ForegroundColor Cyan
    Write-Host ("  Client Secret   : {0}" -f $spnDetails.Secret)          -ForegroundColor Cyan
    Write-Host ("  Secret Expiry   : {0}" -f $spnDetails.SecretExpiry)    -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  To connect with this SPN in PowerShell:" -ForegroundColor White
    Write-Host ""
    Write-Host ('  $spnCredential = New-Object PSCredential(') -ForegroundColor White
    Write-Host ('      "' + $spnDetails.AppId + '",') -ForegroundColor White
    Write-Host ('      (ConvertTo-SecureString "' + $spnDetails.Secret + '" -AsPlainText -Force))') -ForegroundColor White
    Write-Host ('  Connect-AzAccount -ServicePrincipal `') -ForegroundColor White
    Write-Host ('      -Tenant "' + $spnDetails.TenantId + '" `') -ForegroundColor White
    Write-Host ('      -Subscription "' + $spnDetails.SubscriptionId + '" `') -ForegroundColor White
    Write-Host ('      -Credential $spnCredential') -ForegroundColor White
    Write-Host ""
    Write-Host "================================================================" -ForegroundColor Yellow
}

#endregion
