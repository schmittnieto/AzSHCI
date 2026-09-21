#Requires -Version 5.1
<#
.SYNOPSIS
Restricts a selected agent staging directory to SYSTEM and Administrators.
.DESCRIPTION
Use only for a dedicated staging directory, not an installed application's data directory.
Replaces the root directory DACL. Does not delete files, recurse or install a scheduled task.
Children inherit where their existing inheritance settings permit it. Review protected children separately.
Defaults to the agent installer directory used by AVD deployment. Environment variables
are expanded on the target host. The directory must already exist.
#>
[CmdletBinding(SupportsShouldProcess,ConfirmImpact='High')]
param([string]$Path = '%ProgramData%\AzSHCI\AVD')
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Common.ps1')
Write-Warning ('System changes: ' + (Get-GuestChangeDescription 'AgentStagingPermission'))
$Path = [Environment]::ExpandEnvironmentVariables($Path)
if (-not [IO.Path]::IsPathRooted($Path) -or $Path.StartsWith('\\')) { throw 'Supply an absolute local staging directory.' }
$full = [IO.Path]::GetFullPath($Path).TrimEnd('\')
$protected = @([IO.Path]::GetPathRoot($full),$env:windir,$env:ProgramFiles,${env:ProgramFiles(x86)},$env:ProgramData,$env:USERPROFILE) | Where-Object { $_ } | ForEach-Object { $_.TrimEnd('\') }
if ($full -in $protected -or $full.StartsWith($env:windir.TrimEnd('\') + '\',[StringComparison]::OrdinalIgnoreCase)) { throw 'This is not a dedicated staging directory.' }
$directory = Get-Item -LiteralPath $full -ErrorAction Stop
if (-not $directory.PSIsContainer) { throw 'The target must be a directory.' }
for ($item = $directory; $item; $item = $item.Parent) {
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Reparse points are not supported in the target path.' }
}
if ($PSCmdlet -and -not $PSCmdlet.ShouldProcess($full,'Replace staging root permissions with SYSTEM and Administrators full control')) { return }
Assert-GuestAdministrator
$acl = Get-Acl -LiteralPath $full
$target = New-Object Security.AccessControl.DirectorySecurity
$target.SetOwner((New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')))
$target.SetAccessRuleProtection($true,$false)
foreach ($sid in @('S-1-5-18','S-1-5-32-544')) {
    $rule = New-Object Security.AccessControl.FileSystemAccessRule(
        (New-Object Security.Principal.SecurityIdentifier($sid)), 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
    $target.AddAccessRule($rule)
}
$sections = [Security.AccessControl.AccessControlSections]'Access,Owner'
if ($acl.GetSecurityDescriptorSddlForm($sections) -ne $target.GetSecurityDescriptorSddlForm($sections)) {
    Set-Acl -LiteralPath $full -AclObject $target
}
$taskResult=[pscustomobject]@{Task='AgentStagingPermission';Status='Succeeded';RebootRequired=$false;ProtectedChildrenReviewed=$false}
$taskResult
