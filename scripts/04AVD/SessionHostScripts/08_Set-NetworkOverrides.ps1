#Requires -Version 5.1
<#
.SYNOPSIS
Configures an explicit DNS suffix search list and/or a hosts-file mapping.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateSet('NotConfigured','Merge','Replace')][string]$DnsSuffixMode = 'NotConfigured',
    [string]$DnsSuffixes,
    [ValidateSet('NotConfigured','Set','Remove')][string]$HostsEntryAction = 'NotConfigured',
    [string]$Hostname,
    [string]$IpAddress
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Common.ps1')
Write-Warning ('System changes: ' + (Get-GuestChangeDescription 'NetworkOverrides'))
if ($DnsSuffixMode -eq 'NotConfigured' -and $HostsEntryAction -eq 'NotConfigured') { throw 'Select a DNS suffix or hosts-file operation.' }
$suffixList=@()
if ($DnsSuffixMode -ne 'NotConfigured') {
    $suffixList=@($DnsSuffixes -split ',' | ForEach-Object { $_.Trim().TrimEnd('.').ToLowerInvariant() } | Where-Object { $_ } | Select-Object -Unique)
    if (-not $suffixList.Count) { throw 'Supply at least one DNS suffix.' }
    foreach ($suffix in $suffixList) { if ([uri]::CheckHostName($suffix) -ne [UriHostNameType]::Dns) { throw "Invalid DNS suffix: $suffix" } }
}
if ($HostsEntryAction -ne 'NotConfigured') {
    $Hostname=$Hostname.Trim().TrimEnd('.').ToLowerInvariant()
    if ([uri]::CheckHostName($Hostname) -ne [UriHostNameType]::Dns) { throw 'Supply a valid DNS hostname for the hosts-file operation.' }
    if ($HostsEntryAction -eq 'Set') {
        [Net.IPAddress]$parsedAddress=$null
        if (-not [Net.IPAddress]::TryParse($IpAddress,[ref]$parsedAddress)) { throw 'Supply a valid IPv4 or IPv6 address.' }
        $IpAddress=$parsedAddress.ToString()
    }
}
if ($PSCmdlet -and -not $PSCmdlet.ShouldProcess('This session host','Apply selected network overrides')) { return }
Assert-GuestAdministrator
if ($DnsSuffixMode -ne 'NotConfigured') {
    $final=@($suffixList)
    if ($DnsSuffixMode -eq 'Merge') {
        $existing=@((Get-DnsClientGlobalSetting -ErrorAction Stop).SuffixSearchList)
        $final=@($existing+$suffixList | ForEach-Object { ([string]$_).Trim().TrimEnd('.').ToLowerInvariant() } | Where-Object { $_ } | Select-Object -Unique)
    }
    Set-DnsClientGlobalSetting -SuffixSearchList $final -ErrorAction Stop
}
if ($HostsEntryAction -ne 'NotConfigured') {
    $hostsPath=Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
    $lines=@(Get-Content -LiteralPath $hostsPath -ErrorAction Stop)
    $updated=New-Object 'System.Collections.Generic.List[string]'
    foreach ($line in $lines) {
        if ($line -match '^\s*#' -or -not $line.Trim()) { $updated.Add($line); continue }
        $parts=@($line -split '\s+' | Where-Object { $_ })
        if ($parts.Count -lt 2) { $updated.Add($line); continue }
        $remaining=@($parts[1..($parts.Count-1)] | Where-Object { $_.TrimEnd('.') -ine $Hostname })
        if ($remaining.Count) { $updated.Add(($parts[0]+"`t"+($remaining -join "`t"))) }
    }
    if ($HostsEntryAction -eq 'Set') { $updated.Add("$IpAddress`t$Hostname") }
    $newText=($updated -join "`r`n")+"`r`n"
    $oldText=($lines -join "`r`n")+"`r`n"
    if ($newText -ne $oldText) {
        Copy-Item -LiteralPath $hostsPath -Destination ($hostsPath+'.avd-backup') -Force
        Set-Content -LiteralPath $hostsPath -Value $newText -Encoding ASCII -NoNewline -Force
        $null=& ipconfig.exe /flushdns
    }
}
$taskResult=[pscustomobject]@{Task='NetworkOverrides';Status='Succeeded';RebootRequired=$false;UserSignInValidationRequired=$true}
$taskResult
