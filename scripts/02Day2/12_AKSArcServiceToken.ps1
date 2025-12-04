# 12_AKSArcServiceToken.ps1
# Generate a Service Account token for an AKS Arc (connectedClusters) Kubernetes cluster
# and fetch kubeconfig into the lab's standard folder.

<#
.SYNOPSIS
    Retrieves AKS Arc kubeconfig and creates a service account with cluster-admin rights.
    Exports a token to a text file for programmatic access.

.DESCRIPTION
    - Validates required CLI dependencies and, if missing, INTERACTIVELY offers to install them (Azure CLI and kubectl).
    - Optional: skip az extension updates with -SkipAzExtensionUpdate.
    - Allows passing a direct kubectl path with -KubectlPath. If not found, you will be asked to point to it or install it.
    - Interactive selection for Subscription, Resource Group, and Cluster (using az --query ... -o tsv) or non interactive via parameters.
    - Supports re-authentication with -ForceAzReauth (runs 'az account clear' and then forces login).
    - Asks how you want to log in to Azure (interactive vs device code) whenever a login is required.
    - Downloads kubeconfig, creates service account and clusterrolebinding, then retrieves a token using TokenRequest API
      with a safe fallback to a secret based token.

.USAGE
    # Interactive mode
    .\12_AKSArcServiceToken.ps1

    # Automated mode
    .\12_AKSArcServiceToken.ps1 -SubscriptionName "MySubscription" -ResourceGroupName "MyRG" -ClusterName "my-aks-arc" -AdminUser "my-admin"

.PARAMETER SubscriptionName
    Azure subscription name. If omitted, you will be prompted to select one.

.PARAMETER ResourceGroupName
    Azure resource group containing the connected cluster. If omitted, you will be prompted.

.PARAMETER ClusterName
    AKS Arc connected cluster name (Microsoft.Kubernetes/connectedClusters). If omitted, you will be prompted.

.PARAMETER AdminUser
    Service account name to create or reuse. If omitted, you will be prompted.

.PARAMETER Namespace
    Namespace for the service account. Defaults to "default".

.PARAMETER OutputFolder
    Folder for kubeconfig and token output. Defaults to "$env:USERPROFILE\.kube\AzSHCI".

.PARAMETER KubeconfigPath
    Full path to write the kubeconfig. Defaults to "<OutputFolder>\aks-arc-kube-config".

.PARAMETER SkipAzExtensionUpdate
    If set, does not update az extensions. Only checks presence and warns if missing.

.PARAMETER KubectlPath
    Full path to kubectl.exe if you want to force it. The script will add its folder to PATH for this session.

.PARAMETER UseDeviceCode
    If set, selects device code as the default login method when prompting.

.PARAMETER ForceAzReauth
    If set, runs 'az account clear' before login and forces a new login.

.PARAMETER Overwrite
    If set, overwrites existing kubeconfig file.

.NOTES
    Author: Cristian Schmitt Nieto
    Repo: https://github.com/schmittnieto/AzSHCI
#>

[CmdletBinding()]
param(
    [string]$SubscriptionName,
    [string]$ResourceGroupName,
    [string]$ClusterName,
    [string]$AdminUser,
    [string]$Namespace = "default",
    [string]$OutputFolder = "$env:USERPROFILE\.kube\AzSHCI",
    [string]$KubeconfigPath,
    [switch]$SkipAzExtensionUpdate,
    [string]$KubectlPath,
    [switch]$UseDeviceCode,
    [switch]$ForceAzReauth,
    [switch]$Overwrite
)

#region Helpers

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

function Update-ProgressBarMain {
    param(
        [int]$CurrentStep,
        [int]$TotalSteps,
        [string]$StatusMessage
    )
    $percent = [math]::Round(($CurrentStep / $TotalSteps) * 100)
    Write-Progress -Id 1 -Activity "AKS Arc Service Token Workflow" -Status $StatusMessage -PercentComplete $percent
}

function Start-SleepWithProgress {
    param(
        [int]$Seconds,
        [string]$Activity = "Waiting",
        [string]$Status = "Please wait..."
    )
    for ($i = 1; $i -le $Seconds; $i++) {
        $percent = [math]::Round(($i / $Seconds) * 100)
        Write-Progress -Id 2 -Activity $Activity -Status "$Status ($i/$Seconds s)" -PercentComplete $percent
        Start-Sleep -Seconds 1
    }
    Write-Progress -Id 2 -Activity $Activity -Completed
}

