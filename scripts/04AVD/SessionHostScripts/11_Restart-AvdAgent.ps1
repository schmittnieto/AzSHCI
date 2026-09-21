#Requires -Version 5.1
<#
.SYNOPSIS
Restarts the Microsoft Azure Virtual Desktop agent boot-loader service.
#>
[CmdletBinding(SupportsShouldProcess,ConfirmImpact='High')]
param()
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Common.ps1')
Write-Warning ('System changes: ' + (Get-GuestChangeDescription 'AvdAgentRestart'))
if ($PSCmdlet -and -not $PSCmdlet.ShouldProcess('RDAgentBootLoader','Restart the AVD agent boot-loader service')) { return }
Assert-GuestAdministrator
$service=Get-Service -Name RDAgentBootLoader -ErrorAction Stop
if ($service.Status -eq 'Stopped') { Start-Service -Name RDAgentBootLoader -ErrorAction Stop }
else { Restart-Service -Name RDAgentBootLoader -Force -ErrorAction Stop }
$service=Get-Service -Name RDAgentBootLoader -ErrorAction Stop
if ($service.Status -ne 'Running') { throw 'RDAgentBootLoader did not return to the Running state.' }
$taskResult=[pscustomobject]@{Task='AvdAgentRestart';Status='Succeeded';RebootRequired=$false;HostPoolHealthValidationRequired=$true}
$taskResult
