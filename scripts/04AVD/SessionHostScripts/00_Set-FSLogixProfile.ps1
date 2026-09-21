#Requires -Version 5.1
<#
.SYNOPSIS
Installs Microsoft FSLogix and configures profile containers.
.DESCRIPTION
Run as administrator on a Windows session host. Supply an existing accessible SMB location.
Does not create storage or validate user SMB authentication. Never deletes local profiles by default.
.PARAMETER VhdLocation
One or more UNC paths for profile containers. No environment-specific default is supplied.
.PARAMETER SkipInstall
Configure an existing FSLogix installation without downloading a package.
.PARAMETER ExperimentalEnvPath
Explicit path to the protected fslogix.env created by 31_FSLogixFileShare.ps1.
Requires -ExperimentalSystemCredentials $true and SYSTEM execution on the session host.
Securely transfer this file to the host; never embed it in a Run Command script or log.
Stores an SMB credential and enables machine-context profile access. Lab only.
.EXAMPLE
.\00_Set-FSLogixProfile.ps1 -ExperimentalSystemCredentials $true -ExperimentalEnvPath C:\SecureStaging\fslogix.env
Run as SYSTEM on the session host after securely staging the protected env file.
Remove the staged file after successful configuration; retain the secured operator copy.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateNotNullOrEmpty()][string[]]$VhdLocation,
    [string]$ExperimentalEnvPath,
    [string]$ExperimentalEnvContentBase64,
    [object]$ExperimentalSystemCredentials = $false,
    [ValidateRange(1024,1048576)][int]$SizeInMBs = 30000,
    [ValidateSet('vhd','vhdx')][string]$VolumeType = 'vhdx',
    [uri]$DownloadUri = 'https://aka.ms/fslogix_download',
    [switch]$SkipInstall,
    [object]$DeleteLocalProfileWhenVHDShouldApply = $false
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Common.ps1')
Write-Warning ('System changes: ' + (Get-GuestChangeDescription 'FSLogixProfile'))
$DeleteLocalProfileWhenVHDShouldApply = ConvertTo-GuestBoolean $DeleteLocalProfileWhenVHDShouldApply 'DeleteLocalProfileWhenVHDShouldApply'
$ExperimentalSystemCredentials = ConvertTo-GuestBoolean $ExperimentalSystemCredentials 'ExperimentalSystemCredentials'
if (($ExperimentalEnvPath -or $ExperimentalEnvContentBase64) -and -not $ExperimentalSystemCredentials) { throw 'The env file requires explicit experimental mode (LAB ONLY).' }
if ($ExperimentalSystemCredentials -and (($ExperimentalEnvPath -and $ExperimentalEnvContentBase64) -or (-not $ExperimentalEnvPath -and -not $ExperimentalEnvContentBase64) -or $VhdLocation)) { throw 'Experimental mode requires exactly one env source and no separate VhdLocation.' }
if (-not $ExperimentalSystemCredentials -and -not $VhdLocation) { throw 'Supply VhdLocation or explicitly select the experimental env mode.' }
if ($ExperimentalSystemCredentials) { Write-Warning 'LAB ONLY: stores shared SMB credentials under SYSTEM and enables AccessNetworkAsComputerObject. The host can access all profiles granted to this account. Credential Guard is unchanged.' }
foreach ($path in $VhdLocation) { if ($path -notmatch '^\\\\[^\\]+\\[^\\]+') { throw 'Profile locations must be UNC share paths.' } }
if ($PSCmdlet -and -not $PSCmdlet.ShouldProcess('This session host','Install/configure FSLogix profiles')) { return }
Assert-GuestAdministrator
if ($ExperimentalSystemCredentials -and [Security.Principal.WindowsIdentity]::GetCurrent().User.Value -ne 'S-1-5-18') { throw 'Experimental credential import must run as SYSTEM on the session host.' }
$work = $null; $reboot = $false
try {
    if ($ExperimentalSystemCredentials) {
        if ((Get-CimInstance Win32_ComputerSystem).DomainRole -in @(4,5)) { throw 'Do not run the FSLogix guest configuration on a domain controller.' }
        $configuration=@{}
        $envLines=if ($ExperimentalEnvContentBase64) {
            try { [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($ExperimentalEnvContentBase64)) -split '\r?\n' }
            catch { throw 'Invalid protected experimental settings encoding.' }
        } else { [IO.File]::ReadAllLines((Resolve-Path -LiteralPath $ExperimentalEnvPath)) }
        $ExperimentalEnvContentBase64=$null
        foreach ($line in $envLines) {
            if (-not $line.Trim() -or $line.TrimStart().StartsWith('#')) { continue }
            if ($line -notmatch '^(FSLOGIX_[A-Z_]+)=(.*)$' -or $configuration.ContainsKey($Matches[1])) { throw 'Invalid or duplicate env entry; file contents are not logged.' }
            $configuration[$Matches[1]]=$Matches[2]
        }
        $envLines=$null; $line=$null
        if ($configuration.FSLOGIX_SCHEMA -ne '1' -or $configuration.FSLOGIX_STATE -ne 'Ready') { throw 'Experimental settings are not ready. Complete share provisioning first.' }
        $server=$configuration.FSLOGIX_SERVER
        if ($server -notmatch '^[A-Za-z0-9][A-Za-z0-9.-]*$' -or $configuration.FSLOGIX_SHARE -notmatch ('^\\\\'+[regex]::Escape($server)+'\\[^\\]+$') -or
            $configuration.FSLOGIX_USERNAME -notmatch '^[^\\\s]+\\[^\\\s]+$' -or -not $configuration.FSLOGIX_PASSWORD) { throw 'Invalid experimental server, share or credential settings.' }
        $VhdLocation=@($configuration.FSLOGIX_SHARE)
        # Use the native API so the password never appears in a child-process command line.
        if (-not ('AvdLab.CredentialStore' -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace AvdLab {
 public static class CredentialStore {
  [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
  public struct Credential {
   public uint Flags, Type;
   public string TargetName, Comment;
   public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;
   public uint CredentialBlobSize;
   public IntPtr CredentialBlob;
   public uint Persist, AttributeCount;
   public IntPtr Attributes;
   public string TargetAlias, UserName;
  }
  [DllImport("advapi32.dll", EntryPoint="CredWriteW", CharSet=CharSet.Unicode, SetLastError=true)]
  public static extern bool Write(ref Credential credential, uint flags);
 }
}
'@
        }
        $credential=New-Object AvdLab.CredentialStore+Credential
        $credential.Type=2; $credential.TargetName=$server; $credential.UserName=$configuration.FSLOGIX_USERNAME
        $credential.Persist=2
        $credential.CredentialBlobSize=[Text.Encoding]::Unicode.GetByteCount($configuration.FSLOGIX_PASSWORD)
        $credential.CredentialBlob=[Runtime.InteropServices.Marshal]::StringToCoTaskMemUni($configuration.FSLOGIX_PASSWORD)
        try {
            if (-not [AvdLab.CredentialStore]::Write([ref]$credential,0)) { throw "Credential storage failed (Win32 $([Runtime.InteropServices.Marshal]::GetLastWin32Error()))." }
        } finally {
            [Runtime.InteropServices.Marshal]::ZeroFreeCoTaskMemUnicode($credential.CredentialBlob)
            $credential.CredentialBlob=[IntPtr]::Zero
            $configuration.Clear()
        }
        if (-not (Test-Path -LiteralPath $VhdLocation[0] -PathType Container)) { throw 'SYSTEM cannot access the profile share. The stored credential remains for diagnosis; check SMB connectivity/policy before retrying.' }
        Write-Host 'SYSTEM share access verified. Real FSLogix logon, write access and user isolation remain unverified.'
    }
    $installed = Join-Path $env:ProgramFiles 'FSLogix\Apps\frx.exe'
    if (-not $SkipInstall) {
        $work = New-GuestWorkspace
        $zip = Join-Path $work 'package.zip'
        Receive-GuestFile $DownloadUri $zip
        Expand-Archive -LiteralPath $zip -DestinationPath (Join-Path $work 'package')
        $setup = @(Get-ChildItem (Join-Path $work 'package') -Recurse -File -Filter FSLogixAppsSetup.exe | Where-Object FullName -Match '\\x64\\')
        if ($setup.Count -ne 1) { throw 'Expected exactly one x64 FSLogix installer.' }
        Assert-MicrosoftSignature $setup[0].FullName
        $available = [version]$setup[0].VersionInfo.ProductVersion
        $current = if (Test-Path -LiteralPath $installed) { [version](Get-Item -LiteralPath $installed).VersionInfo.ProductVersion } else { $null }
        if (-not $current -or $current -lt $available) {
            $process = Start-Process -FilePath $setup[0].FullName -ArgumentList '/install /quiet /norestart' -Wait -PassThru -WindowStyle Hidden
            if ($process.ExitCode -notin @(0,3010)) { throw "FSLogix installation failed (exit $($process.ExitCode))." }
            $reboot = $process.ExitCode -eq 3010
        }
    }
    if (-not (Test-Path -LiteralPath $installed)) { throw 'FSLogix is not installed.' }
    $key = 'HKLM:\SOFTWARE\FSLogix\Profiles'
    if ($ExperimentalSystemCredentials) { Set-GuestRegistryValue $key 'AccessNetworkAsComputerObject' 1 DWord }
    Set-GuestRegistryValue $key 'Enabled' 1 DWord
    Set-GuestRegistryValue $key 'VHDLocations' $VhdLocation MultiString
    Set-GuestRegistryValue $key 'SizeInMBs' $SizeInMBs DWord
    Set-GuestRegistryValue $key 'VolumeType' $VolumeType String
    Set-GuestRegistryValue $key 'IsDynamic' 1 DWord
    Set-GuestRegistryValue $key 'FlipFlopProfileDirectoryName' 1 DWord
    Set-GuestRegistryValue $key 'DeleteLocalProfileWhenVHDShouldApply' ([int]$DeleteLocalProfileWhenVHDShouldApply) DWord
    $taskResult=[pscustomobject]@{Task='FSLogixProfile';Status='Succeeded';RebootRequired=$reboot;UserSignInValidationRequired=$true}
    $taskResult
} finally { if ($work) { Remove-GuestWorkspace $work } }