function Test-Command {
    param(
        [Parameter(Mandatory = $true)][string]$Name
    )
    return [bool](Get-Command -Name $Name -ErrorAction SilentlyContinue)
}

function Read-YesNo {
    param(
        [Parameter(Mandatory = $true)][string]$Prompt,
        [bool]$DefaultYes = $true
    )
    $suffix = if ($DefaultYes) { "[Y/n]" } else { "[y/N]" }
    while ($true) {
        $ans = Read-Host "$Prompt $suffix"
        if ([string]::IsNullOrWhiteSpace($ans)) {
            return $DefaultYes
        }
        switch ($ans.ToLower()) {
            "y"  { return $true }
            "yes" { return $true }
            "n"  { return $false }
            "no" { return $false }
            default { Write-Message "Please answer y or n." -Type "Warning" }
        }
    }
}

function Ensure-WingetAvailable {
    $wg = Get-Command -Name "winget" -ErrorAction SilentlyContinue
    if (-not $wg) {
        return $false
    }
    return $true
}

function Install-WithWinget {
    param(
        [Parameter(Mandatory = $true)][string]$PackageId,
        [Parameter(Mandatory = $true)][string]$FriendlyName
    )
    if (-not (Ensure-WingetAvailable)) {
        Write-Message "winget is not available. Please install $FriendlyName manually and rerun." -Type "Error"
        return $false
    }
    Write-Message "Installing $FriendlyName via winget..." -Type "Info"
    winget install -e --id $PackageId --accept-package-agreements --accept-source-agreements | Out-Null
    return $true
}

function Initialize-AzDependencies {
    # Azure CLI
    $azCmd = Get-Command -Name "az" -ErrorAction SilentlyContinue
    if (-not $azCmd) {
        if (Read-YesNo -Prompt "Azure CLI was not found in PATH. Do you want to install it now?" -DefaultYes:$true) {
            if (Install-WithWinget -PackageId "Microsoft.AzureCLI" -FriendlyName "Azure CLI") {
                # Re-detect in this session
                $azCmd = Get-Command -Name "az" -ErrorAction SilentlyContinue
                if (-not $azCmd) {
                    Write-Message "Azure CLI installation finished but 'az' is still not visible in this session. Open a new PowerShell and rerun if this fails." -Type "Warning"
                }
            } else {
                Write-Message "Azure CLI installation request could not be completed." -Type "Error"
            }
        } else {
            Write-Message "Azure CLI is required to continue. Exiting by user choice." -Type "Error"
            throw "Az CLI not found and user declined installation"
        }
    }
    $azCmd = Get-Command -Name "az" -ErrorAction SilentlyContinue
    if (-not $azCmd) {
        throw "Az CLI still not available after attempted installation"
    }
    Write-Message "Using az at: $($azCmd.Source)" -Type "Info"

    # Required extension(s)
    $requiredExtensions = @("aksarc")
    foreach ($ext in $requiredExtensions) {
        az extension show --name $ext 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) {
            if ($SkipAzExtensionUpdate) {
                Write-Message "Missing az extension '$ext' and -SkipAzExtensionUpdate is set. Some features may fail." -Type "Warning"
            } else {
                if (Read-YesNo -Prompt "Azure extension '$ext' is missing. Install it now?" -DefaultYes:$true) {
                    az extension add --name $ext --allow-preview true --only-show-errors | Out-Null
                } else {
                    Write-Message "Extension '$ext' not installed. Script may not work properly." -Type "Warning"
                }
            }
        } elseif (-not $SkipAzExtensionUpdate) {
            if (Read-YesNo -Prompt "Update az extension '$ext' to latest?" -DefaultYes:$true) {
                az extension update --name $ext --allow-preview true --only-show-errors | Out-Null
            }
        }
    }
}

