#Requires -Version 5.1
<#
.SYNOPSIS
Installs approved common session-host applications using an existing WinGet client.
.DESCRIPTION
Does not bootstrap WinGet or Chocolatey. Package IDs are allowlisted and WinGet performs the
manifest installer-hash validation. Internet or private WinGet source access is required.
#>
[CmdletBinding(SupportsShouldProcess)]
param([Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$PackageIds)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Common.ps1')
Write-Warning ('System changes: ' + (Get-GuestChangeDescription 'WinGetApplications'))
$approved=@('7zip.7zip','Adobe.Acrobat.Reader.64-bit','Google.Chrome','Microsoft.Edge','Mozilla.Firefox','Notepad++.Notepad++','Microsoft.VisualStudioCode','Microsoft.OneDrive','Microsoft.Teams','Microsoft.Office','Zoom.Zoom.VDI')
$packages=@($PackageIds -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Select-Object -Unique)
if (-not $packages.Count) { throw 'Select at least one application package.' }
foreach ($package in $packages) { if ($package -notin $approved) { throw "Package ID is not approved by this task: $package" } }
if ($PSCmdlet -and -not $PSCmdlet.ShouldProcess('This session host',('Install applications: '+($packages -join ', ')))) { return }
Assert-GuestAdministrator
$winget=Get-Command winget.exe -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $winget) {
    $appInstaller=Get-AppxPackage -AllUsers -Name Microsoft.DesktopAppInstaller -ErrorAction SilentlyContinue | Sort-Object Version -Descending | Select-Object -First 1
    if ($appInstaller) {
        $candidate=Join-Path $appInstaller.InstallLocation 'winget.exe'
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { $winget=[pscustomobject]@{Source=$candidate} }
    }
}
if (-not $winget) { throw 'WinGet is not available. Install or service Microsoft Desktop App Installer before running this task.' }
foreach ($package in $packages) {
    $arguments=@('install','--id',$package,'--exact','--silent','--accept-package-agreements','--accept-source-agreements','--disable-interactivity')
    $process=Start-Process -FilePath $winget.Source -ArgumentList $arguments -Wait -PassThru -WindowStyle Hidden
    if ($process.ExitCode -ne 0) { throw "WinGet failed for $package (exit $($process.ExitCode))." }
}
$taskResult=[pscustomobject]@{Task='WinGetApplications';Status='Succeeded';RebootRequired=$false;UserSignInValidationRequired=$true}
$taskResult
