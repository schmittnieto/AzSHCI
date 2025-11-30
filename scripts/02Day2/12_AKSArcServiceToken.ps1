# 12_AKSArcServiceToken.ps1
# Generate a Service Account token for an AKS Arc (connectedClusters) Kubernetes cluster
# and fetch kubeconfig into the lab's standard folder.

<#
.SYNOPSIS
    Retrieves AKS Arc kubeconfig and creates a service account with cluster-admin rights.
    Exports a token to a text file for programmatic access.

.DESCRIPTION
    - Validates required CLI dependencies. No Azure CLI installation is attempted by this script.
    - Optional: skip az extension updates with -SkipAzExtensionUpdate.
    - Allows passing a direct kubectl path with -KubectlPath. If not found and -InstallDependencies is set, tries winget.
    - Interactive selection for Subscription, Resource Group, and Cluster (using az --query ... -o tsv) or non interactive via parameters.
    - Supports re-authentication with -ForceAzReauth (runs 'az account clear' and 'az login', with device code if -UseDeviceCode).
    - Downloads kubeconfig, creates service account and clusterrolebinding, then retrieves a token using TokenRequest API with a safe fallback to a secret based token.

.USAGE
    # Interactive mode: select subscription, resource group, and cluster interactively
    .\12_AKSArcServiceToken.ps1

    # Fully automated mode with all parameters specified
    .\12_AKSArcServiceToken.ps1 -SubscriptionName "MySubscription" -ResourceGroupName "MyResourceGroup" -ClusterName "my-aks-arc-cluster" -AdminUser "my-admin" -OutputFolder "C:\kube"

    # With device code authentication
    .\12_AKSArcServiceToken.ps1 -UseDeviceCode

    # Force re-authentication and skip extension updates
    .\12_AKSArcServiceToken.ps1 -ForceAzReauth -SkipAzExtensionUpdate

    # Specify custom kubectl path and install dependencies if needed
    .\12_AKSArcServiceToken.ps1 -KubectlPath "C:\tools\kubectl.exe" -InstallDependencies

    # Overwrite existing kubeconfig file
    .\12_AKSArcServiceToken.ps1 -SubscriptionName "MySubscription" -Overwrite

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

.PARAMETER InstallDependencies
    If set, attempts to install kubectl using winget if not found.

.PARAMETER SkipAzExtensionUpdate
    If set, does not update az extensions. Only checks presence and warns if missing.

.PARAMETER KubectlPath
    Full path to kubectl.exe if you want to force it. The script will add its folder to PATH for this session.

.PARAMETER UseDeviceCode
    If set, signs in with "az login --use-device-code".

.PARAMETER ForceAzReauth
    If set, runs 'az account clear' before login and performs an interactive login.

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
    [switch]$InstallDependencies,
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
    param([Parameter(Mandatory=$true)][string]$Name)
    return [bool](Get-Command -Name $Name -ErrorAction SilentlyContinue)
}

function Initialize-AzDependencies {
    $azCmd = Get-Command -Name "az" -ErrorAction SilentlyContinue
    if (-not $azCmd) {
        Write-Message "Azure CLI is not available in this session PATH. Open a 64 bit PowerShell or add az to PATH." -Type "Error"
        throw "Az CLI not found in PATH"
    }
    Write-Message "Using az at: $($azCmd.Source)" -Type "Info"

    $requiredExtensions = @("aksarc")
    if ($SkipAzExtensionUpdate) {
        foreach ($ext in $requiredExtensions) {
            az extension show --name $ext 2>$null | Out-Null
            if ($LASTEXITCODE -ne 0) {
                Write-Message "Missing az extension '$ext'. Install it manually or rerun without -SkipAzExtensionUpdate." -Type "Warning"
            }
        }
        return
    }

    foreach ($ext in $requiredExtensions) {
        az extension show --name $ext 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Message "Adding az extension: $ext" -Type "Info"
            az extension add --name $ext --allow-preview true --only-show-errors | Out-Null
        } else {
            Write-Message "Updating az extension: $ext" -Type "Info"
            az extension update --name $ext --allow-preview true --only-show-errors | Out-Null
        }
    }
}