function Initialize-KubectlDependency {
    # Explicit path provided
    if ($KubectlPath) {
        if (Test-Path $KubectlPath) {
            $dir = Split-Path -Path $KubectlPath -Parent
            if ($env:PATH -notlike "*$dir*") {
                $env:PATH = "$dir;$env:PATH"
            }
            Write-Message "Using kubectl at: $KubectlPath" -Type "Info"
            return
        } else {
            Write-Message "Provided kubectl path does not exist: $KubectlPath" -Type "Warning"
        }
    }

    # In PATH already?
    $kubectlCmd = Get-Command -Name "kubectl" -ErrorAction SilentlyContinue
    if ($kubectlCmd) {
        Write-Message "Using kubectl at: $($kubectlCmd.Source)" -Type "Info"
        return
    }

    # Common locations
    $candidates = @(
        "$env:ProgramFiles\Kubernetes\kubectl.exe",
        "$env:ProgramFiles\Kubernetes\bin\kubectl.exe",
        "$env:ProgramFiles\Docker\Docker\resources\bin\kubectl.exe",
        "$env:ChocolateyInstall\bin\kubectl.exe",
        "$env:USERPROFILE\kubectl.exe"
    ) | Where-Object { $_ -and (Test-Path $_) }

    if ($candidates.Count -gt 0) {
        $first = $candidates | Select-Object -First 1
        $dir = Split-Path -Path $first -Parent
        if ($env:PATH -notlike "*$dir*") {
            $env:PATH = "$dir;$env:PATH"
        }
        Write-Message "Found kubectl at: $first" -Type "Success"
        return
    }

    # Interactive path prompt or install
    if (Read-YesNo -Prompt "kubectl not found. Do you want to install it now (winget)?" -DefaultYes:$true) {
        if (Install-WithWinget -PackageId "Kubernetes.kubectl" -FriendlyName "kubectl") {
            $kubectlCmd = Get-Command -Name "kubectl" -ErrorAction SilentlyContinue
            if ($kubectlCmd) {
                Write-Message "kubectl installed. Path: $($kubectlCmd.Source)" -Type "Success"
                return
            } else {
                Write-Message "kubectl installation finished but command is not visible yet. You may need a new session." -Type "Warning"
            }
        } else {
            Write-Message "kubectl installation failed or winget not available." -Type "Error"
        }
    } else {
        $tryPath = Read-Host "Enter full path to kubectl.exe or leave empty to cancel"
        if (-not [string]::IsNullOrWhiteSpace($tryPath) -and (Test-Path $tryPath)) {
            $dir = Split-Path -Path $tryPath -Parent
            if ($env:PATH -notlike "*$dir*") {
                $env:PATH = "$dir;$env:PATH"
            }
            Write-Message "Using kubectl at: $tryPath" -Type "Info"
            return
        }
    }

    throw "kubectl not available"
}

function Select-FromList {
    param(
        [Parameter(Mandatory = $true)][object[]]$Items,   # array of display strings OR objects with a Display property
        [Parameter(Mandatory = $true)][string]$Prompt
    )
    if (-not $Items -or $Items.Count -eq 0) {
        throw "No items to select."
    }

    for ($i = 0; $i -lt $Items.Count; $i++) {
        $text = if ($Items[$i] -is [string]) { $Items[$i] } else { $Items[$i].Display }
        Write-Host ("[{0}] {1}" -f $i, $text)
    }

    do {
        $usrinput = Read-Host "$Prompt (0-$($Items.Count-1))"
        [int]$index = -1
        $ok = [int]::TryParse($usrinput, [ref]$index)
        if ($ok -and $index -ge 0 -and $index -lt $Items.Count) {
            return $Items[$index]
        }
        Write-Message "Invalid selection. Try again." -Type "Warning"
    } while ($true)
}

function Get-SubscriptionInteractive {
    # name, id, tenantId for a nicer display
    $raw = az account list --all --query "[].{name:name,id:id,tenantId:tenantId,state:state}" -o tsv
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($raw)) {
        throw "Failed to list subscriptions."
    }

    $lines = $raw -split "`r?`n" | Where-Object { $_.Trim() -ne "" }
    $objs = foreach ($l in $lines) {
        $p = $l -split "`t"
        # Expecting 4 columns: name, id, tenantId, state
        [pscustomobject]@{
            Name     = $p[0]
            Id       = $p[1]
            TenantId = $p[2]
            State    = $p[3]
            Display  = ("{0}  [{1}]  (tenant {2})  {3}" -f $p[0], $p[1].Substring(0,8), $p[2].Substring(0,8), $p[3])
        }
    }

    if ($objs.Count -eq 1) {
        Write-Message "Auto-selected subscription: $($objs[0].Name)" -Type "Info"
        return $objs[0].Name
    }

    $chosen = Select-FromList -Items $objs -Prompt "Select subscription"
    return $chosen.Name
}

