#Requires -Version 5.1
<#
.SYNOPSIS
Installs signed Microsoft BGInfo and configures its per-user logon invocation.
.DESCRIPTION
Run as administrator. An optional reviewed local BGI configuration may contain script references.
Without one, downloads a pinned generic layout and verifies its SHA-256 before installing it.
The signed executable and selected configuration are placed beneath Program Files.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$ConfigPath,
    [ValidateLength(4,45000)][string]$ConfigContentBase64,
    [uri]$DownloadUri = 'https://download.sysinternals.com/files/BGInfo.zip'
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Common.ps1')
Write-Warning ('System changes: ' + (Get-GuestChangeDescription 'BGInfo'))
$script:AvdTaskStage = 'Validating BGInfo configuration'
if ($ConfigPath -and $ConfigContentBase64) { throw 'Supply ConfigPath or ConfigContentBase64, not both.' }
if ($ConfigPath -and (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf) -or [IO.Path]::GetExtension($ConfigPath) -ne '.bgi')) { throw 'Supply a reviewed local .bgi file.' }
$script:AvdTaskStage = 'Checking ShouldProcess confirmation'
if ($PSCmdlet -and -not $PSCmdlet.ShouldProcess('This session host','Install BGInfo and set its logon command')) { return }
$script:AvdTaskStage = 'Checking administrator permissions'
Assert-GuestAdministrator
$script:AvdTaskStage = 'Creating temporary workspace'
$work = New-GuestWorkspace
try {
    if ($ConfigContentBase64) {
        $script:AvdTaskStage = 'Writing protected BGInfo configuration'
        $ConfigPath = Join-Path $work 'Desktop.bgi'
        try { $configBytes = [Convert]::FromBase64String($ConfigContentBase64) }
        catch { throw 'The protected BGInfo configuration is not valid Base64.' }
        if (-not $configBytes.Length -or $configBytes.Length -gt 32768) { throw 'The decoded BGInfo configuration must contain 1 to 32768 bytes.' }
        [IO.File]::WriteAllBytes($ConfigPath,$configBytes)
        $configBytes=$null
    }
    if (-not $ConfigPath) {
        $script:AvdTaskStage = 'Downloading default BGInfo configuration'
        $ConfigPath = Join-Path $work 'Desktop.bgi'
        Receive-GuestFile ([uri]'https://raw.githubusercontent.com/adamfortuno/BgInfo.Config/6c3ab865c6e7ff7365902d690799f1a5c6a3e001/default.bgi') $ConfigPath
        $configHash = (Get-FileHash -LiteralPath $ConfigPath -Algorithm SHA256).Hash
        if ($configHash -ne '6B2721B42198FD15BF509AE9C7DB27559398476E0EA5A896F497D3D9C5F50C78') {
            throw 'Downloaded default BGInfo configuration failed its SHA-256 check.'
        }
    }
    $script:AvdTaskStage = 'Downloading BGInfo package'
    Receive-GuestFile $DownloadUri (Join-Path $work 'package.zip')
    $script:AvdTaskStage = 'Extracting BGInfo package'
    Expand-Archive -LiteralPath (Join-Path $work 'package.zip') -DestinationPath (Join-Path $work 'package')
    $exe = Join-Path $work 'package\Bginfo64.exe'
    $script:AvdTaskStage = 'Validating Microsoft signature'
    Assert-MicrosoftSignature $exe
    $script:AvdTaskStage = 'Installing BGInfo files'
    $destination = Join-Path $env:ProgramFiles 'AVDGuestTools\BGInfo'
    $null = New-Item -ItemType Directory -Path $destination -Force
    $exeDestination = Join-Path $destination 'Bginfo64.exe'
    if (-not (Test-Path -LiteralPath $exeDestination) -or (Get-FileHash -LiteralPath $exe).Hash -ne (Get-FileHash -LiteralPath $exeDestination).Hash) {
        Copy-Item -LiteralPath $exe -Destination $exeDestination -Force
    }
    $configDestination = Join-Path $destination 'Desktop.bgi'
    if (-not (Test-Path -LiteralPath $configDestination) -or (Get-FileHash -LiteralPath $ConfigPath).Hash -ne (Get-FileHash -LiteralPath $configDestination).Hash) {
        Copy-Item -LiteralPath $ConfigPath -Destination $configDestination -Force
    }
    $command = '"' + $exeDestination + '" "' + $configDestination + '" /TIMER:0 /SILENT /NOLICPROMPT'
    $script:AvdTaskStage = 'Setting the BGInfo logon command'
    $runKey='HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
    $legacyCommand=(Get-ItemProperty -LiteralPath $runKey -Name 'BGInfo' -ErrorAction SilentlyContinue).BGInfo
    if ($legacyCommand -match '(?i)\bBGInfo(?:64)?\.exe\b') {
        Remove-ItemProperty -LiteralPath $runKey -Name 'BGInfo' -Force -ErrorAction Stop
    }
    Set-GuestRegistryValue $runKey 'AVDGuestBGInfo' $command String
    $taskResult=[pscustomobject]@{Task='BGInfo';Status='Succeeded';NextLogonRequired=$true;RebootRequired=$false}
    $taskResult
} finally { Remove-GuestWorkspace $work }
