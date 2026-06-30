# Set-LabEnv.ps1
# Loads the 01Lab configuration into the current PowerShell session.

<#
.SYNOPSIS
    Reads scripts\01Lab\.env and assigns every value as an AZSHCI_* environment
    variable in the current session.

.DESCRIPTION
    Run this once per PowerShell session before running the 01Lab deployment and
    teardown scripts. Every value lives in a single .env file, so you configure
    the lab in one place instead of editing each script before a deployment.

        cd <repo>
        .\scripts\01Lab\Set-LabEnv.ps1
        .\scripts\01Lab\00_Infra_AzHCI.ps1
        .\scripts\01Lab\01_DC.ps1
        .\scripts\01Lab\02_Cluster.ps1

    The variables are stored in the process environment, so they stay available
    to every script you run afterwards in the same session. The 01Lab scripts
    also call this loader automatically if you forget to run it first.

    scripts\01Lab\.env is gitignored and must never be committed. Copy
    scripts\01Lab\.env.example to scripts\01Lab\.env and edit it for your
    environment.

.PARAMETER EnvFile
    Path to the .env file. Defaults to the .env next to this script.

.PARAMETER Quiet
    Suppress the summary output.

.NOTES
    - Lines starting with # are comments. Inline comments after a value are not supported.
    - Surrounding single or double quotes around a value are removed.
    - Designed by Cristian Schmitt Nieto. For more information and usage, visit:
      https://schmitt-nieto.com/blog/azure-local-demolab/
#>

[CmdletBinding()]
param(
    [string]$EnvFile = (Join-Path -Path $PSScriptRoot -ChildPath '.env'),
    [switch]$Quiet
)

if (-not (Test-Path -Path $EnvFile)) {
    throw "Lab .env not found at '$EnvFile'. Copy scripts\01Lab\.env.example to scripts\01Lab\.env and edit it before running the deployment scripts."
}

$loaded = 0
foreach ($line in Get-Content -Path $EnvFile) {
    $trimmed = $line.Trim()
    if ([string]::IsNullOrWhiteSpace($trimmed) -or $trimmed.StartsWith('#')) { continue }

    $idx = $trimmed.IndexOf('=')
    if ($idx -lt 1) { continue }

    $key = $trimmed.Substring(0, $idx).Trim()
    $val = $trimmed.Substring($idx + 1).Trim()

    # Strip one layer of surrounding single or double quotes
    if ($val.Length -ge 2 -and
        (($val.StartsWith('"') -and $val.EndsWith('"')) -or
         ($val.StartsWith("'") -and $val.EndsWith("'")))) {
        $val = $val.Substring(1, $val.Length - 2)
    }

    Set-Item -Path "env:$key" -Value $val
    $loaded++
}

Set-Item -Path 'env:AZSHCI_ENV_LOADED' -Value '1'

if (-not $Quiet) {
    $subscription = if ([string]::IsNullOrWhiteSpace($env:AZSHCI_SUBSCRIPTION_ID)) { 'interactive / not set' } else { $env:AZSHCI_SUBSCRIPTION_ID }
    Write-Host ""
    Write-Host "Lab environment loaded from '$EnvFile' ($loaded variables)." -ForegroundColor Green
    Write-Host ("  Subscription : {0}" -f $subscription)                 -ForegroundColor Cyan
    Write-Host ("  Resource grp : {0}" -f $env:AZSHCI_RESOURCE_GROUP)    -ForegroundColor Cyan
    Write-Host ("  Region       : {0}" -f $env:AZSHCI_LOCATION)          -ForegroundColor Cyan
    Write-Host ("  Node / DC    : {0} / {1}" -f $env:AZSHCI_HCI_VM_NAME, $env:AZSHCI_DC_VM_NAME) -ForegroundColor Cyan
    Write-Host ("  Lab subnet   : {0}" -f $env:AZSHCI_LAB_SUBNET)        -ForegroundColor Cyan
    Write-Host "Secrets are loaded but not displayed. You can now run the 01Lab scripts." -ForegroundColor Yellow
    Write-Host ""
}