function Initialize-KubectlDependency {
    if ($KubectlPath) {
        if (Test-Path $KubectlPath) {
            $dir = Split-Path -Path $KubectlPath -Parent
            if ($env:PATH -notlike "*$dir*") {
                $env:PATH = "$dir;$env:PATH"
            }
            Write-Message "Using kubectl at: $KubectlPath" -Type "Info"
            return
        } else {
            Write-Message "Provided kubectl path does not exist: $KubectlPath" -Type "Error"
            throw "kubectl path invalid"
        }
    }

    $kubectlCmd = Get-Command -Name "kubectl" -ErrorAction SilentlyContinue
    if ($kubectlCmd) {
        Write-Message "Using kubectl at: $($kubectlCmd.Source)" -Type "Info"
        return
    }

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

    if ($InstallDependencies) {
        if (Get-Command -Name "winget" -ErrorAction SilentlyContinue) {
            Write-Message "Installing kubectl via winget..." -Type "Info"
            winget install -e --id Kubernetes.kubectl --accept-package-agreements --accept-source-agreements | Out-Null
            $kubectlCmd = Get-Command -Name "kubectl" -ErrorAction SilentlyContinue
            if ($kubectlCmd) {
                Write-Message "kubectl installed. Path: $($kubectlCmd.Source)" -Type "Success"
                return
            }
        }
        Write-Message "Automatic kubectl installation failed. Please install it and rerun." -Type "Error"
        throw "kubectl install failed"
    }

    Write-Message "kubectl is not in PATH. Provide -KubectlPath or use -InstallDependencies." -Type "Error"
    throw "kubectl missing"
}

