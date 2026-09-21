#Requires -Version 5.1
<#
.SYNOPSIS
Installs applicable Windows software updates with the built-in Windows Update Agent.
.DESCRIPTION
Does not install PowerShell Gallery modules and never restarts the host automatically.
#>
[CmdletBinding(SupportsShouldProcess,ConfirmImpact='High')]
param([object]$IncludeDrivers = $false)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Common.ps1')
Write-Warning ('System changes: ' + (Get-GuestChangeDescription 'WindowsUpdates'))
$IncludeDrivers=ConvertTo-GuestBoolean $IncludeDrivers 'IncludeDrivers'
if ($PSCmdlet -and -not $PSCmdlet.ShouldProcess('This session host','Download and install applicable Windows updates without rebooting')) { return }
Assert-GuestAdministrator
$session=New-Object -ComObject Microsoft.Update.Session
$searcher=$session.CreateUpdateSearcher()
$criteria="IsInstalled=0 and IsHidden=0"+$(if (-not $IncludeDrivers) { " and Type='Software'" } else { '' })
$search=$searcher.Search($criteria)
$updates=New-Object -ComObject Microsoft.Update.UpdateColl
foreach ($update in $search.Updates) {
    if (-not $update.EulaAccepted) { $update.AcceptEula() }
    $null=$updates.Add($update)
}
$rebootRequired=$false
if ($updates.Count) {
    $downloader=$session.CreateUpdateDownloader(); $downloader.Updates=$updates
    $download=$downloader.Download()
    if ([int]$download.ResultCode -notin @(2,3)) { throw "Windows Update download failed (result $($download.ResultCode))." }
    $installer=$session.CreateUpdateInstaller(); $installer.Updates=$updates
    $installation=$installer.Install()
    if ([int]$installation.ResultCode -notin @(2,3)) { throw "Windows Update installation failed (result $($installation.ResultCode))." }
    $rebootRequired=[bool]$installation.RebootRequired
}
$taskResult=[pscustomobject]@{Task='WindowsUpdates';Status='Succeeded';RebootRequired=$rebootRequired;HostPoolHealthValidationRequired=$true}
$taskResult
