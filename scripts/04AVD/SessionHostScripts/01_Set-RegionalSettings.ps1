#Requires -Version 5.1
<#
.SYNOPSIS
Sets explicitly selected Windows language, locale and time-zone settings.
.DESCRIPTION
Run as administrator. User settings affect the executing identity, which is SYSTEM under Arc.
Does not claim to configure existing users. Language installation needs Windows Update access.
.PARAMETER CopyToSystemAndDefaultUser
Copies the executing account's international settings to system and new user defaults.
.PARAMETER SetDeviceSetupRegion
Sets Windows' DeviceRegion DWORD to the selected GeoID so Settings displays the same Device setup region after restart. This is an undocumented community workaround.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$Language,
    [string]$TimeZone,
    [string]$HomeLocationGeoId,
    [object]$EnableTimeZoneRedirection = $false,
    [object]$InstallLanguagePack = $false,
    [object]$CopyToSystemAndDefaultUser = $false,
    [Alias('ResetDeviceSetupRegion')]
    [object]$SetDeviceSetupRegion = $false
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Common.ps1')
Write-Warning ('System changes: ' + (Get-GuestChangeDescription 'RegionalSettings'))
$EnableTimeZoneRedirection = ConvertTo-GuestBoolean $EnableTimeZoneRedirection 'EnableTimeZoneRedirection'
$InstallLanguagePack = ConvertTo-GuestBoolean $InstallLanguagePack 'InstallLanguagePack'
$CopyToSystemAndDefaultUser = ConvertTo-GuestBoolean $CopyToSystemAndDefaultUser 'CopyToSystemAndDefaultUser'
$SetDeviceSetupRegion = ConvertTo-GuestBoolean $SetDeviceSetupRegion 'SetDeviceSetupRegion'
$script:AvdTaskStage = 'Validating regional settings'
if (-not $Language -and -not $TimeZone -and -not $HomeLocationGeoId -and -not $EnableTimeZoneRedirection) { throw 'Select a language, country or region, time zone or time-zone redirection.' }
if (($InstallLanguagePack -or $CopyToSystemAndDefaultUser) -and -not $Language) { throw 'Language is required for the selected operation.' }
if ($SetDeviceSetupRegion -and -not $HomeLocationGeoId) { throw 'HomeLocationGeoId is required to set the Device setup region display.' }
if ($Language) { $null = [Globalization.CultureInfo]::GetCultureInfo($Language) }
if ($TimeZone) { $null = Get-TimeZone -Id $TimeZone }
if ($HomeLocationGeoId -and $HomeLocationGeoId -notmatch '^\d{1,4}$') { throw 'HomeLocationGeoId must be a numeric Windows geographical identifier.' }
if ($PSCmdlet -and -not $PSCmdlet.ShouldProcess('This session host','Apply regional settings')) { return }
Assert-GuestAdministrator
$languageSettingsDeferred=$false
$deviceSetupRegionValueApplied=$false
$systemPreferredLanguageApplied=$null
if ($TimeZone) { $script:AvdTaskStage = "Setting time zone to $TimeZone"; Set-TimeZone -Id $TimeZone }
if ($HomeLocationGeoId) {
    if (-not (Get-Command Set-WinHomeLocation -ErrorAction SilentlyContinue)) { throw 'Set-WinHomeLocation is not available on this Windows image.' }
    $script:AvdTaskStage = "Setting the execution account country or region to GeoID $HomeLocationGeoId"
    Set-WinHomeLocation -GeoId ([int]$HomeLocationGeoId)
}
if ($EnableTimeZoneRedirection) {
    $script:AvdTaskStage = 'Enabling RDP time-zone redirection'
    Set-GuestRegistryValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services' 'fEnableTimeZoneRedirection' 1 DWord
}
if ($Language) {
    $script:AvdTaskStage = 'Checking regional command availability'
    $required = @('Get-SystemPreferredUILanguage','Set-WinSystemLocale','Set-SystemPreferredUILanguage','Set-WinUILanguageOverride','Set-WinUserLanguageList','Set-Culture')
    if ($InstallLanguagePack) { $required += 'Get-InstalledLanguage','Install-Language' }
    if ($CopyToSystemAndDefaultUser) { $required += 'Copy-UserInternationalSettingsToSystem' }
    foreach ($command in $required) { $null = Get-Command $command -ErrorAction Stop }
    if ($InstallLanguagePack) {
        $languageInstalledNow=$false
        $script:AvdTaskStage = "Checking whether language $Language is installed"
        $installedLanguage=@(Get-InstalledLanguage -Language $Language -ErrorAction Stop | ForEach-Object { foreach ($installedEntry in $_) { $installedEntry } })
        if (-not $installedLanguage.Count) {
            $languageTasks=@()
            try {
                $displayVersion=[string](Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name DisplayVersion -ErrorAction Stop).DisplayVersion
                $modernLanguageBuild=$displayVersion -match '^(\d{2})H([12])$' -and ([int]$Matches[1] -gt 24 -or ([int]$Matches[1] -eq 24 -and [int]$Matches[2] -ge 2))
                if ($modernLanguageBuild) {
                    foreach ($taskName in @('Installation','ReconcileLanguageResources')) {
                        $scheduledTask=Get-ScheduledTask -TaskPath '\Microsoft\Windows\LanguageComponentsInstaller\' -TaskName $taskName -ErrorAction SilentlyContinue
                        if ($scheduledTask) {
                            $languageTasks += [pscustomobject]@{Task=$scheduledTask;WasEnabled=($scheduledTask.State -ne 'Disabled')}
                            if ($scheduledTask.State -ne 'Disabled') { $null=Disable-ScheduledTask -InputObject $scheduledTask -ErrorAction Stop }
                        }
                    }
                }
                $script:AvdTaskStage = "Installing language pack $Language"
                $null = Install-Language -Language $Language -ErrorAction Stop
                $languageInstalledNow=$true
            } finally {
                foreach ($languageTask in $languageTasks | Where-Object WasEnabled) { $null=Enable-ScheduledTask -InputObject $languageTask.Task -ErrorAction SilentlyContinue }
            }
            $script:AvdTaskStage = "Verifying installed language pack $Language"
            if (-not @(Get-InstalledLanguage -Language $Language -ErrorAction Stop | ForEach-Object { foreach ($installedEntry in $_) { $installedEntry } }).Count) { throw "Windows did not report $Language as installed after Install-Language completed." }
        }
        $currentPreferredLanguage=[string](Get-SystemPreferredUILanguage -ErrorAction Stop)
        $componentRestartPending=Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
        $updateRestartPending=Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
        $sessionManager=Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -ErrorAction SilentlyContinue
        $restartPending=$componentRestartPending -or $updateRestartPending -or $null -ne $sessionManager.PendingFileRenameOperations
        if ($currentPreferredLanguage -ne $Language -and ($languageInstalledNow -or $restartPending)) {
            $script:AvdTaskStage = "Waiting for a restart before setting preferred UI language to $Language"
            $languageSettingsDeferred=$true
        }
    }
    $script:AvdTaskStage = "Setting system locale to $Language"
    Set-WinSystemLocale $Language
    $script:AvdTaskStage = "Setting culture to $Language"
    Set-Culture $Language
    if (-not $languageSettingsDeferred) {
        $script:AvdTaskStage = "Setting UI language override to $Language"
        Set-WinUILanguageOverride $Language
        $script:AvdTaskStage = "Setting the execution account language list to $Language"
        Set-WinUserLanguageList $Language -Force
        try {
            $script:AvdTaskStage = "Setting preferred UI language to $Language"
            Set-SystemPreferredUILanguage $Language
            $systemPreferredLanguageApplied=([string](Get-SystemPreferredUILanguage -ErrorAction Stop) -eq $Language)
        } catch [ArgumentException] {
            # Windows 11 can reject this device-wide value even though the language is installed.
            # Keep the supported per-account settings so they can be copied to system/new-user defaults.
            $systemPreferredLanguageApplied=$false
        }
    }
    if ($CopyToSystemAndDefaultUser) {
        $script:AvdTaskStage = "Copying regional settings and country or region to system and new users"
        Copy-UserInternationalSettingsToSystem -WelcomeScreen $true -NewUser $true
    }
}
if ($SetDeviceSetupRegion) {
    $script:AvdTaskStage = "Setting the Device setup region display to GeoID $HomeLocationGeoId"
    $null=Get-Command Invoke-CimMethod -ErrorAction Stop
    $deviceRegionSubKey='SOFTWARE\Microsoft\Windows\CurrentVersion\Control Panel\DeviceRegion'
    $deviceRegionArguments=@{hDefKey=[uint32]2147483650;sSubKeyName=$deviceRegionSubKey;sValueName='DeviceRegion'}
    $currentDeviceRegion=Invoke-CimMethod -Namespace root/default -ClassName StdRegProv -MethodName GetDWORDValue -Arguments $deviceRegionArguments -ErrorAction Stop
    if ($currentDeviceRegion.ReturnValue -ne 0 -or [int]$currentDeviceRegion.uValue -ne [int]$HomeLocationGeoId) {
        $setDeviceRegionArguments=@{}+$deviceRegionArguments
        $setDeviceRegionArguments.uValue=[uint32]$HomeLocationGeoId
        $setDeviceRegion=Invoke-CimMethod -Namespace root/default -ClassName StdRegProv -MethodName SetDWORDValue -Arguments $setDeviceRegionArguments -ErrorAction Stop
        if ($setDeviceRegion.ReturnValue -ne 0) { throw "Windows registry provider returned $($setDeviceRegion.ReturnValue) while setting DeviceRegion." }
    }
    $verifiedDeviceRegion=Invoke-CimMethod -Namespace root/default -ClassName StdRegProv -MethodName GetDWORDValue -Arguments $deviceRegionArguments -ErrorAction Stop
    if ($verifiedDeviceRegion.ReturnValue -ne 0 -or [int]$verifiedDeviceRegion.uValue -ne [int]$HomeLocationGeoId) { throw 'Windows did not retain the selected Device setup region value.' }
    $deviceSetupRegionValueApplied=$true
}
$taskResult=[pscustomobject]@{Task='RegionalSettings';Status='Succeeded';RebootRequired=[bool]($Language -or $SetDeviceSetupRegion);LanguageSettingsDeferred=[bool]$languageSettingsDeferred;SystemPreferredUILanguageApplied=$systemPreferredLanguageApplied;HomeLocationGeoId=$HomeLocationGeoId;DefaultUserRegionalSettingsApplied=[bool]$CopyToSystemAndDefaultUser;DefaultUserSettingsApplied=[bool]($CopyToSystemAndDefaultUser -and -not $languageSettingsDeferred);DeviceSetupRegionRequested=[bool]$SetDeviceSetupRegion;DeviceSetupRegionValueApplied=[bool]$deviceSetupRegionValueApplied;ExistingUserSettingsApplied=$false}
$taskResult