function Select-FromList {
    param(
        [Parameter(Mandatory=$true)][string[]]$Items,
        [Parameter(Mandatory=$true)][string]$Prompt
    )
    if (-not $Items -or $Items.Count -eq 0) {
        throw "No items to select."
    }

    # Print enumerated list (robust across terminals)
    for ($i = 0; $i -lt $Items.Count; $i++) {
        Write-Host ("[{0}] {1}" -f $i, $Items[$i])
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

function Get-Option-AzTsv {
    param(
        [Parameter(Mandatory=$true)][string]$AzCommand,
        [Parameter(Mandatory=$true)][string]$Prompt
    )
    $raw = Invoke-Expression $AzCommand
    if ($LASTEXITCODE -ne 0) {
        throw "Command failed: $AzCommand"
    }
    $lines = ($raw -split "`r?`n" | ForEach-Object { $_.Trim() }) | Where-Object { $_ -ne "" } | Select-Object -Unique
    if (-not $lines -or $lines.Count -eq 0) {
        throw "No results for: $AzCommand"
    }
    return Select-FromList -Items $lines -Prompt $Prompt
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
    $step++; Update-ProgressBarMain -CurrentStep $step -TotalSteps $total -StatusMessage $steps[$step-1]
    Initialize-AzDependencies
    Initialize-KubectlDependency

    # Step 2 (login/reauth optional)
    $step++; Update-ProgressBarMain -CurrentStep $step -TotalSteps $total -StatusMessage $steps[$step-1]
    if ($ForceAzReauth) {
        Write-Message "Clearing Azure account context..." -Type "Info"
        az account clear --only-show-errors | Out-Null
        if ($UseDeviceCode) {
            Write-Message "Signing in to Azure using device code..." -Type "Info"
            az login --use-device-code --only-show-errors | Out-Null
        } else {
            Write-Message "Signing in to Azure..." -Type "Info"
            az login --only-show-errors | Out-Null
        }
    } else {
        # Ensure we at least have a token
        $acct = az account show 2>$null | ConvertFrom-Json
        if (-not $acct) {
            if ($UseDeviceCode) {
                Write-Message "Signing in to Azure using device code..." -Type "Info"
                az login --use-device-code --only-show-errors | Out-Null
            } else {
                Write-Message "Signing in to Azure..." -Type "Info"
                az login --only-show-errors | Out-Null
            }
        }
    }

    # Step 3 (interactive selection using az --query ... -o tsv)
    $step++; Update-ProgressBarMain -CurrentStep $step -TotalSteps $total -StatusMessage $steps[$step-1]

    if (-not $SubscriptionName) {
        Write-Message "Select the Subscription" -Type "Info"
        $SubscriptionName = Get-Option-AzTsv -AzCommand 'az account list --all --query "[].name" -o tsv' -Prompt "Select subscription index"
    }
    az account set --name $SubscriptionName --only-show-errors | Out-Null

    if (-not $ResourceGroupName) {
        Write-Message "Select the Resource Group" -Type "Info"
        $ResourceGroupName = Get-Option-AzTsv -AzCommand 'az group list --query "[].name" -o tsv' -Prompt "Select resource group index"
    }

    if (-not $ClusterName) {
        Write-Message "Select the AKS Arc Cluster" -Type "Info"
        $ClusterName = Get-Option-AzTsv -AzCommand ("az resource list -g {0} --resource-type Microsoft.Kubernetes/connectedClusters --query ""[].name"" -o tsv" -f $ResourceGroupName) -Prompt "Select cluster index"
    }

    if (-not $AdminUser) {
        $AdminUser = Read-Host -Prompt "Input the service account name"
    }

    # Step 4
    $step++; Update-ProgressBarMain -CurrentStep $step -TotalSteps $total -StatusMessage $steps[$step-1]
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
    $step++; Update-ProgressBarMain -CurrentStep $step -TotalSteps $total -StatusMessage $steps[$step-1]
    if ((-not (Test-Path $KubeconfigPath)) -or $Overwrite) {
        Write-Message "Fetching kubeconfig for $ClusterName in $ResourceGroupName..." -Type "Info"
        az aksarc get-credentials --name $ClusterName --resource-group $ResourceGroupName --file $KubeconfigPath --admin --only-show-errors | Out-Null
        Write-Message "Kubeconfig written to $KubeconfigPath" -Type "Success"
    }

    # Step 6
    $step++; Update-ProgressBarMain -CurrentStep $step -TotalSteps $total -StatusMessage $steps[$step-1]
    $nodes = Invoke-Kubectl -KubectlArgs "get nodes -o name" -Kubeconfig $KubeconfigPath
    if (-not $nodes) {
        Write-Message "Failed to reach cluster. Check connectivity and credentials." -Type "Error"
        throw "Cluster not reachable"
    }
    Write-Message "Cluster connectivity OK." -Type "Success"

    # Step 7
    $step++; Update-ProgressBarMain -CurrentStep $step -TotalSteps $total -StatusMessage $steps[$step-1]
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
    $step++; Update-ProgressBarMain -CurrentStep $step -TotalSteps $total -StatusMessage $steps[$step-1]
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
    $step++; Update-ProgressBarMain -CurrentStep $step -TotalSteps $total -StatusMessage $steps[$step-1]
    $Token = $null
    Write-Message "Trying TokenRequest API..." -Type "Info"
    try {
        $Token = Invoke-Kubectl -KubectlArgs "create token $AdminUser -n $Namespace" -Kubeconfig $KubeconfigPath
        if ($Token -and ($Token.Trim().Length -gt 0)) {
            Write-Message "TokenRequest API succeeded." -Type "Success"
        }
    } catch { }

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
    $step++; Update-ProgressBarMain -CurrentStep $step -TotalSteps $total -StatusMessage $steps[$step-1]
    $tokenFile = Join-Path $OutputFolder "$($AdminUser)-$($Namespace)-token.txt"
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
