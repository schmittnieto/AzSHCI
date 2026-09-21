#Requires -Version 5.1
<#
.SYNOPSIS
Configures selected machine-wide Azure Virtual Desktop policies.
.DESCRIPTION
Combines portable policy actions from the reviewed source collections. Every setting is explicit;
NotConfigured leaves the corresponding policy unchanged.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateSet('NotConfigured','Disabled','TextOnly','TextAndImages','TextRichAndImages','TextRichHtmlAndImages')][string]$HostToClientClipboard = 'NotConfigured',
    [ValidateSet('NotConfigured','Disabled','TextOnly','TextAndImages','TextRichAndImages','TextRichHtmlAndImages')][string]$ClientToHostClipboard = 'NotConfigured',
    [ValidateSet('NotConfigured','Enable','Disable')][string]$ScreenCaptureProtection = 'NotConfigured',
    [ValidateSet('NotConfigured','DisableLimits','RestoreNotConfigured')][string]$SessionTimeLimits = 'NotConfigured',
    [ValidateSet('NotConfigured','Enable','Disable')][string]$EdgeOptimization = 'NotConfigured',
    [ValidateSet('NotConfigured','Enable','Disable')][string]$ManagedShortpath = 'NotConfigured',
    [ValidateRange(1024,65535)][int]$ShortpathPort = 3390,
    [string]$ShortpathClientAddresses = 'LocalSubnet'
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Common.ps1')
Write-Warning ('System changes: ' + (Get-GuestChangeDescription 'AvdHostPolicies'))
$values=@($HostToClientClipboard,$ClientToHostClipboard,$ScreenCaptureProtection,$SessionTimeLimits,$EdgeOptimization,$ManagedShortpath)
if ($ManagedShortpath -eq 'Enable') {
    foreach ($address in ($ShortpathClientAddresses -split ',')) {
        if ($address.Trim() -eq 'LocalSubnet') { continue }
        $parts=$address.Trim() -split '/'; $ip=$null
        if ($parts.Count -gt 2 -or -not [net.ipaddress]::TryParse($parts[0],[ref]$ip)) { throw 'Shortpath clients must be explicit IP addresses, CIDRs or LocalSubnet.' }
        if ($parts.Count -eq 2) {
            $max=if ($ip.AddressFamily -eq 'InterNetwork') { 32 } else { 128 }
            if ($parts[1] -notmatch '^\d+$' -or [int]$parts[1] -lt 1 -or [int]$parts[1] -gt $max) { throw 'Invalid or unrestricted Shortpath client subnet.' }
        }
    }
}
if (@($values | Where-Object { $_ -ne 'NotConfigured' }).Count -eq 0) { throw 'Select at least one AVD host policy.' }
if ($PSCmdlet -and -not $PSCmdlet.ShouldProcess('This session host','Apply selected AVD host policies')) { return }
Assert-GuestAdministrator
$terminalPath='HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services'
if ($ManagedShortpath -ne 'NotConfigured') {
    Write-Warning "Managed Shortpath changes the UDP listener and its dedicated inbound firewall rule. Mode: $ManagedShortpath; port: $ShortpathPort; clients: $ShortpathClientAddresses. Restart and verify UDP from a client afterwards."
    # Values from Microsoft's current terminalserver-avd.admx (https://aka.ms/avdgpo).
    Set-GuestRegistryValue $terminalPath 'fUseUdpPortRedirector' ([int]($ManagedShortpath -eq 'Enable')) DWord
    $ruleName='AVDGuest-ManagedShortpath'
    if (Get-NetFirewallRule -Name $ruleName -ErrorAction SilentlyContinue) { Remove-NetFirewallRule -Name $ruleName -ErrorAction Stop }
    if ($ManagedShortpath -eq 'Enable') {
        Set-GuestRegistryValue $terminalPath 'UdpRedirectorPort' $ShortpathPort DWord
        Set-GuestRegistryValue $terminalPath 'SelectTransport' 2 DWord
        $addresses=@($ShortpathClientAddresses -split ',' | ForEach-Object { $_.Trim() })
        $null=New-NetFirewallRule -Name $ruleName -DisplayName 'AVD managed Shortpath (reviewed clients)' -Direction Inbound -Action Allow -Protocol UDP -LocalPort $ShortpathPort -RemoteAddress $addresses -Service TermService -Program "$env:SystemRoot\System32\svchost.exe" -Profile Any -ErrorAction Stop
    }
}
$clipboardMap=@{Disabled=0;TextOnly=1;TextAndImages=2;TextRichAndImages=3;TextRichHtmlAndImages=4}
if ($HostToClientClipboard -ne 'NotConfigured') { Set-GuestRegistryValue $terminalPath 'SCClipLevel' $clipboardMap[$HostToClientClipboard] DWord }
if ($ClientToHostClipboard -ne 'NotConfigured') { Set-GuestRegistryValue $terminalPath 'CSClipLevel' $clipboardMap[$ClientToHostClipboard] DWord }
if ($ScreenCaptureProtection -ne 'NotConfigured') {
    Set-GuestRegistryValue $terminalPath 'fEnableScreenCaptureProtect' ([int]($ScreenCaptureProtection -eq 'Enable')) DWord
}
if ($SessionTimeLimits -ne 'NotConfigured') {
    foreach ($name in @('MaxConnectionTime','MaxDisconnectionTime','MaxIdleTime','RemoteAppLogoffTimeLimit','fResetBroken')) {
        if (Get-ItemProperty -LiteralPath $terminalPath -Name $name -ErrorAction SilentlyContinue) {
            Remove-ItemProperty -LiteralPath $terminalPath -Name $name -Force -ErrorAction Stop
        }
    }
    if ($SessionTimeLimits -eq 'DisableLimits') { Set-GuestRegistryValue $terminalPath 'fResetBroken' 0 DWord }
}
if ($EdgeOptimization -ne 'NotConfigured') {
    $enabled=[int]($EdgeOptimization -eq 'Enable')
    Set-GuestRegistryValue 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' 'SleepingTabsEnabled' $enabled DWord
    Set-GuestRegistryValue 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' 'StartupBoostEnabled' $enabled DWord
}
$taskResult=[pscustomobject]@{Task='AvdHostPolicies';Status='Succeeded';RebootRequired=$true;UserSignInValidationRequired=$true}
$taskResult
