#Requires -Version 5.1
# Shared functions only. Dot-source from a reviewed guest task.
function Get-GuestChangeDescription {
    param([Parameter(Mandatory)][string]$TaskName)
    switch ($TaskName) {
        'FSLogixProfile' { 'Installs/updates FSLogix unless skipped and writes machine-wide profile-container settings for the SMB location, disk size/format and directory naming. The optional local-profile deletion setting allows FSLogix to delete local profiles when applying a container. Requires working share authentication; a restart may be needed.' }
        'RegionalSettings' { 'Changes the selected time zone, country, system locale and execution-account language/format. Options install a language pack, enable RDP time-zone redirection, copy settings to the welcome screen/new users and write the community Device setup region value. Language installation temporarily disables/restores language tasks on recent Windows builds. Existing user profiles are not migrated; a restart and second run may be needed.' }
        'BGInfo' { 'Downloads/installs BGInfo and its layout and writes a machine-wide logon entry to display desktop information at user sign-in. Replaces the legacy BGInfo logon entry if it invokes BGInfo. Changes the wallpaper at next sign-in; does not restart Windows.' }
        'AgentStagingPermission' { 'Replaces the selected directory root permissions with full control for SYSTEM and local Administrators, removing other root access entries. Does not recurse or delete files. Applications using other identities may lose access.' }
        'AVDAgentUpdate' { 'Installs newer supplied AVD Agent/Boot Loader MSI packages and starts RDAgentBootLoader. Changes installed software and may interrupt host availability. Requires drained hosts and maintenance; a restart may be needed.' }
        'EntraKerberosSettings' { 'Sets machine-wide CloudKerberosTicketRetrievalEnabled and LoadCredKeyFromProfile policies to 1 (Enable) or 0 (Disable). Optionally starts LanmanWorkstation (SMB client connections) and WinHttpAutoProxySvc (WinHTTP automatic proxy discovery), changing disabled services to Manual. Requires a new sign-in. Does not configure SMB authentication or verify share access. Disable does not stop services or restore their startup types.' }
        'AvdHostPolicies' { 'Writes/removes selected machine-wide clipboard, screen capture, session time-limit and Edge sleeping-tab/startup-boost policies. Managed Shortpath optionally changes the UDP listener, TCP/UDP transport and a dedicated inbound firewall rule scoped to specified clients; Disable removes that rule but retains the transport setting. Disabling time limits permits sessions without those limits. A new session may be needed; centrally managed policy can override local values.' }
        'SessionHostExperience' { 'Changes selected machine-wide Explorer drive visibility and OneDrive RemoteApp logon registry values and enables/disables the Office Feature Updates scheduled task. Hidden drives remain accessible by path. Disabling the Office task affects its update scheduling; logon changes apply at next sign-in.' }
        'NetworkOverrides' { 'Merges/replaces the machine-wide DNS suffix search list and/or adds, updates or removes a hosts-file entry. Changes name resolution for users and applications; replacing suffixes can break short-name access. Backs up the hosts file before changing it.' }
        'WinGetApplications' { 'Uses the existing WinGet client to silently install/update selected applications and accept package/source agreements. Changes installed software through each installer; a restart or new sign-in may be needed. Does not install WinGet itself.' }
        'WindowsUpdates' { 'Downloads/installs applicable Windows updates and accepts their EULAs, including driver updates if selected. Changes operating-system components and potentially drivers. Requires maintenance; reports restart requirements but does not restart Windows automatically.' }
        'AvdAgentRestart' { 'Starts/restarts RDAgentBootLoader, the AVD agent boot-loader service. Host availability may be briefly interrupted. Requires drained hosts and maintenance; does not restart Windows.' }
        'LocalAdministrator' { 'Adds/removes the specified existing identity from local Administrators. Adding grants administrative control; removing withdraws that membership and may affect administrative access. Does not create/delete the account.' }
        default { throw "No system-change description is defined for task: $TaskName" }
    }
}

