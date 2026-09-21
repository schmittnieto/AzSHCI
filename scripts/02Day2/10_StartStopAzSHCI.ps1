#region Script help, parameters and initialization
#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Starts or gracefully stops the single-node nested Azure Local lab.
.DESCRIPTION
    Run on the outer Hyper-V host. Discovers all nested VMs, including randomly
    named Arc Resource Bridge and AKS VMs. Sets AutomaticStopAction=ShutDown and
    clustered VM OfflineAction=2, then verifies registered guests are Off and
    clustered roles are fully Offline before stopping the cluster, node and DC.
    Offline cluster configurations may unregister VMs. Start brings ALL guests online,
    including previously Off VMs. Clustered VMs use cluster-managed startup.
    No saved state is deleted and no guest is force-powered off. Failed shutdown
    blocks outer node/DC shutdown. This workflow is for a single-node lab only.
    After successful guest startup, requests Azure Local cloud synchronization
    with Sync-AzureStackHCI on the node. This is not a VM re-registration check.
.PARAMETER Action
    Start, Stop or Configure. Configure changes policies without power operations.
.PARAMETER SkipDC
    Use for an AD-less lab with a local administrative NodeCredential.
.PARAMETER NodeCredential
    Administrative node credential. Defaults to the domain DC_LCM account in
    .env, not the deployment-only NODE_SETUP account. Explicit credentials win.
.PARAMETER DCCredential
    Current DC administrator credential. Uses DEFAULT_ADMIN from .env by default;
    a rejected sign-in offers one secure replacement prompt. Credentials are not saved.
.PARAMETER TimeoutMinutes
    Maximum wait per readiness or VM state transition.
.EXAMPLE
    .\10_StartStopAzSHCI.ps1 -Action Configure
.EXAMPLE
    .\10_StartStopAzSHCI.ps1 -Action Stop
.EXAMPLE
    .\10_StartStopAzSHCI.ps1 -Action Start -SkipDC -NodeCredential (Get-Credential)
.NOTES
    Uses scripts/01Lab/.env or secure credential prompts. Policy snapshots live
    under LocalAppData, outside the repository. No plaintext credentials embedded.
    https://learn.microsoft.com/previous-versions/windows/desktop/mscs/virtual-machines-offlineaction
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification='Interactive lab console status.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '', Justification='Existing lab .env contract; credentials are never logged or persisted by this script.')]
[CmdletBinding()]
param(
    [ValidateSet('Start','Stop','Configure')][string]$Action,
    [string]$NodeName,
    [string]$DCName,
    [pscredential]$NodeCredential,
    [pscredential]$DCCredential,
    [switch]$SkipDC,
    [ValidateRange(1,120)][int]$TimeoutMinutes = 15,
    [string]$OutputDirectory = (Join-Path $env:LOCALAPPDATA 'AzSHCI\PowerLifecycle')
)