function Get-ResourceGroupInteractive {
    $raw = az group list --query "[].{name:name,location:location}" -o tsv
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($raw)) {
        throw "Failed to list resource groups."
    }

    $lines = $raw -split "`r?`n" | Where-Object { $_.Trim() -ne "" }
    $objs = foreach ($l in $lines) {
        $p = $l -split "`t"
        [pscustomobject]@{
            Name     = $p[0]
            Location = $p[1]
            Display  = ("{0}  ({1})" -f $p[0], $p[1])
        }
    }

    if ($objs.Count -eq 1) {
        Write-Message "Auto-selected resource group: $($objs[0].Name)" -Type "Info"
        return $objs[0].Name
    }

    $chosen = Select-FromList -Items $objs -Prompt "Select resource group"
    return $chosen.Name
}

function Get-ClusterInteractive {
    param(
        [Parameter(Mandatory = $true)][string]$ResourceGroupName
    )

    $raw = az resource list -g $ResourceGroupName --resource-type Microsoft.Kubernetes/connectedClusters --query "[].{name:name,location:location}" -o tsv
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to list AKS Arc clusters in RG '$ResourceGroupName'."
    }

    $lines = $raw -split "`r?`n" | Where-Object { $_.Trim() -ne "" }
    if (-not $lines -or $lines.Count -eq 0) {
        throw "No AKS Arc connectedClusters found in RG '$ResourceGroupName'."
    }

    $objs = foreach ($l in $lines) {
        $p = $l -split "`t"
        [pscustomobject]@{
            Name     = $p[0]
            Location = $p[1]
            Display  = ("{0}  ({1})" -f $p[0], $p[1])
        }
    }

    if ($objs.Count -eq 1) {
        Write-Message "Auto-selected cluster: $($objs[0].Name)" -Type "Info"
        return $objs[0].Name
    }

    $chosen = Select-FromList -Items $objs -Prompt "Select AKS Arc cluster"
    return $chosen.Name
}