function Assert-GuestAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Run this task as a local administrator or SYSTEM.'
    }
}

function ConvertTo-GuestBoolean {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][object]$Value,
        [Parameter(Mandatory)][string]$Name
    )
    if ($Value -is [bool]) { return $Value }
    $text = ([string]$Value).Trim()
    if ($text -match '^(?i:true|1)$') { return $true }
    if ($text -match '^(?i:false|0)$') { return $false }
    throw "$Name must be True, False, 1 or 0."
}

function New-GuestWorkspace {
    $path = Join-Path ([IO.Path]::GetFullPath($env:TEMP)) ('AvdGuest-' + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $path -ErrorAction Stop
    return $path
}

function Remove-GuestWorkspace {
    param([Parameter(Mandatory)][string]$Path)
    $full = [IO.Path]::GetFullPath($Path)
    $parent = [IO.Path]::GetFullPath($env:TEMP).TrimEnd('\')
    if ((Split-Path $full -Parent).TrimEnd('\') -ne $parent -or (Split-Path $full -Leaf) -notmatch '^AvdGuest-[a-f0-9]{32}$') {
        throw 'Refusing to remove a directory outside the guest temporary workspace.'
    }
    if (Test-Path -LiteralPath $full) {
        if ((Get-Item -LiteralPath $full).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Workspace is a reparse point.' }
        Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction Stop
    }
}

function Receive-GuestFile {
    param([Parameter(Mandatory)][uri]$Uri, [Parameter(Mandatory)][string]$Destination)
    if ($Uri.Scheme -ne 'https' -or $Uri.UserInfo) { throw 'Downloads require HTTPS without embedded credentials.' }
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    try { Invoke-WebRequest -Uri $Uri -OutFile $Destination -UseBasicParsing -TimeoutSec 180 -ErrorAction Stop }
    catch { throw 'Guest download failed. Check the supplied source and guest network access.' }
}

function Assert-MicrosoftSignature {
    param([Parameter(Mandatory)][string]$Path)
    $signature = Get-AuthenticodeSignature -LiteralPath $Path
    if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch '(^|,\s*)O=Microsoft Corporation(,|$)') {
        throw 'The package must have a valid Microsoft signature.'
    }
}

function Get-GuestMsiMetadata {
    param([Parameter(Mandatory)][string]$Path)
    $installer = New-Object -ComObject WindowsInstaller.Installer
    $database = $null; $view = $null; $record = $null
    try {
        $database = $installer.OpenDatabase([IO.Path]::GetFullPath($Path),0)
        $metadata = @{}
        foreach ($property in @('ProductName','ProductVersion')) {
            $query = 'SELECT `Value` FROM `Property` WHERE `Property` = ''' + $property + ''''
            $view = $database.OpenView($query)
            $view.Execute(); $record = $view.Fetch()
            if (-not $record) { throw 'Required MSI metadata is missing.' }
            $metadata[$property] = $record.StringData(1)
            $null = [Runtime.InteropServices.Marshal]::FinalReleaseComObject($record); $record = $null
            $view.Close(); $null = [Runtime.InteropServices.Marshal]::FinalReleaseComObject($view); $view = $null
        }
        return [pscustomobject]$metadata
    } finally {
        foreach ($com in @($record,$view,$database,$installer)) { if ($com) { $null = [Runtime.InteropServices.Marshal]::FinalReleaseComObject($com) } }
    }
}

function Set-GuestRegistryValue {
    param([string]$Path, [string]$Name, [object]$Value, [ValidateSet('DWord','String','MultiString')][string]$Type)
    if (-not (Test-Path -LiteralPath $Path)) { $null = New-Item -Path $Path -Force }
    $current = Get-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction SilentlyContinue
    if ($null -eq $current -or (Compare-Object @($current.$Name) @($Value))) {
        $null = New-ItemProperty -LiteralPath $Path -Name $Name -Value $Value -PropertyType $Type -Force
    }
}