& {
param($SelectedAction,$NodeVMName,$DomainVMName,$NodeAuth,$DomainAuth,$WithoutDC,$TransitionMinutes,$HistoryDirectory)
$ErrorActionPreference = 'Stop'
$waitMinutes = $TransitionMinutes

$waitDisplay = @{}
$ProgressPreference = 'Continue'
#endregion

#region Progress and guest readiness helpers
function Show-LifecycleWait {
    param([string]$Activity,[string]$Status,[datetime]$Deadline,[int]$Minutes)
    $now=Get-Date
    $remaining=[Math]::Max(0,($Deadline-$now).TotalSeconds)
    $elapsed=[Math]::Max(0,($Minutes*60)-$remaining)
    $percent=[Math]::Min(99,[int](100*$elapsed/($Minutes*60)))
    $detail="{0} | elapsed {1:mm\:ss} | timeout {2} min" -f $Status,[timespan]::FromSeconds($elapsed),$Minutes
    Write-Progress -Id 20 -Activity $Activity -Status "$detail (bar = wait budget used)" -PercentComplete $percent
    # Persistent fallback for hosts that suppress or clear progress records.
    $key=$Activity + '|' + $Deadline.Ticks
    if (-not $waitDisplay.ContainsKey($key) -or ($now-$waitDisplay[$key]).TotalSeconds -ge 10) {
        $filled=[int][Math]::Floor($percent/5)
        $bar=('='*$filled).PadRight(20,'.')
        Write-Host "[WAIT] [$bar] $Activity | $detail | $percent% of wait budget" -ForegroundColor Cyan
        $waitDisplay[$key]=$now
    }
}
function Wait-OuterVM {
    param([guid]$Id,[string]$Desired)
    $deadline = (Get-Date).AddMinutes($waitMinutes)
    do {
        $machine = Get-VM -Id $Id -ErrorAction Stop
        Show-LifecycleWait "VM: $($machine.Name)" "State: $($machine.State); waiting for $Desired" $deadline $waitMinutes
        if ([string]$machine.State -eq $Desired) { Write-Progress -Id 20 -Activity 'VM power transition' -Completed; return }
        if ([string]$machine.State -match 'Saved|Paused|Critical') { throw "Outer VM $($machine.Name) is $($machine.State). Manual recovery is required." }
        Start-Sleep -Seconds 3
    } while ((Get-Date) -lt $deadline)
    throw "Timed out waiting for $($machine.Name) to be $Desired. No forced power-off requested."
}
function Wait-GuestReady {
    param([string]$Name,[pscredential]$Credential,[switch]$DomainController)
    $deadline = (Get-Date).AddMinutes($waitMinutes)
    $credentialPrompted = $false
    $bootRetryUsed = $false
    $lastFailure = 'Required guest services are not running.'
    do {
        Show-LifecycleWait "Readiness: $Name" "PowerShell Direct and guest services" $deadline $waitMinutes
        try {
            $ready = Invoke-Command -VMName $Name -Credential $Credential -ErrorAction Stop -ScriptBlock {
                param($IsDC)
                $ErrorActionPreference='Stop'
                if ($IsDC) { return ((Get-Service NTDS).Status -eq 'Running' -and (Get-Service DNS).Status -eq 'Running') }
                return ((Get-Service vmms).Status -eq 'Running')
            } -ArgumentList ([bool]$DomainController)
            if ($ready -eq $true) { Write-Progress -Id 20 -Activity "Readiness: $Name" -Completed; Write-Host "[OK] $Name is ready." -ForegroundColor Green; return $Credential }
        } catch {
            $lastFailure = $_.Exception.Message
            # Running is a Hyper-V power state, not proof that guest logon is ready.
            if ($_.FullyQualifiedErrorId -match 'InvalidCredential|AuthenticationFailed|AccessDenied' -or
                $_.Exception.Message -match 'credential is invalid|credentials? (are|is) (invalid|incorrect)|logon failure|user name or password is incorrect|access is denied|0x8007052e|0x80070005') {
                $guestVM=Get-VM -Name $Name -ErrorAction Stop
                if (-not $bootRetryUsed -and -not $credentialPrompted -and
                    $guestVM.State -eq 'Running' -and $guestVM.Uptime.TotalSeconds -lt 180) {
                    $bootRetryUsed=$true
                    Write-Host "[WAIT] $Name has only just started. Allowing guest sign-in services to initialize before retrying once." -ForegroundColor Cyan
                    # Do not repeatedly submit credentials during boot: avoid lockouts.
                    do {
                        Show-LifecycleWait "Startup: $Name" "Waiting for initial guest startup before retrying sign-in" $deadline $waitMinutes
                        if ((Get-Date) -ge $deadline) { throw "Startup readiness timed out for $Name. Later power operations were not executed." }
                        Start-Sleep -Seconds 5
                        $guestVM=Get-VM -Name $Name -ErrorAction Stop
                        if ($guestVM.State -ne 'Running') { throw "$Name left the Running state during startup. Later power operations were not executed." }
                    } while ($guestVM.Uptime.TotalSeconds -lt 180)
                    continue
                }
                Write-Progress -Id 20 -Activity "Readiness: $Name" -Completed
                $parameter=if($DomainController){'DCCredential'}else{'NodeCredential'}
                if ($credentialPrompted) { throw "Sign-in rejected for $Name. Rerun with -$parameter (Get-Credential). Details: $lastFailure" }
                Write-Host "[FAILED] Sign-in rejected for $Name as $($Credential.UserName). Supply a current administrative account; the LCM account is not necessarily a DC administrator." -ForegroundColor Red
                $replacement=Get-Credential -Message "Current administrative credential for $Name (DOMAIN\user or user@domain); cancel to stop"
                if (-not $replacement) { throw "Sign-in cancelled for $Name. Later power operations were not executed." }
                $Credential=$replacement
                $credentialPrompted=$true
                $deadline=(Get-Date).AddMinutes($waitMinutes)
                continue
            }
            Write-Verbose "Waiting for PowerShell Direct/services on ${Name}: $lastFailure"
        }
        Start-Sleep -Seconds 5
    } while ((Get-Date) -lt $deadline)
    throw "Timed out waiting for $Name. Last readiness error: $lastFailure Later power operations were not executed."
}
function Stop-OuterVM {
    [CmdletBinding(SupportsShouldProcess)]
    param($Machine)
    if ([string]$Machine.State -eq 'Off') { return }
    if (-not $PSCmdlet.ShouldProcess($Machine.Name,'Request guest OS shutdown')) { throw 'Outer VM shutdown declined; dependent shutdown steps must not continue.' }
    $job = Stop-VM -VM $Machine -AsJob -Confirm:$false -ErrorAction Stop
    try {
        Wait-OuterVM $Machine.Id 'Off'
        if ($job.State -eq 'Failed') { $null = Receive-Job $job -ErrorAction Stop; throw "Shutdown failed: $($Machine.Name)" }
    } finally {
        if ($job.State -in @('Completed','Failed','Stopped')) { Remove-Job $job }
    }
    Write-Host "[OK] $($Machine.Name) is Off." -ForegroundColor Green
}

#endregion

#region Node-side cluster and guest operations
# All nested Hyper-V and cluster operations execute on the node via PowerShell Direct.
$nodeOperation = {
    param([string]$Mode,[int]$Minutes)
    $ErrorActionPreference='Stop'
$waitDisplay = @{}
$ProgressPreference = 'Continue'
function Show-LifecycleWait {
    param([string]$Activity,[string]$Status,[datetime]$Deadline,[int]$Minutes)
    $now=Get-Date
    $remaining=[Math]::Max(0,($Deadline-$now).TotalSeconds)
    $elapsed=[Math]::Max(0,($Minutes*60)-$remaining)
    $percent=[Math]::Min(99,[int](100*$elapsed/($Minutes*60)))
    $detail="{0} | elapsed {1:mm\:ss} | timeout {2} min" -f $Status,[timespan]::FromSeconds($elapsed),$Minutes
    Write-Progress -Id 20 -Activity $Activity -Status "$detail (bar = wait budget used)" -PercentComplete $percent
    # Persistent fallback for hosts that suppress or clear progress records.
    $key=$Activity + '|' + $Deadline.Ticks
    if (-not $waitDisplay.ContainsKey($key) -or ($now-$waitDisplay[$key]).TotalSeconds -ge 10) {
        $filled=[int][Math]::Floor($percent/5)
        $bar=('='*$filled).PadRight(20,'.')
        Write-Host "[WAIT] [$bar] $Activity | $detail | $percent% of wait budget" -ForegroundColor Cyan
        $waitDisplay[$key]=$now
    }
}
    Import-Module Hyper-V -ErrorAction Stop
    Import-Module FailoverClusters -ErrorAction Stop
    function Test-OfflineVMRole {
        param($Resource)
        $group=Get-ClusterGroup -Name ([string]$Resource.OwnerGroup) -ErrorAction Stop
        $members=@(Get-ClusterResource -ErrorAction Stop | Where-Object { [string]$_.OwnerGroup -eq [string]$group.Name })
        $vmMembers=@($members | Where-Object { [string]$_.ResourceType -eq 'Virtual Machine' })
        $configMembers=@($members | Where-Object { [string]$_.ResourceType -eq 'Virtual Machine Configuration' })
        return ($group.State -eq 'Offline' -and $vmMembers.Count -eq 1 -and
            $vmMembers[0].Name -eq $Resource.Name -and $vmMembers[0].State -eq 'Offline' -and
            $configMembers.Count -eq 1 -and $configMembers[0].State -eq 'Offline')
    }
    if ($Mode -eq 'StartCluster') {
        Start-Service ClusSvc -ErrorAction Stop
        $deadline=(Get-Date).AddMinutes($Minutes)
        do {
            try {
                Show-LifecycleWait "Cluster startup" "Waiting for cluster node and CSVs Online" $deadline $Minutes
                $nodes=@(Get-ClusterNode -ErrorAction Stop)
                if ($nodes.Count -ne 1) { throw 'This script supports a single-node nested lab only.' }
                $volumes=@(Get-ClusterSharedVolume -ErrorAction Stop)
                if ($nodes[0].State -eq 'Up' -and -not @($volumes | Where-Object State -ne 'Online').Count) { Write-Progress -Id 20 -Activity 'Cluster startup' -Completed; return }
            } catch {
                if ($_.Exception.Message -like '*single-node*') { throw }
                Write-Verbose 'Waiting for cluster and CSV readiness.'
            }
            Start-Sleep -Seconds 5
        } while ((Get-Date) -lt $deadline)
        throw 'Cluster/CSV readiness timed out. Guest startup was not attempted.'
    }
    $nodes=@(Get-ClusterNode -ErrorAction Stop)
    if ($nodes.Count -ne 1) { throw 'This script supports a single-node nested lab only. No guest policies or power states were changed.' }
    $machines=@(Get-VM -ErrorAction Stop)
    $vmResources=@(Get-ClusterResource -ErrorAction Stop | Where-Object { [string]$_.ResourceType -eq 'Virtual Machine' })
    $rolesById=@{}
    foreach ($resource in $vmResources) {
        $vmId=[guid](($resource | Get-ClusterParameter -Name VmId -ErrorAction Stop).Value)
        if (-not @($machines | Where-Object Id -eq $vmId).Count) {
            if (-not (Test-OfflineVMRole $resource)) { throw "Cluster VM $($resource.Name) is absent from Hyper-V and its VM/configuration resources are not verifiably Offline. Resolve it before continuing." }
            # An offline configuration resource can unregister the VM from VMMS.
            # Keep its cluster identity so retries and Start do not omit it.
            $machines += [pscustomobject]@{Id=$vmId;Name=[string]$resource.OwnerGroup;State='OfflineClusterRole';AutomaticStopAction='Not currently registered';AutomaticStartAction='Not currently registered'}
        }
        $rolesById[$vmId.ToString()]=$resource
    }
    if ($Mode -eq 'Inventory') {
        foreach ($machine in $machines) {
            $resource=$rolesById[$machine.Id.ToString()]
            [pscustomobject]@{
                Id=$machine.Id.ToString();Name=$machine.Name;State=[string]$machine.State
                AutomaticStopAction=[string]$machine.AutomaticStopAction
                AutomaticStartAction=[string]$machine.AutomaticStartAction
                ClusterGroup=if($resource){[string]$resource.OwnerGroup}else{$null}
                OfflineAction=if($resource){($resource | Get-ClusterParameter -Name OfflineAction).Value}else{$null}
            }
        }
        return
    }
    if ($Mode -eq 'Configure') {
        foreach ($machine in $machines) {
            $resource=$rolesById[$machine.Id.ToString()]
            # Clustered VM startup belongs to the cluster, not a competing VMMS action.
            $startup=if($resource){'Nothing'}else{'Start'}
            if ($machine.State -ne 'OfflineClusterRole') {
                $machine | Set-VM -AutomaticStopAction ShutDown -AutomaticStartAction $startup -ErrorAction Stop
            }
            if ($resource) {
                $resource | Set-ClusterParameter -Name OfflineAction -Value 2 -ErrorAction Stop
                if (($resource | Get-ClusterParameter -Name OfflineAction).Value -ne 2) { throw "Cluster policy verification failed: $($machine.Name)" }
            }
            if ($machine.State -eq 'OfflineClusterRole') { continue }
            $updated=Get-VM -Id $machine.Id -ErrorAction Stop
            if ([string]$updated.AutomaticStopAction -ne 'ShutDown' -or [string]$updated.AutomaticStartAction -ne $startup) { throw "Hyper-V policy verification failed: $($machine.Name)" }
        }
        return
    }
    if ($Mode -eq 'StopCluster') {
        foreach ($resource in $vmResources) {
            if (-not (Test-OfflineVMRole $resource)) { throw "Cluster shutdown blocked: VM role is not completely Offline: $($resource.OwnerGroup)" }
        }
        $active=@(Get-VM | Where-Object { [string]$_.State -ne 'Off' })
        if ($active.Count) { throw "Cluster shutdown blocked: guests are not Off: $($active.Name -join ', ')" }
        Stop-Cluster -Force -ErrorAction Stop
        if (@(Get-VM | Where-Object { [string]$_.State -ne 'Off' }).Count) { throw 'A guest restarted during cluster shutdown. Outer node left running; inspect manually.' }
        return
    }
    if ($Mode -eq 'StartGuests') {
        $settleDeadline=(Get-Date).AddMinutes($Minutes)
        while (@($machines | Where-Object { [string]$_.State -in @('Starting','Stopping','Reset') }).Count) {
            if ((Get-Date) -ge $settleDeadline) { throw 'Existing guest power transitions did not settle. Inspect the node before retrying.' }
            Show-LifecycleWait "Guest transitions" "Waiting for existing guest power transitions" $settleDeadline $Minutes
            Start-Sleep -Seconds 3
            $machines=@($machines | Where-Object State -eq 'OfflineClusterRole') + @(Get-VM -ErrorAction Stop)
        }
    }
    $blocked=@($machines | Where-Object { [string]$_.State -notin @('Running','Off','OfflineClusterRole') })
    if ($blocked.Count) { throw "Resolve guest states manually: $(($blocked | ForEach-Object { "$($_.Name)=$($_.State)" }) -join ', '). Saved state is never removed automatically." }
    if ($Mode -eq 'StopGuests') {
        # Refuse to offline newly created/reconfigured roles with an unverified Save policy.
        foreach ($machine in $machines) {
            $resource=$rolesById[$machine.Id.ToString()]
            if (($machine.State -ne 'OfflineClusterRole' -and [string]$machine.AutomaticStopAction -ne 'ShutDown') -or ($resource -and ($resource | Get-ClusterParameter -Name OfflineAction).Value -ne 2)) {
                throw "Shutdown policy changed or a new VM appeared: $($machine.Name). Run Configure/retry before shutting down."
            }
        }
    }
    # Names influence ordering only, never discovery. Randomly named guests are included.
    $ordered=@($machines | Sort-Object @{Expression={if($_.Name -match 'control-plane|resource.?bridge|arcbridge'){0}else{1}}},Name)
    if ($Mode -eq 'StopGuests') { [array]::Reverse($ordered) }
    $desired=if($Mode -eq 'StopGuests'){'Off'}else{'Running'}
    foreach ($machine in $ordered) {
        $resource=$rolesById[$machine.Id.ToString()]
        $role=if($resource){Get-ClusterGroup -Name ([string]$resource.OwnerGroup) -ErrorAction Stop}else{$null}
        $job=$null
        Write-Host "[TASK] $Mode : $($machine.Name) | target: $desired" -ForegroundColor Cyan
        if ($role) {
            if ($Mode -eq 'StopGuests') {
                if ($role.State -ne 'Offline') { $null=$role | Stop-ClusterGroup -Wait 0 -ErrorAction Stop }
            } else {
                if ($role.State -ne 'Online') { $null=$role | Start-ClusterGroup -Wait 0 -ErrorAction Stop }
            }
        } elseif ([string]$machine.State -ne $desired) {
            if ($Mode -eq 'StopGuests') { $job=Stop-VM -VM $machine -AsJob -Confirm:$false -ErrorAction Stop }
            else { $null=Start-VM -VM $machine -ErrorAction Stop }
        }
        $deadline=(Get-Date).AddMinutes($Minutes)
        try {
            do {
                # Enumerate successfully first: a missing ID is not a VMMS failure.
                $current=@(Get-VM -ErrorAction Stop | Where-Object Id -eq $machine.Id) | Select-Object -First 1
                Show-LifecycleWait "$Mode : $($machine.Name)" "VM state: $($current.State); target: $desired" $deadline $Minutes
                $roleReady=$true
                if ($role) {
                    $roleState=(Get-ClusterGroup -Name $role.Name -ErrorAction Stop).State
                    $roleReady=if($Mode -eq 'StopGuests'){$roleState -eq 'Offline'}else{$roleState -eq 'Online'}
                    if ($roleState -eq 'Failed') { throw "Cluster role failed: $($role.Name)" }
                }
                if ($job -and $job.State -eq 'Failed') { $null=Receive-Job $job -ErrorAction Stop; throw "Guest shutdown failed: $($machine.Name)" }
                if (-not $current -and $resource -and $Mode -eq 'StopGuests' -and (Test-OfflineVMRole $resource)) { break }
                if (-not $current -and -not $resource) { throw "Standalone VM disappeared: $($machine.Name). Node shutdown is blocked." }
                if ([string]$current.State -eq $desired -and $roleReady) { break }
                if ([string]$current.State -match 'Saved|Saving|Paused|Critical') { throw "Unexpected state $($current.State): $($machine.Name). No destructive recovery attempted." }
                if ((Get-Date) -ge $deadline) { throw "Timed out waiting for $($machine.Name) to be $desired. Node shutdown is blocked." }
                Start-Sleep -Seconds 3
            } while ($true)
        } finally {
            Write-Progress -Id 20 -Activity "Guest power transition" -Completed
            if ($job -and $job.State -in @('Completed','Failed','Stopped')) { Remove-Job $job }
        }
        Write-Host "[OK] $($machine.Name): $desired; cluster role verified where applicable." -ForegroundColor Green
        if ($Mode -eq 'StartGuests' -and $resource) {
            # Deferred while the offline role was absent from VMMS.
            $current | Set-VM -AutomaticStopAction ShutDown -AutomaticStartAction Nothing -ErrorAction Stop
        }
    }
    $remaining=@(Get-VM | Where-Object { [string]$_.State -ne $desired })
    if ($remaining.Count) { throw "Guest state verification failed: $($remaining.Name -join ', ')" }
    foreach ($resource in @(Get-ClusterResource -ErrorAction Stop | Where-Object { [string]$_.ResourceType -eq 'Virtual Machine' })) {
        if ($Mode -eq 'StopGuests') {
            if (-not (Test-OfflineVMRole $resource)) { throw "VM role not fully offline: $($resource.OwnerGroup). Node shutdown is blocked." }
        } else {
            $id=[guid](($resource | Get-ClusterParameter -Name VmId -ErrorAction Stop).Value)
            $registered=@(Get-VM -ErrorAction Stop | Where-Object Id -eq $id)
            if ($registered.Count -ne 1 -or $registered[0].State -ne 'Running' -or
                (Get-ClusterGroup -Name ([string]$resource.OwnerGroup) -ErrorAction Stop).State -ne 'Online') {
                throw "Cluster VM did not register and start: $($resource.OwnerGroup)"
            }
        }
    }
}

#endregion

#region Main workflow: authentication, inventory and Start / Stop / Configure
try {
    Import-Module Hyper-V -ErrorAction Stop
    $envFile=Join-Path $PSScriptRoot '..\01Lab\.env'
    if (Test-Path -LiteralPath $envFile) { & (Join-Path $PSScriptRoot '..\01Lab\Set-LabEnv.ps1') -Quiet }
    if (-not $NodeVMName) { $NodeVMName=if($env:AZSHCI_HCI_VM_NAME){$env:AZSHCI_HCI_VM_NAME}else{'AZLN01'} }
    if (-not $DomainVMName) { $DomainVMName=if($env:AZSHCI_DC_VM_NAME){$env:AZSHCI_DC_VM_NAME}else{'DC'} }
    if (-not $SelectedAction) { $SelectedAction=Read-Host 'Choose Start, Stop or Configure' }
    if ($SelectedAction -notin @('Start','Stop','Configure')) { throw 'Choose Start, Stop or Configure.' }
    if (-not $WithoutDC -and $NodeVMName -eq $DomainVMName) { throw 'Node and DC must be different VMs.' }
    $outerNode=Get-VM -Name $NodeVMName -ErrorAction Stop
    if (@($outerNode).Count -ne 1) { throw 'Specify one exact node VM name.' }
    $outerDC=$null
    if (-not $WithoutDC) {
        $outerDC=Get-VM -Name $DomainVMName -ErrorAction Stop
        if (@($outerDC).Count -ne 1) { throw 'Specify one exact DC VM name.' }
    }
    if (-not $NodeAuth) {
        if ($env:AZSHCI_DC_LCM_USER -and $env:AZSHCI_DC_LCM_PASSWORD -and -not $WithoutDC) {
            $username=$env:AZSHCI_DC_LCM_USER
            if ($username -notmatch '[\\@]' -and $env:AZSHCI_DOMAIN_NETBIOS) { $username="$env:AZSHCI_DOMAIN_NETBIOS\$username" }
            $NodeAuth=[pscredential]::new($username,(ConvertTo-SecureString $env:AZSHCI_DC_LCM_PASSWORD -AsPlainText -Force))
        } else { $NodeAuth=Get-Credential -Message "LCM or local administrative credential for PowerShell Direct to $NodeVMName" }
    }
    if (-not $NodeAuth) { throw 'No node credential supplied. No power operations were executed.' }
    if ($SelectedAction -eq 'Start' -and -not $WithoutDC -and -not $DomainAuth) {
        if ($env:AZSHCI_DEFAULT_ADMIN_USER -and $env:AZSHCI_DEFAULT_ADMIN_PASSWORD -and $env:AZSHCI_DOMAIN_NETBIOS) {
            $dcUser=$env:AZSHCI_DEFAULT_ADMIN_USER
            if ($dcUser -notmatch '[\\@]') { $dcUser="$env:AZSHCI_DOMAIN_NETBIOS\$dcUser" }
            $DomainAuth=[pscredential]::new($dcUser,(ConvertTo-SecureString $env:AZSHCI_DEFAULT_ADMIN_PASSWORD -AsPlainText -Force))
        } else { $DomainAuth=Get-Credential -Message "DC credential for NTDS/DNS readiness checks on $DomainVMName" }
    }
    Write-Host "Action: $SelectedAction | Node: $NodeVMName | Skip DC: $WithoutDC" -ForegroundColor Cyan
    Write-Host "Node sign-in: $($NodeAuth.UserName) (PowerShell Direct)"
    if ($DomainAuth) { Write-Host "DC sign-in: $($DomainAuth.UserName) (PowerShell Direct)" }
    Write-Host 'Persistent policies: guest OS shutdown, cluster-managed startup for HA VMs and automatic Start for standalone guests.'
    Write-Host 'Start brings ALL discovered guests online, including Arc/AKS and previously Off VMs. Saved states are never discarded.'
    if ($SelectedAction -eq 'Stop') { Write-Host 'Ensure a maintenance window is active and user/application workloads are ready for shutdown.' }
    if ((Read-Host 'Continue? (Y/N) [N]') -ne 'Y') { return }
    foreach ($outerVM in @($outerNode,$outerDC) | Where-Object { $null -ne $_ }) {
        if ([string]$outerVM.State -notin @('Off','Running')) { throw "$($outerVM.Name) is $($outerVM.State). Resolve this manually before continuing." }
    }
    if ($SelectedAction -eq 'Start') {
        if ($outerDC) {
            if ($outerDC.State -eq 'Off') { Write-Host "[START] Starting domain controller $DomainVMName." -ForegroundColor Cyan; $null=Start-VM -VM $outerDC -ErrorAction Stop } else { Write-Host "[CHECK] DC $DomainVMName is already Running; checking guest readiness." -ForegroundColor Cyan }
            Wait-OuterVM $outerDC.Id 'Running'
            $DomainAuth=Wait-GuestReady $DomainVMName $DomainAuth -DomainController
        }
        if ($outerNode.State -eq 'Off') { Write-Host "[START] Starting Azure Local node $NodeVMName." -ForegroundColor Cyan; $null=Start-VM -VM $outerNode -ErrorAction Stop } else { Write-Host "[CHECK] Node $NodeVMName is already Running; checking guest readiness." -ForegroundColor Cyan }
        Wait-OuterVM $outerNode.Id 'Running'
        $NodeAuth=Wait-GuestReady $NodeVMName $NodeAuth
        Write-Host "[START] Starting cluster services and waiting for CSV storage on $NodeVMName." -ForegroundColor Cyan
        Invoke-Command -VMName $NodeVMName -Credential $NodeAuth -ScriptBlock $nodeOperation -ArgumentList 'StartCluster',$TransitionMinutes -ErrorAction Stop
    } else {
        if ($outerNode.State -ne 'Running') { throw 'The node must be running for inventory and safe shutdown checks. Start it first.' }
        $NodeAuth=Wait-GuestReady $NodeVMName $NodeAuth
    }
    $inventory=@(Invoke-Command -VMName $NodeVMName -Credential $NodeAuth -ScriptBlock $nodeOperation -ArgumentList 'Inventory',$TransitionMinutes -ErrorAction Stop)
    $null=New-Item -ItemType Directory -Path $HistoryDirectory -Force
    $snapshot=Join-Path $HistoryDirectory ((Get-Date -Format yyyyMMdd-HHmmss) + '-' + [guid]::NewGuid().ToString('N').Substring(0,6) + '.json')
    [ordered]@{Node=$NodeVMName;Action=$SelectedAction;TimeUtc=[datetime]::UtcNow.ToString('o');OuterVMs=@(@($outerNode,$outerDC) | Where-Object {$null -ne $_} | Select-Object Name,Id,AutomaticStopAction);Guests=$inventory} | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $snapshot -Encoding UTF8
    $inventory | Format-Table Name,State,ClusterGroup,AutomaticStopAction,OfflineAction -AutoSize | Out-Host
    Write-Host "Previous policies: $snapshot"
    foreach ($outerVM in @($outerNode,$outerDC) | Where-Object { $null -ne $_ }) { $outerVM | Set-VM -AutomaticStopAction ShutDown -ErrorAction Stop }
    Invoke-Command -VMName $NodeVMName -Credential $NodeAuth -ScriptBlock $nodeOperation -ArgumentList 'Configure',$TransitionMinutes -ErrorAction Stop
    Write-Host '[OK] Guest and cluster shutdown policies verified.' -ForegroundColor Green
    switch ($SelectedAction) {
        'Stop' {
            Invoke-Command -VMName $NodeVMName -Credential $NodeAuth -ScriptBlock $nodeOperation -ArgumentList 'StopGuests',$TransitionMinutes -ErrorAction Stop
            Invoke-Command -VMName $NodeVMName -Credential $NodeAuth -ScriptBlock $nodeOperation -ArgumentList 'StopCluster',$TransitionMinutes -ErrorAction Stop
            Stop-OuterVM (Get-VM -Id $outerNode.Id)
            if ($outerDC) { Stop-OuterVM (Get-VM -Id $outerDC.Id) }
            Write-Host '[OK] All nested VMs, the node and the selected DC are Off.' -ForegroundColor Green
        }
        'Start' {
            Invoke-Command -VMName $NodeVMName -Credential $NodeAuth -ScriptBlock $nodeOperation -ArgumentList 'StartGuests',$TransitionMinutes -ErrorAction Stop
            Write-Host '[OK] All discovered guests are Running. Arc/AKS application readiness can take additional time.' -ForegroundColor Green
            Write-Host "[SYNC] Running Sync-AzureStackHCI on $NodeVMName." -ForegroundColor Cyan
            $syncJob=Invoke-Command -VMName $NodeVMName -Credential $NodeAuth -AsJob -ErrorAction Stop -ScriptBlock {
                $ErrorActionPreference='Stop'
                Import-Module AzureStackHCI -ErrorAction Stop
                Sync-AzureStackHCI -ErrorAction Stop
            }
            $syncDeadline=(Get-Date).AddMinutes($TransitionMinutes)
            try {
                while ($syncJob.State -in @('NotStarted','Running')) {
                    Show-LifecycleWait "Azure synchronization: $NodeVMName" 'Waiting for Sync-AzureStackHCI to return' $syncDeadline $TransitionMinutes
                    if ((Get-Date) -ge $syncDeadline) { throw 'Synchronization wait timed out. Guests remain running; the remote synchronization may still be active. Verify Azure status before retrying.' }
                    $null=Wait-Job -Job $syncJob -Timeout 5
                }
                Receive-Job -Job $syncJob -ErrorAction Stop | Out-Host
                if ($syncJob.State -ne 'Completed') { throw "Azure synchronization job ended in state $($syncJob.State). Guests remain running." }
                Write-Host '[OK] Sync-AzureStackHCI returned successfully. Azure portal status may take additional time to refresh.' -ForegroundColor Green
            } finally {
                Write-Progress -Id 20 -Activity 'Azure synchronization' -Completed
                if ($syncJob.State -in @('NotStarted','Running')) { Stop-Job -Job $syncJob -ErrorAction SilentlyContinue }
                Remove-Job -Job $syncJob -ErrorAction SilentlyContinue
            }
        }
        'Configure' { Write-Host '[OK] Policies applied. No guest power operations requested.' -ForegroundColor Green }
    }
} catch {
    Write-Progress -Id 20 -Activity 'Lab lifecycle' -Completed
    Write-Host "[FAILED] $($_.Exception.Message)" -ForegroundColor Red
    Write-Host 'Sequence stopped. Completed steps are retained; later node/DC power operations were not executed.'
    throw
}
} $Action $NodeName $DCName $NodeCredential $DCCredential $SkipDC $TimeoutMinutes $OutputDirectory
#endregion