function Invoke-Kubectl {
    param(
        [string]$KubectlArgs,
        [string]$Kubeconfig
    )
    $cmd = "kubectl $KubectlArgs --kubeconfig `"$Kubeconfig`""
    $out = Invoke-Expression $cmd
    return $out
}

#endregion Helpers

#region Workflow

$steps = @(
    "Checking dependencies",
    "Azure login and context",
    "Selecting Subscription RG Cluster",
    "Preparing output paths",
    "Fetching kubeconfig",
    "Validating cluster access",
    "Ensuring namespace and service account",
    "Binding cluster-admin",
    "Retrieving token",
    "Writing outputs"
)

$total = $steps.Count
$step = 0

try {
    # Step 1
    $step++
    Update-ProgressBarMain -CurrentStep $step -TotalSteps $total -StatusMessage $steps[$step-1]
    Initialize-AzDependencies
    Initialize-KubectlDependency

    # Step 2 (login / reauth with interactive choice)
    $step++
    Update-ProgressBarMain -CurrentStep $step -TotalSteps $total -StatusMessage $steps[$step-1]

    $needLogin = $false
    if ($ForceAzReauth) {
        Write-Message "Clearing Azure account context..." -Type "Info"
        az account clear --only-show-errors
        $needLogin = $true
    } else {
        $acct = $null
        try {
            $acct = az account show 2>$null | ConvertFrom-Json
        } catch {
            $acct = $null
        }
        if (-not $acct) {
            $needLogin = $true
            Write-Message "No active Azure CLI context detected. Login is required." -Type "Warning"
        } else {
            Write-Message "Using existing Azure CLI context for subscription '$($acct.name)'." -Type "Info"
        }
    }

    if ($needLogin) {
        $defaultMethod = if ($UseDeviceCode) { "D" } else { "I" }
        $defaultLabel = if ($defaultMethod -eq "D") { "Device code" } else { "Interactive" }

        while ($true) {
            $choice = Read-Host "Choose Azure login method: [I]nteractive or [D]evice code (default: $defaultLabel)"
            if ([string]::IsNullOrWhiteSpace($choice)) {
                $choice = $defaultMethod
            }
            $first = $choice.Substring(0,1).ToUpper()
            if ($first -eq "I") {
                Write-Message "Signing in to Azure (interactive)..." -Type "Info"
                az login --only-show-errors
                break
            } elseif ($first -eq "D") {
                Write-Message "Signing in to Azure using device code..." -Type "Info"
                az login --use-device-code --only-show-errors
                break
            } else {
                Write-Message "Invalid option. Please choose I or D." -Type "Warning"
            }
        }

        $acct = $null
        try {
            $acct = az account show 2>$null | ConvertFrom-Json
        } catch {
            $acct = $null
        }
        if (-not $acct) {
            Write-Message "Azure login failed. No active context." -Type "Error"
            throw "Azure login failed"
        } else {
            Write-Message "Azure login successful. Using subscription '$($acct.name)'." -Type "Success"
        }
    }

    # Step 3 (interactive selection with clear names)
    $step++
    Update-ProgressBarMain -CurrentStep $step -TotalSteps $total -StatusMessage $steps[$step-1]

    if (-not $SubscriptionName) {
        Write-Message "Select the Subscription" -Type "Info"
        $SubscriptionName = Get-SubscriptionInteractive
    }
    az account set --name $SubscriptionName --only-show-errors | Out-Null

    if (-not $ResourceGroupName) {
        Write-Message "Select the Resource Group" -Type "Info"
        $ResourceGroupName = Get-ResourceGroupInteractive
    }

    if (-not $ClusterName) {
        Write-Message "Select the AKS Arc Cluster" -Type "Info"
        $ClusterName = Get-ClusterInteractive -ResourceGroupName $ResourceGroupName
    }

    if (-not $AdminUser) {
        $AdminUser = Read-Host -Prompt "Input the service account name"
    }

    # Step 4
    $step++
    Update-ProgressBarMain -CurrentStep $step -TotalSteps $total -StatusMessage $steps[$step-1]

    if (-not (Test-Path -Path $OutputFolder)) {
        New-Item -Path $OutputFolder -ItemType Directory -Force | Out-Null
        Write-Message "Created output folder: $OutputFolder" -Type "Success"
    }
    if (-not $KubeconfigPath) {
        $KubeconfigPath = Join-Path $OutputFolder "aks-arc-kube-config"
    }
    if ((Test-Path $KubeconfigPath) -and (-not $Overwrite)) {
        Write-Message "Kubeconfig already exists at $KubeconfigPath. Use -Overwrite to replace." -Type "Warning"
    }

    # Step 5
    $step++
    Update-ProgressBarMain -CurrentStep $step -TotalSteps $total -StatusMessage $steps[$step-1]

    if ((-not (Test-Path $KubeconfigPath)) -or $Overwrite) {
        Write-Message "Fetching kubeconfig for $ClusterName in $ResourceGroupName..." -Type "Info"
        az aksarc get-credentials --name $ClusterName --resource-group $ResourceGroupName --file $KubeconfigPath --admin --only-show-errors | Out-Null
        Write-Message "Kubeconfig written to $KubeconfigPath" -Type "Success"
    }

    # Step 6
    $step++
    Update-ProgressBarMain -CurrentStep $step -TotalSteps $total -StatusMessage $steps[$step-1]

    $nodes = Invoke-Kubectl -KubectlArgs "get nodes -o name" -Kubeconfig $KubeconfigPath
    if (-not $nodes) {
        Write-Message "Failed to reach cluster. Check connectivity and credentials." -Type "Error"
        throw "Cluster not reachable"
    }
    Write-Message "Cluster connectivity OK." -Type "Success"

    # Step 7
    $step++
    Update-ProgressBarMain -CurrentStep $step -TotalSteps $total -StatusMessage $steps[$step-1]

    $nsExists = Invoke-Kubectl -KubectlArgs "get ns $Namespace --ignore-not-found" -Kubeconfig $KubeconfigPath
    if (-not $nsExists) {
        Write-Message "Creating namespace '$Namespace'..." -Type "Info"
        Invoke-Kubectl -KubectlArgs "create namespace $Namespace" -Kubeconfig $KubeconfigPath | Out-Null
        Write-Message "Namespace '$Namespace' created." -Type "Success"
    } else {
        Write-Message "Namespace '$Namespace' already exists." -Type "Info"
    }

    $saExists = Invoke-Kubectl -KubectlArgs "get sa $AdminUser -n $Namespace --ignore-not-found" -Kubeconfig $KubeconfigPath
    if (-not $saExists) {
        Write-Message "Creating service account '$AdminUser' in namespace '$Namespace'..." -Type "Info"
        Invoke-Kubectl -KubectlArgs "create serviceaccount $AdminUser -n $Namespace" -Kubeconfig $KubeconfigPath | Out-Null
        Write-Message "Service account '$AdminUser' created." -Type "Success"
    } else {
        Write-Message "Service account '$AdminUser' already exists." -Type "Info"
    }

    # Step 8
    $step++
    Update-ProgressBarMain -CurrentStep $step -TotalSteps $total -StatusMessage $steps[$step-1]

    $crbName = "$AdminUser-binding"
    $crbExists = Invoke-Kubectl -KubectlArgs "get clusterrolebinding $crbName --ignore-not-found" -Kubeconfig $KubeconfigPath
    if (-not $crbExists) {
        Write-Message "Creating clusterrolebinding '$crbName' with cluster-admin..." -Type "Info"
        $saRef = ("{0}:{1}" -f $Namespace, $AdminUser)  # avoids PowerShell scope parsing on ':'
        Invoke-Kubectl -KubectlArgs ("create clusterrolebinding {0} --clusterrole cluster-admin --serviceaccount {1}" -f $crbName, $saRef) -Kubeconfig $KubeconfigPath | Out-Null
        Write-Message "Clusterrolebinding '$crbName' created." -Type "Success"
    } else {
        Write-Message "Clusterrolebinding '$crbName' already exists." -Type "Info"
    }

    # Step 9
    $step++
    Update-ProgressBarMain -CurrentStep $step -TotalSteps $total -StatusMessage $steps[$step-1]

    $Token = $null
    Write-Message "Trying TokenRequest API..." -Type "Info"
    try {
        $Token = Invoke-Kubectl -KubectlArgs "create token $AdminUser -n $Namespace" -Kubeconfig $KubeconfigPath
        if ($Token -and ($Token.Trim().Length -gt 0)) {
            Write-Message "TokenRequest API succeeded." -Type "Success"
        }
    } catch {
        # ignore and fall back
    }

    if (-not $Token) {
        Write-Message "Falling back to secret based token method..." -Type "Warning"
        $secretName = "$AdminUser-token-secret"
        $yaml = @"
apiVersion: v1
kind: Secret
metadata:
  name: $secretName
  namespace: $Namespace
  annotations:
    kubernetes.io/service-account.name: $AdminUser
type: kubernetes.io/service-account-token
"@
        $tmp = New-TemporaryFile
        $yaml | Out-File -FilePath $tmp -Encoding ascii
        try {
            Invoke-Kubectl -KubectlArgs "apply -f `"$tmp`"" -Kubeconfig $KubeconfigPath | Out-Null
            Start-SleepWithProgress -Seconds 2 -Activity "Waiting for token projection" -Status "Creating SA token secret"
            $b64 = Invoke-Kubectl -KubectlArgs "get secret $secretName -n $Namespace -o jsonpath='{.data.token}'" -Kubeconfig $KubeconfigPath
            if ($b64) {
                $Token = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($b64))
                Write-Message "Secret based token retrieval succeeded." -Type "Success"
            } else {
                throw "Token not present in secret data"
            }
        } finally {
            Remove-Item -Path $tmp -Force -ErrorAction SilentlyContinue | Out-Null
        }
    }

    if (-not $Token) {
        Write-Message "Failed to retrieve a token using both methods." -Type "Error"
        throw "Token retrieval failed"
    }

    # Step 10
    $step++
    Update-ProgressBarMain -CurrentStep $step -TotalSteps $total -StatusMessage $steps[$step-1]

    $tokenFile = Join-Path $OutputFolder ("{0}-{1}-token.txt" -f $AdminUser, $Namespace)
    $Token | Out-File -FilePath $tokenFile -Encoding ascii -Force
    Write-Message "Token written to: $tokenFile" -Type "Success"
    Write-Message "Kubeconfig at:     $KubeconfigPath" -Type "Info"

    Write-Host ""
    Write-Host "Usage tips:" -ForegroundColor Cyan
    Write-Host "  `$env:KUBECONFIG = `"$KubeconfigPath`""
    Write-Host "  kubectl get nodes"
    Write-Host ""
    Write-Host "  Use the token from: $tokenFile" -ForegroundColor Cyan

} catch {
    Write-Message "Error: $_" -Type "Error"
    exit 1
} finally {
    Write-Progress -Id 1 -Activity "AKS Arc Service Token Workflow" -Completed
}

#endregion
