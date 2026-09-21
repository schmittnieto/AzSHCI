#Requires -Version 5.1
<#
.SYNOPSIS
Creates an experimental FSLogix SMB share on the lab domain controller.
.DESCRIPTION
LAB ONLY. Creates a dedicated AD storage user, directory and encrypted SMB share.
Runs through PowerShell Direct by default, or WinRM with -ComputerName.
Writes a plaintext secret to fslogix.env beside this script, protected for the
current operator, SYSTEM and local Administrators. Never publish this file.
Existing accounts, directories, shares and env files are never overwritten.
Partial failures retain resources and the prepared env file for manual recovery.
Does not configure session hosts, firewall rules or Credential Guard.
.EXAMPLE
.\31_FSLogixFileShare.ps1
.EXAMPLE
.\31_FSLogixFileShare.ps1 -ComputerName dc.example.test -DCCredential (Get-Credential)
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification='Interactive lab review and progress.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '', Justification='Lab env input and newly generated secret; secure remoting argument, no secret logging.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseUsingScopeModifierInNewRunspaces', '', Justification='Remote values are explicit ScriptBlock parameters supplied through ArgumentList.')]
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$DCVMName,
    [string]$ComputerName,
    [pscredential]$DCCredential,
    [ValidatePattern('^[A-Za-z][A-Za-z0-9_-]{0,18}$')][string]$StorageAccount = 'svc-fslogix-lab',
    [ValidatePattern('^[A-Za-z][A-Za-z0-9_-]{0,60}\$?$')][string]$ShareName = 'FSLogixLab$',
    [ValidatePattern('^[A-Za-z]:\\.+')][string]$SharePath = 'C:\FSLogixLab'
)
$ErrorActionPreference='Stop'
#region Configuration and review
$envPath=Join-Path $PSScriptRoot 'fslogix.env'
if(Test-Path -LiteralPath $envPath){throw 'fslogix.env already exists. Preserve it and review the previous deployment before creating another share.'}
$loader=Join-Path $PSScriptRoot '..\01Lab\Set-LabEnv.ps1'
if(Test-Path (Join-Path $PSScriptRoot '..\01Lab\.env')){ & $loader -Quiet }
if(-not $DCVMName){$DCVMName=if($env:AZSHCI_DC_VM_NAME){$env:AZSHCI_DC_VM_NAME}else{'DC'}}
$target=if($ComputerName){$ComputerName}else{$DCVMName}
Write-Host '+--------------------------------------------------------------------+' -ForegroundColor Cyan
Write-Host '| EXPERIMENTAL FSLOGIX SHARE ON DC - LAB ONLY                         |' -ForegroundColor Cyan
Write-Host '+--------------------------------------------------------------------+' -ForegroundColor Cyan
Write-Host "DC: $target | AD storage account: $StorageAccount"
Write-Host "New share: $ShareName | New directory: $SharePath"
Write-Host 'Creates a non-administrator AD account and restricts directory/share access.'
Write-Host 'Hosts using its credential can access ALL profiles in this share.'
Write-Host "Stores a plaintext password in ACL-protected $envPath. Not recommended for production."
if(-not $PSCmdlet.ShouldProcess($target,'Create experimental AD account, FSLogix directory/share and local secret file')){return}
if((Read-Host 'Type CREATE to proceed, or press Enter to cancel') -cne 'CREATE'){return}
if(-not $DCCredential){
    if($env:AZSHCI_DEFAULT_ADMIN_USER -and $env:AZSHCI_DEFAULT_ADMIN_PASSWORD -and $env:AZSHCI_DOMAIN_NETBIOS){
        $dcUser=$env:AZSHCI_DEFAULT_ADMIN_USER
        if($dcUser -notmatch '[\\@]'){$dcUser="$env:AZSHCI_DOMAIN_NETBIOS\$dcUser"}
        $DCCredential=[pscredential]::new($dcUser,(ConvertTo-SecureString $env:AZSHCI_DEFAULT_ADMIN_PASSWORD -AsPlainText -Force))
    }else{$DCCredential=Get-Credential -Message 'DC administrator for the experimental share'}
}
#endregion
#region Remote preflight
$session=$null;$passwordText=$null
try{
    $connection=@{Credential=$DCCredential;ErrorAction='Stop'}
    if($ComputerName){$connection.ComputerName=$ComputerName}else{$connection.VMName=$DCVMName}
    $session=New-PSSession @connection
    $inventory=Invoke-Command -Session $session -ArgumentList $StorageAccount,$ShareName,$SharePath -ScriptBlock {
        param($Account,$Share,$Directory)
        $ErrorActionPreference='Stop'
        if((Get-CimInstance Win32_ComputerSystem).DomainRole -notin @(4,5)){throw 'Target is not a domain controller.'}
        Import-Module ActiveDirectory
        Import-Module SmbShare
        $domain=Get-ADDomain
        if(Get-ADUser -Filter "SamAccountName -eq '$Account'"){throw 'Storage account already exists; no password or permissions were changed.'}
        if(Get-SmbShare -Name $Share -ErrorAction SilentlyContinue){throw 'Share already exists; choose a new name.'}
        if(Test-Path -LiteralPath $Directory){throw 'Directory already exists; choose a new dedicated directory.'}
        $parent=Split-Path $Directory -Parent
        if(-not (Test-Path -LiteralPath $parent -PathType Container)){throw 'Parent directory must already exist.'}
        $item=Get-Item -LiteralPath $parent
        while($item){
            if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Reparse-point directories are not allowed.'}
            $item=$item.Parent
        }
        [pscustomobject]@{Server="$env:COMPUTERNAME.$($domain.DNSRoot)";NetBIOS=$domain.NetBIOSName;UsersContainer=$domain.UsersContainer}
    }
#endregion
#region Protected settings and provisioning
    $random=New-Object byte[] 36
    $rng=[Security.Cryptography.RandomNumberGenerator]::Create()
    try{$rng.GetBytes($random)}finally{$rng.Dispose()}
    $passwordText='Aa1!'+[Convert]::ToBase64String($random)
    $secret=ConvertTo-SecureString $passwordText -AsPlainText -Force
    # Create an empty file, remove inheritance, then write the secret.
    $stream=[IO.File]::Open($envPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    $stream.Dispose()
    $acl=New-Object Security.AccessControl.FileSecurity
    $acl.SetAccessRuleProtection($true,$false)
    foreach($sid in @([Security.Principal.WindowsIdentity]::GetCurrent().User.Value,'S-1-5-18','S-1-5-32-544') | Select-Object -Unique){
        $rule=New-Object Security.AccessControl.FileSystemAccessRule([Security.Principal.SecurityIdentifier]::new($sid),'FullControl','Allow')
        $acl.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $envPath -AclObject $acl
    $settings=@(
        '# EXPERIMENTAL SECRET FILE - DO NOT COMMIT OR LOG',
        'FSLOGIX_SCHEMA=1',
        'FSLOGIX_STATE=Prepared',
        "FSLOGIX_SERVER=$($inventory.Server)",
        "FSLOGIX_SHARE=\\$($inventory.Server)\$ShareName",
        "FSLOGIX_USERNAME=$($inventory.NetBIOS)\$StorageAccount",
        "FSLOGIX_PASSWORD=$passwordText"
    )
    [IO.File]::WriteAllLines($envPath,$settings,[Text.UTF8Encoding]::new($false))
    Invoke-Command -Session $session -ArgumentList $StorageAccount,$ShareName,$SharePath,$secret,$inventory.UsersContainer,$inventory.NetBIOS -ScriptBlock {
        param($Account,$Share,$Directory,[securestring]$Password,$Container,$DomainName)
        $ErrorActionPreference='Stop'
        if((Test-Path -LiteralPath $Directory) -or (Get-SmbShare -Name $Share -ErrorAction SilentlyContinue) -or (Get-ADUser -Filter "SamAccountName -eq '$Account'")){throw 'A target appeared after preflight; refusing to overwrite it.'}
        $user=New-ADUser -Name $Account -SamAccountName $Account -Path $Container -AccountPassword $Password -Enabled $true -AccountNotDelegated $true -Description 'Experimental FSLogix storage only - not for production' -PassThru
        $null=New-Item -ItemType Directory -Path $Directory
        $acl=New-Object Security.AccessControl.DirectorySecurity
        $acl.SetAccessRuleProtection($true,$false)
        foreach($sid in @('S-1-5-18','S-1-5-32-544',$user.SID.Value)){
            $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($sid),'FullControl','ContainerInherit, ObjectInherit','None','Allow'))
        }
        Set-Acl -LiteralPath $Directory -AclObject $acl
        $verifiedAcl=Get-Acl -LiteralPath $Directory
        $expectedSids=@('S-1-5-18','S-1-5-32-544',$user.SID.Value)
        if(-not $verifiedAcl.AreAccessRulesProtected -or $verifiedAcl.Access.Count -ne 3){throw 'Directory ACL verification failed.'}
        foreach($rule in $verifiedAcl.Access){
            if($rule.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value -notin $expectedSids -or $rule.AccessControlType -ne 'Allow' -or $rule.FileSystemRights -ne 'FullControl'){throw 'Unexpected directory access rule.'}
        }
        $admins=([Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')).Translate([Security.Principal.NTAccount]).Value
        $accountName="$DomainName\$Account"
        $null=New-SmbShare -Name $Share -Path $Directory -FullAccess @($admins,$accountName) -EncryptData $true -FolderEnumerationMode AccessBased -CachingMode None -Description 'Experimental FSLogix - shared SYSTEM credentials'
        $created=Get-SmbShare -Name $Share
        if($created.Path -ne $Directory -or -not $created.EncryptData){throw 'Share verification failed.'}
        $grants=@(Get-SmbShareAccess -Name $Share)
        if(@($grants | Where-Object { $_.AccessControlType -ne 'Allow' -or $_.AccessRight -ne 'Full' -or $_.AccountName -notin @($admins,$accountName) }).Count -or $grants.Count -ne 2){throw 'Unexpected share permissions; inspect before use.'}
    }
    $settings[2]='FSLOGIX_STATE=Ready'
    [IO.File]::WriteAllLines($envPath,$settings,[Text.UTF8Encoding]::new($false))
    Write-Host '[OK] Share created. fslogix.env is ready for the experimental guest configuration.' -ForegroundColor Green
    Write-Host 'The AD password follows domain expiration policy. Rotate it before expiry on all consuming hosts.'
    Write-Host 'SMB connectivity and real profile/user isolation still require validation. No session host was modified.'
}catch{
    Write-Host '[FAILED] Setup incomplete. Any created resources and prepared env file are retained for recovery. Do not publish that file.' -ForegroundColor Red
    throw
}finally{
    $passwordText=$null;$settings=$null;$secret=$null
    if($session){Remove-PSSession $session}
}
#endregion
