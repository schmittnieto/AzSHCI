#Requires -Version 5.1
<#
.SYNOPSIS
Configures selected Explorer, Office and OneDrive session-host behavior.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateSet('NotConfigured','Hide','Unhide')][string]$DriveVisibility = 'NotConfigured',
    [string]$DrivesToHide,
    [ValidateSet('NotConfigured','Enable','Disable')][string]$OfficeFeatureUpdatesTask = 'NotConfigured',
    [ValidateSet('NotConfigured','Enable','Disable')][string]$OneDriveRemoteApp = 'NotConfigured'
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Common.ps1')
Write-Warning ('System changes: ' + (Get-GuestChangeDescription 'SessionHostExperience'))
if ($DriveVisibility -eq 'NotConfigured' -and $OfficeFeatureUpdatesTask -eq 'NotConfigured' -and $OneDriveRemoteApp -eq 'NotConfigured') { throw 'Select at least one session-host experience setting.' }
$letters=@()
if ($DriveVisibility -eq 'Hide') {
    $letters=@($DrivesToHide -split ',' | ForEach-Object { $_.Trim().ToUpperInvariant() } | Where-Object { $_ })
    if (-not $letters.Count -or @($letters | Where-Object { $_ -notmatch '^[A-Z]$' }).Count) { throw 'DrivesToHide must contain comma-separated drive letters.' }
}
if ($PSCmdlet -and -not $PSCmdlet.ShouldProcess('This session host','Apply selected user-experience settings')) { return }
Assert-GuestAdministrator
if ($DriveVisibility -ne 'NotConfigured') {
    $explorerPath='HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer'
    if ($DriveVisibility -eq 'Unhide') {
        if (Get-ItemProperty -LiteralPath $explorerPath -Name NoDrives -ErrorAction SilentlyContinue) { Remove-ItemProperty -LiteralPath $explorerPath -Name NoDrives -Force }
    } else {
        [uint32]$mask=0
        foreach ($letter in $letters | Select-Object -Unique) { $mask=$mask -bor ([uint32]1 -shl ([int][char]$letter - 65)) }
        Set-GuestRegistryValue $explorerPath 'NoDrives' $mask DWord
    }
}
if ($OfficeFeatureUpdatesTask -ne 'NotConfigured') {
    $officeTask=Get-ScheduledTask -TaskName 'Office Feature Updates' -TaskPath '\Microsoft\Office\' -ErrorAction SilentlyContinue
    if (-not $officeTask) { throw 'The Microsoft Office Feature Updates scheduled task was not found.' }
    if ($OfficeFeatureUpdatesTask -eq 'Enable') { $null=Enable-ScheduledTask -InputObject $officeTask }
    else { $null=Disable-ScheduledTask -InputObject $officeTask }
}
if ($OneDriveRemoteApp -ne 'NotConfigured') {
    $terminalPath='HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services'
    $runPath='HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
    if ($OneDriveRemoteApp -eq 'Enable') {
        $oneDrive=Join-Path $env:ProgramFiles 'Microsoft OneDrive\OneDrive.exe'
        if (-not (Test-Path -LiteralPath $oneDrive -PathType Leaf)) { throw 'Install OneDrive per-machine before enabling its RemoteApp background launch.' }
        Set-GuestRegistryValue $terminalPath 'UseShellAppRuntimeRemoteApp' 1 DWord
        Set-GuestRegistryValue $runPath 'OneDrive' ('"' + $oneDrive + '" /background') String
    } else {
        foreach ($entry in @(@{Path=$terminalPath;Name='UseShellAppRuntimeRemoteApp'},@{Path=$runPath;Name='OneDrive'})) {
            if (Get-ItemProperty -LiteralPath $entry.Path -Name $entry.Name -ErrorAction SilentlyContinue) { Remove-ItemProperty -LiteralPath $entry.Path -Name $entry.Name -Force }
        }
    }
}
$taskResult=[pscustomobject]@{Task='SessionHostExperience';Status='Succeeded';NextLogonRequired=$true;RebootRequired=$false}
$taskResult
