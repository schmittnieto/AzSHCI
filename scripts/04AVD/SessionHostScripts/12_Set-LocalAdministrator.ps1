#Requires -Version 5.1
<#
.SYNOPSIS
Adds or removes one explicitly supplied identity from the local Administrators group.
.DESCRIPTION
Intended for reviewed personal-desktop scenarios. It does not infer the assigned AVD user.
#>
[CmdletBinding(SupportsShouldProcess,ConfirmImpact='High')]
param(
    [Parameter(Mandatory)][ValidateSet('Add','Remove')][string]$Action,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Identity
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Common.ps1')
Write-Warning ('System changes: ' + (Get-GuestChangeDescription 'LocalAdministrator'))
$Identity=$Identity.Trim()
if (-not $Identity -or $Identity -match '[\x00-\x1f]' -or $Identity.Length -gt 256) { throw 'The identity is empty, contains invalid characters or is too long.' }
if ($PSCmdlet -and -not $PSCmdlet.ShouldProcess($Identity,"$Action local Administrators membership")) { return }
Assert-GuestAdministrator
$administrators=Get-LocalGroup -SID 'S-1-5-32-544' -ErrorAction Stop
$existing=@(Get-LocalGroupMember -Group $administrators -ErrorAction Stop | Where-Object { $_.Name -ieq $Identity })
if ($Action -eq 'Add' -and -not $existing.Count) { Add-LocalGroupMember -Group $administrators -Member $Identity -ErrorAction Stop }
if ($Action -eq 'Remove' -and $existing.Count) { Remove-LocalGroupMember -Group $administrators -Member $Identity -ErrorAction Stop }
$taskResult=[pscustomobject]@{Task='LocalAdministrator';Status='Succeeded';NewSignInRequired=$true;UserSignInValidationRequired=$true}
$taskResult
