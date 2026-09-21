#Requires -Version 5.1
<#
.SYNOPSIS
Applies explicitly supplied Microsoft AVD agent MSI packages to a registered host.
.DESCRIPTION
Maintenance task only. Does not replace the deployment script's registration flow.
Drain the host and verify that it has no active users before invocation. No registration key is accepted.
.PARAMETER MaintenanceConfirmed
Confirms that host/session maintenance was arranged by the caller. This task cannot verify AVD sessions.
#>
[CmdletBinding(SupportsShouldProcess,ConfirmImpact='High')]
param([uri]$AgentUri, [uri]$BootLoaderUri, [object]$MaintenanceConfirmed = $false)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Common.ps1')
Write-Warning ('System changes: ' + (Get-GuestChangeDescription 'AVDAgentUpdate'))
$MaintenanceConfirmed = ConvertTo-GuestBoolean $MaintenanceConfirmed 'MaintenanceConfirmed'
if (-not $AgentUri -and -not $BootLoaderUri) { throw 'Supply at least one package URI.' }
if ($PSCmdlet -and -not $PSCmdlet.ShouldProcess('This session host','Update registered AVD components')) { return }
if (-not $MaintenanceConfirmed) { throw 'Confirm that the host is drained and user maintenance is complete.' }
Assert-GuestAdministrator
$key = 'HKLM:\SOFTWARE\Microsoft\RDInfraAgent'
if ((Get-ItemProperty -LiteralPath $key -ErrorAction Stop).IsRegistered -ne 1) { throw 'Use the deployment registration flow for an unregistered host.' }
$work = New-GuestWorkspace; $reboot = $false
try {
    $packages = @()
    if ($AgentUri) { $packages += @{Uri=$AgentUri;File='Agent.msi';Pattern='^Remote Desktop Services Infrastructure Agent$'} }
    if ($BootLoaderUri) { $packages += @{Uri=$BootLoaderUri;File='BootLoader.msi';Pattern='^Remote Desktop Agent Boot Loader$'} }
    foreach ($package in $packages) {
        $file = Join-Path $work $package.File
        Receive-GuestFile $package.Uri $file
        Assert-MicrosoftSignature $file
        # Read MSI metadata without invoking Win32_Product, which can repair unrelated products.
        $metadata = Get-GuestMsiMetadata $file
        if ($metadata.ProductName -notmatch $package.Pattern) { throw 'The MSI is not the requested AVD component.' }
        $available = [version]$metadata.ProductVersion
        $current = @(Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -match $package.Pattern } | ForEach-Object { [version]$_.DisplayVersion } | Sort-Object -Descending)
        if ($current.Count -and $current[0] -ge $available) { continue }
        $process = Start-Process msiexec.exe -ArgumentList ('/i "' + $file + '" /quiet /norestart') -Wait -PassThru -WindowStyle Hidden
        if ($process.ExitCode -notin @(0,3010)) { throw "AVD package update failed (exit $($process.ExitCode))." }
        $reboot = $reboot -or $process.ExitCode -eq 3010
    }
    Start-Service RDAgentBootLoader
    if ((Get-Service RDAgentBootLoader).Status -ne 'Running') { throw 'AVD Boot Loader is not running.' }
    $taskResult=[pscustomobject]@{Task='AVDAgentUpdate';Status='Succeeded';RebootRequired=$reboot;HostPoolHealthValidationRequired=$true}
    $taskResult
} finally { Remove-GuestWorkspace $work }
