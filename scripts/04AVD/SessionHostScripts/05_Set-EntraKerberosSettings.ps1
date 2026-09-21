#Requires -Version 5.1
<#
.SYNOPSIS
Sets explicit Windows policy values used by an Entra Kerberos configuration.
.DESCRIPTION
Does not configure Azure Files identity authentication, grants, DNS or user identity requirements.
Validate the intended SMB authentication design independently. No tenant or domain is assumed.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][ValidateSet('Enable','Disable')][string]$Mode,
    [object]$StartRequiredServices = $false
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Common.ps1')
Write-Warning ('System changes: ' + (Get-GuestChangeDescription 'EntraKerberosSettings'))
$StartRequiredServices = ConvertTo-GuestBoolean $StartRequiredServices 'StartRequiredServices'
if ($PSCmdlet -and -not $PSCmdlet.ShouldProcess('This session host',("Set Entra Kerberos policies: " + $Mode))) { return }
Assert-GuestAdministrator
$value = [int]($Mode -eq 'Enable')
Set-GuestRegistryValue 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa\Kerberos\Parameters' 'CloudKerberosTicketRetrievalEnabled' $value DWord
Set-GuestRegistryValue 'HKLM:\SOFTWARE\Policies\Microsoft\AzureADAccount' 'LoadCredKeyFromProfile' $value DWord
if ($StartRequiredServices -and $Mode -eq 'Enable') {
    foreach ($name in @('LanmanWorkstation','WinHttpAutoProxySvc')) {
        $service = Get-Service $name -ErrorAction Stop
        if ($service.StartType -eq 'Disabled') { Set-Service $name -StartupType Manual }
        if ($service.Status -ne 'Running') { Start-Service $name }
    }
}
$taskResult=[pscustomobject]@{Task='EntraKerberosSettings';Status='Succeeded';NewSignInRequired=$true;SmbAuthenticationValidated=$false}
$taskResult
