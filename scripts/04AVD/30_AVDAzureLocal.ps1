#region Script help, parameters and initialization
#Requires -Version 5.1
<#
.SYNOPSIS
    Deploys Microsoft Entra joined Azure Virtual Desktop session hosts on Azure Local.
.DESCRIPTION
    Interactive lab deployment using an SPN and ARM deployments. Checks effective
    permissions, offers an alternate user login for RBAC repair, discovers Azure
    Local resources and optionally imports a Windows 11 Marketplace image.
    Creates a pooled or personal host pool, desktop application group, workspace and session
    hosts with managed identities, Entra join and the AVD agents.
    On later runs, asks whether to start a new deployment or adjust a discovered
    pool through inspection, selected guest tasks, host expansion or removal.
    Includes pooled and personal power-management scaling plans with subscription-scoped AVD
    service permission repair, explicit activation and ASCII console menus.
    Removal verifies Azure permissions and Entra Device.ReadWrite.All consent,
    resolves exact device identities and requires an explicit deletion review.
    Run after the Azure Local cluster is deployed. Requires a generalized Windows
    11 Enterprise generation 2 image (multi-session for pooled deployments) and a working logical network.
.PARAMETER Monitor
    Path to a previous run.json. Observes deployments, guest tasks and removal state without resubmitting operations.
.PARAMETER InfrastructureResourceGroup
    Resource group containing the Azure Local custom location and VM resources.
.PARAMETER CustomLocationId
    Optional explicit custom location resource ID in InfrastructureResourceGroup.
.PARAMETER OutputDirectory
    Local directory for templates, progress events and run.json. Defaults under
    the current user's LocalAppData. No credentials or registration tokens are written here.
.EXAMPLE
    .\scripts\04AVD\30_AVDAzureLocal.ps1
.EXAMPLE
    .\scripts\04AVD\30_AVDAzureLocal.ps1 -Monitor "$env:LOCALAPPDATA\AVDEntraJoin\runs\<run>\run.json"
.NOTES
    Designed for the Azure Local lab maintained by Cristian Schmitt Nieto.
    https://schmitt-nieto.com/blog/azure-local-demolab/
#>
[CmdletBinding()]
param(
    [string]$SubscriptionId,
    [string]$TenantId,
    [string]$InfrastructureResourceGroup,
    [string]$CustomLocationId,
    [string]$Monitor,
    [string]$OutputDirectory = (Join-Path (Join-Path $env:LOCALAPPDATA 'AVDEntraJoin\runs') ((Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0,6))),
    [ValidateRange(5,60)][int]$PollSeconds = 15,
    [ValidateRange(5,1440)][int]$TimeoutMinutes = 180
)

$ErrorActionPreference = 'Stop'
$script:ArmApi = '2022-09-01'
$script:HciApi = '2024-01-01'
$script:HciPowerApi = '2026-04-01-preview'
$script:AvdApi = '2024-04-03'
$script:ArcApi = '2024-07-10'
$script:RunCommandApi = '2025-01-13'
$script:GuestScriptsPath = Join-Path $PSScriptRoot 'SessionHostScripts'
$script:Run = $null
$script:RunFile = $null
$script:SpnContext = $null
$script:DeploymentErrorCodes = @()
$script:Roles = @{
    Contributor = 'b24988ac-6180-42a0-ab88-20f7382dd24c'
    Reader = 'acdd72a7-3385-48ef-bd42-f606fba81ae7'
    RbacAdministrator = 'f58310d9-a9f6-439a-9e8d-f62e7b41a168'
    DesktopUser = '1d18fff3-a72a-46b5-b4a9-0b38a3cd7e63'
    VmUser = 'fb879df8-f326-4884-b1cf-06f3ad86be52'
    ConnectedMachineAdmin = 'cd570a14-e51a-42ad-bac8-bafd67325302'
}

#endregion

#region Interactive input
function Read-Value {
    param([string]$Prompt, [string]$Default, [string]$Pattern = '.+')
    do {
        $value = Read-Host "$Prompt [$Default]"
        if ([string]::IsNullOrWhiteSpace($value)) { $value = $Default }
        if ($value -match $Pattern) { return $value.Trim() }
        Write-Warning 'Invalid value. Please try again.'
    } while ($true)
}

function Read-SecureText {
    param([string]$Prompt)
    $secure=Read-Host $Prompt -AsSecureString
    if ($secure.Length -eq 0) { return '' }
    $pointer=[IntPtr]::Zero
    try {
        $pointer=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
    } finally {
        if ($pointer -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer) }
        $secure.Dispose()
    }
}

#endregion

#region Permission profiles and configuration menu
function Get-AvdPermissionProfiles {
    return @(
        [pscustomobject]@{Id='Discovery';Name='Discover and inspect resources (subscription Reader)';Roles=@($script:Roles.Reader);Actions=@('Microsoft.DesktopVirtualization/hostPools/read','Microsoft.HybridCompute/machines/read','Microsoft.AzureStackHCI/virtualMachineInstances/read');Scope='Subscription'},
        [pscustomobject]@{Id='Deploy';Name='Deploy / expand hosts and assign access (RG Contributor + RBAC Administrator)';Roles=@($script:Roles.Contributor,$script:Roles.RbacAdministrator);Actions=@('Microsoft.Resources/deployments/write','Microsoft.Resources/deployments/read','Microsoft.Resources/deployments/validate/action','Microsoft.Resources/deployments/operations/read','Microsoft.DesktopVirtualization/hostPools/read','Microsoft.DesktopVirtualization/hostPools/write','Microsoft.DesktopVirtualization/hostPools/retrieveRegistrationToken/action','Microsoft.DesktopVirtualization/hostPools/sessionHosts/read','Microsoft.DesktopVirtualization/applicationGroups/read','Microsoft.DesktopVirtualization/applicationGroups/write','Microsoft.DesktopVirtualization/workspaces/read','Microsoft.DesktopVirtualization/workspaces/write','Microsoft.HybridCompute/machines/read','Microsoft.HybridCompute/machines/write','Microsoft.HybridCompute/machines/extensions/read','Microsoft.HybridCompute/machines/extensions/write','Microsoft.HybridCompute/machines/runCommands/read','Microsoft.HybridCompute/machines/runCommands/write','Microsoft.AzureStackHCI/virtualMachineInstances/read','Microsoft.AzureStackHCI/virtualMachineInstances/write','Microsoft.AzureStackHCI/networkInterfaces/read','Microsoft.AzureStackHCI/networkInterfaces/write','Microsoft.Authorization/roleAssignments/read','Microsoft.Authorization/roleAssignments/write');Scope='ResourceGroups'},
        [pscustomobject]@{Id='Infrastructure';Name='Use Azure Local infrastructure / import images (infrastructure RG Contributor)';Roles=@($script:Roles.Contributor);Actions=@('Microsoft.ExtendedLocation/customLocations/read','Microsoft.ExtendedLocation/customLocations/deploy/action','Microsoft.AzureStackHCI/logicalNetworks/read','Microsoft.AzureStackHCI/logicalNetworks/join/action','Microsoft.AzureStackHCI/storageContainers/read','Microsoft.AzureStackHCI/galleryImages/read','Microsoft.AzureStackHCI/marketplaceGalleryImages/read','Microsoft.AzureStackHCI/marketplaceGalleryImages/write','Microsoft.AzureStackHCI/marketplaceGalleryImages/delete','Microsoft.ResourceConnector/appliances/read','Microsoft.Resources/deployments/write','Microsoft.Resources/deployments/read','Microsoft.Resources/deployments/validate/action','Microsoft.Resources/deployments/operations/read');Scope='Infrastructure'},
        [pscustomobject]@{Id='Remove';Name='Remove hosts, selected NICs/disks and Entra devices (RG Contributor + tenant Graph consent)';Roles=@($script:Roles.Contributor);Actions=@('Microsoft.HybridCompute/machines/read','Microsoft.HybridCompute/machines/delete','Microsoft.HybridCompute/machines/runCommands/read','Microsoft.HybridCompute/machines/runCommands/write','Microsoft.HybridCompute/machines/runCommands/delete','Microsoft.AzureStackHCI/virtualMachineInstances/read','Microsoft.AzureStackHCI/virtualMachineInstances/delete','Microsoft.AzureStackHCI/networkInterfaces/read','Microsoft.AzureStackHCI/networkInterfaces/delete','Microsoft.AzureStackHCI/virtualHardDisks/read','Microsoft.AzureStackHCI/virtualHardDisks/delete','Microsoft.DesktopVirtualization/hostPools/sessionHosts/read','Microsoft.DesktopVirtualization/hostPools/sessionHosts/write','Microsoft.DesktopVirtualization/hostPools/sessionHosts/delete','Microsoft.DesktopVirtualization/hostPools/sessionHosts/userSessions/read');Scope='ResourceGroups'},
        [pscustomobject]@{Id='Guest';Name='Run guest scripts (RG Azure Connected Machine Resource Administrator)';Roles=@($script:Roles.ConnectedMachineAdmin);Actions=@('Microsoft.HybridCompute/machines/read','Microsoft.HybridCompute/machines/runCommands/read','Microsoft.HybridCompute/machines/runCommands/write','Microsoft.HybridCompute/machines/runCommands/delete');Scope='ResourceGroups'},
        [pscustomobject]@{Id='Maintenance';Name='Pool settings / blue-green maintenance / VM restart (RG Contributor)';Roles=@($script:Roles.Contributor);Actions=@('Microsoft.DesktopVirtualization/hostPools/read','Microsoft.DesktopVirtualization/hostPools/write','Microsoft.DesktopVirtualization/hostPools/sessionHosts/read','Microsoft.DesktopVirtualization/hostPools/sessionHosts/write','Microsoft.DesktopVirtualization/hostPools/sessionHosts/userSessions/read','Microsoft.DesktopVirtualization/applicationGroups/read','Microsoft.DesktopVirtualization/applicationGroups/desktops/read','Microsoft.DesktopVirtualization/applicationGroups/desktops/write','Microsoft.DesktopVirtualization/scalingPlans/read','Microsoft.HybridCompute/machines/read','Microsoft.AzureStackHCI/virtualMachineInstances/read','Microsoft.AzureStackHCI/virtualMachineInstances/restart/action');Scope='ResourceGroups'},
        [pscustomobject]@{Id='Autoscale';Name='Scaling plans (RG Desktop Virtualization Contributor + Reader; AVD service power role)';Roles=@('082f0a83-3be5-4ba1-904c-961cca79b387',$script:Roles.Reader);Actions=@('Microsoft.DesktopVirtualization/scalingPlans/read','Microsoft.DesktopVirtualization/scalingPlans/write','Microsoft.DesktopVirtualization/scalingPlans/personalSchedules/read','Microsoft.DesktopVirtualization/scalingPlans/personalSchedules/write','Microsoft.DesktopVirtualization/hostPools/read','Microsoft.DesktopVirtualization/hostPools/sessionHosts/read','Microsoft.AzureStackHCI/virtualMachineInstances/read','Microsoft.Resources/deployments/read','Microsoft.Resources/deployments/write','Microsoft.Resources/deployments/validate/action','Microsoft.Resources/deployments/operations/read');Scope='ResourceGroups'},
        [pscustomobject]@{Id='StartConnect';Name='Start VM on Connect (RG Host Pool Contributor + Reader; AVD service power-on role)';Roles=@('e307426c-f9b6-4e81-87de-d99efb3c32bc',$script:Roles.Reader);Actions=@('Microsoft.DesktopVirtualization/hostPools/read','Microsoft.DesktopVirtualization/hostPools/write','Microsoft.DesktopVirtualization/hostPools/sessionHosts/read','Microsoft.AzureStackHCI/virtualMachineInstances/read');Scope='ResourceGroups'},
        [pscustomobject]@{Id='Directory';Name='Directory lookups (Graph application/user/group/tenant read permissions)';Roles=@();Actions=@();Scope='Tenant'}
    )
}

function Invoke-AvdPermissionMenu {
    while ($true) {
        $mode=Select-Item @([pscustomobject]@{Name='Select permission profiles';Id='Select'},[pscustomobject]@{Name='Configure all permission profiles';Id='All'},[pscustomobject]@{Name='Back';Id='Back'}) 'Permissions for the current deployment account'
        if ($mode.Id -eq 'Back') { return }
        $catalog=@(Get-AvdPermissionProfiles)
        $selected=@(if ($mode.Id -eq 'All') { $catalog } else { Select-Multiple $catalog 'Select permission profiles' })
        if (-not $selected.Count) { continue }
        $scopes=@(); $infraScope=$null
        if (@($selected | Where-Object Scope -eq 'ResourceGroups').Count) {
            Write-Host 'Select existing resource groups containing the host pools, application groups and VMs you intend to manage. Include each group when these resources are separated.'
            do {
                $rg=Select-ResourceGroup 'Select target resource group for permissions' ''
                $scopes+= "$script:SubscriptionScope/resourceGroups/$rg"
            } while ((Read-Value 'Add another target resource group? (Y/N)' 'N' '^[YyNn]$') -eq 'Y')
            $scopes=@($scopes | Select-Object -Unique)
        }
        if ('Infrastructure' -in $selected.Id) {
            $rg=Select-ResourceGroup 'Select Azure Local infrastructure resource group for permissions' ''
            $infraScope="$script:SubscriptionScope/resourceGroups/$rg"
        }
        Show-AvdPanel 'PERMISSION CHANGE REVIEW' @(
            "Account: $($script:SpnContext.Account.Id) | SPN object: $script:SpnObjectId",
            "Tenant: $script:Tenant | Subscription: $script:Subscription",
            'Profiles select built-in roles, not custom action-only roles. Contributor also permits unrelated resource changes within its assigned scope.',
            'Only missing/unverified prerequisites are offered for repair. An authorized alternate user grants rights; the original SPN context is restored.',
            'This workflow configures access only. It does not deploy/delete VMs, run guest scripts, enable autoscale or enable Start VM on Connect.'
        )
        foreach ($selectedProfile in $selected) {
            $targets=@(switch ($selectedProfile.Scope) { 'Subscription' {$script:SubscriptionScope}; 'ResourceGroups' {$scopes}; 'Infrastructure' {$infraScope}; 'Tenant' {$script:Tenant} })
            Show-AvdPanel $selectedProfile.Name @($targets + @("SPN repair role IDs: $($selectedProfile.Roles -join ', ')"))
        }
        if ('Remove' -in $selected.Id) { Write-Warning 'Removal includes tenant-wide Device.ReadWrite.All Graph application consent and subscription Reader for attachment ownership checks. Azure RG roles cannot restrict this Graph permission.' }
        if ('Directory' -in $selected.Id) { Write-Host ('Graph reads: '+((Get-GraphPermissionCatalog | ForEach-Object Name) -join ', ')) }
        if ('Autoscale' -in $selected.Id) { Write-Host 'Autoscale additionally verifies Power On Off Contributor for the MICROSOFT AVD SERVICE at subscription scope.' }
        if ('StartConnect' -in $selected.Id) { Write-Host 'Start VM on Connect additionally verifies Power On Contributor for the MICROSOFT AVD SERVICE at each selected RG.' }
        if (@($selected | Where-Object { $_.Id -in @('Deploy','Infrastructure') }).Count) { Write-Host 'Deployment/image prerequisites also verify the Azure Local resource-provider service role on the selected RGs and offer registration of required Azure providers.' }
        if ((Read-Value 'Check and configure these permission profiles? (Y/N)' 'N' '^[YyNn]$') -ne 'Y') { continue }
        $results=@()
        foreach ($selectedProfile in $selected) {
            try {
                Show-AvdPanel 'CHECKING PERMISSIONS' @($selectedProfile.Name)
                $targets=@(switch ($selectedProfile.Scope) { 'Subscription' {$script:SubscriptionScope}; 'ResourceGroups' {$scopes}; 'Infrastructure' {$infraScope} })
                foreach ($scope in $targets) { Confirm-Permission $scope $selectedProfile.Actions $selectedProfile.Roles }
                switch ($selectedProfile.Id) {
                    'Remove' {
                        Confirm-Permission $script:SubscriptionScope @('Microsoft.HybridCompute/machines/read','Microsoft.AzureStackHCI/virtualMachineInstances/read') @($script:Roles.Reader)
                        Confirm-EntraDeviceDeleteAccess
                    }
                    'Directory' {
                        if (-not (Test-GraphAccess) -and -not (Grant-GraphReadAccess -RefreshSignIn)) { throw 'Directory read permissions were not verified.' }
                        $script:GraphAvailable=$true
                    }
                    'Autoscale' { Confirm-AvdScalingPowerRole }
                    'StartConnect' { foreach ($scope in $scopes) { Confirm-AvdScalingPowerRole -PowerOnOnly -RoleScope $scope } }
                }
                if ($selectedProfile.Id -in @('Deploy','Infrastructure')) {
                    foreach ($namespace in @('Microsoft.DesktopVirtualization','Microsoft.AzureStackHCI','Microsoft.HybridCompute','Microsoft.ExtendedLocation')) { Confirm-ResourceProvider $namespace }
                    $rpApp='1412d89f-b8a8-4111-b4fd-e82905cbd85d'
                    $query="/servicePrincipals?`$filter=appId eq '$rpApp'&`$select=id,appId"
                    $providerPrincipals=@(); try { $providerPrincipals=@(Get-GraphList $query) } catch { }
                    if ($providerPrincipals.Count -ne 1) {
                        if ((Read-Value 'Resolve the Azure Local service identity with an authorized user? (Y/N)' 'Y' '^[YyNn]$') -ne 'Y') { throw 'Azure Local service identity was not verified.' }
                        $providerPrincipals=@(Invoke-AlternateUser { Get-GraphList $query })
                    }
                    if ($providerPrincipals.Count -ne 1 -or $providerPrincipals[0].appId -ne $rpApp) { throw 'Azure Local service identity could not be verified.' }
                    $rpId=$providerPrincipals[0].id
                    $rpRole=(Get-AzRoleDefinition -Name 'Azure Connected Machine Resource Manager').Id
                    if (-not $rpId -or -not $rpRole) { throw 'Azure Local service identity or role is missing.' }
                    foreach ($scope in $targets) {
                        try { Grant-Role $scope $rpId $rpRole }
                        catch {
                            Write-Host "Grant Azure Connected Machine Resource Manager to Azure Local service $rpId at $scope."
                            if ((Read-Value 'Use an authorized user for this service role assignment? (Y/N)' 'Y' '^[YyNn]$') -ne 'Y') { throw 'Azure Local service role repair declined.' }
                            Invoke-AlternateUser { Grant-Role $scope $rpId $rpRole }
                        }
                    }
                }
                $results+="[OK] $($selectedProfile.Id): prerequisites checked / assignments completed"
            } catch {
                Write-Warning $_.Exception.Message
                $results+="[FAILED] $($selectedProfile.Id): incomplete - $($_.Exception.Message)"
            }
        }
        Show-AvdPanel 'PERMISSION RESULTS' @($results + @('', 'Completed grants are retained. Incomplete profiles can be retried. Resource-specific checks still run before each operation; RBAC propagation and conditional restrictions can affect subsequent requests.'))
    }
}

#endregion

#region Session host naming
function Get-AvdSessionHostPrefix {
    param([string]$HostPoolName)
    $value=($HostPoolName -replace '^hp[-_]','' -replace '[^a-zA-Z0-9-]','-').Trim('-').ToLowerInvariant()
    if (-not $value) { $value='avd' }
    $value='sh-'+$value
    if ($value.Length -gt 11) { $value=$value.Substring(0,11).TrimEnd('-') }
    return $value
}

#endregion

#region Scaling plans and power management
function Get-AvdScalingPlans {
    param([string]$PoolId)
    @(Get-ArmList "$PoolId/scalingPlans?api-version=$script:AvdApi")
}

function Assert-AvdAutoscalePaused {
    param([string]$PoolId)
    $scope=$PoolId -replace '/providers/Microsoft.DesktopVirtualization/hostPools/[^/]+$',''
    Confirm-Permission $scope @('Microsoft.DesktopVirtualization/scalingPlans/read') @($script:Roles.Reader)
    foreach ($plan in @(Get-AvdScalingPlans $PoolId)) {
        if (@($plan.properties.hostPoolReferences | Where-Object { $_.hostPoolArmPath -eq $PoolId -and $_.scalingPlanEnabled -eq $true }).Count) {
            throw "Scaling plan '$($plan.name)' is enabled. Disable it for this pool in Scaling Plans before maintenance; autoscale can override drain mode."
        }
    }
}

function Confirm-AvdScalingPowerRole {
    param([switch]$AuthorizedUser,[switch]$PowerOnOnly,[string]$RoleScope=$script:SubscriptionScope)
    # This role belongs to Microsoft's AVD service, never to the deployment SPN.
    $appId='9cdead84-a844-4324-93f2-b2e6bb768d07'
    $roleId='40c5ff49-9181-41f8-ae61-143b0e78555e'
    $roleName='Desktop Virtualization Power On Off Contributor'
    if ($PowerOnOnly) { $roleId='489581de-a3bd-480d-9518-53dea7416b33'; $roleName='Desktop Virtualization Power On Contributor' }
    elseif ($RoleScope -ne $script:SubscriptionScope) { throw 'Autoscale requires subscription-scoped power management permissions.' }
    $lookup="/servicePrincipals?`$filter=appId eq '$appId'&`$select=id,appId,displayName"
    $principals=@()
    try { $principals=@(Get-GraphList $lookup) } catch { Write-Warning 'The current account cannot resolve the Azure Virtual Desktop enterprise application.' }
    if ($principals.Count -ne 1) {
        if ($AuthorizedUser) { throw 'The authorized user could not resolve the AVD service identity. Check directory read access and Microsoft.DesktopVirtualization provider registration.' }
        if ((Read-Value 'Use an authorized user to resolve the Microsoft AVD enterprise application? (Y/N)' 'Y' '^[YyNn]$') -ne 'Y') { throw 'The AVD service identity must be verified before granting power permissions.' }
        Invoke-AlternateUser { Confirm-AvdScalingPowerRole -AuthorizedUser -PowerOnOnly:$PowerOnOnly -RoleScope $RoleScope }
        return
    }
    if ($principals.Count -ne 1 -or $principals[0].appId -ne $appId -or -not $principals[0].id) { throw 'Exactly one verified Azure Virtual Desktop enterprise application is required.' }
    $principalId=[string]$principals[0].id
    $assignmentPath="$RoleScope/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01&`$filter=atScope()"
    $checkRole={
        @((Get-ArmList $assignmentPath) | Where-Object {
            $_.properties.principalId -eq $principalId -and
            ($_.properties.roleDefinitionId -like "*/$roleId" -or ($PowerOnOnly -and $_.properties.roleDefinitionId -like '*/40c5ff49-9181-41f8-ae61-143b0e78555e')) -and
            ($_.properties.scope -eq $RoleScope -or ($PowerOnOnly -and $_.properties.scope -and $RoleScope.StartsWith(($_.properties.scope.TrimEnd('/')+'/'),[StringComparison]::OrdinalIgnoreCase))) -and -not $_.properties.condition
        }).Count -gt 0
    }
    try { if (& $checkRole) { Write-Host "AVD service power-management permission verified at $RoleScope."; return } } catch { Write-Warning 'The power-management role assignment could not be read with the current account.' }
    Show-AvdPanel 'AVD power permission review' @(
        "Principal: Azure Virtual Desktop [$principalId]", "Application: $appId",
        "Role: $roleName", "Scope: $RoleScope",
        $(if ($PowerOnOnly) { 'Allows AVD to start VMs in this scope on user connection. It does not grant stop rights.' } else { 'Microsoft requires subscription scope for autoscale. This allows AVD to manage session-host power and admission across this subscription.' }),
        'The deployment SPN does not receive this role. An authorized Owner or RBAC administrator can grant it.'
    )
    if ((Read-Value 'Verify or grant this AVD service role using an authorized user? (Y/N)' 'N' '^[YyNn]$') -ne 'Y') { throw 'Autoscale power permission was not verified.' }
    $repair={
        Grant-Role $RoleScope $principalId $roleId
        if (-not (& $checkRole)) { throw 'Role assignment was not visible yet. Wait for RBAC propagation and retry.' }
    }
    if ($AuthorizedUser) { & $repair } else { Invoke-AlternateUser $repair }
    Write-Host 'Role assignment verified. Azure RBAC propagation can take several minutes.'
}

function Select-AvdScheduleDays {
    param([string[]]$UsedDays=@())
    $all=@('Monday','Tuesday','Wednesday','Thursday','Friday','Saturday','Sunday')
    $available=@($all | Where-Object { $_ -notin $UsedDays })
    if (-not $available.Count) { return @() }
    $choice=Select-Item @(
        [pscustomobject]@{Name='All days (Monday-Sunday; remaining days only)';Id='All'},
        [pscustomobject]@{Name='Weekdays (Monday-Friday; remaining days only)';Id='Weekdays'},
        [pscustomobject]@{Name='Select individual days';Id='Custom'},
        [pscustomobject]@{Name='Cancel schedule';Id='Cancel'}
    ) 'Select schedule days'
    switch ($choice.Id) {
        'All' { return $available }
        'Weekdays' { return @($available | Where-Object { $_ -notin @('Saturday','Sunday') }) }
        'Custom' { return @(Select-Multiple @($available | ForEach-Object { [pscustomobject]@{Name=$_} }) 'Select individual schedule days' | ForEach-Object Name) }
        default { return @() }
    }
}

function Set-AvdSavingsSchedule {
    param([object]$Schedule)
    $copy=$Schedule | ConvertTo-Json -Depth 10 | ConvertFrom-Json
    foreach ($phase in @('rampUp','peak','rampDown','offPeak')) {
        $copy | Add-Member -NotePropertyName ($phase+'LoadBalancingAlgorithm') -NotePropertyValue 'DepthFirst' -Force
    }
    foreach ($phase in @('rampUp','rampDown')) {
        $copy | Add-Member -NotePropertyName ($phase+'MinimumHostsPct') -NotePropertyValue 0 -Force
        $copy | Add-Member -NotePropertyName ($phase+'CapacityThresholdPct') -NotePropertyValue 100 -Force
    }
    $copy | Add-Member -NotePropertyName rampDownForceLogoffUsers -NotePropertyValue $false -Force
    $copy | Add-Member -NotePropertyName rampDownStopHostsWhen -NotePropertyValue 'ZeroSessions' -Force
    $copy | Add-Member -NotePropertyName rampDownWaitTimeMinutes -NotePropertyValue 0 -Force
    $copy | Add-Member -NotePropertyName rampDownNotificationMessage -NotePropertyValue '' -Force
    return $copy
}

function New-AvdScalingSchedule {
    param([string]$Name,[string[]]$Days,[string[]]$Times,
        [ValidateRange(0,100)][int]$RampUpMinimum=20,[ValidateRange(0,100)][int]$RampDownMinimum=10,
        [ValidateRange(1,100)][int]$RampUpThreshold=80,[ValidateRange(1,100)][int]$RampDownThreshold=80)
    $validDays=@('Monday','Tuesday','Wednesday','Thursday','Friday','Saturday','Sunday')
    if (-not $Days.Count -or @($Days | Where-Object { $_ -notin $validDays }).Count -or @($Days | Select-Object -Unique).Count -ne $Days.Count) { throw 'Select unique valid weekdays for this schedule.' }
    if ($Times.Count -ne 4) { throw 'Four phase start times are required.' }
    $previous=-1; $parsed=@()
    foreach ($time in $Times) {
        if ($time -notmatch '^([01][0-9]|2[0-3]):([0-5][0-9])$') { throw 'Times must use HH:mm (24-hour clock).' }
        $hour=[int]$Matches[1]; $minute=[int]$Matches[2]; $total=$hour*60+$minute
        if ($total -le $previous) { throw 'Phase times must increase within the same day: ramp up, peak, ramp down, off peak.' }
        $previous=$total; $parsed+=@{hour=$hour;minute=$minute}
    }
    return @{
        name=$Name;daysOfWeek=@($Days);rampUpStartTime=$parsed[0];peakStartTime=$parsed[1];rampDownStartTime=$parsed[2];offPeakStartTime=$parsed[3]
        rampUpLoadBalancingAlgorithm='BreadthFirst';peakLoadBalancingAlgorithm='BreadthFirst'
        rampDownLoadBalancingAlgorithm='DepthFirst';offPeakLoadBalancingAlgorithm='DepthFirst'
        rampUpMinimumHostsPct=$RampUpMinimum;rampDownMinimumHostsPct=$RampDownMinimum
        rampUpCapacityThresholdPct=$RampUpThreshold;rampDownCapacityThresholdPct=$RampDownThreshold
        rampDownForceLogoffUsers=$false;rampDownStopHostsWhen='ZeroSessions';rampDownWaitTimeMinutes=0;rampDownNotificationMessage=''
    }
}

function New-AvdPersonalSchedule {
    param([string]$Name,[string[]]$Days,[string[]]$Times,
        [ValidateSet('None','All','WithAssignedUser')][string]$AutoStart='None',
        [ValidateRange(0,1440)][int]$LogoffDelay=15)
    # Reuse time/day validation, but never send pooled capacity properties to personalSchedules.
    $validated=New-AvdScalingSchedule $Name $Days $Times
    $properties=@{daysOfWeek=@($Days);rampUpAutoStartHosts=$AutoStart}
    foreach ($phase in @('rampUp','peak','rampDown','offPeak')) {
        $properties[$phase+'StartTime']=$validated[$phase+'StartTime']
        $properties[$phase+'StartVMOnConnect']='Enable'
        $properties[$phase+'ActionOnDisconnect']='None'
        $properties[$phase+'MinutesToWaitOnDisconnect']=0
        $properties[$phase+'ActionOnLogoff']='Deallocate'
        $properties[$phase+'MinutesToWaitOnLogoff']=$LogoffDelay
    }
    return @{name=$Name;properties=$properties}
}

function Confirm-AvdScalingPool {
    param([object]$Deployment,[switch]$AllowPersonal)
    Confirm-Permission $Deployment.Id @('Microsoft.DesktopVirtualization/hostPools/read','Microsoft.DesktopVirtualization/hostPools/sessionHosts/read') @($script:Roles.Reader)
    $pool=Invoke-Arm "$($Deployment.Id)?api-version=$script:AvdApi"
    if ($pool.properties.hostPoolType -ne 'Pooled' -and -not ($AllowPersonal -and $pool.properties.hostPoolType -eq 'Personal')) { throw 'This wizard supports power-management schedules for pooled host pools only.' }
    if ($pool.properties.hostPoolType -eq 'Pooled' -and ([int]$pool.properties.maxSessionLimit -le 0 -or [int]$pool.properties.maxSessionLimit -eq [int]::MaxValue)) { throw 'Configure a finite positive session limit in host pool properties before enabling power automation.' }
    foreach ($sessionHost in @(Get-ArmList "$($Deployment.Id)/sessionHosts?api-version=$script:AvdApi")) {
        $machineId=[string]$sessionHost.properties.resourceId
        if ($machineId -notmatch ('(?i)^'+[regex]::Escape($script:SubscriptionScope)+'/resourceGroups/[^/]+/providers/Microsoft.HybridCompute/machines/[^/]+$')) { throw 'This wizard requires Azure Local session hosts in the selected subscription. Cross-subscription and generic Arc hosts require separate configuration.' }
        Confirm-Permission $machineId @('Microsoft.AzureStackHCI/virtualMachineInstances/read') @($script:Roles.Reader)
        if (-not (Invoke-Arm "$machineId/providers/Microsoft.AzureStackHCI/virtualMachineInstances/default?api-version=$script:HciApi" -AllowNotFound)) { throw 'A session host has no Azure Local VM instance. Generic Arc servers do not support native AVD power management.' }
    }
    return $pool
}

function New-AvdScalingPlan {
    param([object]$Deployment)
    $pool=Confirm-AvdScalingPool $Deployment -AllowPersonal
    if (@(Get-AvdScalingPlans $Deployment.Id).Count) { throw 'This host pool already has a scaling plan. Inspect or enable/disable it instead; existing assignments are not replaced.' }
    $scope=$Deployment.Id -replace '/providers/Microsoft.DesktopVirtualization/hostPools/[^/]+$',''
    Confirm-Permission $scope @('Microsoft.DesktopVirtualization/scalingPlans/read','Microsoft.DesktopVirtualization/scalingPlans/write','Microsoft.Resources/deployments/write','Microsoft.Resources/deployments/read','Microsoft.Resources/deployments/operations/read','Microsoft.Resources/deployments/validate/action') @($script:Roles.Contributor)
    Confirm-AvdScalingPowerRole
    $defaultName=('sp-'+($pool.name -replace '^hp-',''))
    if ($defaultName.Length -gt 64) { $defaultName=$defaultName.Substring(0,64) }
    $name=Read-Value 'Scaling plan name' $defaultName '^[A-Za-z0-9][A-Za-z0-9_-]{2,63}$'
    $id="$scope/providers/Microsoft.DesktopVirtualization/scalingPlans/$name"
    Assert-NewResource $id $script:AvdApi
    Write-Host 'Select the schedule time zone. It does not change the Windows time zone on session hosts.'
    $zone=Select-WindowsTimeZone
    if (-not $zone) { Write-Host 'Scaling plan creation cancelled: a schedule time zone is required.'; return }
    $isPersonal=$pool.properties.hostPoolType -eq 'Personal'
    if ($isPersonal) {
        Confirm-Permission $scope @('Microsoft.DesktopVirtualization/scalingPlans/personalSchedules/read','Microsoft.DesktopVirtualization/scalingPlans/personalSchedules/write') @($script:Roles.Contributor)
        $selectedProfile=Select-Item @([pscustomobject]@{Name='Personal savings - start on connect, stop after logoff';Id='Savings'},[pscustomobject]@{Name='Personal scheduled start';Id='Custom'}) 'Select personal scaling profile'
        Write-Host 'Disconnected sessions are preserved. No hibernation or forced logoff. Start VM on Connect is enabled in every phase; deallocate after logoff (default 15 minutes).'
    } else {
    $selectedProfile=Select-Item @([pscustomobject]@{Name='Maximum savings (DepthFirst, 0% minimum, preserve all sessions)';Id='Savings'},[pscustomobject]@{Name='Custom business-hours schedule';Id='Custom'}) 'Select scaling profile'
    if ($selectedProfile.Id -eq 'Savings') {
        Write-Host 'Savings uses DepthFirst in all phases, 0% minimum and a 100% capacity threshold. Enable Start VM on Connect separately before enabling this plan.'
        Write-Host 'All active and disconnected sessions are preserved. Only empty VMs can stop. Native pooled autoscale has no configurable 15-minute empty-VM timer; actual power transitions follow service evaluation.' -ForegroundColor Yellow
    }
    }
    $schedules=@(); $usedDays=@()
    do {
        $days=@(Select-AvdScheduleDays $usedDays)
        if (-not $days.Count) { Write-Host 'Scaling plan creation cancelled: no schedule days selected.'; return }
        if ($isPersonal) {
            $times=@('00:00','00:01','00:02','00:03'); $autoStart='None'
            if ($selectedProfile.Id -eq 'Custom') {
                $autoStart=(Select-Item @([pscustomobject]@{Name='Start assigned hosts';Id='WithAssignedUser'},[pscustomobject]@{Name='Start all hosts';Id='All'},[pscustomobject]@{Name='Start only on user connection';Id='None'}) 'Personal ramp-up behavior').Id
            }
            $delay=[int](Read-Value 'Minutes after logoff before stopping (0-1440)' '15' '^(1440|14[0-3][0-9]|1[0-3][0-9]{2}|[0-9]{1,3})$')
            do {
                if ($selectedProfile.Id -eq 'Custom') { $times=@(Read-Value 'Ramp-up starts (HH:mm)' '07:00'; Read-Value 'Peak starts (HH:mm)' '08:00'; Read-Value 'Ramp-down starts (HH:mm)' '18:00'; Read-Value 'Off-peak starts (HH:mm)' '20:00') }
                try { $schedule=New-AvdPersonalSchedule ('schedule-'+($schedules.Count+1)) $days $times -AutoStart $autoStart -LogoffDelay $delay; break } catch { Write-Host $_.Exception.Message -ForegroundColor Red }
            } while ($true)
        } elseif ($selectedProfile.Id -eq 'Savings') {
            # The API requires four phases. Keep their settings identical and spend
            # most of the day off-peak, where empty hosts can scale down to zero.
            $schedule=Set-AvdSavingsSchedule (New-AvdScalingSchedule ('schedule-'+($schedules.Count+1)) $days @('00:00','00:01','00:02','00:03'))
        } else {
        do {
            $times=@(Read-Value 'Ramp-up starts (HH:mm)' '07:00'; Read-Value 'Peak starts (HH:mm)' '08:00'; Read-Value 'Ramp-down starts (HH:mm)' '18:00'; Read-Value 'Off-peak starts (HH:mm)' '20:00')
            try { $schedule=New-AvdScalingSchedule ('schedule-'+($schedules.Count+1)) $days $times; break } catch { Write-Warning $_.Exception.Message }
        } while ($true)
        $schedule.rampUpMinimumHostsPct=[int](Read-Value 'Ramp-up minimum hosts (%)' '20' '^(100|[0-9]{1,2})$')
        $schedule.rampDownMinimumHostsPct=[int](Read-Value 'Ramp-down minimum hosts (%)' '10' '^(100|[0-9]{1,2})$')
        $schedule.rampUpCapacityThresholdPct=[int](Read-Value 'Ramp-up capacity threshold (%)' '80' '^(100|[1-9][0-9]?)$')
        $schedule.rampDownCapacityThresholdPct=[int](Read-Value 'Ramp-down capacity threshold (%)' '80' '^(100|[1-9][0-9]?)$')
        }
        $schedules+=$schedule; $usedDays+=$days
    } while ($usedDays.Count -lt 7 -and (Read-Value 'Add a schedule for other days? (Y/N)' 'N' '^[YyNn]$') -eq 'Y')
    $body=@{location=$pool.location;properties=@{hostPoolType=$pool.properties.hostPoolType;timeZone=$zone;exclusionTag='excludeFromScaling';friendlyName=$name;
        schedules=@($schedules);hostPoolReferences=@(@{hostPoolArmPath=$Deployment.Id;scalingPlanEnabled=$false})}}
    if ($isPersonal) {
        $body.properties.Remove('schedules')
        Show-AvdPanel 'Review personal scaling plan' @("Name: $name | Type: Personal | Time zone: $zone",'Created DISABLED. Starts existing VMs; stops after logoff according to each schedule.','Disconnected sessions preserved; no forced logoff or hibernation.','Start VM on Connect is enabled in every phase. Exclusion tag: excludeFromScaling.')
    } else {
    Show-AvdPanel 'Review scaling plan' @("Name: $name", "Resource group: $($Deployment.ResourceGroup) | Region: $($pool.location)","Time zone: $zone",
        'Created DISABLED. Enable separately after reviewing the plan and power permissions.',
        'Power management only: starts/stops existing VMs and changes load balancing/drain mode. Does not create or delete VMs.',
        'No forced logoff; ramp-down stops only hosts with no active or disconnected sessions.',
        $(if ($selectedProfile.Id -eq 'Savings') { 'Savings: DepthFirst, 0% minimum and 100% capacity threshold in every phase. No 15-minute shutdown guarantee. Start VM on Connect is required before activation.' } else { 'Ramp up / peak: BreadthFirst. Ramp down / off peak: DepthFirst.' }),
        'Unselected days retain the last off-peak settings. Minimum percentages round up.',
        'Exclusion tag: excludeFromScaling. This wizard does not add tags to hosts.')
    }
    foreach ($schedule in $schedules) {
        $settings=if ($isPersonal) { $schedule.properties } else { $schedule }
        $scheduleLines=@("Days: $($settings.daysOfWeek -join ', ')")
        foreach ($phase in @('rampUp','peak','rampDown','offPeak')) {
            $time=$settings[$phase+'StartTime']
            $scheduleLines+=('{0}: {1:00}:{2:00}' -f $phase,$time.hour,$time.minute)
        }
        if ($isPersonal) { $scheduleLines+=@("Ramp-up starts: $($settings.rampUpAutoStartHosts)","After logoff: stop after $($settings.rampUpMinutesToWaitOnLogoff) minutes in every phase; preserve disconnected sessions.") }
        Show-AvdPanel $schedule.name $scheduleLines
    }
    $schedules | ConvertTo-Json -Depth 8 | Write-Verbose
    if ((Read-Value 'Create this disabled scaling plan and verify its service permissions? (Y/N)' 'N' '^[YyNn]$') -ne 'Y') { return }
    Assert-NewResource $id $script:AvdApi
    if (@(Get-AvdScalingPlans $Deployment.Id).Count) { throw 'A scaling plan was associated while this wizard was open. No plan was created.' }
    $directory=Join-Path $script:AvdHistoryRoot ('scaling-'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N').Substring(0,8))
    $null=New-Item -ItemType Directory -Path $directory -Force
    $script:RunFile=Join-Path $directory 'run.json'
    $script:Run=[pscustomobject]@{runId=[guid]::NewGuid().ToString('N');subscriptionId=$script:Subscription;tenantId=$script:Tenant;hostPoolId=$Deployment.Id;
        status='ScalingPlanPrepared';updatedUtc='';deployments=@();sessionHosts=@();registrationSubmitted=$false;scalingPlanId=$id}
    Save-Run
    $template=@{'$schema'='https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#';contentVersion='1.0.0.0';resources=@(@{
        type='Microsoft.DesktopVirtualization/scalingPlans';apiVersion=$script:AvdApi;name=$name;location=$body.location;properties=$body.properties})}
    if ($isPersonal) {
        foreach ($schedule in $schedules) {
            $template.resources+=@{type='Microsoft.DesktopVirtualization/scalingPlans/personalSchedules';apiVersion=$script:AvdApi;name=($name+'/'+$schedule.name);dependsOn=@($id);properties=$schedule.properties}
        }
    }
    Start-Deployment $scope 'scaling-plan' $template
    $created=Invoke-Arm "$id`?api-version=$script:AvdApi"
    $observedSchedules=if ($isPersonal) { @(Get-ArmList "$id/personalSchedules?api-version=$script:AvdApi") } else { @($created.properties.schedules) }
    $reference=@($created.properties.hostPoolReferences | Where-Object hostPoolArmPath -eq $Deployment.Id)
    if ($reference.Count -ne 1 -or $reference[0].scalingPlanEnabled -ne $false -or @($observedSchedules).Count -ne $schedules.Count) { throw 'Scaling plan read-back did not match the requested disabled association. Inspect the deployment before retrying.' }
    if ($isPersonal) {
        foreach ($expected in $schedules) {
            $actual=@($observedSchedules | Where-Object { ($_.name -split '/')[-1] -eq $expected.name })
            if ($actual.Count -ne 1) { throw 'Personal schedule read-back is missing or ambiguous.' }
            foreach ($key in $expected.properties.Keys) {
                $wanted=$expected.properties[$key]; $observed=$actual[0].properties.$key
                $matchesValue=if ($key -like '*StartTime') { $wanted.hour -eq $observed.hour -and $wanted.minute -eq $observed.minute } elseif ($key -eq 'daysOfWeek') { ($wanted -join ',') -eq ($observed -join ',') } else { [string]$wanted -eq [string]$observed }
                if (-not $matchesValue) { throw "Personal schedule '$($expected.name)' differs at '$key'. Inspect the disabled plan before activation." }
            }
        }
    }
    $script:Run.status='Succeeded'; Save-Run
    Write-Host "Scaling plan created and disabled. Tracking: $script:RunFile" -ForegroundColor Green
    if ($selectedProfile.Id -eq 'Savings') { Set-AvdHostPoolConfiguration $Deployment -StartOnConnectOnly }
}

function Set-AvdScalingPlanEnabled {
    param([object]$Deployment,[object]$Plan,[bool]$Enabled)
    Confirm-Permission $Plan.id @('Microsoft.DesktopVirtualization/scalingPlans/read','Microsoft.DesktopVirtualization/scalingPlans/write') @($script:Roles.Contributor)
    if ($Enabled) {
        $powerPool=Confirm-AvdScalingPool $Deployment -AllowPersonal
        $powerPlan=Invoke-Arm "$($Plan.id)?api-version=$script:AvdApi"
        if ($powerPlan.properties.hostPoolType -and $powerPlan.properties.hostPoolType -ne $powerPool.properties.hostPoolType) { throw 'Scaling plan and host pool types must match.' }
        if ($powerPool.properties.hostPoolType -eq 'Personal') {
            Confirm-Permission $Plan.id @('Microsoft.DesktopVirtualization/scalingPlans/personalSchedules/read') @($script:Roles.Reader)
            if (-not @(Get-ArmList "$($Plan.id)/personalSchedules?api-version=$script:AvdApi").Count) { throw 'Create a personal schedule before activating this plan.' }
            Write-Host 'Personal autoscale applies its per-phase Start VM on Connect and session-state actions. Review personal schedules before enabling.'
        }
        if (@($powerPlan.properties.schedules | Where-Object { $_.rampDownMinimumHostsPct -eq 0 }).Count -and -not $powerPool.properties.startVMOnConnect) {
            Write-Warning 'This plan can reach zero running VMs. Configure Start VM on Connect before enabling it.'
            Set-AvdHostPoolConfiguration $Deployment -StartOnConnectOnly
            $powerPool=Invoke-Arm "$($Deployment.Id)?api-version=$script:AvdApi"
            if (-not $powerPool.properties.startVMOnConnect) { Write-Warning 'Autoscale activation cancelled: Start VM on Connect is still disabled.'; return }
        }
        Write-Host 'Enabling autoscale can immediately start/stop hosts and override drain mode and load balancing. Complete maintenance and suspend other scaling automation first.' -ForegroundColor Yellow
        if ((Read-Value 'Confirm maintenance is complete and this plan may control host power/admission? (Y/N)' 'N' '^[YyNn]$') -ne 'Y') { return }
        Confirm-AvdScalingPowerRole
    } else {
        Write-Host 'Disabling autoscale leaves current VM power and drain states unchanged. Review host admission separately.'
        if ((Read-Value 'Disable this scaling plan for the selected pool? (Y/N)' 'N' '^[YyNn]$') -ne 'Y') { return }
    }
    $fresh=Invoke-Arm "$($Plan.id)?api-version=$script:AvdApi"
    $refs=@($fresh.properties.hostPoolReferences)
    if (@($refs | Where-Object hostPoolArmPath -eq $Deployment.Id).Count -ne 1) { throw 'The selected host pool association changed. Refresh the menu.' }
    $before=$refs | ConvertTo-Json -Depth 5 -Compress
    $updated=@($refs | ForEach-Object { @{hostPoolArmPath=$_.hostPoolArmPath;scalingPlanEnabled=$(if ($_.hostPoolArmPath -eq $Deployment.Id) {$Enabled} else {$_.scalingPlanEnabled})} })
    $record=@{planId=$Plan.id;hostPoolId=$Deployment.Id;enabled=$Enabled;before=$refs;requested=$updated;status='Prepared';utc=[datetime]::UtcNow.ToString('o')}
    $null=New-Item -ItemType Directory -Path $script:AvdHistoryRoot -Force
    $path=Join-Path $script:AvdHistoryRoot ('scaling-change-'+[guid]::NewGuid().ToString('N')+'.json')
    $record | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $path -Encoding UTF8
    Write-Host "Scaling change record: $path"
    $latest=Invoke-Arm "$($Plan.id)?api-version=$script:AvdApi"
    if (($latest.properties.hostPoolReferences | ConvertTo-Json -Depth 5 -Compress) -ne $before) { throw 'Scaling associations changed during review. Refresh and retry.' }
    try {
        $null=Invoke-Arm "$($Plan.id)?api-version=$script:AvdApi" PATCH @{properties=@{hostPoolReferences=$updated}}
        $deadline=[datetime]::UtcNow.AddMinutes(5)
        do {
            $observed=Invoke-Arm "$($Plan.id)?api-version=$script:AvdApi"
            $target=@($observed.properties.hostPoolReferences | Where-Object hostPoolArmPath -eq $Deployment.Id)
            if ($target.Count -eq 1 -and $target[0].scalingPlanEnabled -eq $Enabled) { $record.status='Succeeded'; break }
            Write-Event 'Waiting for the scaling plan association to update...'; Start-Sleep -Seconds $PollSeconds
        } while ([datetime]::UtcNow -lt $deadline)
        if ($record.status -ne 'Succeeded') { throw 'Scaling change was submitted but verification timed out. Inspect the plan before retrying.' }
        Write-Host "Scaling plan enabled for this pool: $Enabled" -ForegroundColor Green
    } catch { $record.status='NeedsReview'; throw } finally { $record | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $path -Encoding UTF8 }
}

function Set-AvdScalingSavingsProfile {
    param([object]$Deployment,[object]$Plan)
    $null=Confirm-AvdScalingPool $Deployment
    Confirm-Permission $Plan.id @('Microsoft.DesktopVirtualization/scalingPlans/read','Microsoft.DesktopVirtualization/scalingPlans/write') @($script:Roles.Contributor)
    $current=Invoke-Arm "$($Plan.id)?api-version=$script:AvdApi"
    $references=@($current.properties.hostPoolReferences)
    if ($references.Count -ne 1 -or $references[0].hostPoolArmPath -ne $Deployment.Id) { throw 'This preset only edits a plan dedicated to the selected pool. Shared plans must be reviewed separately.' }
    if ($references[0].scalingPlanEnabled) { throw 'Disable this plan before changing its schedule. Use Maintenance > Disable autoscale or the Scaling Plans menu.' }
    if ($current.properties.hostPoolType -ne 'Pooled' -or -not @($current.properties.schedules).Count) { throw 'An existing pooled power-management schedule is required.' }
    $schedules=@($current.properties.schedules | ForEach-Object { Set-AvdSavingsSchedule (New-AvdScalingSchedule $_.name @($_.daysOfWeek) @('00:00','00:01','00:02','00:03')) })
    Show-AvdPanel 'Maximum savings preset for the existing plan' @(
        "Plan: $($current.name) | Time zone: $($current.properties.timeZone)",
        'Retains schedule days. Replaces phase times with 00:00 / 00:01 / 00:02 / 00:03.',
        'All phases: DepthFirst, minimum 0%, capacity threshold 100%. The plan remains disabled.',
        'All sessions are preserved. Only VMs with zero sessions can stop. No logoff or idle-session policy is installed.',
        'Pooled autoscale does not offer an exact 15-minute empty-VM shutdown timer. Start VM on Connect must be enabled before activation.'
    )
    if ((Read-Value 'Replace the existing schedules with this savings preset? (Y/N)' 'N' '^[YyNn]$') -ne 'Y') { return }
    $before=$current.properties | Select-Object schedules,hostPoolReferences | ConvertTo-Json -Depth 15 -Compress
    $latest=Invoke-Arm "$($Plan.id)?api-version=$script:AvdApi"
    if (($latest.properties | Select-Object schedules,hostPoolReferences | ConvertTo-Json -Depth 15 -Compress) -ne $before) { throw 'Scaling settings changed during review. Refresh and retry.' }
    $null=New-Item -ItemType Directory -Path $script:AvdHistoryRoot -Force
    $path=Join-Path $script:AvdHistoryRoot ('scaling-savings-'+[guid]::NewGuid().ToString('N')+'.json')
    $record=@{planId=$Plan.id;before=$current.properties.schedules;requested=$schedules;status='Submitting'}
    $record | ConvertTo-Json -Depth 15 | Set-Content -LiteralPath $path -Encoding UTF8
    Write-Host "Savings profile tracking: $path"
    try {
        $null=Invoke-Arm "$($Plan.id)?api-version=$script:AvdApi" PATCH @{properties=@{schedules=$schedules}}
        $updated=Invoke-Arm "$($Plan.id)?api-version=$script:AvdApi"
        $actual=@($updated.properties.schedules)
        if ($actual.Count -ne $schedules.Count) { throw 'Schedule count could not be verified.' }
        foreach ($expected in $schedules) {
            $match=@($actual | Where-Object name -eq $expected.name)
            if ($match.Count -ne 1) { throw 'Schedule name could not be verified.' }
            foreach ($property in $expected.PSObject.Properties) {
                $observed=$match[0].($property.Name)
                $equal=if ($property.Name -like '*StartTime') { $observed.hour -eq $property.Value.hour -and $observed.minute -eq $property.Value.minute }
                    elseif ($property.Name -eq 'daysOfWeek') { (@($observed | Sort-Object) -join ',') -ceq (@($property.Value | Sort-Object) -join ',') }
                    else { [string]$observed -ceq [string]$property.Value }
                if (-not $equal) { throw "Savings property '$($property.Name)' could not be verified. Inspect the saved operation before retrying." }
            }
        }
        $record.status='Succeeded'; Write-Host 'Savings profile verified. The plan remains disabled.' -ForegroundColor Green
    } catch { $record.status='NeedsReview'; throw } finally { $record | ConvertTo-Json -Depth 15 | Set-Content -LiteralPath $path -Encoding UTF8 }
    Set-AvdHostPoolConfiguration $Deployment -StartOnConnectOnly
}

function Disable-AvdPoolAutoscale {
    param([object]$Deployment)
    Confirm-Permission ($Deployment.Id -replace '/providers/Microsoft.DesktopVirtualization/hostPools/[^/]+$','') @('Microsoft.DesktopVirtualization/scalingPlans/read') @($script:Roles.Reader)
    $plans=@(Get-AvdScalingPlans $Deployment.Id | Where-Object { @($_.properties.hostPoolReferences | Where-Object { $_.hostPoolArmPath -eq $Deployment.Id -and $_.scalingPlanEnabled }).Count })
    if (-not $plans.Count) { Write-Host 'No enabled scaling plan is associated with this pool.'; return }
    foreach ($plan in $plans) { Set-AvdScalingPlanEnabled $Deployment $plan $false }
    Write-Host 'Start VM on Connect is separate from autoscale. Use its menu to disable it too if required for maintenance. No VM power states or session timeout policies were changed.'
}

function Invoke-AvdScalingMenu {
    param([object]$Deployment)
    while ($true) {
        $scalingChoices=@([pscustomobject]@{Name='Create a power-management scaling plan';Kind='Create'},
            [pscustomobject]@{Name='Inspect associated scaling plans';Kind='Inspect'},
            [pscustomobject]@{Name='Enable autoscale for this pool';Kind='Enable'},
            [pscustomobject]@{Name='Disable autoscale for this pool (maintenance)';Kind='Disable'},
            [pscustomobject]@{Name='Apply maximum savings preset to a disabled dedicated plan';Kind='Savings'},
            [pscustomobject]@{Name='Start VM on Connect (enable/disable and permissions)';Kind='StartOnConnect'},
            [pscustomobject]@{Name='Back';Kind='Back'})
        if ($Deployment.HostPoolType -eq 'Personal') { $scalingChoices=@($scalingChoices | Where-Object Kind -ne 'Savings') }
        $choice=Select-Item $scalingChoices "Scaling Plans | $($Deployment.Name)"
        if ($choice.Kind -eq 'Back') { return }
        try {
            if ($choice.Kind -eq 'StartOnConnect') { Set-AvdHostPoolConfiguration $Deployment -StartOnConnectOnly; continue }
            Confirm-Permission ($Deployment.Id -replace '/providers/Microsoft.DesktopVirtualization/hostPools/[^/]+$','') @('Microsoft.DesktopVirtualization/scalingPlans/read') @($script:Roles.Reader)
            if ($choice.Kind -eq 'Create') { New-AvdScalingPlan $Deployment; continue }
            $plans=@(Get-AvdScalingPlans $Deployment.Id)
            if (-not $plans.Count) { Write-Host 'No scaling plan is associated with this host pool.'; continue }
            if ($choice.Kind -eq 'Inspect') {
                foreach ($plan in $plans) {
                    Show-AvdPanel $plan.name @("Region: $($plan.location) | Time zone: $($plan.properties.timeZone)","Exclusion tag: $($plan.properties.exclusionTag)","Portal: https://portal.azure.com/#resource$($plan.id)/overview")
                    $plan.properties | Select-Object hostPoolType,hostPoolReferences,schedules | ConvertTo-Json -Depth 12 | Write-Host
                    if ($plan.properties.hostPoolType -eq 'Personal') {
                        Confirm-Permission $plan.id @('Microsoft.DesktopVirtualization/scalingPlans/personalSchedules/read') @($script:Roles.Reader)
                        @(Get-ArmList "$($plan.id)/personalSchedules?api-version=$script:AvdApi") | ConvertTo-Json -Depth 12 | Write-Host
                    }
                }
                continue
            }
            $plan=Select-Item $plans 'Select associated scaling plan'
            if ($choice.Kind -eq 'Savings') { Set-AvdScalingSavingsProfile $Deployment $plan; continue }
            Set-AvdScalingPlanEnabled $Deployment $plan ($choice.Kind -eq 'Enable')
        } catch { Write-Warning $_.Exception.Message }
    }
}

#endregion

#region Console panels and resource selection
function Show-AvdPanel {
    param([string]$Title, [string[]]$Lines)
    $width=88
    try { if ([Console]::WindowWidth -gt 20) { $width=[Math]::Min(100,[Console]::WindowWidth-2) } } catch { }
    $inside=$width-4
    $border='+'+('-'*($width-2))+'+'
    Write-Host ''
    Write-Host $border -ForegroundColor DarkCyan
    foreach ($line in @($Title)+@('')+@($Lines)) {
        $lineColor = if ($line -match '\[FAILED\]') { 'Red' } elseif ($line -match '\[OK\]') { 'Green' } else { 'Cyan' }
        $remaining=[string]$line
        do {
            $length=[Math]::Min($inside,$remaining.Length)
            if ($remaining.Length -gt $inside) {
                $wordBreak=$remaining.LastIndexOf(' ',$inside-1,$inside)
                if ($wordBreak -gt 0) { $length=$wordBreak }
            }
            Write-Host ('| '+$remaining.Substring(0,$length).PadRight($inside)+' |') -ForegroundColor $lineColor
            $remaining=$remaining.Substring($length).TrimStart()
        } while ($remaining.Length)
    }
    Write-Host $border -ForegroundColor DarkCyan
}

function Select-Item {
    param([object[]]$Items, [string]$Prompt, [string]$Property = 'name', [int]$DefaultIndex = 0)
    if (-not $Items.Count) { throw "No items available: $Prompt" }
    $menuLines = @(for ($i=0; $i -lt $Items.Count; $i++) { '  {0}. {1}' -f ($i+1), $Items[$i].$Property })
    Show-AvdPanel $Prompt ($menuLines + @('', 'Enter an option number. Press Enter to accept the default.'))
    do {
        $choice = Read-Value $Prompt ([string]($DefaultIndex+1)) '^\d{1,6}$'
        if ([int]$choice -ge 1 -and [int]$choice -le $Items.Count) { return $Items[[int]$choice-1] }
    } while ($true)
}

function Get-TenantLabel {
    param([object]$Tenant)
    $domain = $Tenant.DefaultDomain
    if (-not $domain) { $domain = @($Tenant.Domains | Where-Object { $_ } | Select-Object -First 1)[0] }
    $name = $Tenant.Name
    if (-not $name) { $name = $Tenant.DisplayName }
    $id = $Tenant.Id
    if (-not $id) { $id = $Tenant.TenantId }
    $label = if ($name -and $domain -and $name -ne $domain) { "$name ($domain)" } elseif ($domain) { $domain } else { $name }
    if ($label) { return "$label [$id]" }
    return "Tenant details unavailable [$id]"
}

function Get-PublicTenantInfo {
    param([string]$TenantId)
    # findTenantInformationByTenantId needs CrossTenantInformation.ReadBasic.All on the caller's
    # app registration (confirmed live: a bare SPN token gets 403 Forbidden without it, not just
    # a missing-token 401). So this only resolves a name for an SPN that has already been through
    # Grant-GraphReadAccess in a previous run - degrading silently otherwise is expected, not a bug.
    try { return Invoke-Graph "/tenantRelationships/findTenantInformationByTenantId(tenantId='$TenantId')" }
    catch {
        if (-not $script:PublicTenantLookupWarned) {
            $status = $_.Exception.Response.StatusCode
            Write-Warning "Tenant name lookup via Microsoft Graph failed ($status): $($_.Exception.Message)"
            $script:PublicTenantLookupWarned = $true
        }
        return $null
    }
}

function Resolve-TenantLabel {
    param([string]$TenantId, [object]$AuthenticatedTenant)
    $info = Get-PublicTenantInfo $TenantId
    if ($info -and ($info.displayName -or $info.federationBrandName -or $info.defaultDomainName)) {
        $name = if ($info.displayName) { $info.displayName } else { $info.federationBrandName }
        return Get-TenantLabel ([pscustomobject]@{Id=$TenantId;Name=$name;DefaultDomain=$info.defaultDomainName})
    }
    if ($AuthenticatedTenant) { return Get-TenantLabel $AuthenticatedTenant }
    return Get-TenantLabel ([pscustomobject]@{Id=$TenantId})
}

function Select-ResourceGroup {
    param([string]$Prompt, [string]$Preferred, [switch]$AllowCreate)
    $choices = @()
    if ($AllowCreate) { $choices += [pscustomobject]@{Name='Create a new AVD resource group';Value='';Kind='New'} }
    try {
        $groups = @(Get-AzResourceGroup -ErrorAction Stop | Sort-Object @{Expression={$_.ResourceGroupName -ne $Preferred}},ResourceGroupName)
        foreach ($group in $groups) {
            $choices += [pscustomobject]@{Name="$($group.ResourceGroupName) ($($group.Location))";Value=$group.ResourceGroupName;Kind='Existing'}
        }
    } catch { Write-Warning 'Resource group discovery is unavailable with this account. You can enter a name for the permission repair flow.' }
    $choices += [pscustomobject]@{Name='Enter a resource group name manually';Value=$Preferred;Kind='Manual'}
    $selected = Select-Item $choices $Prompt
    if ($selected.Kind -eq 'Existing') { return $selected.Value }
    $label = if ($selected.Kind -eq 'New') { 'New AVD resource group name' } else { 'Resource group name' }
    return Read-Value $label $Preferred '^[\w().-]{1,90}$'
}

#endregion

#region Run history and ARM requests
function New-AvdRunDirectory {
    param([string]$ParentDirectory,[ValidateSet('deployment','guest')][string]$Operation='deployment')
    # Menu navigation can leave an earlier operation's run.json in OutputDirectory.
    # Allocate a separate directory; never overwrite or relabel that earlier run.
    $directory=$ParentDirectory
    if (Test-Path -LiteralPath (Join-Path $directory 'run.json')) {
        do {
            $directory=Join-Path $ParentDirectory ($Operation+'-'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N'))
        } while (Test-Path -LiteralPath $directory)
        Write-Verbose "Preserving previous run history. New $Operation directory: $directory"
    }
    $null=New-Item -ItemType Directory -Path $directory -Force
    return (Resolve-Path -LiteralPath $directory).Path
}

function Save-Run {
    if ($script:RunFile) {
        $script:Run.updatedUtc = [datetime]::UtcNow.ToString('o')
        $temp = "$script:RunFile.tmp"
        $script:Run | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $temp -Encoding UTF8
        Move-Item -LiteralPath $temp -Destination $script:RunFile -Force
    }
}

function Write-Event {
    param([string]$Message)
    $eventColor = if ($Message -match '\b(failed|failure|timed out)\b') { 'Red' } elseif ($Message -match '\b(succeeded|verified|completed)\b') { 'Green' } else { 'Cyan' }
    Write-Host ('[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $Message) -ForegroundColor $eventColor
    if ($script:RunFile) {
        @{time=[datetime]::UtcNow.ToString('o');message=$Message} | ConvertTo-Json -Compress |
            Add-Content -LiteralPath (Join-Path (Split-Path $script:RunFile) 'events.jsonl') -Encoding UTF8
    }
}

function Invoke-Arm {
    param([string]$Path, [string]$Method = 'GET', [object]$Body, [switch]$AllowNotFound, [switch]$WaitForCompletion)
    # Use Az's token cache. Never print request payloads or raw error responses:
    # deployments can carry secure parameters and host pools can carry tokens.
    $request = @{Path=$Path;Method=$Method;ErrorAction='Stop';Verbose=$false;Debug=$false}
    if ($null -ne $Body) { $request.Payload = $Body | ConvertTo-Json -Depth 100 -Compress }
    if ($WaitForCompletion) { $request.WaitForCompletion = $true }
    for ($attempt=0; $attempt -lt 5; $attempt++) {
        try { $response = Invoke-AzRestMethod @request }
        catch {
            throw "ARM $Method request failed for $($Path.Split('?')[0]). Check Azure Activity Log and the active account."
        }
        $status = [int]$response.StatusCode
        if ($status -eq 404 -and $AllowNotFound) { return $null }
        if ($status -ge 200 -and $status -lt 300) {
            if ($response.Content) { return ($response.Content | ConvertFrom-Json) }
            return $null
        }
        if (($status -eq 429 -or $status -ge 500) -and $attempt -lt 4) {
            Start-Sleep -Seconds ([math]::Min(30, [math]::Pow(2,$attempt+1)))
            continue
        }
        $code = 'Unknown'
        try { $code = ($response.Content | ConvertFrom-Json).error.code } catch { $code = 'NonJsonResponse' }
        throw "ARM $Method failed: HTTP $status ($code), resource $($Path.Split('?')[0])."
    }
}

#endregion

#region Azure Local VM restarts and Arc readiness
function Get-HciVmRestartPath {
    param([string]$MachineId)
    if ($MachineId -notmatch '(?i)^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft\.HybridCompute/machines/[^/]+$') {
        throw 'A valid Azure Arc machine resource ID is required to build the Azure Local restart action.'
    }
    return "$MachineId/providers/Microsoft.AzureStackHCI/virtualMachineInstances/default/restart?api-version=$script:HciPowerApi"
}

function Get-ArmResponseHeader {
    param([object]$Response,[string]$Name)
    if (-not $Response -or -not $Response.Headers) { return '' }
    if ($Response.Headers -is [System.Collections.IDictionary]) {
        foreach ($key in $Response.Headers.Keys) {
            if ([string]$key -ieq $Name) { return [string](@($Response.Headers[$key])[0]) }
        }
        return ''
    }
    foreach ($header in $Response.Headers) {
        if ([string]$header.Key -ieq $Name) { return [string](@($header.Value)[0]) }
    }
    return ''
}

function Get-HciRestartActivityState {
    param([string]$MachineId,[string]$CorrelationId,[datetime]$SubmittedUtc)
    if (-not $CorrelationId -or $MachineId -notmatch '(?i)^/subscriptions/([^/]+)/') { return $null }
    $subscriptionId=$Matches[1]
    $start=$SubmittedUtc.ToUniversalTime().AddMinutes(-2).ToString('yyyy-MM-ddTHH:mm:ssZ')
    $filter="eventTimestamp ge '$start' and correlationId eq '$CorrelationId'"
    $path="/subscriptions/$subscriptionId/providers/Microsoft.Insights/eventtypes/management/values?api-version=2015-04-01&`$filter=$([uri]::EscapeDataString($filter))"
    $events=@((Invoke-Arm $path).value | Where-Object {
        $_.operationName.value -eq 'Microsoft.AzureStackHCI/virtualMachineInstances/restart/action' -and
        $_.resourceId -ieq "$MachineId/providers/Microsoft.AzureStackHCI/virtualMachineInstances/default"
    } | Sort-Object eventTimestamp -Descending)
    if (-not $events.Count) { return $null }
    return [pscustomobject]@{Status=[string]$events[0].status.value;SubStatus=[string]$events[0].subStatus.value;Timestamp=$events[0].eventTimestamp}
}

function Wait-HciVmRestart {
    param([string]$MachineId,[object]$Submission,[datetime]$SubmittedUtc,[object]$RestartRecord)
    $correlationId=Get-ArmResponseHeader $Submission 'x-ms-correlation-request-id'
    $trackingUri=Get-ArmResponseHeader $Submission 'Azure-AsyncOperation'
    if (-not $trackingUri) { $trackingUri=Get-ArmResponseHeader $Submission 'Location' }
    if ($trackingUri -match '^https://management\.azure\.com/') { $trackingUri=([uri]$trackingUri).PathAndQuery }
    elseif ($trackingUri -match '^https?://') { $trackingUri='' }
    $RestartRecord.correlationId=$correlationId
    $RestartRecord.trackingUri=$trackingUri
    $RestartRecord.status='Tracking'
    Save-Run
    $deadline=[datetime]::UtcNow.AddMinutes(10)
    do {
        if ($trackingUri) {
            try {
                $poll=Invoke-AzRestMethod -Path $trackingUri -Method GET -ErrorAction Stop -Verbose:$false -Debug:$false
                if ([int]$poll.StatusCode -ge 200 -and [int]$poll.StatusCode -lt 300 -and $poll.Content) {
                    $pollBody=$poll.Content | ConvertFrom-Json
                    $pollState=[string]$pollBody.status
                    if (-not $pollState) { $pollState=[string]$pollBody.properties.provisioningState }
                    if ($pollState -match '^(?i:Succeeded)$') { Write-Progress -Activity "Restarting $($RestartRecord.hostName)" -Completed; return }
                    if ($pollState -match '^(?i:Failed|Canceled)$') { throw "Azure Local reported restart state $pollState." }
                }
            } catch {
                # Some Azure Local responses expose an action URL that cannot be read with GET.
                # Activity Log correlation below remains authoritative for the accepted operation.
                if ($_.Exception.Message -match '^Azure Local reported restart state') { throw }
            }
        }
        if ($correlationId) {
            try {
                $activity=Get-HciRestartActivityState $MachineId $correlationId $SubmittedUtc
                if ($activity.Status -eq 'Succeeded') { Write-Progress -Activity "Restarting $($RestartRecord.hostName)" -Completed; return }
                if ($activity.Status -in @('Failed','Canceled')) { throw "Azure Activity Log reported restart state $($activity.Status) ($($activity.SubStatus))." }
            } catch {
                if ($_.Exception.Message -match '^Azure Activity Log reported') { throw }
            }
        }
        Write-Progress -Activity "Restarting $($RestartRecord.hostName)" -Status 'Waiting for the Azure Local operation'
        Start-Sleep -Seconds $PollSeconds
    } while ([datetime]::UtcNow -lt $deadline)
    throw 'AVD_RESTART_ACCEPTED_UNVERIFIED: Azure accepted the restart, but completion could not be verified within ten minutes. The operation was not resubmitted.'
}

function Wait-ArcMachineAfterRestart {
    param([string]$MachineId)
    # Power-operation completion does not mean the guest/Arc services are ready.
    # Allow boot settling, then require a sustained Connected observation.
    $started=[datetime]::UtcNow
    $deadline=$started.AddMinutes(10)
    $connectedSince=$null
    while ([datetime]::UtcNow -lt $deadline) {
        try { $machine=Invoke-Arm "$MachineId`?api-version=$script:ArcApi" -AllowNotFound }
        catch {
            $connectedSince=$null
            Write-Event 'Arc status is temporarily unavailable during restart recovery; retrying.'
            Start-Sleep -Seconds 15
            continue
        }
        $connected=$machine -and $machine.properties.status -eq 'Connected' -and $machine.properties.provisioningState -eq 'Succeeded'
        if ($connected -and [datetime]::UtcNow -ge $started.AddSeconds(60)) {
            if ($null -eq $connectedSince) { $connectedSince=[datetime]::UtcNow }
            if ([datetime]::UtcNow -ge $connectedSince.AddSeconds(60)) {
                Write-Event 'Arc has remained connected after the post-restart settling period.'
                return
            }
        } else { $connectedSince=$null }
        Write-Event 'Waiting for Windows and Arc to settle after restart (up to 10 minutes).'
        Start-Sleep -Seconds 15
    }
    throw 'AVD_RESTART_ACCEPTED_UNVERIFIED: The power operation completed, but Arc did not remain connected after restart. Resume verification with -Monitor; do not submit another restart.'
}

function Invoke-HciVmRestart {
    param([string]$MachineId,[string]$RestartPath,[object]$RestartRecord)
    $submittedUtc=[datetime]::UtcNow
    for ($attempt=0;$attempt -lt 5;$attempt++) {
        try { $response=Invoke-AzRestMethod -Path $RestartPath -Method POST -ErrorAction Stop -Verbose:$false -Debug:$false }
        catch { throw "Azure Local restart submission failed for $MachineId. Check Azure Activity Log and the active account." }
        $status=[int]$response.StatusCode
        if ($status -eq 200) {
            $RestartRecord.correlationId=Get-ArmResponseHeader $response 'x-ms-correlation-request-id'
            return
        }
        if ($status -eq 202) { Wait-HciVmRestart $MachineId $response $submittedUtc $RestartRecord; return }
        $code='Unknown'
        try { $code=($response.Content|ConvertFrom-Json).error.code } catch { $code='NonJsonResponse' }
        if (($status -eq 429 -or $status -ge 500) -and $attempt -lt 4) {
            Start-Sleep -Seconds ([math]::Min(30,[math]::Pow(2,$attempt+1)))
            continue
        }
        throw "Azure Local restart submission failed: HTTP $status ($code), resource $($RestartPath.Split('?')[0])."
    }
}

#endregion

#region Existing deployment discovery and inspection
function Get-ArmList {
    param([string]$Path)
    do {
        $page = Invoke-Arm $Path
        foreach ($item in $page.value) { $item }
        $Path = $page.nextLink
        if ($Path -match '^https://management.azure.com/') { $Path = ([uri]$Path).PathAndQuery }
        elseif ($Path -match '^https?://') { throw 'Unexpected ARM pagination endpoint.' }
    } while ($Path)
}

function Get-ExistingAvdDeployment {
    param([string]$SubscriptionScope)
    $base = "$SubscriptionScope/providers/Microsoft.DesktopVirtualization"
    $pools = @(Get-ArmList "$base/hostPools?api-version=$script:AvdApi")
    # Linked-resource discovery must not hide otherwise readable host pools.
    $groups = @(); $workspaces = @(); $relatedRead = 'Succeeded'
    try { $groups = @(Get-ArmList "$base/applicationGroups?api-version=$script:AvdApi") }
    catch { $relatedRead = 'RestrictedOrUnavailable'; Write-Verbose $_.Exception.Message }
    try { $workspaces = @(Get-ArmList "$base/workspaces?api-version=$script:AvdApi") }
    catch { $relatedRead = 'RestrictedOrUnavailable'; Write-Verbose $_.Exception.Message }
    foreach ($pool in $pools) {
        $poolId = [string]$pool.id
        $poolGroups = @($groups | Where-Object { $_.properties.hostPoolArmPath -eq $poolId })
        $poolWorkspaces = @($workspaces | Where-Object {
            $references = @($_.properties.applicationGroupReferences)
            @($poolGroups | Where-Object { $references -contains $_.id }).Count -gt 0
        })
        $hosts = @(); $hostRead = 'Succeeded'
        try { $hosts = @(Get-ArmList "$poolId/sessionHosts?api-version=$script:AvdApi") }
        catch { $hostRead = 'RestrictedOrUnavailable' }
        $history = @()
        $runRoot = $script:AvdHistoryRoot
        if ($runRoot -and (Test-Path -LiteralPath $runRoot)) {
            foreach ($runFile in (Get-ChildItem -LiteralPath $runRoot -Filter run.json -File -Recurse -ErrorAction SilentlyContinue)) {
                try {
                    $run = Get-Content -LiteralPath $runFile.FullName -Raw | ConvertFrom-Json
                    if ($run.hostPoolId -eq $poolId) { $history += $runFile.FullName }
                } catch { }
            }
        }
        [pscustomobject]@{
            Name=$pool.name; Id=$poolId; ResourceGroup=([regex]::Match($poolId,'(?i)/resourceGroups/([^/]+)').Groups[1].Value)
            Location=$pool.location; ProvisioningState=$pool.properties.provisioningState
            HostPoolType=$pool.properties.hostPoolType; LoadBalancerType=$pool.properties.loadBalancerType
            MaxSessionLimit=$pool.properties.maxSessionLimit; CustomRdpProperty=$pool.properties.customRdpProperty
            ApplicationGroups=$poolGroups; Workspaces=$poolWorkspaces; SessionHosts=$hosts
            SessionHostReadState=$hostRead; RelatedResourceReadState=$relatedRead; RunHistory=$history
        }
    }
}

function Show-ExistingAvdDeployment {
    param([object]$Deployment)
    Write-Host "Host pool: $($Deployment.Name) [$($Deployment.ProvisioningState)]"
    Write-Host "Resource group: $($Deployment.ResourceGroup) | Region: $($Deployment.Location)"
    if ($Deployment.RelatedResourceReadState -eq 'RestrictedOrUnavailable') { Write-Host 'Linked application-group/workspace discovery is incomplete. Inspect discovery access under Configure permissions.' -ForegroundColor Yellow }
    if ($Deployment.HostPoolType -eq 'Personal') { Write-Host 'Type: Personal | Dedicated user assignments | Persistent load balancing' }
    else { Write-Host "Type: $($Deployment.HostPoolType) | Load balancing: $($Deployment.LoadBalancerType) | Session limit: $($Deployment.MaxSessionLimit)" }
    if ($Deployment.ApplicationGroups.Count) { Write-Host ('Application groups: ' + (($Deployment.ApplicationGroups | ForEach-Object { $_.name }) -join ', ')) }
    else { Write-Warning 'No linked application groups were returned. This may be a partial deployment or discovery may be restricted.' }
    if ($Deployment.Workspaces.Count) { Write-Host ('Workspaces: ' + (($Deployment.Workspaces | ForEach-Object { $_.name }) -join ', ')) }
    else { Write-Warning 'No linked workspaces were returned.' }
    if ($Deployment.SessionHostReadState -eq 'Succeeded') {
        Write-Host "Session hosts: $($Deployment.SessionHosts.Count)"
        foreach ($sessionHost in $Deployment.SessionHosts) {
            $hardwareSummary='Profile unavailable'
            $machineId=[string]$sessionHost.properties.resourceId
            if ($machineId -match '(?i)^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft\.HybridCompute/machines/[^/]+$') {
                try {
                    $vmInstance=Invoke-Arm "$machineId/providers/Microsoft.AzureStackHCI/virtualMachineInstances/default?api-version=$script:HciApi"
                    $processors=$vmInstance.properties.hardwareProfile.processors
                    $memoryMB=$vmInstance.properties.hardwareProfile.memoryMB
                    if ($null -ne $processors -and $null -ne $memoryMB) {
                        $hardwareSummary=('{0} vCPU | {1:N1} GB RAM' -f $processors,([double]$memoryMB / 1024))
                    }
                } catch { $hardwareSummary='Profile unavailable (Azure Local instance read failed)' }
            }
            Write-Host ('  {0} | {1} | {2} | {3}' -f $sessionHost.name,$sessionHost.properties.status,$hardwareSummary,$machineId)
            if ($Deployment.HostPoolType -eq 'Personal') { Write-Host ("    Assigned user: " + $(if ($sessionHost.properties.assignedUser) { $sessionHost.properties.assignedUser } else { 'Unassigned' })) }
        }
    } else { Write-Warning 'Session host discovery was denied or unavailable. No host list is assumed.' }
    if ($Deployment.RunHistory.Count) { Write-Host "Local run history entries: $($Deployment.RunHistory.Count)" }
    else { Write-Host 'No matching local run history. Azure discovery remains authoritative.' }
}

#endregion

#region Entra device permissions and identity resolution
function Test-EntraDeviceDeleteAccess {
    $token=$null
    try {
        if ((Get-AzContext).Account.Type -ne 'ServicePrincipal') { return $false }
        $token=(Get-AzAccessToken -ResourceUrl 'https://graph.microsoft.com/').Token
        if ($token -is [securestring]) { $token=[pscredential]::new('token',$token).GetNetworkCredential().Password }
        $part=($token -split '\.')[1].Replace('-','+').Replace('_','/')
        $part=$part.PadRight($part.Length+((4-$part.Length%4)%4),'=')
        $claims=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($part)) | ConvertFrom-Json
        if ($claims.tid -ne $script:Tenant -or $claims.oid -ne $script:SpnObjectId -or $claims.roles -notcontains 'Device.ReadWrite.All') { return $false }
        $null=Invoke-Graph '/devices?$top=1&$select=id'
        return $true
    } catch { return $false } finally { $token=$null; $part=$null; $claims=$null }
}

function Grant-AvdDeviceDeletePermission {
        $graph=@(Get-GraphList "/servicePrincipals?`$filter=appId eq '00000003-0000-0000-c000-000000000000'&`$select=id,appRoles")
        if ($graph.Count -ne 1) { throw 'Cannot resolve Microsoft Graph service principal.' }
        $role=@($graph[0].appRoles | Where-Object { $_.value -eq 'Device.ReadWrite.All' -and $_.isEnabled -and $_.allowedMemberTypes -contains 'Application' })
        if ($role.Count -ne 1) { throw 'Cannot resolve Device.ReadWrite.All application permission.' }
        $assignments=@(Get-GraphList "/servicePrincipals/$script:SpnObjectId/appRoleAssignments")
        if (-not @($assignments | Where-Object { $_.resourceId -eq $graph[0].id -and $_.appRoleId -eq $role[0].id }).Count) {
            $null=Invoke-Graph "/servicePrincipals/$script:SpnObjectId/appRoleAssignments" POST @{principalId=$script:SpnObjectId;resourceId=$graph[0].id;appRoleId=$role[0].id}
        }
    }

function Confirm-EntraDeviceDeleteAccess {
    if ($script:RemovalPermissionBatch -and $script:RemovalPermissionProof.Graph -and $script:RemovalPermissionProof.Principal -eq $script:SpnObjectId -and $script:RemovalPermissionProof.Tenant -eq $script:Tenant) { return }
    if (Test-EntraDeviceDeleteAccess) { return }
    if ($script:RemovalPermissionBatch) { throw 'Entra permissions changed after the grouped preflight. Return to the menu and retry permission preparation.' }
    Write-Warning 'SPN Microsoft Graph Device.ReadWrite.All application access is missing or unverified. No host will be deleted.'
    Write-Host 'This permission manages devices throughout the Entra tenant; it cannot be restricted by Azure resource-group RBAC.'
    Write-Host 'Consent requires a Global Administrator or Privileged Role Administrator. Manual option: Entra > App registrations > this SPN > API permissions > Microsoft Graph > Application > Device.ReadWrite.All > Grant admin consent.'
    if ((Read-Value 'Use an authorized account to grant Device.ReadWrite.All to this SPN? (Y/N)' 'N' '^[YyNn]$') -ne 'Y') { throw 'Device deletion permission was not granted. Nothing was deleted.' }
    Invoke-AlternateUser { Grant-AvdDeviceDeletePermission }
    if (-not (Test-EntraDeviceDeleteAccess)) {
        Write-Verbose 'Consent is saved. Refresh the SPN sign-in to obtain a new Graph token.'
        # Only reuse the .env secret when it belongs to the current SPN and tenant.
        $secret = if ($env:AZSHCI_SPN_SECRET -and $env:AZSHCI_SPN_APP_ID -eq $script:SpnContext.Account.Id -and $env:AZSHCI_TENANT_ID -eq $script:Tenant) {
            ConvertTo-SecureString $env:AZSHCI_SPN_SECRET -AsPlainText -Force
        } else { Read-Host 'SPN secret for a fresh sign-in (no matching .env credentials)' -AsSecureString }
        try {
            $credential=[pscredential]::new($script:SpnContext.Account.Id,$secret)
            $null=Connect-AzAccount -ServicePrincipal -Tenant $script:Tenant -Subscription $script:Subscription -Credential $credential -Scope Process -Force
            $script:SpnContext=Get-AzContext
        } finally { $secret=$null; $credential=$null }
    }
    if (-not (Test-EntraDeviceDeleteAccess)) { throw 'Device permissions are not effective yet. Retry after consent propagation. Nothing was deleted.' }
}

function Remove-ArmResourceAndWait {
    param([string]$ResourceId,[string]$ApiVersion,[switch]$ForceStaleRegistration)
    if ($ForceStaleRegistration -and $ResourceId -notmatch '/providers/Microsoft\.DesktopVirtualization/hostPools/[^/]+/sessionHosts/[^/]+$') { throw 'Force cleanup is restricted to an AVD session host registration.' }
    if (-not (Invoke-Arm "$ResourceId`?api-version=$ApiVersion" -AllowNotFound)) { return }
    $deletePath="$ResourceId`?api-version=$ApiVersion"
    if ($ForceStaleRegistration) { $deletePath+='&force=true' }
    $null=Invoke-Arm $deletePath DELETE
    $deadline=[datetime]::UtcNow.AddMinutes($TimeoutMinutes)
    while (Invoke-Arm "$ResourceId`?api-version=$ApiVersion" -AllowNotFound) {
        if ([datetime]::UtcNow -ge $deadline) { throw "Deletion remains pending: $ResourceId. Inspect the saved removal plan before retrying." }
        Write-Event "Waiting for deletion: $ResourceId"
        Start-Sleep -Seconds $PollSeconds
    }
}

function Get-SessionHostEntraIdentity {
    param([object]$Machine,[int]$Sequence)
    if ($Machine.properties.status -ne 'Connected') {
        Write-Host 'Obtain DeviceId from this offline host dsregcmd /status output or verified inventory. Do not use the Arc managed-identity principal ID or AVD internal objectId.'
        return [pscustomobject]@{deviceId=(Read-Value 'Verified Entra DeviceId for this host' '' '^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$');tenantId=$script:Tenant}
    }
    Confirm-Permission $Machine.id @('Microsoft.HybridCompute/machines/runCommands/read','Microsoft.HybridCompute/machines/runCommands/write','Microsoft.HybridCompute/machines/runCommands/delete') @($script:Roles.ConnectedMachineAdmin)
    Remove-CompletedGuestRunCommand $Machine.id
    $commandName='AVDTask-'+$script:Run.runId.Replace('-','')+'-'+$Sequence
    $commandId="$($Machine.id)/runCommands/$commandName"
    $marker='AVD_DEVICE_'+[guid]::NewGuid().ToString('N')
    $source=@'
$ErrorActionPreference='Stop'
$text=(& "$env:windir\System32\dsregcmd.exe" /status | Out-String)
if ($LASTEXITCODE -ne 0 -or $text -notmatch '(?m)^\s*AzureAdJoined\s*:\s*YES\s*$') { throw 'The guest is not confirmed Entra joined.' }
$device=[regex]::Match($text,'(?m)^\s*DeviceId\s*:\s*([0-9a-fA-F-]{36})\s*$').Groups[1].Value
$tenant=[regex]::Match($text,'(?m)^\s*TenantId\s*:\s*([0-9a-fA-F-]{36})\s*$').Groups[1].Value
if (-not $device -or -not $tenant) { throw 'Cannot read the joined device and tenant IDs.' }
Write-Output ('__MARKER__'+(@{deviceId=$device;tenantId=$tenant}|ConvertTo-Json -Compress))
'@
    $body=@{location=$Machine.location;properties=@{asyncExecution=$false;timeoutInSeconds=120;source=@{script=$source.Replace('__MARKER__',$marker)}}}
    Write-Event "Reading Entra identity from $($Machine.name) using dsregcmd /status: $commandId"
    $null=Invoke-GuestTaskRunCommand $Machine $commandName $body
    $deadline=[datetime]::UtcNow.AddMinutes(5)
    do {
        $command=Invoke-Arm "$commandId`?api-version=$script:RunCommandApi&`$expand=instanceView" -AllowNotFound
        $view=$command.properties.instanceView
        if ($view.executionState -eq 'Succeeded' -and $null -ne $view.exitCode -and $view.exitCode -eq 0) {
            $match=[regex]::Match([string]$view.output,([regex]::Escape($marker)+'(\{[^\r\n]+\})'))
            if (-not $match.Success) { throw 'The device identity completion marker was not returned.' }
            return ($match.Groups[1].Value | ConvertFrom-Json)
        }
        if ($view.executionState -in @('Failed','TimedOut','Canceled')) { throw 'Guest identity lookup failed. No host was deleted.' }
        Start-Sleep -Seconds $PollSeconds
    } while ([datetime]::UtcNow -lt $deadline)
    throw 'Guest identity lookup remains pending. No host was deleted; do not infer a device from its display name.'
}

#endregion

#region Maintenance and blue-green switching
function Save-AvdMaintenancePlan {
    param([object]$Plan,[string]$Path)
    $Plan.updatedUtc=[datetime]::UtcNow.ToString('o')
    $temp=$Path+'.tmp'
    $Plan | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $temp -Encoding UTF8
    Move-Item -LiteralPath $temp -Destination $Path -Force
}

function Get-AvdMaintenanceHosts {
    param([object]$Plan)
    if ($Plan.version -ne 1 -or $Plan.tenantId -ne $script:Tenant -or $Plan.subscriptionId -ne $script:Subscription) { throw 'Maintenance plan version/account does not match this session.' }
    if ($Plan.hostPoolId -notmatch ('(?i)^/subscriptions/'+[regex]::Escape($script:Subscription)+'/resourceGroups/[^/]+/providers/Microsoft\.DesktopVirtualization/hostPools/[^/]+$')) { throw 'Invalid maintenance pool ID.' }
    $planned=@($Plan.blue)+@($Plan.green)
    if (-not @($Plan.blue).Count -or -not @($Plan.green).Count -or @($planned | Select-Object -ExpandProperty id -Unique).Count -ne $planned.Count) { throw 'Blue/green groups must be nonempty and disjoint.' }
    $current=@(Get-ArmList "$($Plan.hostPoolId)/sessionHosts?api-version=$script:AvdApi")
    if ($current.Count -ne $planned.Count) { throw 'Pool membership changed since preparation. Review or recreate the maintenance plan.' }
    foreach ($entry in $planned) {
        $match=@($current | Where-Object id -eq $entry.id)
        if ($match.Count -ne 1 -or $match[0].properties.resourceId -ne $entry.machineId -or $match[0].properties.virtualMachineId -ne $entry.vmId) { throw 'A planned session host is missing or has been replaced. Maintenance stopped.' }
    }
    return $current
}

function Set-AvdSessionAdmission {
    param([object]$Entry,[bool]$Allow,[datetime]$Deadline)
    if ([datetime]::UtcNow -ge $Deadline) { throw 'Maintenance window ended before this change. No later changes were submitted.' }
    $current=Invoke-Arm "$($Entry.id)?api-version=$script:AvdApi"
    if ($current.properties.resourceId -ne $Entry.machineId -or $current.properties.virtualMachineId -ne $Entry.vmId) { throw 'Session host identity changed before the admission change.' }
    if ($Allow) {
        $machine=Invoke-Arm "$($Entry.machineId)?api-version=$script:ArcApi"
        if ($current.properties.status -ne 'Available' -or $machine.properties.status -ne 'Connected') { throw 'A target host is no longer available; admission was not enabled.' }
    }
    if ($current.properties.allowNewSession -eq $Allow) { return }
    if ([datetime]::UtcNow -ge $Deadline) { throw 'Maintenance window ended during the readiness check. The admission change was not submitted.' }
    $null=Invoke-Arm "$($Entry.id)?api-version=$script:AvdApi" PATCH @{properties=@{allowNewSession=$Allow}}
    $verifyDeadline=[datetime]::UtcNow.AddMinutes(3)
    if ($Deadline -lt $verifyDeadline) { $verifyDeadline=$Deadline }
    do {
        $current=Invoke-Arm "$($Entry.id)?api-version=$script:AvdApi"
        if ($current.properties.allowNewSession -eq $Allow) { return }
        Write-Event "Waiting for session admission=$Allow on $($Entry.name)."
        Start-Sleep -Seconds 15
    } while ([datetime]::UtcNow -lt $verifyDeadline)
    throw 'Admission change was submitted but not verified. Inspect the maintenance plan before retrying.'
}

function New-AvdMaintenancePlan {
    param([object]$Deployment)
    if ($Deployment.HostPoolType -ne 'Pooled') { throw 'Blue/green maintenance requires a pooled host pool.' }
    Assert-AvdAutoscalePaused $Deployment.Id
    $hosts=@(Get-ArmList "$($Deployment.Id)/sessionHosts?api-version=$script:AvdApi")
    Write-Host 'Select existing replacement hosts as green. All other hosts in this pool become blue. Use Add session hosts first if more capacity is needed. Preparation drains green; it does not create isolated VMs or update software.'
    $green=@(Select-Multiple $hosts 'Select green replacement hosts')
    $blue=@($hosts | Where-Object { $_.id -notin @($green | ForEach-Object id) })
    if (-not $green.Count -or -not $blue.Count) { throw 'At least one blue host and one green host are required.' }
    foreach ($sessionHost in $hosts) {
        if (-not $sessionHost.properties.virtualMachineId -or $sessionHost.properties.resourceId -notmatch ('(?i)^/subscriptions/'+[regex]::Escape($script:Subscription)+'/resourceGroups/[^/]+/providers/Microsoft\.HybridCompute/machines/[^/]+$')) { throw 'Maintenance requires exact Azure Local host and VM identities.' }
        Confirm-Permission $sessionHost.id @('Microsoft.DesktopVirtualization/hostPools/sessionHosts/read','Microsoft.DesktopVirtualization/hostPools/sessionHosts/write','Microsoft.DesktopVirtualization/hostPools/sessionHosts/userSessions/read') @($script:Roles.Contributor)
    }
    foreach ($entry in $green) {
        if (@(Get-ArmList "$($entry.id)/userSessions?api-version=$script:AvdApi").Count) { throw 'A green host still has user sessions. Select unused replacements or drain/sign out those users first.' }
    }
    foreach ($entry in $blue) { if ($entry.properties.status -ne 'Available' -or $entry.properties.allowNewSession -ne $true) { throw 'Blue hosts must be Available and accepting connections before preparation.' } }
    Write-Host "Blue (serving): $(@($blue | ForEach-Object name) -join ', ')"
    Write-Host "Green (will be drained): $(@($green | ForEach-Object name) -join ', ')"
    Write-Warning 'Keep autoscale and other admission-changing automation suspended throughout this maintenance. Drain mode blocks new sessions but does not prevent users reconnecting to existing sessions.'
    if ((Read-Value 'Confirm blue capacity is sufficient, automation is suspended, and drain green now? (Y/N)' 'N' '^[YyNn]$') -ne 'Y') { return }
    $convert={ [pscustomobject]@{id=$_.id;name=$_.name;machineId=$_.properties.resourceId;vmId=$_.properties.virtualMachineId} }
    $plan=[pscustomobject]@{version=1;tenantId=$script:Tenant;subscriptionId=$script:Subscription;hostPoolId=$Deployment.Id;blue=@($blue | ForEach-Object $convert);green=@($green | ForEach-Object $convert);status='Preparing';updatedUtc='';windowStartUtc='';windowEndUtc='';pendingDirection='';lastGuestRun='';events=@()}
    $directory=Join-Path $env:LOCALAPPDATA 'AVDEntraJoin/maintenance'
    $null=New-Item -ItemType Directory -Path $directory -Force
    $path=Join-Path $directory ((Get-Date -Format 'yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N').Substring(0,6)+'.json')
    Save-AvdMaintenancePlan $plan $path
    try {
        foreach ($entry in $plan.green) {
            Set-AvdSessionAdmission $entry $false ([datetime]::UtcNow.AddMinutes(5))
            $plan.events+=@{utc=[datetime]::UtcNow.ToString('o');id=$entry.id;allow=$false}; Save-AvdMaintenancePlan $plan $path
        }
        foreach ($entry in $plan.green) { if (@(Get-ArmList "$($entry.id)/userSessions?api-version=$script:AvdApi").Count) { throw 'A session arrived while green was being drained. Sign users out before running updates.' } }
        $plan.status='Prepared'; Save-AvdMaintenancePlan $plan $path
    } catch { $plan.status='NeedsReview'; Save-AvdMaintenancePlan $plan $path; throw }
    Write-Host "Green is drained. Plan: $path"
}

function Invoke-AvdMaintenanceSwitch {
    param([object]$Plan,[string]$Path,[switch]$Rollback)
    Assert-AvdAutoscalePaused $Plan.hostPoolId
    $current=@(Get-AvdMaintenanceHosts $Plan)
    if (-not $Rollback -and $Plan.status -notin @('Prepared','Scheduled','RolledBack')) { throw 'Prepare and validate green before switching. A partial change requires inspection or explicit rollback.' }
    if ($Rollback -and $Plan.status -notin @('Switched','NeedsReview','Switching','Scheduled')) { throw 'Rollback requires a switched or partially changed plan.' }
    $target=if ($Rollback) { @($Plan.blue) } else { @($Plan.green) }
    $source=if ($Rollback) { @($Plan.green) } else { @($Plan.blue) }
    if (-not $Rollback -and $Plan.lastGuestRun) {
        $guestRun=Get-Content -LiteralPath $Plan.lastGuestRun -Raw -ErrorAction Stop | ConvertFrom-Json
        if ($guestRun.hostPoolId -ne $Plan.hostPoolId -or $guestRun.guestTaskStatus -ne 'Succeeded') { throw 'The last green guest-task run has not succeeded. Resolve it and run green validation again before switching.' }
    }
    foreach ($entry in (@($Plan.blue)+@($Plan.green))) { Confirm-Permission $entry.id @('Microsoft.DesktopVirtualization/hostPools/sessionHosts/read','Microsoft.DesktopVirtualization/hostPools/sessionHosts/write','Microsoft.DesktopVirtualization/hostPools/sessionHosts/userSessions/read') @($script:Roles.Contributor) }
    Write-Host "Accept new sessions on: $(@($target | ForEach-Object name) -join ', ')"
    Write-Host "Drain: $(@($source | ForEach-Object name) -join ', '). Existing sessions stay running; no VM is deleted."
    Write-Host 'Window times require an explicit UTC offset, for example 2026-10-01 22:00 +02:00. Keep this PowerShell process open for a scheduled switch; no credentials are stored or unattended scheduler installed.'
    $start=[datetimeoffset]::MinValue; $end=[datetimeoffset]::MinValue
    $startText=Read-Value 'Maintenance start (yyyy-MM-dd HH:mm zzz)' ([datetimeoffset]::Now.AddMinutes(2).ToString('yyyy-MM-dd HH:mm zzz'))
    $endText=Read-Value 'Maintenance end (yyyy-MM-dd HH:mm zzz)' ([datetimeoffset]::Now.AddHours(1).ToString('yyyy-MM-dd HH:mm zzz'))
    $culture=[Globalization.CultureInfo]::InvariantCulture; $style=[Globalization.DateTimeStyles]::None
    if (-not [datetimeoffset]::TryParseExact($startText,'yyyy-MM-dd HH:mm zzz',$culture,$style,[ref]$start) -or -not [datetimeoffset]::TryParseExact($endText,'yyyy-MM-dd HH:mm zzz',$culture,$style,[ref]$end) -or $end -le $start -or $end -le [datetimeoffset]::UtcNow) { throw 'Invalid or expired maintenance window.' }
    if ((Read-Value 'Confirm target capacity, application/FSLogix/sign-in tests, required restarts and suspended autoscale; authorize this switch in the window? (Y/N)' 'N' '^[YyNn]$') -ne 'Y') { return }
    $Plan.windowStartUtc=$start.UtcDateTime.ToString('o'); $Plan.windowEndUtc=$end.UtcDateTime.ToString('o'); $Plan.status='Scheduled'
    $Plan | Add-Member -NotePropertyName pendingDirection -NotePropertyValue $(if ($Rollback) { 'Blue' } else { 'Green' }) -Force
    Save-AvdMaintenancePlan $Plan $Path
    while ([datetime]::UtcNow -lt $start.UtcDateTime) {
        Write-Event "Maintenance waiting until $($Plan.windowStartUtc). Close this process to stop waiting; reopening the plan requires explicit authorization."
        Start-Sleep -Seconds 30
    }
    try {
        if ([datetime]::UtcNow -ge $end.UtcDateTime) { throw 'The authorized window expired. No switch was started.' }
        Assert-AvdAutoscalePaused $Plan.hostPoolId
        $current=@(Get-AvdMaintenanceHosts $Plan)
        if (-not $Rollback) { foreach ($entry in $source) { if (@($current | Where-Object id -eq $entry.id)[0].properties.allowNewSession -ne $true) { throw 'Blue admission changed since preparation. Inspect the pool before switching.' } } }
        foreach ($entry in $target) {
            $hostState=@($current | Where-Object id -eq $entry.id)[0]
            $machine=Invoke-Arm "$($entry.machineId)?api-version=$script:ArcApi"
            if ($hostState.properties.status -ne 'Available' -or $machine.properties.status -ne 'Connected') { throw 'A target host or its Arc agent is not ready. No switch was started.' }
            if (-not $Rollback -and ($hostState.properties.allowNewSession -ne $false -or @(Get-ArmList "$($entry.id)/userSessions?api-version=$script:AvdApi").Count)) { throw 'Green must remain drained and free of user sessions before switching.' }
        }
        # Admission changes are sequential, not an atomic migration. Bring target capacity
        # online first to avoid removing the last serving host on a partial failure.
        $Plan.status='Switching'; Save-AvdMaintenancePlan $Plan $Path
        foreach ($entry in $target) {
            Set-AvdSessionAdmission $entry $true $end.UtcDateTime
            $Plan.events+=@{utc=[datetime]::UtcNow.ToString('o');id=$entry.id;allow=$true}; Save-AvdMaintenancePlan $Plan $Path
        }
        foreach ($entry in $source) {
            Set-AvdSessionAdmission $entry $false $end.UtcDateTime
            $Plan.events+=@{utc=[datetime]::UtcNow.ToString('o');id=$entry.id;allow=$false}; Save-AvdMaintenancePlan $Plan $Path
        }
        $Plan.status=if ($Rollback) { 'RolledBack' } else { 'Switched' }; Save-AvdMaintenancePlan $Plan $Path
        Write-Host "Maintenance $($Plan.status). Existing sessions remain on the drained group until sign-out. Use removal separately once no sessions remain."
    } catch { $Plan.status='NeedsReview'; Save-AvdMaintenancePlan $Plan $Path; throw }
}

function Invoke-AvdMaintenanceMenu {
    param([object]$Deployment)
    while ($true) {
        $maintenanceChoices=@([pscustomobject]@{Name='Prepare blue/green groups';Id='Prepare'},[pscustomobject]@{Name='Run updates or scripts on prepared green hosts';Id='Update'},[pscustomobject]@{Name='Schedule / run switch to green';Id='Switch'},[pscustomobject]@{Name='Roll back admission to blue';Id='Rollback'},[pscustomobject]@{Name='Inspect maintenance plan';Id='Inspect'},[pscustomobject]@{Name='Disable autoscale for maintenance';Id='PauseScaling'},[pscustomobject]@{Name='Start VM on Connect (enable/disable)';Id='StartOnConnect'},[pscustomobject]@{Name='Back';Id='Back'})
        if ($Deployment.HostPoolType -eq 'Personal') {
            $maintenanceChoices=@([pscustomobject]@{Name='Run maintenance scripts on personal hosts';Id='PersonalTasks'}) + @($maintenanceChoices | Where-Object Id -in @('PauseScaling','StartOnConnect','Back'))
            Write-Host 'Personal desktops retain user assignments. Blue/green admission switching is available for pooled hosts only.'
        }
        $action=Select-Item $maintenanceChoices 'Maintenance'
        if ($action.Id -eq 'Back') { return }
        try {
            if ($action.Id -eq 'PersonalTasks') { Invoke-GuestTaskWorkflow $Deployment; continue }
            if ($action.Id -eq 'PauseScaling') { Disable-AvdPoolAutoscale $Deployment; continue }
            if ($action.Id -eq 'StartOnConnect') { Set-AvdHostPoolConfiguration $Deployment -StartOnConnectOnly; continue }
            if ($action.Id -eq 'Prepare') { New-AvdMaintenancePlan $Deployment; continue }
            $directory=Join-Path $env:LOCALAPPDATA 'AVDEntraJoin/maintenance'
            $plans=@(Get-ChildItem -LiteralPath $directory -Filter *.json -ErrorAction SilentlyContinue | ForEach-Object {
                try { $plan=Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json; if ($plan.hostPoolId -eq $Deployment.Id -and $plan.tenantId -eq $script:Tenant) { [pscustomobject]@{Name="$($_.BaseName) [$($plan.status)]";Path=$_.FullName;Plan=$plan} } } catch { Write-Warning 'An unreadable maintenance plan was skipped.' }
            })
            if (-not $plans.Count) { Write-Host 'No saved maintenance plans for this pool. Prepare the groups first.'; continue }
            $selected=Select-Item $plans 'Select maintenance plan'
            $plan=$selected.Plan; $current=@(Get-AvdMaintenanceHosts $plan)
            if ($action.Id -eq 'Inspect') {
                Write-Host "Status: $($plan.status) | Window: $($plan.windowStartUtc) to $($plan.windowEndUtc)"
                foreach ($entry in $current) { $group=if ($entry.id -in @($plan.green | ForEach-Object id)) { 'Green' } else { 'Blue' }; Write-Host "$group | $($entry.name) | $($entry.properties.status) | Allow new sessions: $($entry.properties.allowNewSession) | Sessions: $($entry.properties.sessions)" }
                continue
            }
            if ($action.Id -eq 'Update') {
                Assert-AvdAutoscalePaused $Deployment.Id
                if ($plan.status -notin @('Prepared','RolledBack')) { throw 'Only a prepared plan can run green updates.' }
                $green=@($current | Where-Object { $_.id -in @($plan.green | ForEach-Object id) })
                foreach ($entry in $green) { if ($entry.properties.allowNewSession -ne $false -or @(Get-ArmList "$($entry.id)/userSessions?api-version=$script:AvdApi").Count) { throw 'Green must be drained and have no user sessions before updates.' } }
                # Isolate task history from other operations executed in this console.
                $OutputDirectory=Join-Path $OutputDirectory ('green-'+[guid]::NewGuid().ToString('N').Substring(0,8))
                try { Invoke-GuestTaskWorkflow ([pscustomobject]@{Id=$Deployment.Id;Name=$Deployment.Name;SessionHostReadState='Succeeded';SessionHosts=$green}) }
                finally {
                    if ($script:RunFile -and $script:RunFile.StartsWith(([IO.Path]::GetFullPath($OutputDirectory)+[IO.Path]::DirectorySeparatorChar),[StringComparison]::OrdinalIgnoreCase)) {
                        $plan.lastGuestRun=$script:RunFile; Save-AvdMaintenancePlan $plan $selected.Path
                    }
                }
                continue
            }
            Invoke-AvdMaintenanceSwitch $plan $selected.Path -Rollback:($action.Id -eq 'Rollback')
        } catch { Write-Warning $_.Exception.Message }
    }
}

#endregion

#region Host pool properties, RDP and friendly names
function Set-AvdRdpEntry {
    param([string]$Current,[string]$Entry,[string]$RemoveName)
    $entries=[ordered]@{}
    foreach ($item in @($Current -split ';' | Where-Object { $_.Trim() })) {
        if ($item -notmatch '^([^:;]+):([isb]):(.*)$') { throw 'Existing RDP properties contain an invalid entry; review them before editing.' }
        if ($entries.Contains($Matches[1])) { throw 'Existing RDP properties contain duplicate names.' }
        $entries[$Matches[1]]=$item
    }
    if ($RemoveName) { $entries.Remove($RemoveName) }
    else {
        if ($Entry -notmatch '^([a-zA-Z][a-zA-Z0-9_ ]*):([isb]):([^;\r\n]*)$') { throw 'Use one RDP entry: property:type:value (no semicolon).' }
        $name=$Matches[1]; $type=$Matches[2]; $value=$Matches[3]
        if ($name -match '(?i)password|credential') { throw 'Credentials must not be stored in custom RDP properties.' }
        if ($type -eq 'i' -and $value -notmatch '^-?\d+$') { throw 'An integer RDP property requires an integer value.' }
        $entries[$name]=$Entry
    }
    if (-not $entries.Count) { return '' }
    return (($entries.Values -join ';')+';')
}

function Set-AvdDesktopFriendlyName {
    param([object]$Deployment)
    $groups=@($Deployment.ApplicationGroups | Where-Object { $_.properties.applicationGroupType -eq 'Desktop' })
    if (-not $groups.Count) { Write-Warning 'No desktop application group was discovered for this pool.'; return }
    $group=Select-Item $groups 'Select the desktop application group'
    Confirm-Permission $group.id @('Microsoft.DesktopVirtualization/applicationGroups/read','Microsoft.DesktopVirtualization/applicationGroups/desktops/read','Microsoft.DesktopVirtualization/applicationGroups/desktops/write') @($script:Roles.Contributor)
    $currentGroup=Invoke-Arm "$($group.id)?api-version=$script:AvdApi"
    if ($currentGroup.properties.hostPoolArmPath -ne $Deployment.Id -or $currentGroup.properties.applicationGroupType -ne 'Desktop') { throw 'The desktop application group association changed. Refresh the deployment.' }
    $desktops=@(Get-ArmList "$($group.id)/desktops?api-version=$script:AvdApi")
    if (-not $desktops.Count) { Write-Warning 'No published desktop was found in this application group.'; return }
    $desktop=Select-Item $desktops 'Select the published remote desktop'
    if (-not $desktop.id.StartsWith(($group.id+'/desktops/'),[StringComparison]::OrdinalIgnoreCase)) { throw 'Unexpected desktop resource ID.' }
    $before=[string]$desktop.properties.friendlyName
    Write-Host 'This changes the published desktop display name in Windows App / Remote Desktop. Resource names, host pool settings and existing sessions are unchanged.'
    $name=Read-Value 'Remote desktop friendly name' $before '^\S[^\r\n]{0,255}$'
    if ($name -ceq $before) { Write-Host 'The remote desktop friendly name is unchanged.'; return }
    Write-Host "Published desktop: $($desktop.name) | '$before' -> '$name'"
    if ((Read-Value 'Apply this remote desktop display name? (Y/N)' 'N' '^[YyNn]$') -ne 'Y') { return }
    $latest=Invoke-Arm "$($desktop.id)?api-version=$script:AvdApi"
    if ([string]$latest.properties.friendlyName -cne $before) { throw 'The desktop friendly name changed during review. Refresh and retry.' }
    $directory=Join-Path $OutputDirectory ('desktop-settings-'+[guid]::NewGuid().ToString('N'))
    $null=New-Item -ItemType Directory -Path $directory -Force
    $path=Join-Path $directory 'settings.json'
    $record=@{desktopId=$desktop.id;hostPoolId=$Deployment.Id;before=$before;requested=$name;status='Submitting'}
    $record | ConvertTo-Json | Set-Content -LiteralPath $path -Encoding UTF8
    Write-Host "Configuration tracking: $path"
    try {
        $null=Invoke-Arm "$($desktop.id)?api-version=$script:AvdApi" PATCH @{properties=@{friendlyName=$name}}
        $deadline=[datetime]::UtcNow.AddMinutes(5)
        do {
            $updated=Invoke-Arm "$($desktop.id)?api-version=$script:AvdApi"
            if ([string]$updated.properties.friendlyName -ceq $name) { $record.status='Succeeded'; break }
            Write-Event 'Waiting for the published desktop friendly name to update.'
            Start-Sleep -Seconds 15
        } while ([datetime]::UtcNow -lt $deadline)
        if ($record.status -ne 'Succeeded') { throw 'Desktop name update could not be verified. Inspect the saved change before retrying.' }
        Write-Host 'Remote desktop friendly name updated. Refresh the workspace in Windows App / Remote Desktop to retrieve the new display name.' -ForegroundColor Green
    } catch { $record.status='NeedsReview'; throw }
    finally { $record | ConvertTo-Json | Set-Content -LiteralPath $path -Encoding UTF8 }
}

function Set-AvdWorkspaceFriendlyName {
    param([object]$Deployment)
    $workspaces=@($Deployment.Workspaces)
    if (-not $workspaces.Count) { Write-Host 'No linked workspace was discovered. Refresh deployment discovery.'; return }
    $workspace=Select-Item $workspaces 'Select the workspace to rename'
    Confirm-Permission $workspace.id @('Microsoft.DesktopVirtualization/workspaces/read','Microsoft.DesktopVirtualization/workspaces/write') @($script:Roles.Contributor)
    $current=Invoke-Arm "$($workspace.id)?api-version=$script:AvdApi"
    $groupIds=@($Deployment.ApplicationGroups | ForEach-Object id)
    $linked=@($current.properties.applicationGroupReferences | Where-Object { $_ -in $groupIds })
    if (-not $linked.Count) { throw 'The workspace is no longer linked to this host pool. Refresh discovery.' }
    $before=[string]$current.properties.friendlyName
    Write-Host 'Changes the workspace display name in the client feed. A shared workspace displays this name for users of its other application groups too.'
    $name=Read-Value 'Workspace friendly name' $before '^\S[^\r\n]{0,255}$'
    if ($name -ceq $before) { Write-Host 'The workspace friendly name is unchanged.'; return }
    Show-AvdPanel 'Review workspace display name' @("Workspace: $($workspace.name)","Current: $before","Requested: $name")
    if ((Read-Value 'Apply this workspace display name? (Y/N)' 'N' '^[YyNn]$') -ne 'Y') { return }
    $latest=Invoke-Arm "$($workspace.id)?api-version=$script:AvdApi"
    if ([string]$latest.properties.friendlyName -cne $before -or -not @($latest.properties.applicationGroupReferences | Where-Object { $_ -in $groupIds }).Count) { throw 'The workspace changed during review. Refresh and retry.' }
    $directory=Join-Path $OutputDirectory ('workspace-settings-'+[guid]::NewGuid().ToString('N'))
    $null=New-Item -ItemType Directory -Path $directory -Force
    $path=Join-Path $directory 'settings.json'
    $record=@{workspaceId=$workspace.id;hostPoolId=$Deployment.Id;before=$before;requested=$name;status='Submitting'}
    $record | ConvertTo-Json | Set-Content -LiteralPath $path -Encoding UTF8
    try {
        $null=Invoke-Arm "$($workspace.id)?api-version=$script:AvdApi" PATCH @{properties=@{friendlyName=$name}}
        $deadline=[datetime]::UtcNow.AddMinutes(5)
        do {
            $updated=Invoke-Arm "$($workspace.id)?api-version=$script:AvdApi"
            if ([string]$updated.properties.friendlyName -ceq $name) { $record.status='Succeeded'; break }
            Write-Event 'Waiting for the workspace friendly name to update.'
            Start-Sleep -Seconds 15
        } while ([datetime]::UtcNow -lt $deadline)
        if ($record.status -ne 'Succeeded') { throw 'Workspace name update could not be verified. Inspect the saved change before retrying.' }
        Write-Host '[OK] Workspace friendly name updated. Refresh the workspace in Windows App / Remote Desktop.' -ForegroundColor Green
    } catch { $record.status='NeedsReview'; throw }
    finally { $record | ConvertTo-Json | Set-Content -LiteralPath $path -Encoding UTF8; Write-Host "Configuration tracking: $path" }
}

function Set-AvdHostPoolConfiguration {
    param([object]$Deployment,[switch]$StartOnConnectOnly)
    if ($StartOnConnectOnly) { Confirm-Permission $Deployment.Id @('Microsoft.DesktopVirtualization/hostPools/read','Microsoft.DesktopVirtualization/hostPools/write') @($script:Roles.Contributor) }
    $api='2024-04-08-preview' # Adds the four host-pool Shortpath switches.
    $pool=Invoke-Arm "$($Deployment.Id)?api-version=$api"
    $changes=[ordered]@{}
    $items=@(
        [pscustomobject]@{Name='Maximum concurrent sessions per host';Id='maxSessionLimit'},
        [pscustomobject]@{Name='Load balancing (breadth first / depth first)';Id='loadBalancerType'},
        [pscustomobject]@{Name='Custom RDP properties (merge or remove individual entries)';Id='customRdpProperty'},
        [pscustomobject]@{Name='RDP Shortpath transport options';Id='Shortpath'},
        [pscustomobject]@{Name='Host pool friendly name (Azure management)';Id='friendlyName'},
        [pscustomobject]@{Name='Description';Id='description'},
        [pscustomobject]@{Name='Validation environment (early AVD service updates)';Id='validationEnvironment'},
        [pscustomobject]@{Name='Public network access (requires correct Private Link design)';Id='publicNetworkAccess'},
        [pscustomobject]@{Name='Remote desktop friendly name (Windows App / Remote Desktop)';Id='DesktopFriendlyName'},
        [pscustomobject]@{Name='Workspace friendly name (Windows App / Remote Desktop)';Id='WorkspaceFriendlyName'},
        [pscustomobject]@{Name='Start VM on Connect (enable/disable and verify service permissions)';Id='startVMOnConnect'}
    )
    if ($pool.properties.hostPoolType -eq 'Personal') {
        $items=@($items | Where-Object Id -notin @('maxSessionLimit','loadBalancerType'))
        $items += [pscustomobject]@{Name='Personal desktop assignment (Automatic / Direct)';Id='personalDesktopAssignmentType'}
    }
    $selected=@(if ($StartOnConnectOnly) { $items | Where-Object Id -eq 'startVMOnConnect' } else { Select-Multiple $items 'Select host pool settings to change' })
    if (-not $selected.Count) { return }
    $changeDesktopName=@($selected | Where-Object Id -eq 'DesktopFriendlyName').Count -gt 0
    $changeWorkspaceName=@($selected | Where-Object Id -eq 'WorkspaceFriendlyName').Count -gt 0
    $selected=@($selected | Where-Object Id -notin @('DesktopFriendlyName','WorkspaceFriendlyName'))
    if (-not $selected.Count) {
        if ($changeDesktopName) { Set-AvdDesktopFriendlyName $Deployment }
        if ($changeWorkspaceName) { Set-AvdWorkspaceFriendlyName $Deployment }
        return
    }
    Write-Warning 'Changes affect the selected pool and future connections. Existing sessions are not migrated or forcibly signed out. Reducing the session limit does not disconnect existing users.'
    foreach ($item in $selected) {
        switch ($item.Id) {
            'personalDesktopAssignmentType' {
                Write-Host 'Automatic assigns an available desktop on first connection. Direct requires assigning each user to a host in the Azure portal. Existing assignments are retained.'
                $changes.personalDesktopAssignmentType=(Select-Item @([pscustomobject]@{Name='Automatic';Id='Automatic'},[pscustomobject]@{Name='Direct';Id='Direct'}) 'Personal desktop assignment').Id
            }
            'startVMOnConnect' {
                Confirm-Permission $Deployment.Id @('Microsoft.DesktopVirtualization/hostPools/read','Microsoft.DesktopVirtualization/hostPools/write') @($script:Roles.Contributor)
                Write-Host "Current Start VM on Connect: $($pool.properties.startVMOnConnect). Enabling permits user connections to start powered-off hosts; it does not stop VMs. Disabling does not stop running hosts or remove service role assignments."
                $enable=(Read-Value 'Enable Start VM on Connect? (Y/N)' 'Y' '^[YyNn]$') -eq 'Y'
                if ($enable) {
                    $null=Confirm-AvdScalingPool $Deployment -AllowPersonal
                    $powerScopes=@($Deployment.Id -replace '/providers/Microsoft.DesktopVirtualization/hostPools/[^/]+$','')
                    $powerScopes+=@(Get-ArmList "$($Deployment.Id)/sessionHosts?api-version=$script:AvdApi" | ForEach-Object { $_.properties.resourceId -replace '/providers/Microsoft.HybridCompute/machines/[^/]+$','' })
                    foreach ($powerScope in @($powerScopes | Select-Object -Unique)) { Confirm-AvdScalingPowerRole -PowerOnOnly -RoleScope $powerScope }
                    Write-Host 'Start VM on Connect can increase connection wait time while a host boots. Pooled hosts start at most once per five minutes; test a real Windows App connection after RBAC propagation.'
                }
                $changes.startVMOnConnect=$enable
            }
            'maxSessionLimit' {
                if ($pool.properties.hostPoolType -ne 'Pooled') { throw 'Maximum session count editing requires a pooled host pool.' }
                $limitText=Read-Value 'Maximum concurrent sessions per host' ([string]$pool.properties.maxSessionLimit) '^\d{1,10}$'
                $limit=0
                if (-not [int]::TryParse($limitText,[ref]$limit) -or $limit -lt 1) { throw 'Session limit must be between 1 and 2147483647.' }
                $changes.maxSessionLimit=$limit
            }
            'loadBalancerType' {
                if ($pool.properties.hostPoolType -ne 'Pooled') { throw 'Load balancing editing requires a pooled host pool.' }
                $changes.loadBalancerType=(Select-Item @([pscustomobject]@{Name='BreadthFirst'},[pscustomobject]@{Name='DepthFirst'}) 'Load balancing').Name
            }
            'customRdpProperty' {
                $rdp=[string]$pool.properties.customRdpProperty
                do {
                    Write-Host "Current RDP properties: $rdp"
                    Write-Host 'Examples: redirectclipboard:i:0, use multimon:i:1. Preserve targetisaadjoined/enablerdsaadauth unless changing the validated sign-in design.'
                    $mode=Read-Value 'RDP operation (Set/Remove)' 'Set' '^(Set|Remove)$'
                    if ($mode -eq 'Set') { $rdp=Set-AvdRdpEntry $rdp (Read-Value 'One RDP property:type:value entry' '') }
                    else { $rdp=Set-AvdRdpEntry $rdp -RemoveName (Read-Value 'Exact RDP property name to remove' '') }
                } while ((Read-Value 'Edit another RDP property? (Y/N)' 'N' '^[YyNn]$') -eq 'Y')
                $changes.customRdpProperty=$rdp
            }
            'Shortpath' {
                Write-Host 'These are host-pool transport switches. Managed listener mode also needs the listener and UDP firewall rule on each host; client routing and firewall policies must permit UDP. Enabling a pool switch alone does not validate a UDP connection.'
                foreach ($option in @(@{Key='managedPrivateUDP';Name='Managed network listener'},@{Key='directUDP';Name='Private network ICE/STUN'},@{Key='publicUDP';Name='Public network ICE/STUN'},@{Key='relayUDP';Name='Public network TURN relay'})) {
                    $current=[string]$pool.properties.($option.Key)
                    $value=Read-Value "$($option.Name): Unchanged/Default/Enabled/Disabled (current: $current)" 'Unchanged' '^(Unchanged|Default|Enabled|Disabled)$'
                    if ($value -ne 'Unchanged') { $changes[$option.Key]=@('Default','Enabled','Disabled') | Where-Object { $_ -eq $value } }
                }
            }
            'validationEnvironment' { $changes.validationEnvironment=((Read-Value 'Enable early service updates for this validation pool? (Y/N)' 'N' '^[YyNn]$') -eq 'Y') }
            'publicNetworkAccess' {
                Write-Warning 'Restricting public access can prevent clients or hosts from connecting unless the corresponding private endpoints and DNS are already working.'
                $defaultAccess=if ($pool.properties.publicNetworkAccess) { [string]$pool.properties.publicNetworkAccess } else { 'Enabled' }
                $value=Read-Value 'Public access: Enabled/Disabled/EnabledForSessionHostsOnly/EnabledForClientsOnly' $defaultAccess '^(Enabled|Disabled|EnabledForSessionHostsOnly|EnabledForClientsOnly)$'
                $changes.publicNetworkAccess=@('Enabled','Disabled','EnabledForSessionHostsOnly','EnabledForClientsOnly') | Where-Object { $_ -eq $value }
            }
            default { $changes[$item.Id]=Read-Value $item.Name ([string]$pool.properties.($item.Id)) '^.{0,1024}$' }
        }
    }
    if (-not $changes.Count) {
        if ($changeDesktopName) { Set-AvdDesktopFriendlyName $Deployment }
        if ($changeWorkspaceName) { Set-AvdWorkspaceFriendlyName $Deployment }
        return
    }
    $before=[ordered]@{}
    foreach ($key in $changes.Keys) { $before[$key]=$pool.properties.$key; Write-Host "${key}: '$($before[$key])' -> '$($changes[$key])'" }
    if ((Read-Value 'Apply these host pool changes? (Y/N)' 'N' '^[YyNn]$') -ne 'Y') { return }
    Confirm-Permission $Deployment.Id @('Microsoft.DesktopVirtualization/hostPools/read','Microsoft.DesktopVirtualization/hostPools/write') @($script:Roles.Contributor)
    $latest=Invoke-Arm "$($Deployment.Id)?api-version=$api"
    foreach ($key in $changes.Keys) { if (($latest.properties.$key | ConvertTo-Json -Compress) -ne ($before[$key] | ConvertTo-Json -Compress)) { throw 'A selected property changed since review. Reload the menu before applying changes.' } }
    $directory=Join-Path $OutputDirectory ('settings-'+[guid]::NewGuid().ToString('N'))
    $null=New-Item -ItemType Directory -Path $directory -Force
    $record=[ordered]@{hostPoolId=$Deployment.Id;apiVersion=$api;before=$before;requested=$changes;status='Submitting'}
    $path=Join-Path $directory 'settings.json'
    $record | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $path -Encoding UTF8
    Write-Host "Configuration tracking: $path"
    $null=Invoke-Arm "$($Deployment.Id)?api-version=$api" PATCH @{properties=$changes}
    $deadline=[datetime]::UtcNow.AddMinutes(5)
    do {
        $updated=Invoke-Arm "$($Deployment.Id)?api-version=$api"
        $mismatch=@($changes.Keys | Where-Object { [string]$updated.properties.$_ -cne [string]$changes[$_] })
        if (-not $mismatch.Count) { $record.status='Succeeded'; break }
        Write-Event 'Waiting for host pool properties to match the requested values.'
        Start-Sleep -Seconds 15
    } while ([datetime]::UtcNow -lt $deadline)
    if ($record.status -ne 'Succeeded') { $record.status='Unverified' }
    $record | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $path -Encoding UTF8
    Write-Host "Host pool configuration: $($record.status). Before/after record: $path"
    if ($changeDesktopName -and $record.status -eq 'Succeeded') { Set-AvdDesktopFriendlyName $Deployment }
    if ($changeWorkspaceName -and $record.status -eq 'Succeeded') { Set-AvdWorkspaceFriendlyName $Deployment }
}

#endregion

#region Session host and deployment removal
function Assert-AvdCleanupResource {
    param([string]$ResourceId,[string[]]$AllowedOwners=@())
    $pattern='(?i)^/subscriptions/'+[regex]::Escape($script:Subscription)+'/resourceGroups/[^/]+/providers/Microsoft\.AzureStackHCI/(networkInterfaces|virtualHardDisks)/[^/]+$'
    if ($ResourceId -notmatch $pattern) { throw "Not an attached Azure Local NIC/disk in this subscription: $ResourceId" }
    # Authoritative reads, not names or eventually consistent Resource Graph results.
    $machines=@(Get-ArmList "$script:SubscriptionScope/providers/Microsoft.HybridCompute/machines?api-version=$script:ArcApi")
    foreach ($machine in $machines) {
        $instanceId="$($machine.id)/providers/Microsoft.AzureStackHCI/virtualMachineInstances/default"
        $instance=Invoke-Arm "$instanceId`?api-version=$script:HciApi" -AllowNotFound
        if (-not $instance) { continue }
        $references=@($instance.properties.networkProfile.networkInterfaces | ForEach-Object id)+@($instance.properties.storageProfile.dataDisks | ForEach-Object id)+@($instance.properties.storageProfile.osDisk.id)
        if ($ResourceId -in $references -and $instanceId -notin $AllowedOwners) { throw "Resource is attached to another VM and cannot be deleted: $ResourceId" }
    }
}

function Get-AvdRemovalPermissionScopes {
    param([object]$Deployment)
    $groups=@(Get-ArmList "$script:SubscriptionScope/providers/Microsoft.DesktopVirtualization/applicationGroups?api-version=$script:AvdApi" | Where-Object { $_.properties.hostPoolArmPath -eq $Deployment.Id })
    $groupIds=@($groups | ForEach-Object id)
    $workspaces=@(Get-ArmList "$script:SubscriptionScope/providers/Microsoft.DesktopVirtualization/workspaces?api-version=$script:AvdApi" | Where-Object { @($_.properties.applicationGroupReferences | Where-Object { $_ -in $groupIds }).Count })
    $ids=@($Deployment.Id)+$groupIds+@($workspaces | ForEach-Object id)+@(Get-AvdScalingPlans $Deployment.Id | ForEach-Object id)
    $hosts=@(Get-ArmList "$($Deployment.Id)/sessionHosts?api-version=$script:AvdApi")
    foreach ($sessionHost in $hosts) {
        $machineId=[string]$sessionHost.properties.resourceId
        if ($machineId -notmatch ('(?i)^'+[regex]::Escape($script:SubscriptionScope)+'/resourceGroups/[^/]+/providers/Microsoft.HybridCompute/machines/[^/]+$')) { throw 'Removal requires Azure Local machines in the selected subscription.' }
        $ids+=$machineId
        $instance=Invoke-Arm "$machineId/providers/Microsoft.AzureStackHCI/virtualMachineInstances/default?api-version=$script:HciApi" -AllowNotFound
        if ($instance) { $ids+=@($instance.properties.networkProfile.networkInterfaces | ForEach-Object id)+@($instance.properties.storageProfile.dataDisks | ForEach-Object id)+@($instance.properties.storageProfile.osDisk.id) }
    }
    $scopes=@($ids | Where-Object { $_ } | ForEach-Object {
        if ($_ -notmatch ('(?i)^('+[regex]::Escape($script:SubscriptionScope)+'/resourceGroups/[^/]+)/providers/')) { throw 'A related resource is outside the selected subscription.' }
        $Matches[1].ToLowerInvariant()
    } | Sort-Object -Unique)
    return [pscustomobject]@{Scopes=$scopes;HasHosts=($hosts.Count -gt 0)}
}

function Confirm-AvdRemovalPermissions {
    param([object]$Deployment)
    $reads=@('Microsoft.DesktopVirtualization/applicationGroups/read','Microsoft.DesktopVirtualization/workspaces/read','Microsoft.DesktopVirtualization/scalingPlans/read','Microsoft.HybridCompute/machines/read','Microsoft.AzureStackHCI/virtualMachineInstances/read')
    $actions=@('Microsoft.DesktopVirtualization/hostPools/read','Microsoft.DesktopVirtualization/hostPools/delete','Microsoft.DesktopVirtualization/hostPools/sessionHosts/read','Microsoft.DesktopVirtualization/hostPools/sessionHosts/write','Microsoft.DesktopVirtualization/hostPools/sessionHosts/delete','Microsoft.DesktopVirtualization/hostPools/sessionHosts/userSessions/read',
        'Microsoft.DesktopVirtualization/applicationGroups/read','Microsoft.DesktopVirtualization/applicationGroups/delete','Microsoft.DesktopVirtualization/workspaces/read','Microsoft.DesktopVirtualization/workspaces/write','Microsoft.DesktopVirtualization/workspaces/delete','Microsoft.DesktopVirtualization/scalingPlans/read','Microsoft.DesktopVirtualization/scalingPlans/write','Microsoft.DesktopVirtualization/scalingPlans/delete',
        'Microsoft.HybridCompute/machines/read','Microsoft.HybridCompute/machines/delete','Microsoft.HybridCompute/machines/runCommands/read','Microsoft.HybridCompute/machines/runCommands/write','Microsoft.HybridCompute/machines/runCommands/delete','Microsoft.AzureStackHCI/virtualMachineInstances/read','Microsoft.AzureStackHCI/virtualMachineInstances/delete','Microsoft.AzureStackHCI/networkInterfaces/read','Microsoft.AzureStackHCI/networkInterfaces/delete','Microsoft.AzureStackHCI/virtualHardDisks/read','Microsoft.AzureStackHCI/virtualHardDisks/delete',
        'Microsoft.Resources/subscriptions/resourceGroups/read','Microsoft.Resources/subscriptions/resourceGroups/delete','Microsoft.Resources/subscriptions/resourceGroups/resources/read')
    Write-Host 'Checking removal permissions with the CURRENT SPN. No administrator sign-in is used for these checks.'
    $script:RemovalPermissionProof=$null
    $inventory=$null;$repair=$false;$checkResults=@()
    try {
        $inventory=Get-AvdRemovalPermissionScopes $Deployment
        $checkResults+='[OK] Related resource inventory read with the current SPN.'
    } catch { $repair=$true;$checkResults+="[FAILED] Resource inventory could not be verified: $($_.Exception.Message)" }
    $targets=@([pscustomobject]@{Scope=$script:SubscriptionScope;Actions=$reads})
    if ($inventory) { $targets+=@($inventory.Scopes | ForEach-Object { [pscustomobject]@{Scope=$_;Actions=$actions} }) }
    foreach ($target in $targets) {
        try {
            $missing=@(Get-MissingAction $target.Scope $target.Actions)
            if ($missing.Count) {
                $repair=$true
                $checkResults+="[FAILED] Missing or unverified at $($target.Scope):"
                $checkResults+=@($missing | ForEach-Object { "[FAILED]   $_" })
            } else { $checkResults+="[OK] Required actions verified at $($target.Scope)" }
        } catch { $repair=$true;$checkResults+="[FAILED] Permission query failed at $($target.Scope): $($_.Exception.Message)" }
    }
    $graphMissing=($null -eq $inventory -or $inventory.HasHosts) -and -not (Test-EntraDeviceDeleteAccess)
    if ($graphMissing) { $checkResults+='[FAILED] Graph Device.ReadWrite.All is missing or could not be verified with the current SPN.' }
    elseif ($inventory.HasHosts) { $checkResults+='[OK] Graph Device.ReadWrite.All verified with the current SPN.' }
    else { $checkResults+='[OK] No session hosts: Graph device deletion access is not required.' }
    Show-AvdPanel 'REMOVAL PERMISSION CHECK | CURRENT SPN' $checkResults
    if (-not $repair -and -not $graphMissing) { $script:RemovalPermissionProof=[pscustomobject]@{Principal=$script:SpnObjectId;Tenant=$script:Tenant;Targets=$targets;Graph=([bool]$inventory.HasHosts);VerifiedUtc=[datetime]::UtcNow}; Write-Host '[OK] All removal permissions are effective.' -ForegroundColor Green; return }
    Write-Host 'Removal repair uses subscription Reader for complete discovery, Contributor on related resource groups (including permissions beyond deletion), and Device.ReadWrite.All for Entra device cleanup when hosts exist.'
    Write-Host 'One authorized account must be able to grant Azure RBAC and, if needed, tenant-wide Graph application consent (Global Administrator / Privileged Role Administrator). No subscription Owner role is granted to the SPN.'
    if ($inventory) { Show-AvdPanel 'Related resource groups' $inventory.Scopes }
    if ((Read-Value 'Repair the missing or unverified permissions shown above with an authorized user? (Y/N)' 'N' '^[YyNn]$') -ne 'Y') { throw 'Removal permission preparation cancelled. No administrator sign-in was started.' }
    $inventory=Invoke-AlternateUser {
        $discovered=Get-AvdRemovalPermissionScopes $Deployment
        Show-AvdPanel 'Grant removal permissions to the current SPN' (@("SPN: $script:SpnObjectId","Reader: $script:SubscriptionScope") + @($discovered.Scopes | ForEach-Object { "Contributor: $_" }) + @("Graph Device.ReadWrite.All consent needed: $($discovered.HasHosts -and $graphMissing)"))
        if ((Read-Value 'Apply this complete permission set? (Y/N)' 'N' '^[YyNn]$') -ne 'Y') { throw 'Permission grants cancelled.' }
        Grant-Role $script:SubscriptionScope $script:SpnObjectId $script:Roles.Reader
        foreach ($scope in $discovered.Scopes) { Grant-Role $scope $script:SpnObjectId $script:Roles.Contributor }
        if ($discovered.HasHosts -and $graphMissing) { Grant-AvdDeviceDeletePermission }
        $discovered
    }
    if ($inventory.HasHosts -and $graphMissing) {
        $secret=if ($env:AZSHCI_SPN_SECRET -and $env:AZSHCI_SPN_APP_ID -eq $script:SpnContext.Account.Id -and $env:AZSHCI_TENANT_ID -eq $script:Tenant) { ConvertTo-SecureString $env:AZSHCI_SPN_SECRET -AsPlainText -Force } else { Read-Host 'SPN secret for fresh Graph verification' -AsSecureString }
        try {
            $credential=[pscredential]::new($script:SpnContext.Account.Id,$secret)
            $null=Connect-AzAccount -ServicePrincipal -Tenant $script:Tenant -Subscription $script:Subscription -Credential $credential -Scope Process -Force
            $script:SpnContext=Get-AzContext
        } finally { $secret=$null;$credential=$null }
    }
    $deadline=[datetime]::UtcNow.AddMinutes(10)
    do {
        $pending=@()
        try {
            $pending+=@(Get-MissingAction $script:SubscriptionScope $reads)
            foreach ($scope in $inventory.Scopes) { $pending+=@(Get-MissingAction $scope $actions) }
            if ($inventory.HasHosts -and -not (Test-EntraDeviceDeleteAccess)) { $pending+='Graph Device.ReadWrite.All' }
        } catch { $pending+='Permission verification unavailable';Write-Verbose $_.Exception.Message }
        if (-not $pending.Count) { $targets=@([pscustomobject]@{Scope=$script:SubscriptionScope;Actions=$reads})+@($inventory.Scopes | ForEach-Object { [pscustomobject]@{Scope=$_;Actions=$actions} }); $script:RemovalPermissionProof=[pscustomobject]@{Principal=$script:SpnObjectId;Tenant=$script:Tenant;Targets=$targets;Graph=([bool]$inventory.HasHosts);VerifiedUtc=[datetime]::UtcNow}; Write-Host '[OK] Complete removal permission set verified.' -ForegroundColor Green; return }
        Write-Verbose ($pending -join ', ');Start-Sleep -Seconds $PollSeconds
    } while ([datetime]::UtcNow -lt $deadline)
    throw 'Removal permissions are still missing or unverified after propagation. No deletion started; review conditions/denies or retry later. No second admin login was requested.'
}

function Resolve-AvdRemovalDevice {
    param([object]$Machine,[object]$SessionHost,[string]$ComputerName,[int]$Sequence)
    if ($Machine -and $Machine.properties.status -eq 'Connected') {
        $identity=$null
        try { $identity=Get-SessionHostEntraIdentity $Machine $Sequence } catch { Write-Verbose "Guest identity unavailable: $($_.Exception.Message). Searching directory inventory." }
        if ($identity) {
            if ($identity.tenantId -ne $script:Tenant) { throw 'The guest belongs to a different Entra tenant.' }
            $devices=@(Get-GraphList "/devices?`$filter=deviceId eq '$($identity.deviceId)'&`$select=id,deviceId,displayName,trustType")
            if ($devices.Count -gt 1) { throw 'Duplicate Entra device identity.' }
            if ($devices.Count) { return $devices[0] }
            Write-Host '[INFO] The verified guest DeviceId is absent from Entra. Entra deletion will be skipped.'
            return $null
        }
    }
    $names=@($ComputerName,($SessionHost.name -split '/')[-1]) | Where-Object { $_ } | Select-Object -Unique
    $devices=@(foreach ($candidateName in $names) {
        $escaped=$candidateName.Replace("'","''")
        Get-GraphList "/devices?`$filter=displayName eq '$escaped'&`$select=id,deviceId,displayName,trustType"
    }) | Sort-Object id -Unique
    if (-not $devices.Count) {
        Write-Host "[INFO] No Entra device matched '$ComputerName'. Azure cleanup can continue; Entra deletion will be skipped."
        return $null
    }
    $choices=@($devices | ForEach-Object { [pscustomobject]@{Name="$($_.displayName) | $($_.trustType) | DeviceId=$($_.deviceId) | ObjectId=$($_.id)";Device=$_} })
    Write-Host 'These directory candidates match the computer name, not a verified guest DeviceId. Review the identity before authorizing deletion.'
    $choices+= [pscustomobject]@{Name='Keep Entra devices; continue with Azure resources only';Device=$null}
    return (Select-Item $choices 'Select the verified Entra device to remove (or keep all)' -DefaultIndex ($choices.Count-1)).Device
}

function Assert-AvdRemovalSessions {
    param([object]$Record)
    if ($Record.manualVmDeletionConfirmed) {
        $machine=Invoke-Arm "$($Record.machineId)?api-version=$script:ArcApi" -AllowNotFound
        if ($machine -and $machine.properties.status -eq 'Connected') { throw 'Arc reports the machine connected again. Manual-deletion cleanup stopped.' }
        $instance=Invoke-Arm "$($Record.instanceId)?api-version=$script:HciApi" -AllowNotFound
        if ($instance -and $instance.properties.osProfile.computerName -ne $Record.deviceName) { throw 'The VM computer identity changed. Cleanup stopped.' }
        $registration=Invoke-Arm "$($Record.sessionHostId)?api-version=$script:AvdApi"
        if ($registration.properties.resourceId -ne $Record.machineId -or $registration.properties.virtualMachineId -ne $Record.avdVirtualMachineId) { throw 'The AVD host identity changed. Cleanup stopped.' }
        # Operator attestation covers a VM deleted locally whose Azure instance still exists.
        # The normal ARM VM deletion must still succeed before Entra/AVD cleanup proceeds.
        return
    }
    if ($Record.vmAlreadyDeleted) {
        if (Invoke-Arm "$($Record.instanceId)?api-version=$script:HciApi" -AllowNotFound) { throw 'The VM instance exists again. Stale-registration cleanup stopped.' }
        return
    }
    if (@(Get-ArmList "$($Record.sessionHostId)/userSessions?api-version=$script:AvdApi").Count) { throw "Sessions remain on $($Record.name). Hosts remain drained; no VM deletion started. Sign users out and retry. A saved or offline VM is not proof that its sessions can be discarded." }
}

function New-AvdHostRemovalPlan {
    param([object]$Deployment,[switch]$AllHosts)
    $hosts=@(Get-ArmList "$($Deployment.Id)/sessionHosts?api-version=$script:AvdApi")
    $selected=@(if ($AllHosts) { $hosts } else { Select-Multiple $hosts 'Select session hosts to permanently remove' -AllowAll })
    if (-not $selected.Count) { return }
    Write-Warning 'Deletes the selected AVD registration, Azure Local VM, Arc machine and verified Entra device. VM-local data can be lost. You can also permanently delete the attached NICs and disks below. Shared infrastructure, images and FSLogix shares are outside this deletion.'
    Confirm-EntraDeviceDeleteAccess
    $runId=(Get-Date -Format 'yyyyMMddHHmmss')+'-'+[guid]::NewGuid().ToString('N').Substring(0,6)
    $folder=Join-Path $OutputDirectory ('remove-'+$runId)
    $null=New-Item -ItemType Directory -Path $folder -Force
    $script:RunFile=Join-Path $folder 'run.json'
    $script:Run=[pscustomobject]@{runId=$runId;subscriptionId=$script:Subscription;tenantId=$script:Tenant;hostPoolId=$Deployment.Id;sessionHosts=@();deployments=@();guestTasks=@();registrationSubmitted=$false;status='RemovalPreflight';updatedUtc='';removals=@()}
    Save-Run
    $sequence=0
    foreach ($sessionHost in $selected) {
        if ([string]$sessionHost.id -notlike "$($Deployment.Id)/sessionHosts/*") { throw 'Session host does not belong to the selected pool.' }
        $machineId=[string]$sessionHost.properties.resourceId
        if ($machineId -notmatch ('(?i)^/subscriptions/'+[regex]::Escape($script:Subscription)+'/resourceGroups/[^/]+/providers/Microsoft\.HybridCompute/machines/[^/]+$')) { throw 'Removal requires an exact Arc machine ID in the selected subscription.' }
        $machine=Invoke-Arm "$machineId`?api-version=$script:ArcApi" -AllowNotFound
        $instanceId="$machineId/providers/Microsoft.AzureStackHCI/virtualMachineInstances/default"
        $instance=Invoke-Arm "$instanceId`?api-version=$script:HciApi" -AllowNotFound
        $vmAlreadyDeleted=$null -eq $instance
        $manualVmDeletionConfirmed=$false
        if ($vmAlreadyDeleted) {
            Write-Host "Azure no longer returns the VM instance for $($sessionHost.name). Stale AVD session records may still exist."
            Write-Host 'Verify the VM was permanently deleted from Azure Local, not merely saved, stopped or disconnected. This cleanup can discard its remaining AVD session records.'
            if ((Read-Value 'Confirm the VM was permanently deleted and authorize stale registration cleanup? (Y/N)' 'N' '^[YyNn]$') -ne 'Y') { throw 'Missing-VM cleanup was not confirmed. Nothing was deleted.' }
        }
        elseif (-not $machine -or $machine.properties.status -ne 'Connected') {
            Write-Host 'Azure still has VM metadata, but Arc is not connected. Normal removal preserves existing sessions.'
            if ((Read-Value 'Was this VM permanently deleted manually from the Azure Local cluster? (Y/N)' 'N' '^[YyNn]$') -eq 'Y') {
                $expectedName=[string]$instance.properties.osProfile.computerName
                if (-not $expectedName) { throw 'Cannot verify the original VM computer name for manual-deletion cleanup.' }
                Write-Host "Only confirm if '$expectedName' was deleted, not merely stopped or saved. Remaining AVD session records will be discarded. Azure VM metadata, Arc and the verified Entra device will be deleted."
                $typed=Read-Value 'Type the VM computer name to confirm permanent local deletion, or CANCEL' 'CANCEL' ('^('+[regex]::Escape($expectedName)+'|CANCEL)$')
                if ($typed -eq 'CANCEL') { $script:Run.status='Cancelled'; Save-Run; return }
                $manualVmDeletionConfirmed=$true
            }
        }
        Confirm-Permission $machineId @('Microsoft.HybridCompute/machines/read','Microsoft.HybridCompute/machines/delete','Microsoft.AzureStackHCI/virtualMachineInstances/read','Microsoft.AzureStackHCI/virtualMachineInstances/delete') @($script:Roles.Contributor)
        Confirm-Permission $sessionHost.id @('Microsoft.DesktopVirtualization/hostPools/sessionHosts/read','Microsoft.DesktopVirtualization/hostPools/sessionHosts/write','Microsoft.DesktopVirtualization/hostPools/sessionHosts/delete','Microsoft.DesktopVirtualization/hostPools/sessionHosts/userSessions/read') @($script:Roles.Contributor)
        $sequence++
        $computerName=[string]$instance.properties.osProfile.computerName
        if (-not $computerName) { $computerName=(($sessionHost.name -split '/')[-1] -split '\.')[0] }
        $device=Resolve-AvdRemovalDevice $(if ($vmAlreadyDeleted) { $null } else { $machine }) $sessionHost $computerName $sequence
        if ($device -and (($device.displayName -split '\.')[0] -ne $computerName)) { throw 'Device name does not match the VM computer name. Verify identity before removal.' }
        if (@($script:Run.removals | Where-Object { ($device -and $_.deviceObjectId -eq $device.id) -or $_.machineId -eq $machineId }).Count) { throw 'Duplicate machine or Entra device in removal selection.' }
        $retained=@($instance.properties.networkProfile.networkInterfaces | ForEach-Object id)+@($instance.properties.storageProfile.dataDisks | ForEach-Object id)+@($instance.properties.storageProfile.osDisk.id)
        $cleanup=@()
        foreach ($associatedId in @($retained | Where-Object { $_ } | Select-Object -Unique)) {
            Write-Host "Attached resource: $associatedId"
            if ((Read-Value 'Permanently delete this attached NIC/disk and all data it contains? (Y/N)' 'N' '^[YyNn]$') -eq 'Y') {
                Write-Host 'Checking for shared attachments requires read access to Arc machines and Azure Local VM instances across this subscription.'
                Confirm-Permission $script:SubscriptionScope @('Microsoft.HybridCompute/machines/read','Microsoft.AzureStackHCI/virtualMachineInstances/read') @($script:Roles.Reader)
                $selectedOwners=@($selected | ForEach-Object { "$($_.properties.resourceId)/providers/Microsoft.AzureStackHCI/virtualMachineInstances/default" })
                Assert-AvdCleanupResource $associatedId $selectedOwners
                $resourceType=if ($associatedId -match '/networkInterfaces/') { 'networkInterfaces' } else { 'virtualHardDisks' }
                Confirm-Permission $associatedId @("Microsoft.AzureStackHCI/$resourceType/read","Microsoft.AzureStackHCI/$resourceType/delete") @($script:Roles.Contributor)
                $cleanup += [pscustomobject]@{id=$associatedId;status='Prepared'}
            }
        }
        $record=[pscustomobject]@{name=$sessionHost.name;sessionHostId=$sessionHost.id;machineId=$machineId;instanceId=$instanceId;deviceId=$device.deviceId;deviceObjectId=$device.id;deviceName=$computerName;cleanupResources=$cleanup;retainedResources=@($retained | Where-Object { $_ -and $_ -notin @($cleanup | ForEach-Object id) });stage='Prepared';error=''}
        $record | Add-Member -NotePropertyName entraDeletionStatus -NotePropertyValue $(if ($device) { 'Prepared' } else { 'SkippedNoDeviceSelected' })
        $record | Add-Member -NotePropertyName vmAlreadyDeleted -NotePropertyValue $vmAlreadyDeleted
        $record | Add-Member -NotePropertyName manualVmDeletionConfirmed -NotePropertyValue $manualVmDeletionConfirmed
        $record | Add-Member -NotePropertyName avdVirtualMachineId -NotePropertyValue $sessionHost.properties.virtualMachineId
        if ($vmAlreadyDeleted) { Write-Host 'The deleted VM no longer exposes its attachment inventory. Previously detached NICs/disks are not automatically selected; inspect the earlier removal run before cleaning those resources.' }
        $script:Run.removals+= $record; Save-Run
        if (-not $device) { Write-Host "Entra deletion: SKIPPED for $computerName (no device selected/found)." }
        Write-Host "Remove $($record.name):`n  VM: $machineId`n  Entra: $($device.displayName) | deviceId=$($device.deviceId) | objectId=$($device.id)"
        foreach ($retainedId in $record.retainedResources) { Write-Host "  Retained associated resource: $retainedId" }
        foreach ($cleanupResource in $record.cleanupResources) { Write-Host "  DELETE resource and data: $($cleanupResource.id)" }
    }
    return [pscustomobject]@{Run=$script:Run;RunFile=$script:RunFile}
}

function Invoke-AvdHostRemovalPlan {
    param([object]$Plan)
    $script:Run=$Plan.Run; $script:RunFile=$Plan.RunFile

    if (-not (Test-EntraDeviceDeleteAccess)) { throw 'SPN device permissions changed. Removal stopped before draining.' }
    foreach ($record in $script:Run.removals) {
        $null=Invoke-Arm "$($record.sessionHostId)?api-version=$script:AvdApi" PATCH @{properties=@{allowNewSession=$false}}
        $record.stage='Drained'; Save-Run
    }
    foreach ($record in $script:Run.removals) {
        Assert-AvdRemovalSessions $record
    }
    $script:Run.status='Removing'; Save-Run
    foreach ($record in $script:Run.removals) {
        try {
            $device=if ($record.deviceObjectId) { @(Get-GraphList "/devices?`$filter=deviceId eq '$($record.deviceId)'&`$select=id,deviceId,displayName") | Select-Object -First 1 } else { $null }
            if ($device -and ($device.deviceId -ne $record.deviceId -or $device.id -ne $record.deviceObjectId)) { throw 'Device identity changed since preflight.' }
            Assert-AvdRemovalSessions $record
            $record.stage='DeletingVm'; Save-Run
            Remove-ArmResourceAndWait $record.instanceId $script:HciApi
            $record.stage='DeletingArcMachine'; Save-Run
            Remove-ArmResourceAndWait $record.machineId $script:ArcApi
            $record.stage='DeletingEntraDevice'; Save-Run
            if ($device) { $null=Invoke-Graph "/devices/$($record.deviceObjectId)" DELETE; $record.entraDeletionStatus='Deleted' } elseif ($record.deviceObjectId) { $record.entraDeletionStatus='AlreadyAbsent' }
            $record.stage='DeletingAvdRegistration'; Save-Run
            Remove-ArmResourceAndWait $record.sessionHostId $script:AvdApi -ForceStaleRegistration:([bool]($record.vmAlreadyDeleted -or $record.manualVmDeletionConfirmed))
            $record.stage='Succeeded'; Save-Run
            Write-Event "Removed $($record.name) and its VM. Entra cleanup: $($record.entraDeletionStatus)."
        } catch { $record.error=$_.Exception.Message; $script:Run.status='RemovalIncomplete'; Save-Run; throw }
    }
    # Remove attachments only after all selected VMs have finished deletion.
    foreach ($record in $script:Run.removals) {
        foreach ($resource in $record.cleanupResources) {
            try {
                Assert-AvdCleanupResource $resource.id
                $resource.status='Deleting'; Save-Run
                Remove-ArmResourceAndWait $resource.id $script:HciApi
                $resource.status='Succeeded'; Save-Run
            } catch { $resource.status='Failed'; $record.error=$_.Exception.Message; $script:Run.status='RemovalIncomplete'; Save-Run; throw }
        }
    }
    $script:Run.status='Succeeded'; Save-Run
    Write-Host "Removal complete. Retained-resource list and history: $script:RunFile"
}

function Remove-AvdSessionHost {
    param([object]$Deployment,[switch]$AllHosts)
    $plan=New-AvdHostRemovalPlan $Deployment -AllHosts:$AllHosts
    if (-not $plan) { return }
    if ((Read-Value 'Type DELETE to drain and permanently remove these exact hosts and Entra devices, or CANCEL' 'CANCEL' '^(DELETE|CANCEL)$') -ne 'DELETE') { $script:Run.status='Cancelled'; Save-Run; return }
    Invoke-AvdHostRemovalPlan $plan
}
function Remove-AvdDeployment {
    param([object]$Deployment)
    # Discover by resource relationships, never by a shared naming prefix or resource group.
    Confirm-Permission $script:SubscriptionScope @('Microsoft.DesktopVirtualization/applicationGroups/read','Microsoft.DesktopVirtualization/workspaces/read','Microsoft.DesktopVirtualization/scalingPlans/read') @($script:Roles.Reader)
    Confirm-Permission $Deployment.Id @('Microsoft.DesktopVirtualization/hostPools/read','Microsoft.DesktopVirtualization/hostPools/delete','Microsoft.DesktopVirtualization/hostPools/sessionHosts/read') @($script:Roles.Contributor)
    $pool=Invoke-Arm "$($Deployment.Id)?api-version=$script:AvdApi"
    $groups=@(Get-ArmList "$script:SubscriptionScope/providers/Microsoft.DesktopVirtualization/applicationGroups?api-version=$script:AvdApi" | Where-Object { $_.properties.hostPoolArmPath -eq $Deployment.Id })
    $groupIds=@($groups | ForEach-Object id)
    $workspaces=@(Get-ArmList "$script:SubscriptionScope/providers/Microsoft.DesktopVirtualization/workspaces?api-version=$script:AvdApi" | Where-Object { @($_.properties.applicationGroupReferences | Where-Object { $_ -in $groupIds }).Count })
    $plans=@(Get-AvdScalingPlans $Deployment.Id)
    $hosts=@(Get-ArmList "$($Deployment.Id)/sessionHosts?api-version=$script:AvdApi")
    $actions=@()
    foreach ($workspace in $workspaces) {
        $remaining=@($workspace.properties.applicationGroupReferences | Where-Object { $_ -notin $groupIds })
        $delete=$false
        if (-not $remaining.Count) { $delete=(Read-Value "Delete dedicated workspace '$($workspace.name)' as well? (Y/N)" 'N' '^[YyNn]$') -eq 'Y' }
        $verb=if ($delete) { 'delete' } else { 'write' }
        Confirm-Permission $workspace.id @('Microsoft.DesktopVirtualization/workspaces/read','Microsoft.DesktopVirtualization/workspaces/write',"Microsoft.DesktopVirtualization/workspaces/$verb") @($script:Roles.Contributor)
        $actions+=@{id=$workspace.id;kind='Workspace';delete=$delete;key='applicationGroupReferences';before=@($workspace.properties.applicationGroupReferences);remaining=$remaining;status='Prepared'}
    }
    foreach ($plan in $plans) {
        $remaining=@($plan.properties.hostPoolReferences | Where-Object hostPoolArmPath -ne $Deployment.Id)
        $delete=$false
        if (-not $remaining.Count) { $delete=(Read-Value "Delete dedicated scaling plan '$($plan.name)' and its schedules? (Y/N)" 'N' '^[YyNn]$') -eq 'Y' }
        Confirm-Permission $plan.id @('Microsoft.DesktopVirtualization/scalingPlans/read','Microsoft.DesktopVirtualization/scalingPlans/write') @($script:Roles.Contributor)
        if ($delete) { Confirm-Permission $plan.id @('Microsoft.DesktopVirtualization/scalingPlans/delete') @($script:Roles.Contributor) }
        $actions+=@{id=$plan.id;kind='ScalingPlan';delete=$delete;key='hostPoolReferences';before=@($plan.properties.hostPoolReferences);remaining=$remaining;status='Prepared'}
    }
    foreach ($group in $groups) { Confirm-Permission $group.id @('Microsoft.DesktopVirtualization/applicationGroups/read','Microsoft.DesktopVirtualization/applicationGroups/delete') @($script:Roles.Contributor) }
    if ($hosts.Count) { Confirm-EntraDeviceDeleteAccess }
    $poolScope=$Deployment.Id -replace '/providers/Microsoft.DesktopVirtualization/hostPools/[^/]+$',''
    $deleteEmptyGroup=(Read-Value 'Delete the host pool resource group too, ONLY if empty after cleanup? (Y/N)' 'N' '^[YyNn]$') -eq 'Y'
    if ($deleteEmptyGroup) { Confirm-Permission $poolScope @('Microsoft.Resources/subscriptions/resourceGroups/read','Microsoft.Resources/subscriptions/resourceGroups/delete','Microsoft.Resources/subscriptions/resourceGroups/resources/read') @($script:Roles.Contributor) }
    $lines=@("DELETE host pool: $($pool.id)","All $($hosts.Count) session hosts: VM, Arc machine, Entra device and AVD registration.",'The exact host, Entra device and attachment selections are listed below. No forced user logoff.')
    $lines+=@($groupIds | ForEach-Object { "DELETE application group: $_" })
    $lines+=@($actions | ForEach-Object { if ($_.delete) { "DELETE $($_.kind): $($_.id)" } else { "RETAIN $($_.kind), detach only this pool: $($_.id)" } })
    $lines+=@('Autoscale will be disabled for this pool before host removal. Shared plans retain their other pool references.','Shared infrastructure, images, profile shares and subscription/tenant permissions are retained.')
    $lines+=if ($deleteEmptyGroup) { "DELETE resource group only if empty: $poolScope. Do not deploy other resources into this group during cleanup." } else { "RETAIN resource group: $poolScope" }
    $hostPlan=$null
    if ($hosts.Count) {
        Show-AvdPanel 'PREPARE SESSION HOST REMOVAL' @('Resolve Entra identities and select optional NIC/disk cleanup.', 'No hosts will be drained or deleted until the final deployment review is confirmed.')
        $hostPlan=New-AvdHostRemovalPlan $Deployment -AllHosts
        if (-not $hostPlan) { return }
        $lines[1]="All $(@($hostPlan.Run.removals).Count) selected session hosts: VM, Arc machine, Entra device and AVD registration."
        foreach ($record in $hostPlan.Run.removals) {
            $lines+="DELETE session host: $($record.name)"
            $lines+="DELETE VM/Arc: $($record.machineId)"
            $lines+=if($record.deviceObjectId){"DELETE Entra device: $($record.deviceName) | ObjectId=$($record.deviceObjectId)"}else{'RETAIN/SKIP Entra: no verified device selected.'}
            $lines+=@($record.cleanupResources | ForEach-Object { "DELETE attached resource and data: $($_.id)" })
            $lines+=@($record.retainedResources | ForEach-Object { "RETAIN attached resource: $_" })
            if($record.vmAlreadyDeleted -or $record.manualVmDeletionConfirmed){$lines+='AUTHORIZED stale-session cleanup for this previously deleted VM.'}
        }
    }
    Show-AvdPanel 'REMOVE COMPLETE AVD DEPLOYMENT | FINAL REVIEW' $lines
    if ((Read-Value 'Type DELETE to execute this complete removal plan, or CANCEL' 'CANCEL' '^(DELETE|CANCEL)$') -ne 'DELETE') { if ($hostPlan) { $hostPlan.Run.status='Cancelled'; Save-Run }; return }
    $folder=New-AvdRunDirectory (Join-Path $OutputDirectory ('remove-pool-'+[guid]::NewGuid().ToString('N')))
    $tracking=Join-Path $folder 'run.json'
    $teardown=[pscustomobject]@{runId=[guid]::NewGuid().ToString('N');subscriptionId=$script:Subscription;tenantId=$script:Tenant;hostPoolId=$Deployment.Id;status='RemovingDeployment';updatedUtc='';deployments=@();sessionHosts=@();registrationSubmitted=$false;deploymentRemoval=[pscustomobject]@{actions=$actions;applicationGroups=@($groups | ForEach-Object { @{id=$_.id;status='Prepared'} });hostRemovalRun='';hostPoolStatus='Prepared'}}
    $teardown.deploymentRemoval | Add-Member -NotePropertyName resourceGroup -NotePropertyValue @{id=$poolScope;deleteIfEmpty=$deleteEmptyGroup;status='Retained'}
    $script:Run=$teardown; $script:RunFile=$tracking; Save-Run
    try {
        # Disable only the target association. Keep other pools and settings intact.
        foreach ($entry in @($actions | Where-Object kind -eq 'ScalingPlan')) {
            $current=Invoke-Arm "$($entry.id)?api-version=$script:AvdApi"
            if (($current.properties.hostPoolReferences | ConvertTo-Json -Depth 10 -Compress) -ne ($entry.before | ConvertTo-Json -Depth 10 -Compress)) { throw 'Scaling associations changed during review. Refresh and retry.' }
            $disabled=@($current.properties.hostPoolReferences | ForEach-Object { @{hostPoolArmPath=$_.hostPoolArmPath;scalingPlanEnabled=$(if ($_.hostPoolArmPath -eq $Deployment.Id) { $false } else { $_.scalingPlanEnabled })} })
            $null=Invoke-Arm "$($entry.id)?api-version=$script:AvdApi" PATCH @{properties=@{hostPoolReferences=$disabled}}
            $current=Invoke-Arm "$($entry.id)?api-version=$script:AvdApi"
            if (@($current.properties.hostPoolReferences | Where-Object { $_.hostPoolArmPath -eq $Deployment.Id -and $_.scalingPlanEnabled }).Count) { throw 'Autoscale disable is not effective yet. Retry after propagation.' }
            $entry.before=@($current.properties.hostPoolReferences); Save-Run
        }
        if ($hosts.Count) {
            try { Invoke-AvdHostRemovalPlan $hostPlan }
            finally {
                if ($script:RunFile -ne $tracking) { $teardown.deploymentRemoval.hostRemovalRun=$script:RunFile }
                $hostResult=$script:Run.status
                $script:Run=$teardown; $script:RunFile=$tracking; Save-Run
            }
            if ($hostResult -ne 'Succeeded') { $teardown.status='Cancelled'; Save-Run; return }
        }
        if (@(Get-ArmList "$($Deployment.Id)/sessionHosts?api-version=$script:AvdApi").Count) { throw 'Session hosts remain or new hosts appeared. The host pool was not deleted.' }
        foreach ($entry in $actions) {
            $current=Invoke-Arm "$($entry.id)?api-version=$script:AvdApi"
            if (($current.properties.($entry.key) | ConvertTo-Json -Depth 10 -Compress) -ne ($entry.before | ConvertTo-Json -Depth 10 -Compress)) { throw 'Resource associations changed after review. Shared resources were not modified.' }
            $entry.status='Submitting'; Save-Run
            $null=Invoke-Arm "$($entry.id)?api-version=$script:AvdApi" PATCH @{properties=@{($entry.key)=@($entry.remaining)}}
            $verified=Invoke-Arm "$($entry.id)?api-version=$script:AvdApi"
            if (($verified.properties.($entry.key) | ConvertTo-Json -Depth 10 -Compress) -ne ($entry.remaining | ConvertTo-Json -Depth 10 -Compress)) { throw 'Association removal could not be verified. Inspect tracking before retrying.' }
            if ($entry.delete) { $entry.status='Deleting'; Save-Run; Remove-ArmResourceAndWait $entry.id $script:AvdApi }
            $entry.status='Succeeded'; Save-Run
        }
        foreach ($entry in $teardown.deploymentRemoval.applicationGroups) {
            $current=Invoke-Arm "$($entry.id)?api-version=$script:AvdApi"
            if ($current.properties.hostPoolArmPath -ne $Deployment.Id) { throw 'Application group ownership changed. Deletion stopped.' }
            $entry.status='Deleting'; Save-Run
            Remove-ArmResourceAndWait $entry.id $script:AvdApi
            $entry.status='Succeeded'; Save-Run
        }
        $teardown.deploymentRemoval.hostPoolStatus='Deleting'; Save-Run
        Remove-ArmResourceAndWait $Deployment.Id $script:AvdApi
        $teardown.deploymentRemoval.hostPoolStatus='Succeeded'; Save-Run
        if ($deleteEmptyGroup) {
            if (@(Get-ArmList "$poolScope/resources?api-version=2021-04-01").Count) {
                Write-Host 'Resource group retained because it still contains resources.'
                $teardown.deploymentRemoval.resourceGroup.status='RetainedNonEmpty'
            } else {
                $teardown.deploymentRemoval.resourceGroup.status='Deleting'; Save-Run
                Remove-ArmResourceAndWait $poolScope '2022-09-01'
                $teardown.deploymentRemoval.resourceGroup.status='Succeeded'
            }
        }
        $teardown.status='Succeeded'; Save-Run
        Write-Host "[OK] Host pool and selected resources removed. Tracking: $tracking" -ForegroundColor Green
    } catch { $teardown.status='RemovalIncomplete'; Save-Run; Write-Host "[FAILED] Deployment removal incomplete. Tracking: $tracking" -ForegroundColor Red; throw }
}

#endregion

#region Guest task payloads and regional selection
function Get-GuestTaskPayload {
    param([object]$Task, [string]$CompletionMarker)
    $taskPath = Join-Path $script:GuestScriptsPath $Task.File
    $commonPath = Join-Path $script:GuestScriptsPath 'Common.ps1'
    if (-not (Test-Path -LiteralPath $taskPath -PathType Leaf) -or -not (Test-Path -LiteralPath $commonPath -PathType Leaf)) {
        throw 'The published guest task files are missing. Restore scripts/04AVD/SessionHostScripts.'
    }
    $tokens=$null; $errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile($taskPath,[ref]$tokens,[ref]$errors)
    if ($errors.Count -or -not $ast.ParamBlock) { throw "Guest task did not parse or has no parameter block: $($Task.File)" }
    $taskText=[IO.File]::ReadAllText($taskPath)
    $body=$taskText.Substring($ast.ParamBlock.Extent.EndOffset)
    $dotSourcePattern='(?m)^[ \t]*\.\s*\(Join-Path \$PSScriptRoot ''Common\.ps1''\)[ \t]*(?:\r?\n|$)'
    if ($body -notmatch $dotSourcePattern) { throw "Guest task does not use the approved shared helper: $($Task.File)" }
    $body=[regex]::Replace($body,$dotSourcePattern,'')
    $common=[IO.File]::ReadAllText($commonPath)
    $common=[regex]::Replace($common,'(?m)^#Requires[^\r\n]*(?:\r?\n|$)','')
    $prefix=$ast.ParamBlock.Extent.Text + "`r`n`$ErrorActionPreference = 'Stop'`r`n`$ConfirmPreference = 'None'`r`n`$script:AvdTaskStage = 'Starting task'`r`n"
    $resultCheck="if (-not `$taskResult -or `$taskResult.Status -ne 'Succeeded' -or `$taskResult.Task -ne '$($Task.ResultTask)') { throw 'Guest task did not report its expected successful result.' }`r`n"
    $resultOutput="Write-Output ('AVD_TASK_RESULT:' + (`$taskResult | ConvertTo-Json -Compress -Depth 5))`r`n"
    $diagnosticOutput="`$diagnosticMessage=([string]`$_.Exception.Message -replace '[\r\n]+',' ').Trim()`r`nWrite-Output ('AVD_TASK_DIAGNOSTIC:stage=' + `$script:AvdTaskStage + ';errorType=' + `$_.Exception.GetType().Name + ';message=' + `$diagnosticMessage)`r`n"
    return $prefix + $common + "`r`ntry {`r`n" + $body + "`r`n" + $resultCheck + $resultOutput + "Write-Output 'AVD_TASK_COMPLETED:$CompletionMarker'`r`n} catch {`r`n" + $diagnosticOutput + "Write-Output 'AVD_TASK_FAILED:$CompletionMarker'`r`nexit 1`r`n}`r`n"
}

function New-GuestTaskRunCommandTemplate {
    param([string]$Location, [string]$Payload, [System.Collections.IDictionary]$Parameters)
    $protected=@($Parameters.GetEnumerator() | ForEach-Object { @{name=[string]$_.Key;value=[string]$_.Value} })
    return @{location=$Location;properties=@{asyncExecution=$false;timeoutInSeconds=3600;source=@{script=$Payload};protectedParameters=$protected}}
}

function Select-WindowsLanguage {
    $commonTags=@('de-DE','en-US','en-GB','es-ES','fr-FR','it-IT','nl-NL','pt-PT')
    $common=@($commonTags | ForEach-Object {
        $culture=[Globalization.CultureInfo]::GetCultureInfo($_)
        [pscustomobject]@{Name="$($culture.Name) - $($culture.EnglishName)";Value=$culture.Name;Kind='Value'}
    })
    while ($true) {
        $choices=@($common)+@(
            [pscustomobject]@{Name='Search all Windows languages';Value='';Kind='Search'}
            [pscustomobject]@{Name='Enter a language tag manually';Value='';Kind='Manual'}
            [pscustomobject]@{Name='Do not change the Windows language';Value='';Kind='Skip'}
        )
        $selected=Select-Item $choices 'Select Windows language' 'Name' ($choices.Count-1)
        if ($selected.Kind -eq 'Value') { return $selected.Value }
        if ($selected.Kind -eq 'Skip') { return '' }
        if ($selected.Kind -eq 'Manual') {
            while ($true) {
                $tag=(Read-Host 'Windows language tag (for example de-DE)').Trim()
                try {
                    $culture=[Globalization.CultureInfo]::GetCultureInfo($tag)
                    if ($culture.IsNeutralCulture) { throw 'A region-specific language tag is required.' }
                    return $culture.Name
                } catch { Write-Warning 'Windows does not recognize that region-specific language tag.' }
            }
        }
        $term=(Read-Host 'Search language by tag or name').Trim()
        if (-not $term) { continue }
        $pattern=[regex]::Escape($term)
        $languageMatches=@([Globalization.CultureInfo]::GetCultures([Globalization.CultureTypes]::SpecificCultures) |
            Where-Object { $_.Name -match $pattern -or $_.EnglishName -match $pattern -or $_.NativeName -match $pattern } |
            Sort-Object EnglishName,Name)
        if (-not $languageMatches.Count) { Write-Warning 'No matching Windows languages were found.'; continue }
        if ($languageMatches.Count -gt 50) { Write-Host 'Showing the first 50 matches. Use a more specific search to narrow the list.' }
        $results=@($languageMatches | Select-Object -First 50 | ForEach-Object {
            [pscustomobject]@{Name="$($_.Name) - $($_.EnglishName)";Value=$_.Name}
        })
        return (Select-Item $results 'Select matching Windows language').Value
    }
}

function Select-WindowsTimeZone {
    $available=@(Get-TimeZone -ListAvailable)
    $commonIds=@('W. Europe Standard Time','GMT Standard Time','Romance Standard Time','Central Europe Standard Time','Central European Standard Time','FLE Standard Time','Eastern Standard Time','Pacific Standard Time','UTC')
    $common=@($commonIds | ForEach-Object {
        $zoneId=$_
        $zone=@($available | Where-Object Id -eq $zoneId | Select-Object -First 1)
        if ($zone.Count) { [pscustomobject]@{Name="$($zone[0].Id) - $($zone[0].DisplayName)";Value=$zone[0].Id;Kind='Value'} }
    })
    while ($true) {
        $choices=@($common)+@(
            [pscustomobject]@{Name='Search all Windows time zones';Value='';Kind='Search'}
            [pscustomobject]@{Name='Enter a time-zone ID manually';Value='';Kind='Manual'}
            [pscustomobject]@{Name='Do not change the Windows time zone';Value='';Kind='Skip'}
        )
        $selected=Select-Item $choices 'Select Windows time zone' 'Name' ($choices.Count-1)
        if ($selected.Kind -eq 'Value') { return $selected.Value }
        if ($selected.Kind -eq 'Skip') { return '' }
        if ($selected.Kind -eq 'Manual') {
            while ($true) {
                $zoneId=(Read-Host 'Windows time-zone ID (for example W. Europe Standard Time)').Trim()
                try { return (Get-TimeZone -Id $zoneId -ErrorAction Stop).Id }
                catch { Write-Warning 'Windows does not recognize that time-zone ID.' }
            }
        }
        $term=(Read-Host 'Search time zone by ID, city or UTC description').Trim()
        if (-not $term) { continue }
        $pattern=[regex]::Escape($term)
        $timeZoneMatches=@($available | Where-Object {
            $_.Id -match $pattern -or $_.DisplayName -match $pattern -or $_.StandardName -match $pattern -or $_.DaylightName -match $pattern
        } | Sort-Object BaseUtcOffset,Id)
        if (-not $timeZoneMatches.Count) { Write-Warning 'No matching Windows time zones were found.'; continue }
        if ($timeZoneMatches.Count -gt 50) { Write-Host 'Showing the first 50 matches. Use a more specific search to narrow the list.' }
        $results=@($timeZoneMatches | Select-Object -First 50 | ForEach-Object {
            [pscustomobject]@{Name="$($_.Id) - $($_.DisplayName)";Value=$_.Id}
        })
        return (Select-Item $results 'Select matching Windows time zone').Value
    }
}

function Select-WindowsRegion {
    param([string]$Language)
    $commonTags=@('de-DE','en-US','en-GB','es-ES','fr-FR','it-IT','nl-NL','pt-PT','de-AT','de-CH')
    $common=@($commonTags | ForEach-Object {
        $region=New-Object Globalization.RegionInfo($_)
        [pscustomobject]@{Name="$($region.EnglishName) - GeoID $($region.GeoId)";Value=[string]$region.GeoId;Culture=$_;Kind='Value'}
    })
    $defaultIndex=$common.Count
    if ($Language) {
        for ($regionIndex=0;$regionIndex -lt $common.Count;$regionIndex++) {
            if ($common[$regionIndex].Culture -eq $Language) { $defaultIndex=$regionIndex; break }
        }
    }
    while ($true) {
        $choices=@($common)+@(
            [pscustomobject]@{Name='Search all Windows countries and regions';Value='';Culture='';Kind='Search'}
            [pscustomobject]@{Name='Do not change the country or region';Value='';Culture='';Kind='Skip'}
        )
        if (-not $Language) { $defaultIndex=$choices.Count-1 }
        $selected=Select-Item $choices 'Select Windows country or region' 'Name' $defaultIndex
        if ($selected.Kind -eq 'Value') { return $selected.Value }
        if ($selected.Kind -eq 'Skip') { return '' }
        $term=(Read-Host 'Search country or region by name or culture tag').Trim()
        if (-not $term) { continue }
        $pattern=[regex]::Escape($term)
        $allRegions=@([Globalization.CultureInfo]::GetCultures([Globalization.CultureTypes]::SpecificCultures) | ForEach-Object {
            try {
                $region=New-Object Globalization.RegionInfo($_.Name)
                [pscustomobject]@{Name="$($region.EnglishName) - $($_.Name) - GeoID $($region.GeoId)";Value=[string]$region.GeoId;Culture=$_.Name}
            } catch {}
        } | Group-Object Value | ForEach-Object { $_.Group | Select-Object -First 1 } |
            Where-Object { $_.Name -match $pattern -or $_.Culture -match $pattern } | Sort-Object Name)
        if (-not $allRegions.Count) { Write-Warning 'No matching Windows countries or regions were found.'; continue }
        if ($allRegions.Count -gt 50) { Write-Host 'Showing the first 50 matches. Use a more specific search to narrow the list.' }
        return (Select-Item @($allRegions | Select-Object -First 50) 'Select matching Windows country or region').Value
    }
}

#endregion

#region Arc Run Command cleanup, execution and verification
function Remove-CompletedGuestRunCommand {
    param([string]$MachineId)
    $commands=@(Get-ArmList "$MachineId/runCommands?api-version=$script:RunCommandApi")
    if ($commands.Count -lt 20) { return }
    if (-not $script:RunFile) { throw 'RunCommandCapacity: A local tracking directory is required before archiving completed commands.' }
    $archiveDirectory=Join-Path (Split-Path $script:RunFile) 'completed-run-commands'
    $null=New-Item -ItemType Directory -Path $archiveDirectory -Force
    $remaining=$commands.Count
    # Only this runner's unique task names. Never registration, diagnostics or unrelated commands.
    foreach ($command in @($commands | Where-Object { $_.name -match '^AVDTask-\d{14}[a-f0-9]{6}-\d+$' } | Sort-Object name)) {
        if ($remaining -lt 20) { break }
        if (@($script:Run.guestTasks | Where-Object { $_.commandId -eq $command.id }).Count) { continue }
        $commandId="$MachineId/runCommands/$($command.name)"
        $current=Invoke-Arm "$commandId`?api-version=$script:RunCommandApi&`$expand=instanceView" -AllowNotFound
        if (-not $current) { $remaining--; continue }
        $view=$current.properties.instanceView
        if ($current.properties.provisioningState -in @('Creating','Updating','Deleting','Accepted','Running')) { continue }
        if ($view.executionState -notin @('Succeeded','Failed','TimedOut','Canceled')) { continue }
        # Retain execution evidence, never script source or protected parameters.
        $archive=[ordered]@{commandId=$commandId;archivedUtc=[datetime]::UtcNow.ToString('o');instanceView=$view}
        $archivePath=Join-Path $archiveDirectory ($command.name+'.json')
        $archive | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $archivePath -Encoding UTF8 -ErrorAction Stop
        $null=Invoke-Arm "$commandId`?api-version=$script:RunCommandApi" -Method DELETE
        $deleteDeadline=[datetime]::UtcNow.AddMinutes(10)
        while (Invoke-Arm "$commandId`?api-version=$script:RunCommandApi" -AllowNotFound) {
            if ([datetime]::UtcNow -ge $deleteDeadline) { throw 'RunCommandCapacity: Completed command deletion is still pending. Run the task again after Azure finishes deleting it.' }
            Write-Event "Waiting for completed Run Command $($command.name) to be deleted (up to 10 minutes)."
            Start-Sleep -Seconds 15
        }
        $remaining--
        Write-Event "Removed completed Run Command $($command.name). Execution evidence saved to $archivePath"
    }
    if ($remaining -ge 25) { throw 'RunCommandCapacity: The machine has 25 Run Commands and no safe slot could be freed. Review unrelated or active commands before rerunning the task.' }
}

function Invoke-GuestTaskRunCommand {
    param([object]$Machine, [string]$CommandName, [object]$Body)
    $machineName=([regex]::Match($Machine.Id,'(?i)/machines/([^/]+)$')).Groups[1].Value
    $resourceGroup=([regex]::Match($Machine.Id,'(?i)/resourceGroups/([^/]+)/providers/')).Groups[1].Value
    if (-not $machineName -or -not $resourceGroup) { throw 'The Arc machine resource ID is invalid for Run Command submission.' }
    $json=$Body | ConvertTo-Json -Depth 100 -Compress
    # The cmdlet waits for the resource-provider operation unless -NoWait is selected.
    New-AzConnectedMachineRunCommand -MachineName $machineName -ResourceGroupName $resourceGroup `
        -RunCommandName $CommandName -SubscriptionId $script:Subscription -JsonString $json -Confirm:$false -ErrorAction Stop
}

function Get-GuestTaskParameters {
    param([object]$Task)
    . (Join-Path $script:GuestScriptsPath 'Common.ps1')
    Write-Host ('System changes: ' + (Get-GuestChangeDescription $Task.ResultTask))
    $values=[ordered]@{}
    switch ($Task.Id) {
        'FSLogix' {
            $fslogixEnvPath=Join-Path (Split-Path $script:GuestScriptsPath -Parent) 'fslogix.env'
            $fslogixSettings=@{}; $defaultShare=''; $useExperimental=$false
            if (Test-Path -LiteralPath $fslogixEnvPath -PathType Leaf) {
                foreach ($envLine in [IO.File]::ReadAllLines($fslogixEnvPath)) {
                    if (-not $envLine.Trim() -or $envLine.TrimStart().StartsWith('#')) { continue }
                    if ($envLine -notmatch '^(FSLOGIX_[A-Z_]+)=(.*)$' -or $fslogixSettings.ContainsKey($Matches[1])) { throw 'Invalid fslogix.env entry; file contents are not logged.' }
                    $fslogixSettings[$Matches[1]]=$Matches[2]
                }
                if ($fslogixSettings.FSLOGIX_SCHEMA -ne '1' -or $fslogixSettings.FSLOGIX_STATE -ne 'Ready' -or $fslogixSettings.FSLOGIX_SHARE -notmatch '^\\\\[^\\]+\\[^\\]+$') { throw 'fslogix.env is not ready or contains an invalid share path.' }
                $defaultShare=$fslogixSettings.FSLOGIX_SHARE
                Write-Host "Found fslogix.env. Profile share: $defaultShare"
                Write-Host 'LAB ONLY: SYSTEM uses the shared storage credential. Each host can access all profiles granted to that account. Credential Guard is unchanged.'
                $useExperimental=(Read-Value 'Use experimental SYSTEM credentials from fslogix.env? (Y/N)' 'N' '^[YyNn]$') -eq 'Y'
                if ($useExperimental) {
                    if (-not $fslogixSettings.FSLOGIX_USERNAME -or -not $fslogixSettings.FSLOGIX_PASSWORD) { throw 'fslogix.env is missing the storage credentials.' }
                    $values.ExperimentalSystemCredentials=$true
                    $envText=($fslogixSettings.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join "`n"
                    $values.ExperimentalEnvContentBase64=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($envText))
                    $envText=$null
                    Write-Host 'Settings will be sent as protected Run Command parameters and imported under SYSTEM; no guest env file is created.'
                }
                $fslogixSettings.Clear(); $envLine=$null
            }
            if (-not $useExperimental) {
                Write-Host 'Per-user SMB authentication is required in this mode; the env credential is not imported.'
                $values.VhdLocation=Read-Value 'FSLogix profile share UNC path' $defaultShare '^\\\\[^\\]+\\[^\\]+(?:\\.*)?$'
            }
            $values.SizeInMBs=Read-Value 'Maximum profile size in MB' '30000' '^\d{4,7}$'
            $values.VolumeType=(Select-Item @([pscustomobject]@{Name='VHDX';Value='vhdx'},[pscustomobject]@{Name='VHD';Value='vhd'}) 'Select profile disk format').Value
            $values.DeleteLocalProfileWhenVHDShouldApply=((Read-Value 'Delete local profiles when applying an FSLogix profile? (Y/N)' 'N' '^[YyNn]$') -eq 'Y')
        }
        'Regional' {
            $language=Select-WindowsLanguage
            $homeLocationGeoId=Select-WindowsRegion $language
            $timeZone=Select-WindowsTimeZone
            $values.EnableTimeZoneRedirection=((Read-Value 'Enable RDP time-zone redirection? (Y/N)' 'N' '^[YyNn]$') -eq 'Y')
            if ($language) { $values.Language=$language }
            if ($homeLocationGeoId) { $values.HomeLocationGeoId=$homeLocationGeoId }
            if ($timeZone) { $values.TimeZone=$timeZone }
            if (-not $language -and -not $homeLocationGeoId -and -not $timeZone -and -not $values.EnableTimeZoneRedirection) { throw 'No regional setting was selected.' }
            if ($language) {
                $values.InstallLanguagePack=((Read-Value 'Install the language pack if missing? (Y/N)' 'N' '^[YyNn]$') -eq 'Y')
                $values.CopyToSystemAndDefaultUser=((Read-Value 'Copy language, regional format and country/region to system and new users? (Y/N)' 'Y' '^[YyNn]$') -eq 'Y')
            }
            if ($homeLocationGeoId) {
                Write-Host 'The Device setup region option writes the undocumented Windows DeviceRegion value so its visual value matches the selected country or region after restart.'
                $values.SetDeviceSetupRegion=((Read-Value 'Apply the community Device setup region display value? (Y/N)' 'Y' '^[YyNn]$') -eq 'Y')
            }
        }
        'BGInfo' {
            $configPath=(Read-Host 'Optional path to a reviewed local .bgi configuration file (press Enter to download the default layout)').Trim()
            if ($configPath) {
                if ([IO.Path]::GetExtension($configPath) -ne '.bgi') { throw 'The BGInfo configuration file must have a .bgi extension.' }
                if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) { throw 'The selected BGInfo file was not found.' }
                $content=[IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $configPath).Path)
                if (-not $content.Length -or $content.Length -gt 32768) { throw 'The BGInfo configuration must contain 1 to 32768 bytes.' }
                Write-Host 'The selected BGI file may contain commands or script references. Review it before continuing.'
                $values.ConfigContentBase64=[Convert]::ToBase64String($content)
                $content=$null
            } else {
                Write-Host 'No BGI file selected. The guest task will download and verify its default layout.'
            }
        }
        'StagingAcl' {
            $values.Path=Read-Value 'Dedicated local agent staging directory' '%ProgramData%\AzSHCI\AVD' '^(?:[A-Za-z]:\\|%ProgramData%\\).+$'
            Write-Host 'The default is the deployment agent-download directory. %ProgramData% is resolved on each target session host.'
            Write-Host "The task replaces the root DACL on $($values.Path) with SYSTEM and Administrators full control. It does not recurse or delete files."
            if ((Read-Value 'Approve this exact ACL change? (Y/N)' 'N' '^[YyNn]$') -ne 'Y') { throw 'Staging ACL change declined.' }
        }
        'AVDAgentUpdate' {
            $defaultAgentUri='https://go.microsoft.com/fwlink/?linkid=2310011'
            $defaultBootUri='https://go.microsoft.com/fwlink/?linkid=2311028'
            Write-Host 'Press Enter to use the official Microsoft production download URL. Enter a custom HTTPS URL to override it, or - to skip that component. Enter - for both to skip this task.'
            $agentUri=Read-SecureText "AVD Agent MSI HTTPS URI [$defaultAgentUri] (Enter = default, - = skip)"
            $bootUri=Read-SecureText "AVD Boot Loader MSI HTTPS URI [$defaultBootUri] (Enter = default, - = skip)"
            $agentUri=if ([string]::IsNullOrWhiteSpace($agentUri)) { $defaultAgentUri } elseif ($agentUri.Trim() -eq '-') { '' } else { $agentUri.Trim() }
            $bootUri=if ([string]::IsNullOrWhiteSpace($bootUri)) { $defaultBootUri } elseif ($bootUri.Trim() -eq '-') { '' } else { $bootUri.Trim() }
            foreach ($value in @($agentUri,$bootUri) | Where-Object { $_ }) {
                $parsed=$null
                if (-not [uri]::TryCreate($value,[UriKind]::Absolute,[ref]$parsed) -or $parsed.Scheme -ne 'https' -or $parsed.UserInfo) { throw 'Agent package URIs must be HTTPS and contain no embedded credentials.' }
            }
            if (-not $agentUri -and -not $bootUri) { Write-Host 'No AVD packages supplied. Skipping the agent update task.'; return $null }
            Write-Host 'Drain the selected hosts, verify there are no active sessions and arrange maintenance before updating agents.'
            if ((Read-Value 'Confirm all selected hosts are drained and maintenance is arranged? (Y/N)' 'N' '^[YyNn]$') -ne 'Y') { throw 'AVD agent maintenance was not confirmed.' }
            if ($agentUri) { $values.AgentUri=$agentUri }
            if ($bootUri) { $values.BootLoaderUri=$bootUri }
            $values.MaintenanceConfirmed=$true
            $agentUri=$null; $bootUri=$null
        }
        'EntraKerberos' {
            $values.Mode=(Select-Item @([pscustomobject]@{Name='Enable';Value='Enable'},[pscustomobject]@{Name='Disable';Value='Disable'}) 'Select Entra Kerberos policy mode').Value
            if ($values.Mode -eq 'Enable') {
                Write-Host 'LanmanWorkstation provides SMB client connections. WinHttpAutoProxySvc provides automatic proxy discovery for WinHTTP applications.'
                Write-Host 'Choosing Yes starts these services if stopped and changes their startup type from Disabled to Manual if necessary.'
            }
            $values.StartRequiredServices=($values.Mode -eq 'Enable' -and (Read-Value 'Start LanmanWorkstation and WinHttpAutoProxySvc? (Y/N)' 'N' '^[YyNn]$') -eq 'Y')
            Write-Host 'These policy values do not configure an SMB identity provider or validate access to the on-premises share.'
        }
        'AvdPolicies' {
            $clipboard=@(
                [pscustomobject]@{Name='Leave unchanged';Value='NotConfigured'},[pscustomobject]@{Name='Disable';Value='Disabled'},
                [pscustomobject]@{Name='Plain text only';Value='TextOnly'},[pscustomobject]@{Name='Plain text and images';Value='TextAndImages'},
                [pscustomobject]@{Name='Plain text, rich text and images';Value='TextRichAndImages'},[pscustomobject]@{Name='Plain text, rich text, HTML and images';Value='TextRichHtmlAndImages'})
            $values.HostToClientClipboard=(Select-Item $clipboard 'Clipboard from session host to client' 'Name' 0).Value
            $values.ClientToHostClipboard=(Select-Item $clipboard 'Clipboard from client to session host' 'Name' 0).Value
            $toggle=@([pscustomobject]@{Name='Leave unchanged';Value='NotConfigured'},[pscustomobject]@{Name='Enable';Value='Enable'},[pscustomobject]@{Name='Disable';Value='Disable'})
            $values.ScreenCaptureProtection=(Select-Item $toggle 'Screen capture protection' 'Name' 0).Value
            $values.EdgeOptimization=(Select-Item $toggle 'Microsoft Edge sleeping tabs and startup boost' 'Name' 0).Value
            $values.ManagedShortpath=(Select-Item $toggle 'Managed RDP Shortpath listener and dedicated Windows firewall rule' 'Name' 0).Value
            if ($values.ManagedShortpath -eq 'Enable') {
                Write-Host 'Enables TCP/UDP transport and the managed Shortpath listener, and allows inbound UDP only from the supplied clients. Network routing and the pool Shortpath switch must also allow the connection.'
                $values.ShortpathPort=[int](Read-Value 'Managed Shortpath UDP port (1024-65535)' '3390' '^\d{4,5}$')
                if ($values.ShortpathPort -lt 1024 -or $values.ShortpathPort -gt 65535) { throw 'UDP port must be between 1024 and 65535.' }
                $values.ShortpathClientAddresses=Read-Value 'Allowed client IPs/CIDRs, comma-separated, or LocalSubnet' 'LocalSubnet'
            }
            $limits=@([pscustomobject]@{Name='Leave unchanged';Value='NotConfigured'},[pscustomobject]@{Name='Disable all session time limits';Value='DisableLimits'},[pscustomobject]@{Name='Remove these local policy values';Value='RestoreNotConfigured'})
            $values.SessionTimeLimits=(Select-Item $limits 'Session time limits' 'Name' 0).Value
            if (@($values.Values | Where-Object { $_ -ne 'NotConfigured' }).Count -eq 0) { throw 'No AVD host policy was selected.' }
        }
        'SessionExperience' {
            $driveChoices=@([pscustomobject]@{Name='Leave drive visibility unchanged';Value='NotConfigured'},[pscustomobject]@{Name='Hide selected drive letters';Value='Hide'},[pscustomobject]@{Name='Unhide all drives';Value='Unhide'})
            $values.DriveVisibility=(Select-Item $driveChoices 'File Explorer drive visibility' 'Name' 0).Value
            if ($values.DriveVisibility -eq 'Hide') { $values.DrivesToHide=Read-Value 'Comma-separated drive letters to hide (for example C,D)' '' '^(?i)[A-Z](\s*,\s*[A-Z])*$' }
            $toggle=@([pscustomobject]@{Name='Leave unchanged';Value='NotConfigured'},[pscustomobject]@{Name='Enable';Value='Enable'},[pscustomobject]@{Name='Disable';Value='Disable'})
            $values.OfficeFeatureUpdatesTask=(Select-Item $toggle 'Microsoft Office Feature Updates scheduled task' 'Name' 0).Value
            $values.OneDriveRemoteApp=(Select-Item $toggle 'OneDrive background launch for RemoteApp' 'Name' 0).Value
            if (@($values.Values | Where-Object { $_ -ne 'NotConfigured' }).Count -eq 0) { throw 'No session-host experience setting was selected.' }
        }
        'NetworkOverrides' {
            $dnsChoices=@([pscustomobject]@{Name='Leave DNS suffixes unchanged';Value='NotConfigured'},[pscustomobject]@{Name='Merge suffixes with the existing list';Value='Merge'},[pscustomobject]@{Name='Replace the DNS suffix search list';Value='Replace'})
            $values.DnsSuffixMode=(Select-Item $dnsChoices 'DNS suffix search list' 'Name' 0).Value
            if ($values.DnsSuffixMode -ne 'NotConfigured') { $values.DnsSuffixes=Read-Value 'Comma-separated DNS suffixes' '' '^\s*[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?\s*(?:,\s*[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?\s*)*$' }
            $hostChoices=@([pscustomobject]@{Name='Leave the hosts file unchanged';Value='NotConfigured'},[pscustomobject]@{Name='Add or update a hosts entry';Value='Set'},[pscustomobject]@{Name='Remove a hosts entry';Value='Remove'})
            $values.HostsEntryAction=(Select-Item $hostChoices 'Hosts-file entry' 'Name' 0).Value
            if ($values.HostsEntryAction -ne 'NotConfigured') {
                $values.Hostname=Read-Value 'DNS hostname' '' '^[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?$'
                if ($values.HostsEntryAction -eq 'Set') { $values.IpAddress=Read-Value 'IPv4 or IPv6 address' '' '^\S+$' }
            }
            if ($values.DnsSuffixMode -eq 'NotConfigured' -and $values.HostsEntryAction -eq 'NotConfigured') { throw 'No network override was selected.' }
        }
        'WinGetApps' {
            $apps=@(
                [pscustomobject]@{Name='7-Zip';Value='7zip.7zip'},[pscustomobject]@{Name='Adobe Acrobat Reader 64-bit';Value='Adobe.Acrobat.Reader.64-bit'},
                [pscustomobject]@{Name='Google Chrome';Value='Google.Chrome'},[pscustomobject]@{Name='Microsoft Edge';Value='Microsoft.Edge'},
                [pscustomobject]@{Name='Mozilla Firefox';Value='Mozilla.Firefox'},[pscustomobject]@{Name='Notepad++';Value='Notepad++.Notepad++'},
                [pscustomobject]@{Name='Visual Studio Code';Value='Microsoft.VisualStudioCode'},[pscustomobject]@{Name='Microsoft OneDrive';Value='Microsoft.OneDrive'},
                [pscustomobject]@{Name='Microsoft Teams';Value='Microsoft.Teams'},[pscustomobject]@{Name='Microsoft 365 Apps for enterprise';Value='Microsoft.Office'},
                [pscustomobject]@{Name='Zoom VDI Workplace';Value='Zoom.Zoom.VDI'})
            $selectedApps=@(Select-Multiple $apps 'Select application(s) to install or update')
            if (-not $selectedApps.Count) { throw 'No applications were selected.' }
            $values.PackageIds=($selectedApps.Value -join ',')
            Write-Host 'This task requires an existing functional WinGet client and access to its configured source. It does not bootstrap a package manager.'
        }
        'WindowsUpdates' {
            $values.IncludeDrivers=((Read-Value 'Include applicable driver updates? (Y/N)' 'N' '^[YyNn]$') -eq 'Y')
            Write-Host 'The task installs applicable updates through Windows Update Agent and never restarts the host automatically.'
            if ((Read-Value 'Confirm the selected hosts are drained and a maintenance window is active? (Y/N)' 'N' '^[YyNn]$') -ne 'Y') { throw 'Windows Update maintenance was not confirmed.' }
        }
        'AgentRestart' {
            Write-Host 'Restarting the AVD agent can temporarily make the session host unavailable.'
            if ((Read-Value 'Confirm the selected hosts are drained and agent restart is required? (Y/N)' 'N' '^[YyNn]$') -ne 'Y') { throw 'AVD agent restart was not confirmed.' }
        }
        'LocalAdministrator' {
            Write-Host 'Use this only for an explicitly reviewed personal-desktop assignment. The script does not infer the assigned user.'
            $values.Action=(Select-Item @([pscustomobject]@{Name='Add identity';Value='Add'},[pscustomobject]@{Name='Remove identity';Value='Remove'}) 'Local Administrators membership action').Value
            $values.Identity=Read-Value 'Exact identity (for example AzureAD\user@example.com)' '' '^.{1,256}$'
            if ((Read-Value "Confirm $($values.Action) for this exact identity on every selected host? (Y/N)" 'N' '^[YyNn]$') -ne 'Y') { throw 'Local administrator membership change was not confirmed.' }
        }
    }
    return $values
}

function Wait-GuestTaskCommand {
    param([object]$TaskRecord)
    if (-not $TaskRecord.PSObject.Properties['errorMessage']) {
        $TaskRecord | Add-Member -NotePropertyName errorMessage -NotePropertyValue ''
    }
    $deadline=[datetime]::UtcNow.AddMinutes($TimeoutMinutes)
    $visibilityDeadline=[datetime]::UtcNow.AddMinutes(2)
    do {
        $result=Invoke-Arm "$($TaskRecord.commandId)?api-version=$script:RunCommandApi&`$expand=instanceView" -AllowNotFound
        if (-not $result) {
            if ([datetime]::UtcNow -ge $visibilityDeadline -or [datetime]::UtcNow -ge $deadline) {
                $TaskRecord.status='Failed'; $TaskRecord.executionState='NotFound'; $TaskRecord.errorCode='RunCommandNotFound'
                $TaskRecord.completedUtc=[datetime]::UtcNow.ToString('o'); Save-Run
                Write-Warning "Arc accepted guest task $($TaskRecord.taskId) on $($TaskRecord.hostName), but its Run Command resource did not become visible within two minutes. Check the Arc machine's runCommands list before retrying."
                return $false
            }
            $TaskRecord.status='Submitted'; Save-Run
            Write-Progress -Activity "Guest task $($TaskRecord.taskId) on $($TaskRecord.hostName)" -Status 'Waiting for the Arc Run Command resource to become visible'
            Start-Sleep -Seconds $PollSeconds
            continue
        }
        $view=$result.properties.instanceView
        $state=[string]$view.executionState
        if ($state -in @('Succeeded','Failed','TimedOut','Canceled','Cancelled')) {
            $output=if ($view.output -is [array]) { $view.output -join "`n" } else { [string]$view.output }
            $TaskRecord.executionState=$state
            $TaskRecord.exitCode=$view.exitCode
            $TaskRecord.completedUtc=[datetime]::UtcNow.ToString('o')
            $verified=($state -eq 'Succeeded' -and [int]$view.exitCode -eq 0 -and $output.Contains($TaskRecord.completionMarker))
            $TaskRecord.status=if ($verified) { 'Succeeded' } else { 'Failed' }
            $TaskRecord.completionVerified=[bool]$verified
            $viewError=if ($view.error -is [string]) { [string]$view.error } elseif ($view.error) { [string]$view.error.message } else { '' }
            $TaskRecord.errorCode=if ($view.error -and $view.error.code) { [string]$view.error.code } else { '' }
            $TaskRecord.errorMessage=($viewError -replace '\s+',' ').Trim()
            $resultLine=@([regex]::Split($output,'\r?\n') | Where-Object { $_ -like 'AVD_TASK_RESULT:*' } | Select-Object -Last 1)
            if ($verified -and $resultLine.Count) {
                try {
                    $taskResult=$resultLine[0].Substring('AVD_TASK_RESULT:'.Length) | ConvertFrom-Json
                    if ($taskResult.Task -ne $TaskRecord.resultTask -or $taskResult.Status -ne 'Succeeded') { $verified=$false }
                    else {
                        $safeResult=[ordered]@{Task=$taskResult.Task;Status=$taskResult.Status}
                        foreach ($property in @('RebootRequired','RestartScheduled','RestartDelaySeconds','LanguageSettingsDeferred','SystemPreferredUILanguageApplied','HomeLocationGeoId','DefaultUserRegionalSettingsApplied','DefaultUserSettingsApplied','DeviceSetupRegionRequested','DeviceSetupRegionValueApplied','UserSignInValidationRequired','ExistingUserSettingsApplied','NextLogonRequired','HostPoolHealthValidationRequired','ProtectedChildrenReviewed','NewSignInRequired','SmbAuthenticationValidated')) {
                            if ($taskResult.PSObject.Properties[$property]) { $safeResult[$property]=$taskResult.$property }
                        }
                        $TaskRecord.result=[pscustomobject]$safeResult
                    }
                } catch { $verified=$false; $TaskRecord.errorCode='InvalidTaskResult' }
            } else { $verified=$false }
            $TaskRecord.status=if ($verified) { 'Succeeded' } else { 'Failed' }
            $TaskRecord.completionVerified=[bool]$verified
            Save-Run
            if ($verified) {
                Write-Event "Guest task $($TaskRecord.taskId) succeeded on $($TaskRecord.hostName): $($TaskRecord.result | ConvertTo-Json -Compress)."
                if ($TaskRecord.result.LanguageSettingsDeferred) {
                    Write-Warning "Restart $($TaskRecord.hostName), then run the Regional task again to apply the installed language settings."
                }
                if ($TaskRecord.result.PSObject.Properties['SystemPreferredUILanguageApplied'] -and $TaskRecord.result.SystemPreferredUILanguageApplied -eq $false) {
                    Write-Warning "Windows rejected the device-wide preferred UI language on $($TaskRecord.hostName). The user language, regional settings and selected system/new-user copy were still applied; validate them after restart."
                }
            }
            else {
                $detail=if ($TaskRecord.errorMessage) { $TaskRecord.errorMessage } elseif ($output) { ($output -replace '\s+',' ').Trim() } else { 'The expected completion marker was not returned.' }
                if ($detail.Length -gt 700) { $detail=$detail.Substring(0,700) + '...' }
                Write-Warning "Guest task $($TaskRecord.taskId) on $($TaskRecord.hostName) ended $state (exit $($view.exitCode)): $detail"
            }
            return [bool]$verified
        }
        $TaskRecord.status='Running'; Save-Run
        Write-Progress -Activity "Guest task $($TaskRecord.taskId) on $($TaskRecord.hostName)" -Status $(if ($state) { $state } else { 'Waiting for Arc Run Command' })
        Start-Sleep -Seconds $PollSeconds
    } while ([datetime]::UtcNow -lt $deadline)
    $TaskRecord.status='TimedOut'; $TaskRecord.executionState='TimedOut'; $TaskRecord.completedUtc=[datetime]::UtcNow.ToString('o')
    Save-Run
    Write-Warning "Guest task $($TaskRecord.taskId) timed out on $($TaskRecord.hostName). The Arc command may still be running; inspect it before retrying."
    return $false
}

function Invoke-GuestTaskWorkflow {
    param([object]$Deployment)
    if ($Deployment.SessionHostReadState -ne 'Succeeded') { throw 'Session-host discovery is restricted or unavailable.' }
    $hosts=@($Deployment.SessionHosts | Where-Object { $_.properties.resourceId } | ForEach-Object {
        [pscustomobject]@{Name=$_.name;ArcId=$_.properties.resourceId;Status=$_.properties.status}
    })
    if (-not $hosts.Count) { throw 'The selected host pool has no session hosts with an Arc machine resource ID.' }
    $catalog=@(
        [pscustomobject]@{Name='Configure FSLogix profiles on the on-premises share';Id='FSLogix';File='00_Set-FSLogixProfile.ps1';ResultTask='FSLogixProfile'}
        [pscustomobject]@{Name='Set Windows regional settings';Id='Regional';File='01_Set-RegionalSettings.ps1';ResultTask='RegionalSettings'}
        [pscustomobject]@{Name='Install BGInfo';Id='BGInfo';File='02_Install-BgInfo.ps1';ResultTask='BGInfo'}
        [pscustomobject]@{Name='Restrict a dedicated agent staging directory ACL';Id='StagingAcl';File='03_Set-AgentStagingPermission.ps1';ResultTask='AgentStagingPermission'}
        [pscustomobject]@{Name='Update registered AVD agents';Id='AVDAgentUpdate';File='04_Update-AVDAgent.ps1';ResultTask='AVDAgentUpdate'}
        [pscustomobject]@{Name='Set Entra Kerberos Windows policies';Id='EntraKerberos';File='05_Set-EntraKerberosSettings.ps1';ResultTask='EntraKerberosSettings'}
        [pscustomobject]@{Name='Configure AVD clipboard, capture, Shortpath, time-limit and Edge policies';Id='AvdPolicies';File='06_Set-AvdHostPolicies.ps1';ResultTask='AvdHostPolicies'}
        [pscustomobject]@{Name='Configure Explorer, Office and OneDrive session behavior';Id='SessionExperience';File='07_Set-SessionHostExperience.ps1';ResultTask='SessionHostExperience'}
        [pscustomobject]@{Name='Configure DNS suffixes or hosts-file entries';Id='NetworkOverrides';File='08_Set-NetworkOverrides.ps1';ResultTask='NetworkOverrides'}
        [pscustomobject]@{Name='Install or update approved applications with WinGet';Id='WinGetApps';File='09_Install-WinGetApplications.ps1';ResultTask='WinGetApplications'}
        [pscustomobject]@{Name='Install applicable Windows updates (no automatic reboot)';Id='WindowsUpdates';File='10_Install-WindowsUpdates.ps1';ResultTask='WindowsUpdates'}
        [pscustomobject]@{Name='Restart the AVD agent boot-loader service';Id='AgentRestart';File='11_Restart-AvdAgent.ps1';ResultTask='AvdAgentRestart'}
        [pscustomobject]@{Name='Add or remove an explicit local administrator';Id='LocalAdministrator';File='12_Set-LocalAdministrator.ps1';ResultTask='LocalAdministrator'}
    )
    Write-Host 'Select one or more guest tasks. Separate several choices with commas, for example: 2,3,7.'
    $selectedTasks=@(Select-Multiple $catalog 'Select guest task(s)')
    if (-not $selectedTasks.Count) { Write-Host 'No guest tasks selected.'; return }
    $selectedHosts=@(Select-Multiple $hosts 'Select target session host(s)' -AllowAll)
    if (-not $selectedHosts.Count) { Write-Host 'No session hosts selected.'; return }
    $operations=@()
    $taskNumber=0
    foreach ($task in $selectedTasks) {
        $taskNumber++
        $parameters=$null
        while ($true) {
            Show-AvdPanel "Configure script $taskNumber of $($selectedTasks.Count): $($task.Name)" @("File: SessionHostScripts/$($task.File)", 'The following settings apply only to this script. Nothing has been submitted yet.')
            try { $parameters=Get-GuestTaskParameters $task; break }
            catch {
                Write-Warning "Settings for '$($task.Name)' [$($task.File)] were not accepted: $($_.Exception.Message)"
                $recovery=Select-Item @(
                    [pscustomobject]@{Name='Retry settings for this script';Id='Retry'},
                    [pscustomobject]@{Name='Skip this script and keep the other selected tasks';Id='Skip'},
                    [pscustomobject]@{Name='Cancel guest configuration (no scripts submitted)';Id='Cancel'}
                ) "Settings recovery | $($task.File)"
                if ($recovery.Id -eq 'Cancel') { Write-Host 'Guest configuration cancelled. No guest scripts were submitted; the completed deployment is preserved.'; return }
                if ($recovery.Id -eq 'Skip') { break }
            }
        }
        if ($null -eq $parameters) { Write-Host "Skipped script: $($task.File). Previously configured tasks are retained."; continue }
        $operations += [pscustomobject]@{Kind='Task';Name=$task.Name;Task=$task;Parameters=$parameters;AfterTaskId=''}
        $restartAfterTask=$false
        if ((Read-Value "Restart the selected session hosts after '$($task.Name)'? (Y/N)" 'N' '^[YyNn]$') -eq 'Y') {
            $restartAfterTask=$true
            $operations += [pscustomobject]@{Kind='Restart';Name="Restart after $($task.Name)";Task=$null;Parameters=$null;AfterTaskId=$task.Id}
        }
        Show-AvdPanel "Settings collected | $($task.Name)" @("Script: SessionHostScripts/$($task.File)","Restart after this script: $restartAfterTask",'Queued for the final review; not executed yet.')
    }
    if (-not $operations.Count) { Write-Host 'No guest tasks remain after configuration. No commands or restarts were submitted.'; return }
    if ((Read-Value 'Restart the selected session hosts once more after the complete task sequence? (Y/N)' 'N' '^[YyNn]$') -eq 'Y') {
        $operations += [pscustomobject]@{Kind='Restart';Name='Final session-host restart';Task=$null;Parameters=$null;AfterTaskId=''}
    }
    $restartRequested=@($operations | Where-Object Kind -eq 'Restart').Count -gt 0
    if ($restartRequested) {
        Write-Host 'Each restart uses the Azure Local control plane and must finish before the next guest task starts.'
        if ((Read-Value 'Confirm the selected hosts are drained and may restart after configuration? (Y/N)' 'N' '^[YyNn]$') -ne 'Y') { Write-Host 'Guest configuration cancelled because restart maintenance was not confirmed. No scripts or restarts were submitted.'; return }
    }
    $machineDetails=@()
    foreach ($sessionHost in $selectedHosts) {
        if ($sessionHost.ArcId -notmatch ('(?i)^/subscriptions/' + [regex]::Escape($script:Subscription) + '/resourceGroups/[^/]+/providers/Microsoft\.HybridCompute/machines/[^/]+$')) {
            throw "The selected session host has an invalid or cross-subscription Arc resource ID: $($sessionHost.Name)"
        }
        $machine=Invoke-Arm "$($sessionHost.ArcId)?api-version=$script:ArcApi"
        if ($machine.properties.provisioningState -ne 'Succeeded' -or $machine.properties.status -ne 'Connected') {
            throw "Arc machine $($sessionHost.Name) is not connected and ready for Run Command."
        }
        $machineDetails += [pscustomobject]@{Name=$sessionHost.Name;Id=$sessionHost.ArcId;Location=$machine.location;VmInstanceId="$($sessionHost.ArcId)/providers/Microsoft.AzureStackHCI/virtualMachineInstances/default";RestartPath=(Get-HciVmRestartPath $sessionHost.ArcId)}
    }
    Show-AvdPanel 'GUEST OPERATIONS | REVIEW' @(
        "Host pool: $($Deployment.Name)",
        "Scripts: $(@($operations | Where-Object Kind -eq 'Task').Count) | Restarts per host: $(@($operations | Where-Object Kind -eq 'Restart').Count) | Target hosts: $($machineDetails.Count)",
        'Operations run in the numbered order below. Nothing is submitted until you confirm.'
    )
    . (Join-Path $script:GuestScriptsPath 'Common.ps1')
    $reviewIndex=0
    foreach ($operation in $operations) {
        $reviewIndex++
        if ($operation.Kind -eq 'Task') {
            Show-AvdPanel ("{0:00}. SCRIPT | {1}" -f $reviewIndex,$operation.Name) @(
                "File: SessionHostScripts/$($operation.Task.File)",
                '', 'System changes:', (Get-GuestChangeDescription $operation.Task.ResultTask)
            )
        } else {
            Show-AvdPanel ("{0:00}. RESTART | {1}" -f $reviewIndex,$operation.Name) @(
                'Restarts Windows on the selected hosts, interrupting any remaining sessions and applications.'
            )
        }
    }
    Show-AvdPanel 'TARGET SESSION HOSTS' @($machineDetails | ForEach-Object { "$($_.Name) | Region: $($_.Location)" })
    if ((Read-Value 'Run these guest tasks on these session hosts now? (Y/N)' 'N' '^[YyNn]$') -ne 'Y') { Write-Host 'Guest task execution declined. No guest scripts were submitted.'; return }
    Write-Host 'Arc Run Command requires Microsoft.HybridCompute/machines/runCommands/read, write and delete (completed task cleanup). If repair is needed, the script offers the Azure Connected Machine Resource Administrator role at each selected Arc machine scope.'
    foreach ($sessionHost in $selectedHosts) {
        Confirm-Permission $sessionHost.ArcId @('Microsoft.HybridCompute/machines/runCommands/read','Microsoft.HybridCompute/machines/runCommands/write','Microsoft.HybridCompute/machines/runCommands/delete') @($script:Roles.ConnectedMachineAdmin)
        if ($restartRequested) {
            Confirm-Permission $sessionHost.ArcId @('Microsoft.AzureStackHCI/virtualMachineInstances/restart/action') @($script:Roles.Contributor)
        }
    }
    $null=New-Item -ItemType Directory -Path $OutputDirectory -Force
    $requestedRunFile=Join-Path (Resolve-Path -LiteralPath $OutputDirectory).Path 'run.json'
    $reuseRun=($script:Run -and $script:RunFile -and $script:RunFile -eq $requestedRunFile -and $script:Run.hostPoolId -eq $Deployment.Id)
    if ($reuseRun) {
        if (-not $script:Run.PSObject.Properties['guestTasks']) { $script:Run | Add-Member -NotePropertyName guestTasks -NotePropertyValue @() }
        if (-not $script:Run.PSObject.Properties['hostRestarts']) { $script:Run | Add-Member -NotePropertyName hostRestarts -NotePropertyValue @() }
        if (-not $script:Run.PSObject.Properties['guestTaskStatus']) { $script:Run | Add-Member -NotePropertyName guestTaskStatus -NotePropertyValue 'NotRun' }
    } else {
        $OutputDirectory=New-AvdRunDirectory $OutputDirectory -Operation guest
        $requestedRunFile=Join-Path $OutputDirectory 'run.json'
        $script:RunFile=$requestedRunFile
        $script:Run=[pscustomobject]@{runId=((Get-Date -Format 'yyyyMMddHHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0,6));subscriptionId=$script:Subscription;tenantId=$script:Tenant;
            status='GuestTask';guestTaskStatus='NotRun';updatedUtc='';deployments=@();hostPoolId=$Deployment.Id;sessionHosts=@($selectedHosts | ForEach-Object Name);guestTasks=@();hostRestarts=@()}
    }
    Save-Run
    $sequence=0
    $batchRecords=@()
    $blockedMachines=@{}
    foreach ($operation in $operations) {
        foreach ($machine in $machineDetails) {
            if ($operation.Kind -eq 'Restart') {
                $restartRecord=[pscustomobject]@{restartId=[guid]::NewGuid().ToString('N');hostName=$machine.Name;machineId=$machine.Id;vmInstanceId=$machine.VmInstanceId;apiVersion=$script:HciPowerApi;correlationId='';trackingUri='';afterTaskId=$operation.AfterTaskId;status='Prepared';errorMessage='';createdUtc=[datetime]::UtcNow.ToString('o');completedUtc=''}
                $script:Run.hostRestarts=@($script:Run.hostRestarts)+$restartRecord
                if ($blockedMachines.ContainsKey($machine.Id) -and $blockedMachines[$machine.Id] -eq 'Pending') {
                    $restartRecord.status='Skipped'; $restartRecord.errorMessage='Restart was not resubmitted because an earlier accepted restart remains unverified.'; $restartRecord.completedUtc=[datetime]::UtcNow.ToString('o')
                    Save-Run
                    Write-Warning "Restart skipped on $($machine.Name) because an earlier accepted restart remains unverified."
                    continue
                }
                $requiredRecords=@($batchRecords | Where-Object { $_.hostName -eq $machine.Name -and $_.taskId -eq $operation.AfterTaskId })
                if ($operation.AfterTaskId -and ($blockedMachines.ContainsKey($machine.Id) -or -not $requiredRecords.Count -or @($requiredRecords | Where-Object status -ne 'Succeeded').Count)) {
                    $restartRecord.status='Skipped'; $restartRecord.errorMessage='Restart was skipped because the required preceding guest task did not succeed.'; $restartRecord.completedUtc=[datetime]::UtcNow.ToString('o')
                    Save-Run
                    Write-Warning "Restart skipped on $($machine.Name) because the required preceding guest task did not succeed."
                    continue
                }
                try {
                    $restartRecord.status='Restarting'; Save-Run
                    Write-Event "$($operation.Name) on $($machine.Name) through the Azure Local control plane."
                    Invoke-HciVmRestart $machine.Id $machine.RestartPath $restartRecord
                    Wait-ArcMachineAfterRestart $machine.Id
                    if ($blockedMachines.ContainsKey($machine.Id)) { $blockedMachines.Remove($machine.Id) }
                    $restartRecord.status='Succeeded'; $restartRecord.completedUtc=[datetime]::UtcNow.ToString('o'); Save-Run
                    Write-Event "Restart completed on $($machine.Name)."
                } catch {
                    $acceptedUnverified=$_.Exception.Message -match '^AVD_RESTART_ACCEPTED_UNVERIFIED:'
                    $restartRecord.status=if ($acceptedUnverified) { 'Tracking' } else { 'Failed' }
                    $restartRecord.errorMessage=$_.Exception.Message; $restartRecord.completedUtc=if ($acceptedUnverified) { '' } else { [datetime]::UtcNow.ToString('o') }
                    $blockedMachines[$machine.Id]=if ($acceptedUnverified) { 'Pending' } else { 'Failed' }; Save-Run
                    $failureEffect=if ($acceptedUnverified) { 'Later operations will not resubmit or overtake the accepted restart.' } elseif ($operation.AfterTaskId) { 'Later guest tasks for this host will be skipped.' } else { 'The final restart failure was recorded.' }
                    Write-Warning "Restart tracking on $($machine.Name) with Azure Local power API $script:HciPowerApi`: $($_.Exception.Message). $failureEffect"
                }
                continue
            }
            $sequence++
            $marker='task-' + [guid]::NewGuid().ToString('N')
            $commandName='AVDTask-' + $script:Run.runId.Replace('-','') + '-' + $sequence
            $commandId="$($machine.Id)/runCommands/$commandName"
            $record=[pscustomobject]@{taskId=$operation.Task.Id;resultTask=$operation.Task.ResultTask;hostName=$machine.Name;machineId=$machine.Id;commandId=$commandId;status='Prepared';executionState='';exitCode=$null;errorCode='';errorMessage='';result=$null;completionMarker="AVD_TASK_COMPLETED:$marker";completionVerified=$false;createdUtc=[datetime]::UtcNow.ToString('o');completedUtc=''}
            $script:Run.guestTasks=@($script:Run.guestTasks)+$record
            $batchRecords += $record
            if ($blockedMachines.ContainsKey($machine.Id)) {
                $record.status='Skipped'; $record.errorCode='PreviousRestartFailed'; $record.errorMessage='Guest task was skipped because the preceding session-host restart failed.'; $record.completedUtc=[datetime]::UtcNow.ToString('o')
                Save-Run
                Write-Warning "Guest task $($operation.Task.Id) skipped on $($machine.Name) because the preceding restart failed."
                continue
            }
            Save-Run
            try {
                $payload=Get-GuestTaskPayload $operation.Task $marker
                $body=New-GuestTaskRunCommandTemplate $machine.Location $payload $operation.Parameters
                Remove-CompletedGuestRunCommand $machine.Id
                $record.status='Submitting'; Save-Run
                Write-Event "Submitting guest task $($operation.Task.Id) to $($machine.Name). Track at $commandId"
                $null=Invoke-GuestTaskRunCommand $machine $commandName $body
                $record.status='Submitted'; Save-Run
                $null=Wait-GuestTaskCommand $record
            } catch {
                if ($_.Exception.Message -match 'Cannot create more than 25 RunCommands|RunCommandCapacity:') {
                    $record.status='Failed'; $record.errorCode='RunCommandCapacity'; $record.completedUtc=[datetime]::UtcNow.ToString('o')
                } elseif ($record.status -in @('Submitting','Submitted','Running','Tracking')) {
                    $record.status='Tracking'; $record.errorCode='SubmissionOrTrackingError'; $record.completedUtc=''
                } else {
                    $record.status='Failed'; $record.errorCode='SubmissionError'; $record.completedUtc=[datetime]::UtcNow.ToString('o')
                }
                $record.errorMessage=$_.Exception.Message
                Save-Run
                $nextStep=if ($record.status -eq 'Tracking') { 'Tracking state saved; use -Monitor with this run.json to resume verification.' } else { 'The task was not submitted. Resolve the submission error and run the task again.' }
                Write-Warning "Guest task $($operation.Task.Id) could not be verified on $($machine.Name): $($_.Exception.Message). $nextStep"
            }
        }
    }
    $verifiedCount=@($script:Run.guestTasks | Where-Object { $_.status -eq 'Succeeded' }).Count
    $restartSucceeded=@($script:Run.hostRestarts | Where-Object status -eq 'Succeeded').Count
    $script:Run.guestTaskStatus=if ($verifiedCount -eq $script:Run.guestTasks.Count -and $restartSucceeded -eq $script:Run.hostRestarts.Count) { 'Succeeded' } else { 'Partial' }
    if (-not @($script:Run.deployments).Count) { $script:Run.status=$script:Run.guestTaskStatus }
    Save-Run
    Show-AvdPanel 'GUEST OPERATIONS | RESULTS' @(
        "Tasks verified: $verifiedCount/$($script:Run.guestTasks.Count)",
        "Restarts completed: $restartSucceeded/$($script:Run.hostRestarts.Count)",
        "Tracking file: $script:RunFile"
    )
}

function Wait-GuestTaskRun {
    foreach ($taskRecord in $script:Run.guestTasks) {
        if ($taskRecord.status -eq 'Failed' -and $taskRecord.errorCode -eq 'SubmissionOrTrackingError') {
            $taskRecord.status='Tracking'; Save-Run
            Write-Event "Resuming verification for previously submitted guest task $($taskRecord.taskId) on $($taskRecord.hostName)."
        }
        if ($taskRecord.status -in @('Succeeded','Failed','TimedOut','NotSubmitted','Skipped')) { continue }
        if ($taskRecord.status -eq 'Prepared') {
            if (-not (Invoke-Arm "$($taskRecord.commandId)?api-version=$script:RunCommandApi" -AllowNotFound)) {
                $taskRecord.status='NotSubmitted'; $taskRecord.completedUtc=[datetime]::UtcNow.ToString('o'); Save-Run
                Write-Event "Guest task $($taskRecord.taskId) was prepared but never submitted for $($taskRecord.hostName)."
                continue
            }
        }
        $null=Wait-GuestTaskCommand $taskRecord
    }
    $restartRecords=if ($script:Run.PSObject.Properties['hostRestarts']) { @($script:Run.hostRestarts) } else { @() }
    foreach ($restartRecord in @($restartRecords | Where-Object status -eq 'Tracking')) {
        if (-not $restartRecord.correlationId -and -not $restartRecord.trackingUri) { continue }
        $headers=@{}
        if ($restartRecord.correlationId) { $headers['x-ms-correlation-request-id']=@([string]$restartRecord.correlationId) }
        if ($restartRecord.trackingUri) { $headers['Azure-AsyncOperation']=@([string]$restartRecord.trackingUri) }
        $submission=[pscustomobject]@{Headers=$headers}
        try {
            Write-Event "Resuming restart verification for $($restartRecord.hostName)."
            Wait-HciVmRestart $restartRecord.machineId $submission ([datetime]$restartRecord.createdUtc) $restartRecord
            Wait-ArcMachineAfterRestart $restartRecord.machineId
            $restartRecord.status='Succeeded'; $restartRecord.errorMessage=''; $restartRecord.completedUtc=[datetime]::UtcNow.ToString('o'); Save-Run
            Write-Event "Restart verification completed for $($restartRecord.hostName)."
        } catch {
            $acceptedUnverified=$_.Exception.Message -match '^AVD_RESTART_ACCEPTED_UNVERIFIED:'
            $restartRecord.status=if ($acceptedUnverified) { 'Tracking' } else { 'Failed' }
            $restartRecord.errorMessage=$_.Exception.Message
            if (-not $acceptedUnverified) { $restartRecord.completedUtc=[datetime]::UtcNow.ToString('o') }
            Save-Run
            Write-Warning "Restart verification on $($restartRecord.hostName) did not complete: $($_.Exception.Message)"
        }
    }
    if (@($script:Run.guestTasks | Where-Object status -in @('Failed','TimedOut','NotSubmitted','Skipped')).Count -or @($restartRecords | Where-Object status -ne 'Succeeded').Count) { $script:Run.guestTaskStatus='Partial' }
    elseif (@($script:Run.guestTasks | Where-Object status -eq 'Succeeded').Count -eq $script:Run.guestTasks.Count) { $script:Run.guestTaskStatus='Succeeded' }
    if (-not @($script:Run.deployments).Count) { $script:Run.status=$script:Run.guestTaskStatus }
    Save-Run
}

#endregion

#region Azure RBAC evaluation and permission repair
function Test-Action {
    param([object[]]$Permissions, [string]$Action)
    foreach ($permission in $Permissions) {
        # NotActions subtracts only from its own permission entry.
        $allow = @($permission.actions | Where-Object { $Action -like $_ }).Count -gt 0
        $exclude = @($permission.notActions | Where-Object { $Action -like $_ }).Count -gt 0
        if ($allow -and -not $exclude -and -not $permission.condition) { return $true }
    }
    return $false
}

function Get-MissingAction {
    param([string]$Scope, [string[]]$Actions)
    $permissions = @(Get-ArmList "$Scope/providers/Microsoft.Authorization/permissions?api-version=2022-04-01")
    foreach ($action in $Actions) { if (-not (Test-Action $permissions $action)) { $action } }
}

function Get-StableGuid {
    param([string]$Value)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = $sha.ComputeHash([text.encoding]::UTF8.GetBytes($Value.ToLowerInvariant()))
        return (New-Object Guid -ArgumentList (,[byte[]]$bytes[0..15])).ToString()
    } finally { $sha.Dispose() }
}

function Grant-Role {
    param([string]$Scope, [string]$ObjectId, [string]$RoleId, [string]$PrincipalType = 'ServicePrincipal')
    $assignments = @(Get-ArmList "$Scope/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01&`$filter=atScope()")
    $existing = @($assignments | Where-Object {
        $_.properties.principalId -eq $ObjectId -and $_.properties.roleDefinitionId -like "*/$RoleId" -and
        -not $_.properties.condition
    })
    if ($existing.Count) { return }
    $name = Get-StableGuid "$Scope|$ObjectId|$RoleId"
    $body = @{properties=@{principalId=$ObjectId;principalType=$PrincipalType;roleDefinitionId="$script:SubscriptionScope/providers/Microsoft.Authorization/roleDefinitions/$RoleId"}}
    $null = Invoke-Arm "$Scope/providers/Microsoft.Authorization/roleAssignments/${name}?api-version=2022-04-01" PUT $body
    Write-Event "Assigned role $RoleId to $ObjectId at $Scope."
}

function Invoke-AlternateUser {
    param([scriptblock]$Action)
    $saved = Get-AzContext
    try {
        Write-Host 'Sign in as a user with permission to perform the displayed prerequisite changes.' -ForegroundColor Yellow
        $null = Connect-AzAccount -Tenant $script:Tenant -Subscription $script:Subscription -UseDeviceAuthentication -Scope Process -Force
        if ((Get-AzContext).Account.Type -ne 'User') { throw 'An interactive user context is required for this repair.' }
        & $Action
    } finally {
        if ($saved) { $null = Set-AzContext -Context $saved }
    }
}

function Confirm-Permission {
    param([string]$Scope, [string[]]$Actions, [string[]]$RepairRoles)
    if ($script:RemovalPermissionBatch -and $script:RemovalPermissionProof) {
        $proof=$script:RemovalPermissionProof
        if ($proof.Principal -ne $script:SpnObjectId -or $proof.Tenant -ne $script:Tenant -or
            ([datetime]::UtcNow-$proof.VerifiedUtc).TotalMinutes -gt 30) { throw 'Removal permission preflight expired or account changed. Return to the menu and prepare again.' }
        $covered=@($proof.Targets | Where-Object { $Scope -eq $_.Scope -or $Scope.StartsWith($_.Scope.TrimEnd('/')+'/',[StringComparison]::OrdinalIgnoreCase) } | ForEach-Object Actions)
        if (-not @($Actions | Where-Object { $_ -notin $covered }).Count) { return }
        throw "A resource/action outside the reviewed removal permission set was discovered: $Scope. Return to the menu and prepare again."
    }
    while ($true) {
        try { $missing = @(Get-MissingAction $Scope $Actions) }
        catch { $missing = $Actions; Write-Warning "Unable to inspect permissions at $Scope." }
        if (-not $missing.Count) { Write-Host "[OK] Required permissions verified at $Scope" -ForegroundColor Green; return }
        if ($script:RemovalPermissionBatch) { throw "Removal permissions changed or a new resource scope was discovered: $Scope. Return to the menu and run grouped preparation again." }
        Write-Host "[FAILED] Missing or unverified SPN permissions at ${Scope}:" -ForegroundColor Red
        $missing | ForEach-Object { Write-Verbose "  $_" }
        Write-Host "Repair will grant these role IDs to SPN object $script:SpnObjectId at this scope: $($RepairRoles -join ', ')"
        if ((Read-Value 'Sign in as an alternate user to grant these roles? (Y/N)' 'Y' '^[YyNn]$') -ne 'Y') {
            throw 'Required permissions were not granted.'
        }
        try {
            Invoke-AlternateUser {
                foreach ($role in $RepairRoles) { Grant-Role $Scope $script:SpnObjectId $role }
            }
            $deadline = [datetime]::UtcNow.AddMinutes(10)
            do {
                try { $missing = @(Get-MissingAction $Scope $Actions) } catch { $missing = $Actions }
                if (-not $missing.Count) { Write-Host "[OK] Required permissions verified at $Scope" -ForegroundColor Green; return }
                Write-Event 'Waiting for SPN RBAC propagation...'
                Start-Sleep -Seconds $PollSeconds
            } while ([datetime]::UtcNow -lt $deadline)
            Write-Warning 'RBAC did not propagate within 10 minutes. Check deny assignments, conditions and PIM activation.'
        } catch { Write-Warning "Permission repair was not completed: $($_.Exception.Message)" }
        if ((Read-Value 'Retry this permission check and repair without losing the current selections? (Y/N)' 'Y' '^[YyNn]$') -ne 'Y') {
            throw 'Permission preflight cancelled. The protected operation was not started.'
        }
    }
}

#endregion

#region Microsoft Graph permissions and principal search
function Invoke-Graph {
    param([string]$Path, [string]$Method = 'GET', [object]$Body)
    # Same token-cache pattern as Invoke-Arm, scoped to the Graph resource instead of ARM.
    $token = (Get-AzAccessToken -ResourceUrl 'https://graph.microsoft.com/').Token
    if ($token -is [securestring]) { $token = [pscredential]::new('token',$token).GetNetworkCredential().Password }
    try {
        $uri = if ($Path -match '^https://') { $Path } else { "https://graph.microsoft.com/v1.0$Path" }
        $headers = @{Authorization = "Bearer $token"; ConsistencyLevel = 'eventual'}
        $request = @{Uri=$uri;Method=$Method;Headers=$headers;ErrorAction='Stop'}
        if ($null -ne $Body) { $request.Body = ($Body | ConvertTo-Json -Depth 20 -Compress); $request.ContentType = 'application/json' }
        return Invoke-RestMethod @request
    } finally { $token = $null; $headers = $null }
}

function Get-GraphList {
    param([string]$Path)
    $page = Invoke-Graph $Path
    foreach ($item in $page.value) { $item }
    while ($page.'@odata.nextLink') {
        $page = Invoke-Graph $page.'@odata.nextLink'
        foreach ($item in $page.value) { $item }
    }
}

function Get-ODataLiteral {
    param([string]$Value)
    # OData single-quote escaping for values interpolated into a $filter string.
    return $Value.Replace("'","''")
}

function Test-GraphAccess {
    # Check every permission in the catalog independently, not just one as a proxy for all:
    # a tenant that already granted Application.Read.All for some unrelated reason would
    # otherwise look "fully available" and the consent prompt for the other three (including
    # CrossTenantInformation.ReadBasic.All) would never fire.
    try {
        $null = Invoke-Graph '/servicePrincipals?$top=1'
        $null = Invoke-Graph '/users?$top=1'
        $null = Invoke-Graph '/groups?$top=1'
        $null = Invoke-Graph "/tenantRelationships/findTenantInformationByTenantId(tenantId='$script:Tenant')"
        return $true
    } catch { return $false }
}

function Get-GraphPermissionCatalog {
    # Single source of truth for every optional Microsoft Graph application permission this
    # script can use - both the up-front message and the actual grant loop read from this,
    # so the two can never drift apart. Checked against learn.microsoft.com on 2026-09-14 and
    # then against a real tenant, which is what actually matters: the docs list Group.ReadBasic.All
    # as valid for this, but this tenant's Microsoft Graph service principal has no application
    # role by that name at all (Grant-GraphReadAccess skips and warns on any name it can't find,
    # rather than failing the whole grant) - Group.Read.All is used instead, a long-standing
    # permission confirmed present. CrossTenantInformation.ReadBasic.All's need was also confirmed
    # live (403 Forbidden without it, not just a missing-token 401).
    return @(
        [pscustomobject]@{Name='Application.Read.All';Reason='resolve the Azure Stack HCI resource provider enterprise app by name instead of a manual object ID'}
        [pscustomobject]@{Name='User.Read.All';Reason='search users by name/UPN when assigning host pool access'}
        [pscustomobject]@{Name='Group.Read.All';Reason='search security groups by name when assigning host pool access'}
        [pscustomobject]@{Name='CrossTenantInformation.ReadBasic.All';Reason="show the tenant's display name and domain instead of just its ID"}
    )
}

function Grant-GraphReadAccess {
    param([switch]$RefreshSignIn)
    # One-time, tenant-wide change: consents read-only Microsoft Graph application permissions
    # for this SPN. Every one is optional - declining just keeps this run's existing manual
    # object ID / bare tenant ID fallbacks; nothing else is affected.
    $catalog = Get-GraphPermissionCatalog
    $appId = $script:SpnContext.Account.Id
    Write-Host "Microsoft Graph read permissions for service principal ($appId) are incomplete or unverified. Optional features that need them:" -ForegroundColor Yellow
    foreach ($permission in $catalog) { Write-Host ("  - {0,-38} {1}" -f $permission.Name, $permission.Reason) }
    Write-Host 'Granting any of these requires signing in as a Global Administrator or Privileged Role Administrator in this tenant.'
    Write-Host "Manual alternative: Microsoft Entra admin center > App registrations > find app ID $appId > API permissions > Add a permission > Microsoft Graph > Application permissions > add the roles above > Grant admin consent for this tenant."
    Write-Host "Direct link that should open that app's API permissions page: https://entra.microsoft.com/#view/Microsoft_AAD_RegisteredApps/ApplicationMenuBlade/~/CallAnAPI/appId/$appId/isMSAApp~/false"
    if ((Read-Value 'Sign in as a directory admin to grant these Microsoft Graph permissions to the SPN now? (Y/N)' 'N' '^[YyNn]$') -ne 'Y') { return $false }
    # $script: scope, not a plain local variable: a scriptblock invoked through Invoke-AlternateUser's
    # own "& $Action" runs in its own child scope, so assigning a plain $granted inside it shadows a
    # same-named local here instead of writing back to it - confirmed live, this silently made every
    # grant attempt report failure even after it fully succeeded. $script: is the one scope that is
    # always the same variable regardless of call depth.
    $script:GraphGrantApplied = $false
    Invoke-AlternateUser {
        $graphSp = @(Get-GraphList "/servicePrincipals?`$filter=appId eq '00000003-0000-0000-c000-000000000000'&`$select=id,appRoles") | Select-Object -First 1
        $spnSp = @(Get-GraphList "/servicePrincipals?`$filter=appId eq '$(Get-ODataLiteral $appId)'&`$select=id,appId") | Select-Object -First 1
        if (-not $graphSp -or -not $spnSp) { throw 'Could not resolve the Microsoft Graph or SPN service principal via Microsoft Graph.' }
        $assignments = @(Get-GraphList "/servicePrincipals/$($spnSp.id)/appRoleAssignments")
        foreach ($permission in $catalog) {
            $role = @($graphSp.appRoles | Where-Object { $_.value -eq $permission.Name -and $_.allowedMemberTypes -contains 'Application' }) | Select-Object -First 1
            if (-not $role) { Write-Warning "Microsoft Graph does not expose an application role named $($permission.Name) in this tenant; skipped."; continue }
            if (@($assignments | Where-Object { $_.appRoleId -eq $role.id -and $_.resourceId -eq $graphSp.id }).Count) { continue }
            $null = Invoke-Graph "/servicePrincipals/$($spnSp.id)/appRoleAssignments" POST @{principalId=$spnSp.id;resourceId=$graphSp.id;appRoleId=$role.id}
            Write-Event "Granted Microsoft Graph permission $($permission.Name) to SPN $($spnSp.appId)."
        }
        $script:GraphGrantApplied = $true
    }
    if (-not $script:GraphGrantApplied) { return $false }
    if ($RefreshSignIn -and -not (Test-GraphAccess)) {
        Write-Verbose 'Consent is saved. Refresh the SPN sign-in so verification can use a new Graph token instead of cached permissions.'
        # Only reuse the .env secret when it belongs to the current SPN and tenant.
        $secret = if ($env:AZSHCI_SPN_SECRET -and $env:AZSHCI_SPN_APP_ID -eq $script:SpnContext.Account.Id -and $env:AZSHCI_TENANT_ID -eq $script:Tenant) {
            ConvertTo-SecureString $env:AZSHCI_SPN_SECRET -AsPlainText -Force
        } else { Read-Host 'SPN secret for a fresh sign-in (no matching .env credentials)' -AsSecureString }
        try {
            $credential=[pscredential]::new($script:SpnContext.Account.Id,$secret)
            $null=Connect-AzAccount -ServicePrincipal -Tenant $script:Tenant -Subscription $script:Subscription -Credential $credential -Scope Process -Force
            $script:SpnContext=Get-AzContext
        } finally { $secret=$null; $credential=$null }
    }
    $deadline = [datetime]::UtcNow.AddMinutes(10)
    do {
        if (Test-GraphAccess) { return $true }
        Write-Event 'Waiting for Microsoft Graph permission propagation...'
        Start-Sleep -Seconds $PollSeconds
    } while ([datetime]::UtcNow -lt $deadline)
    Write-Warning 'Microsoft Graph permissions did not propagate in time. Falling back to manual object ID entry.'
    return $false
}

function Confirm-GraphAccess {
    if ($null -eq $script:GraphAvailable) {
        $script:GraphAvailable = Test-GraphAccess
        if (-not $script:GraphAvailable) { $script:GraphAvailable = Grant-GraphReadAccess }
    }
    return $script:GraphAvailable
}

function Search-GraphPrincipals {
    param([string]$Term, [ValidateSet('User','Group')][string]$Kind)
    # Each kind is tried and caught independently: this SPN can easily have User.Read.All
    # granted but not Group.Read.All (or vice versa), and a missing permission for the kind
    # the caller didn't ask for should never be why the one they did ask for comes back empty.
    $literal = Get-ODataLiteral $Term
    try {
        if ($Kind -eq 'User') {
            return @(Get-GraphList "/users?`$filter=startswith(displayName,'$literal') or startswith(userPrincipalName,'$literal')&`$select=id,displayName,userPrincipalName&`$count=true&`$top=25") |
                ForEach-Object { [pscustomobject]@{Id=$_.id;Type='User';Name="$($_.displayName) <$($_.userPrincipalName)>"} }
        }
        return @(Get-GraphList "/groups?`$filter=startswith(displayName,'$literal') and securityEnabled eq true&`$select=id,displayName&`$count=true&`$top=25") |
            ForEach-Object { [pscustomobject]@{Id=$_.id;Type='Group';Name="$($_.displayName) (security group)"} }
    } catch {
        Write-Warning "$Kind search via Microsoft Graph failed: $($_.Exception.Message)"
        return @()
    }
}

function Select-Multiple {
    param([object[]]$Items, [string]$Prompt, [switch]$AllowAll)
    if (-not $Items.Count) { Write-Host 'No matches.'; return @() }
    $menuLines=@(for ($i=0; $i -lt $Items.Count; $i++) { '  {0}. {1}' -f ($i+1), $Items[$i].Name })
    if ($AllowAll) { $menuLines+="  A. All $($Items.Count) session host(s)" }
    Show-AvdPanel $Prompt $menuLines
    $choice = if ($AllowAll) {
        Read-Value "$Prompt (comma-separated numbers, A for all, blank for none)" '' '^(?i:A|\d{1,3}(,\s*\d{1,3})*)?$'
    } else {
        Read-Value "$Prompt (comma-separated numbers, blank for none)" '' '^(\d{1,3}(,\s*\d{1,3})*)?$'
    }
    if (-not $choice) { return @() }
    if ($AllowAll -and $choice -ieq 'A') { return @($Items) }
    $indexes = @($choice -split ',\s*' | ForEach-Object { [int]$_ } | Where-Object { $_ -ge 1 -and $_ -le $Items.Count } | Select-Object -Unique)
    return @($indexes | ForEach-Object { $Items[$_-1] })
}

#endregion

#region Resource providers, Marketplace images and ARM deployments
function Confirm-ResourceProvider {
    param([string]$Namespace)
    $provider = Get-AzResourceProvider -ProviderNamespace $Namespace
    if ($provider.RegistrationState -eq 'Registered') { return }
    Write-Host "$Namespace needs subscription-level provider registration."
    if ((Read-Value 'Register using an alternate user? (Y/N)' 'Y' '^[YyNn]$') -ne 'Y') { throw "Provider $Namespace is not registered." }
    Invoke-AlternateUser { $null = Register-AzResourceProvider -ProviderNamespace $Namespace }
    $deadline = [datetime]::UtcNow.AddMinutes(10)
    do {
        if ((Get-AzResourceProvider -ProviderNamespace $Namespace).RegistrationState -eq 'Registered') { return }
        Start-Sleep -Seconds $PollSeconds
    } while ([datetime]::UtcNow -lt $deadline)
    throw "Timed out waiting for $Namespace registration."
}

function New-Template {
    param([object[]]$Resources, [hashtable]$Parameters = @{})
    return @{'$schema'='https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#';contentVersion='1.0.0.0';parameters=$Parameters;resources=@($Resources)}
}

function Resolve-MarketplaceImageVersion {
    param([string]$Location, [string]$Offer, [string]$Sku, [string]$Version = 'latest')
    if ([string]::IsNullOrWhiteSpace($Version) -or $Version -eq 'latest') {
        # Match stack-hci-vm's validator: resolve latest through Compute before sending ARM.
        $available = @(Get-AzVMImage -Location $Location -PublisherName 'microsoftwindowsdesktop' -Offer $Offer -Skus $Sku |
            Where-Object { $_.Version -match '^\d+\.\d+\.\d+$' } | Sort-Object { [version]$_.Version } -Descending)
        if (-not $available.Count) { throw 'No concrete image version could be resolved. Select a different SKU or enter a version.' }
        $Version = $available[0].Version
    }
    if ($Version -notmatch '^\d+\.\d+\.\d+$') { throw 'A concrete numeric Marketplace image version is required.' }
    return $Version
}

function New-MarketplaceImageTemplate {
    param([string]$Name, [string]$Location, [string]$CustomLocationId, [string]$StorageId,
        [string]$Offer, [string]$Sku, [Parameter(Mandatory)][ValidatePattern('^\d+\.\d+\.\d+$')][string]$Version)
    $properties = @{osType='Windows';hyperVGeneration='V2';version=@{name=$Version};
        identifier=@{publisher='microsoftwindowsdesktop';offer=$Offer;sku=$Sku}}
    if ($StorageId) { $properties.containerId = $StorageId }
    New-Template @(@{type='Microsoft.AzureStackHCI/marketplaceGalleryImages';apiVersion=$script:HciApi;
        name=$Name;location=$Location;extendedLocation=@{name=$CustomLocationId;type='CustomLocation'};properties=$properties})
}

function Format-ImageImportStatus {
    param([object]$Image)
    if (-not $Image) { return 'Waiting for the image resource' }
    $parts = @("Image: $($Image.properties.provisioningState)")
    $status = $Image.properties.status
    if ($null -ne $status.progressPercentage) { $parts += "download $($status.progressPercentage)%" }
    if ($status.downloadStatus.downloadSizeInMb) { $parts += "$($status.downloadStatus.downloadSizeInMb) MB" }
    if ($Image.properties.version.name) { $parts += "version $($Image.properties.version.name)" }
    if ($status.errorCode) { $parts += "error $($status.errorCode)" }
    return ($parts -join '; ')
}

function Wait-Deployment {
    param([object]$Deployment)
    $deadline = [datetime]::UtcNow.AddMinutes($TimeoutMinutes)
    $lastImageStatus = ''
    do {
        $result = Invoke-Arm "$($Deployment.id)?api-version=$script:ArmApi" -AllowNotFound
        $state = if ($result) { $result.properties.provisioningState } else { 'WaitingForVisibility' }
        if ($Deployment.PSObject.Properties['imageId'] -and $Deployment.imageId) {
            $imageState = Invoke-Arm "$($Deployment.imageId)?api-version=$script:HciApi" -AllowNotFound
            $imageStatus = Format-ImageImportStatus $imageState
            if ($imageStatus -ne $lastImageStatus) { Write-Event $imageStatus; $lastImageStatus = $imageStatus }
            if ($imageState.properties.status.errorCode) { $script:DeploymentErrorCodes += $imageState.properties.status.errorCode }
        }
        if ($Deployment.status -ne $state) {
            $Deployment.status = $state
            Write-Event "$($Deployment.name): $state"
            Save-Run
        }
        $operations = if ($result) { @(Get-ArmList "$($Deployment.id)/operations?api-version=$script:ArmApi") } else { @() }
        $active = @($operations | Where-Object { $_.properties.provisioningState -notin @('Succeeded','Ready') })
        foreach ($op in $active) {
            $target = $op.properties.targetResource.resourceName
            if ($target) { Write-Progress -Activity $Deployment.name -Status "$target : $($op.properties.provisioningState)" }
        }
        if ($state -eq 'Succeeded') { Write-Progress -Activity $Deployment.name -Completed; return }
        if ($state -in @('Failed','Canceled','Cancelled')) {
            # Only the error code, never statusMessage itself: operation payloads can echo
            # template content, and this script's templates carry secure parameters.
            foreach ($op in $active) {
                $code = $op.properties.statusMessage.error.code
                if ($code) { $script:DeploymentErrorCodes += $code }
                $suffix = if ($code) { "$($op.properties.provisioningState), $code" } else { $op.properties.provisioningState }
                Write-Event "Operation $($op.operationId): $($op.properties.targetResource.id) ($suffix)."
            }
            $codes = @($script:DeploymentErrorCodes | Select-Object -Unique)
            $detail = if ($codes.Count) { " Error codes: $($codes -join ', ')." } else { '' }
            throw "Deployment $($Deployment.name) ended with $state.$detail Details: $($Deployment.portalUrl)"
        }
        Start-Sleep -Seconds $PollSeconds
    } while ([datetime]::UtcNow -lt $deadline)
    throw "Monitoring timed out. Azure deployment continues. Use -Monitor '$script:RunFile'."
}

function Start-Deployment {
    param([string]$Scope, [string]$Stage, [hashtable]$Template, [hashtable]$Parameters = @{}, [string]$ImageId)
    $name = 'avd-' + $Stage + '-' + $script:Run.runId
    $script:DeploymentErrorCodes = @()
    $id = "$Scope/providers/Microsoft.Resources/deployments/$name"
    $entry = [pscustomobject]@{name=$name;id=$id;status='Prepared';portalUrl="https://portal.azure.com/#resource$id/overview"}
    if ($ImageId) { $entry | Add-Member -NotePropertyName imageId -NotePropertyValue $ImageId }
    $templatePath = Join-Path (Split-Path $script:RunFile) "$Stage.template.json"
    $Template | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $templatePath -Encoding UTF8
    $script:Run.deployments = @($script:Run.deployments) + $entry
    Save-Run
    Write-Event "Submitting $name. Track at $($entry.portalUrl)"
    $body = @{properties=@{mode='Incremental';template=$Template;parameters=$Parameters}}
    # ARM validates the complete template before submitting the deployment.
    $null = Invoke-Arm "$id/validate?api-version=$script:ArmApi" POST $body
    $null = Invoke-Arm "$id`?api-version=$script:ArmApi" PUT $body
    $entry.status = 'Submitted'
    if ($Stage -eq 'avd-agent') { $script:Run.registrationSubmitted = $true }
    Save-Run
    Wait-Deployment $entry
}

function Assert-NewResource {
    param([string]$Id, [string]$Api)
    if (Invoke-Arm "$Id`?api-version=$Api" -AllowNotFound) {
        throw "Resource already exists: $Id. Choose a different name. Use -Monitor for previous deployments."
    }
}

#endregion

#region Azure Local resources and session host availability
function Get-LocalResource {
    param([string]$Type, [string]$CustomId)
    @(Get-ArmList "$script:InfraScope/providers/Microsoft.AzureStackHCI/$Type`?api-version=$script:HciApi") |
        Where-Object { $_.extendedLocation.name -eq $CustomId -and $_.properties.provisioningState -eq 'Succeeded' }
}

function Select-AvdLogicalNetwork {
    param([string]$CustomLocationId)
    while ($true) {
        # Azure Local creates <cluster-name>-InfraLNET; API list order is not meaningful.
        $networks = @(Get-LocalResource 'logicalNetworks' $CustomLocationId | Sort-Object @{Expression={ $_.name -match '-InfraLNET$' }}, name)
        $vmNetworks = @($networks | Where-Object { $_.name -notmatch '-InfraLNET$' })
        if (-not $vmNetworks.Count) {
            Write-Warning 'No additional, successfully provisioned logical network exists for this custom location. The default infrastructure network should not be used for session hosts. Create a VM logical network in the Azure portal, then refresh.'
            Write-Host "Infrastructure resource group: https://portal.azure.com/#resource$script:InfraScope/overview"
            Write-Host 'Open your Azure Local cluster and create a logical network for VMs using the selected custom location.'
            Write-Host 'Portal instructions: https://learn.microsoft.com/en-us/azure/azure-local/manage/create-logical-networks?tabs=azureportal'
            if ((Read-Value 'Refresh logical networks after creating a VM network? (Y/N; N cancels this deployment)' 'Y' '^[YyNn]$') -ne 'Y') { return $null }
            continue
        }
        $choices = @($networks | ForEach-Object {
            $infra = $_.name -match '-InfraLNET$'
            [pscustomobject]@{Name=if ($infra) { "$($_.name) [Infrastructure - should not be used for session hosts]" } else { $_.name };Resource=$_;Infrastructure=$infra}
        })
        $selectedNetwork = Select-Item $choices 'Select logical network'
        if ($selectedNetwork.Infrastructure) {
            Write-Warning 'This is the default Azure Local infrastructure network. Select a VM logical network instead.'
            continue
        }
        return $selectedNetwork.Resource
    }
}

function Format-SessionHostDetail {
    param([object]$SessionHost)
    if (-not $SessionHost) { return 'not yet registered with the host pool' }
    $status = $SessionHost.properties.status
    $failed = @($SessionHost.properties.sessionHostHealthCheckResults | Where-Object { $_.healthCheckResult -and $_.healthCheckResult -ne 'HealthCheckSucceeded' })
    if ($failed.Count) { return "$status - failed checks: $(($failed | ForEach-Object { $_.healthCheckName }) -join ', ')" }
    return $status
}

function Wait-SessionHosts {
    $deadline = [datetime]::UtcNow.AddMinutes($TimeoutMinutes)
    $lastDetail = @{}
    do {
        $hosts = @(Get-ArmList "$($script:Run.hostPoolId)/sessionHosts?api-version=$script:AvdApi")
        $ready = 0
        foreach ($vmName in $script:Run.sessionHosts) {
            $match = @($hosts | Where-Object { (($_.name -split '/')[-1] -split '\.')[0] -eq $vmName })
            $one = if ($match.Count -eq 1) { $match[0] } else { $null }
            if ($one -and $one.properties.status -eq 'Available') { $ready++ }
            # Only log per-host detail when it changes, so a long stall does not spam the run log.
            $detail = Format-SessionHostDetail $one
            if ($lastDetail[$vmName] -ne $detail) {
                Write-Event "${vmName}: $detail"
                $lastDetail[$vmName] = $detail
            }
        }
        Write-Event "Available session hosts: $ready/$($script:Run.sessionHosts.Count)"
        if ($ready -eq $script:Run.sessionHosts.Count) { return }
        Start-Sleep -Seconds $PollSeconds
    } while ([datetime]::UtcNow -lt $deadline)
    throw 'Session hosts did not become Available in time. Review Entra join, Arc connectivity and AVD agent health in the portal.'
}

#endregion

#region Tenant and service principal discovery
function Get-AmbientTenants {
    param([object]$Context)
    # A leftover SPN context from a previous run (this script ends by restoring it, and Az
    # persists context across sessions by default) usually can't read tenant display names,
    # so only a human context is used to seed the friendly tenant picker.
    if (-not $Context -or $Context.Account.Type -ne 'User') { return @() }
    try { return @(Get-AzTenant -ErrorAction Stop) }
    catch { Write-Warning 'Tenant names could not be retrieved from the current account. They will be requested again after SPN login.'; return @() }
}

function Select-TenantFromUserContext {
    param([object]$Context, [string]$PreferredTenantId)
    # Only a human context can list tenant display names; used solely to pick a tenant to
    # deploy into. The deployment itself always authenticates as the service principal.
    $tenants = @(Get-AmbientTenants $Context)
    if (-not $tenants.Count) { return [pscustomobject]@{TenantId=$null;Tenants=@()} }
    $tenantChoices = @($tenants | Sort-Object @{Expression={$_.Id -ne $PreferredTenantId}},Id | ForEach-Object {
        [pscustomobject]@{Name=(Get-TenantLabel $_);Id=$_.Id}
    })
    $picked = (Select-Item $tenantChoices 'Select tenant').Id
    return [pscustomobject]@{TenantId=$picked;Tenants=$tenants}
}

function Get-SpnObjectId {
    # The token's oid is the enterprise application object ID, not the app/client ID.
    $token = (Get-AzAccessToken -ResourceUrl 'https://management.azure.com/').Token
    if ($token -is [securestring]) { $token = [pscredential]::new('token',$token).GetNetworkCredential().Password }
    try {
        $part = $token.Split('.')[1].Replace('-','+').Replace('_','/')
        $part = $part.PadRight($part.Length + ((4-$part.Length%4)%4),'=')
        $claims = [text.encoding]::UTF8.GetString([convert]::FromBase64String($part)) | ConvertFrom-Json
        if (-not $claims.oid -or $claims.tid -ne $script:Tenant) { throw 'Unexpected ARM token identity.' }
        return $claims.oid
    } finally { $token = $null; $claims = $null }
}

#endregion

#region Deployment templates and AVD registration
function New-SessionHostTemplate {
    param([string[]]$Names, [string]$Location, [string]$CustomId, [string]$ImageId,
        [string]$NetworkId, [string]$StorageId, [int]$Cpu, [int]$MemoryMB, [string]$AdminUser)
    $resources = @()
    foreach ($vm in $Names) {
        $machineId = "$script:AvdScope/providers/Microsoft.HybridCompute/machines/$vm"
        $nicId = "$script:AvdScope/providers/Microsoft.AzureStackHCI/networkInterfaces/nic-$vm"
        $resources += @{type='Microsoft.HybridCompute/machines';apiVersion=$script:ArcApi;name=$vm;location=$Location;kind='HCI';identity=@{type='SystemAssigned'};properties=@{}}
        $resources += @{type='Microsoft.AzureStackHCI/networkInterfaces';apiVersion=$script:HciApi;name="nic-$vm";location=$Location;
            extendedLocation=@{type='CustomLocation';name=$CustomId};properties=@{ipConfigurations=@(@{name='ipconfig1';properties=@{subnet=@{id=$NetworkId}}})}}
        $resources += @{type='Microsoft.AzureStackHCI/virtualMachineInstances';apiVersion=$script:HciApi;name='default';scope="Microsoft.HybridCompute/machines/$vm";
            extendedLocation=@{type='CustomLocation';name=$CustomId};dependsOn=@($machineId,$nicId);properties=@{
                hardwareProfile=@{vmSize='Custom';processors=$Cpu;memoryMB=$MemoryMB}
                osProfile=@{computerName=$vm;adminUsername=$AdminUser;adminPassword="[parameters('adminPassword')]";windowsConfiguration=@{provisionVMAgent=$true;provisionVMConfigAgent=$true}}
                storageProfile=@{imageReference=@{id=$ImageId};vmConfigStoragePathId=$StorageId;osDisk=@{osType='Windows'}}
                securityProfile=@{enableTPM=$true;uefiSettings=@{secureBootEnabled=$true}}
                networkProfile=@{networkInterfaces=@(@{id=$nicId})}
            }}
    }
    New-Template $resources @{adminPassword=@{type='securestring'}}
}

function New-ExtensionTemplate {
    param([string[]]$Names, [string]$Location, [string]$MdmId = '')
    $resources = foreach ($vm in $Names) {
        @{type='Microsoft.HybridCompute/machines/extensions';apiVersion=$script:ArcApi;name="$vm/AADLoginForWindows";location=$Location;
            properties=@{publisher='Microsoft.Azure.ActiveDirectory';type='AADLoginForWindows';typeHandlerVersion='2.0';autoUpgradeMinorVersion=$true;settings=@{mdmId=$MdmId}}}
    }
    New-Template @($resources) @{}
}

function New-RegistrationTemplate {
    param([string[]]$Names, [string]$Location)
    # Arc executes a readable script. Only the token is secret; no compressed launcher.
    $resources = foreach ($vm in $Names) {
        @{type='Microsoft.HybridCompute/machines/runCommands';apiVersion='2025-01-13';name="$vm/AVDRegistration";location=$Location;
            properties=@{asyncExecution=$false;timeoutInSeconds=1800;source=@{script=(Get-SessionHostPayload)};
                protectedParameters=@(@{name='RegistrationToken';value="[parameters('registrationToken')]"})}}
    }
    New-Template @($resources) @{registrationToken=@{type='securestring'}}
}

function Get-SessionHostPayload {
    # The script contains no secret. Arc supplies the token as a protected parameter.
    return @'
#Requires -Version 5.1
# Guest payload for 30_AVDAzureLocal.ps1. Do not run directly.
param([string]$RegistrationToken)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$stage = 'checking Entra join'
try {
    Write-Output 'AVD guest setup started.'
    $state = & dsregcmd.exe /status
    if ($LASTEXITCODE -ne 0 -or ($state -join "`n") -notmatch 'AzureAdJoined\s*:\s*YES') { throw 'The VM is not Microsoft Entra joined.' }
    if (($state -join "`n") -match 'DomainJoined\s*:\s*YES') { throw 'AD DS joined VMs are not allowed in this host pool.' }
    $agentKey = 'HKLM:\SOFTWARE\Microsoft\RDInfraAgent'
    $existing = Get-ItemProperty -Path $agentKey -ErrorAction SilentlyContinue
    if ($existing.IsRegistered -eq 1 -and (Get-Service RDAgentBootLoader -ErrorAction SilentlyContinue).Status -eq 'Running') {
        Write-Output 'AVD agent is already registered and running.'
        return
    }
    if ($RegistrationToken -notmatch '^[A-Za-z0-9._~+/=-]+$') { throw 'Missing or invalid registration token.' }
    $folder = Join-Path $env:ProgramData 'AzSHCI\AVD'
    $null = New-Item -ItemType Directory -Path $folder -Force
    $sources = @(
        @{name='Agent.msi';uri='https://go.microsoft.com/fwlink/?linkid=2310011'},
        @{name='BootLoader.msi';uri='https://go.microsoft.com/fwlink/?linkid=2311028'}
    )
    foreach ($source in $sources) {
        $stage = "downloading $($source.name)"
        Write-Output $stage
        $path = Join-Path $folder $source.name
        Invoke-WebRequest -Uri $source.uri -OutFile $path -UseBasicParsing -TimeoutSec 180
        $signature = Get-AuthenticodeSignature -LiteralPath $path
        if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation') {
            throw 'An AVD installer does not have a valid Microsoft signature.'
        }
    }
    foreach ($source in $sources) {
        $stage = "installing $($source.name)"
        Write-Output $stage
        $path = Join-Path $folder $source.name
        $arguments = '/i "' + $path + '" /quiet /norestart'
        if ($source.name -eq 'Agent.msi') { $arguments += ' REGISTRATIONTOKEN="' + $RegistrationToken + '"' }
        # Avoid verbose MSI logs because they can contain the registration token.
        $process = Start-Process -FilePath msiexec.exe -ArgumentList $arguments -Wait -PassThru -WindowStyle Hidden
        if ($process.ExitCode -notin @(0,3010)) { throw "AVD installer failed with exit code $($process.ExitCode)." }
    }
    $stage = 'registering the AVD agent (check broker connectivity and Windows event logs)'
    # MSI maintenance mode may not apply a new token on a retry. Refresh only an unregistered agent.
    if ((Get-ItemProperty -Path $agentKey).IsRegistered -ne 1) {
        Set-ItemProperty -Path $agentKey -Name IsRegistered -Value 0
        Set-ItemProperty -Path $agentKey -Name RegistrationToken -Value $RegistrationToken
        Restart-Service RDAgentBootLoader
    } else { Start-Service RDAgentBootLoader }
    $deadline = [datetime]::UtcNow.AddMinutes(10)
    do {
        $agentState = Get-ItemProperty -Path $agentKey
        if ($agentState.IsRegistered -eq 1 -and [string]::IsNullOrEmpty($agentState.RegistrationToken) -and
            (Get-Service RDAgentBootLoader).Status -eq 'Running') {
            Write-Output 'AVD agent registration verified. Boot Loader is running.'
            return
        }
        Start-Sleep -Seconds 15
    } while ([datetime]::UtcNow -lt $deadline)
    throw 'AVD agent registration did not complete within ten minutes.'
} catch {
    # Do not echo exception invocation details, commands or token-bearing variables.
    Write-Output "AVD guest setup failed while $stage."
    exit 1
} finally { $RegistrationToken = $null; $arguments = $null; $agentState = $null }
'@
}

function Wait-Registration {
    param([string[]]$Ids)
    foreach ($id in $Ids) {
        $deadline = [datetime]::UtcNow.AddMinutes($TimeoutMinutes)
        do {
            $result = Invoke-Arm "$id`?api-version=2025-01-13&`$expand=instanceView"
            $view = $result.properties.instanceView
            if ($view.executionState -eq 'Succeeded' -and $view.exitCode -eq 0 -and
                $view.output -match 'AVD agent (registration verified|is already registered and running)') { break }
            if ($view.executionState -in @('Succeeded','Failed','TimedOut','Canceled','Cancelled')) {
                throw "AVD registration command did not verify registration: $id (state $($view.executionState), exit $($view.exitCode)). Review its output in Azure Arc Run Command."
            }
            Start-Sleep -Seconds $PollSeconds
        } while ([datetime]::UtcNow -lt $deadline)
        if ([datetime]::UtcNow -ge $deadline) { throw "Timed out waiting for AVD registration: $id" }
        Write-Event "AVD guest registration verified: $id"
    }
}

$script:SavedAvdWarningPreference = $WarningPreference
#endregion

#region Main deployment and management workflow
try {
    $WarningPreference = if ($VerbosePreference -eq 'Continue') { 'Continue' } else { 'SilentlyContinue' }
    if ($Monitor) {
        Show-AvdPanel 'AVD | MONITOR' @('Connect to Azure and resume verification of the recorded run.')
    } else {
        Show-AvdPanel 'AVD | CONNECT TO AZURE' @(
            'Confirm your account, then select the tenant and subscription.',
            'The deployment and management menu opens after sign-in.'
        )
    }
    foreach ($module in @('Az.Accounts','Az.Resources','Az.Compute','Az.ConnectedMachine')) {
        if (-not (Get-Module -ListAvailable -Name $module)) {
            if ((Read-Value "Install $module from PSGallery for the current user? (Y/N)" 'Y' '^[YyNn]$') -ne 'Y') { throw "Module $module is required." }
            Install-Module $module -Scope CurrentUser -Repository PSGallery -Force -AllowClobber
        }
        Import-Module $module
    }
    $null = Disable-AzContextAutosave -Scope Process
    if ($Monitor) {
        $script:RunFile = (Resolve-Path -LiteralPath $Monitor).Path
        $script:Run = Get-Content -LiteralPath $script:RunFile -Raw | ConvertFrom-Json
        $script:Subscription = $script:Run.subscriptionId
        $script:Tenant = $script:Run.tenantId
        if (-not (Get-AzContext)) { $null = Connect-AzAccount -Tenant $script:Tenant -Subscription $script:Subscription -UseDeviceAuthentication -Scope Process }
        $null = Set-AzContext -Subscription $script:Subscription -Tenant $script:Tenant
        foreach ($deployment in $script:Run.deployments) {
            if ($deployment.status -eq 'Prepared' -and -not (Invoke-Arm "$($deployment.id)?api-version=$script:ArmApi" -AllowNotFound)) {
                Write-Event "$($deployment.name) was prepared but never submitted."
                continue
            }
            Wait-Deployment $deployment
        }
        if ($script:Run.registrationSubmitted) {
            if ($script:Run.PSObject.Properties['registrationCommands']) { Wait-Registration $script:Run.registrationCommands }
            Wait-SessionHosts
        }
        if ($script:Run.PSObject.Properties['guestTasks'] -and $script:Run.guestTasks.Count) { Wait-GuestTaskRun }
        if ($script:Run.PSObject.Properties['scalingPlanId'] -and $script:Run.scalingPlanId) {
            $scalingPlan=Invoke-Arm "$($script:Run.scalingPlanId)?api-version=$script:AvdApi" -AllowNotFound
            if ($scalingPlan) {
                $scalingReference=@($scalingPlan.properties.hostPoolReferences | Where-Object hostPoolArmPath -eq $script:Run.hostPoolId)
                Write-Host "Scaling plan: $($scalingPlan.name) | Time zone: $($scalingPlan.properties.timeZone) | Enabled for this pool: $($scalingReference.scalingPlanEnabled)"
            } else { Write-Warning 'The recorded scaling plan does not currently exist.' }
        }
        if ($script:Run.PSObject.Properties['deploymentRemoval']) {
            $removal=$script:Run.deploymentRemoval
            Write-Host "Deployment removal: $($script:Run.status)"
            foreach ($entry in @($removal.actions)+@($removal.applicationGroups)+@(@{id=$script:Run.hostPoolId;status=$removal.hostPoolStatus})) {
                $present=$null -ne (Invoke-Arm "$($entry.id)?api-version=$script:AvdApi" -AllowNotFound)
                Write-Host "  Present=$present | recorded=$($entry.status) : $($entry.id)"
            }
            if ($removal.hostRemovalRun) { Write-Host "VM/Entra/attachment stages: .\30_AVDAzureLocal.ps1 -Monitor '$($removal.hostRemovalRun)'" }
            if ($removal.resourceGroup) {
                $present=$null -ne (Invoke-Arm "$($removal.resourceGroup.id)?api-version=2022-09-01" -AllowNotFound)
                Write-Host "Resource group present=$present | recorded=$($removal.resourceGroup.status)"
            }
            Write-Host 'Read-only inspection. For retained shared resources, inspect their associations; presence is expected. No deletion stages were resubmitted.'
        }
        if ($script:Run.PSObject.Properties['removals']) {
            foreach ($removal in $script:Run.removals) {
                Write-Host "Removal $($removal.name): last saved stage $($removal.stage). $($removal.error)"
                foreach ($resource in @(@{Id=$removal.instanceId;Api=$script:HciApi},@{Id=$removal.machineId;Api=$script:ArcApi},@{Id=$removal.sessionHostId;Api=$script:AvdApi})) {
                    $present=$null -ne (Invoke-Arm "$($resource.Id)?api-version=$($resource.Api)" -AllowNotFound)
                    Write-Host "  Present=$present : $($resource.Id)"
                }
                $devices=@(if ($removal.deviceId) { Get-GraphList "/devices?`$filter=deviceId eq '$($removal.deviceId)'&`$select=id" })
                Write-Host "  Entra device present=$($devices.Count -gt 0) : $($removal.deviceId)"
                foreach ($resource in $removal.cleanupResources) {
                    $present=$null -ne (Invoke-Arm "$($resource.id)?api-version=$script:HciApi" -AllowNotFound)
                    Write-Host "  Attachment present=$present | saved status=$($resource.status) : $($resource.id)"
                }
            }
            Write-Host 'Removal monitoring is read-only. Unfinished deletion stages are not resubmitted.'
        }
        Write-Event "Monitoring complete. Workflow status: $($script:Run.status). This mode does not submit missing stages."
        return
    }

    $envFile = Join-Path $PSScriptRoot '..\01Lab\.env'
    if (-not $env:AZSHCI_ENV_LOADED -and (Test-Path -LiteralPath $envFile)) {
        & (Join-Path $PSScriptRoot '..\01Lab\Set-LabEnv.ps1') -Quiet
    }
    if (-not $TenantId) { $TenantId = $env:AZSHCI_TENANT_ID }
    if (-not $SubscriptionId) { $SubscriptionId = $env:AZSHCI_SUBSCRIPTION_ID }

    # Never silently reuse a leftover session or an environment-configured credential: ask
    # first, and show the tenant it actually belongs to so the answer means something.
    $context = Get-AzContext
    $tenants = @()
    $confirmed = $false
    $ambientUsable = $context -and (-not $PSBoundParameters.ContainsKey('TenantId') -or $PSBoundParameters['TenantId'] -eq $context.Tenant.Id)
    if ($ambientUsable) {
        $who = if ($context.Account.Type -eq 'ServicePrincipal') { "service principal $($context.Account.Id)" } else { "user $($context.Account.Id)" }
        $authTenant = try { Get-AzTenant -TenantId $context.Tenant.Id -ErrorAction Stop } catch { $null }
        $ambientLabel = Resolve-TenantLabel $context.Tenant.Id $authTenant
        Show-AvdPanel 'EXISTING AZURE SIGN-IN' @("Account: $who", "Tenant: $ambientLabel", 'Use this account or choose another sign-in below.')
        $confirmed = (Read-Value 'Use this account? (Y/N)' 'Y' '^[YyNn]$') -eq 'Y'
        if ($confirmed -and $context.Account.Type -eq 'ServicePrincipal' -and -not $TenantId) { $TenantId = $context.Tenant.Id }
        if (-not $confirmed) { $context = $null }
    } elseif ($env:AZSHCI_SPN_APP_ID -and $TenantId) {
        Write-Host "Found a configured service principal in the environment: $($env:AZSHCI_SPN_APP_ID) for tenant $TenantId."
        if ((Read-Value 'Use this credential? (Y/N)' 'Y' '^[YyNn]$') -eq 'Y') {
            $secret = if ($env:AZSHCI_SPN_SECRET) { ConvertTo-SecureString $env:AZSHCI_SPN_SECRET -AsPlainText -Force } else { Read-Host 'SPN secret' -AsSecureString }
            $credential = New-Object System.Management.Automation.PSCredential($env:AZSHCI_SPN_APP_ID,$secret)
            $null = Connect-AzAccount -ServicePrincipal -Tenant $TenantId -Credential $credential -Scope Process
            $secret = $null; $credential = $null
            $context = Get-AzContext
            $confirmed = $true
        }
    }

    if ($confirmed -and $context.Account.Type -eq 'User') {
        $picked = Select-TenantFromUserContext $context $TenantId
        $TenantId = $picked.TenantId
        $tenants = $picked.Tenants
        Write-Host 'This sign-in only selects the tenant. The deployment always runs as a service principal, entered next.'
        $context = $null
    } elseif (-not $confirmed) {
        $mode = Select-Item @(
            [pscustomobject]@{Name='Service principal: enter tenant, app ID and secret directly'}
            [pscustomobject]@{Name='Interactive user: sign in to browse available tenants first'}
        ) 'How do you want to sign in'
        if ($mode.Name -like 'Interactive*') {
            $null = Connect-AzAccount -UseDeviceAuthentication -Scope Process
            $picked = Select-TenantFromUserContext (Get-AzContext) $TenantId
            $TenantId = $picked.TenantId
            $tenants = $picked.Tenants
            Write-Host 'This sign-in only selects the tenant. The deployment always runs as a service principal, entered next.'
        }
    }
    if (-not $TenantId) { $TenantId = Read-Value 'Tenant domain or ID for SPN login' '' '^(?:[0-9a-fA-F-]{36}|[a-zA-Z0-9][a-zA-Z0-9.-]+\.[a-zA-Z]{2,})$' }
    if (-not ($context -and $context.Account.Type -eq 'ServicePrincipal')) {
        $appId = Read-Value 'SPN application (client) ID' $env:AZSHCI_SPN_APP_ID '^[0-9a-fA-F-]{36}$'
        $secret = if ($env:AZSHCI_SPN_SECRET) { ConvertTo-SecureString $env:AZSHCI_SPN_SECRET -AsPlainText -Force } else { Read-Host 'SPN secret' -AsSecureString }
        $credential = New-Object System.Management.Automation.PSCredential($appId,$secret)
        $null = Connect-AzAccount -ServicePrincipal -Tenant $TenantId -Credential $credential -Scope Process
        $secret = $null; $credential = $null
    }
    # Use the authenticated GUID internally even when login used a domain name.
    $TenantId = (Get-AzContext).Tenant.Id
    $authTenant = try { Get-AzTenant -TenantId $TenantId -ErrorAction Stop } catch { @($tenants | Where-Object Id -eq $TenantId | Select-Object -First 1)[0] }
    $tenantLabel = Resolve-TenantLabel $TenantId $authTenant
    Write-Host "Tenant: $tenantLabel" -ForegroundColor Cyan
    if (-not $PSBoundParameters.ContainsKey('SubscriptionId')) {
        $subscriptions = @(Get-AzSubscription -TenantId $TenantId | Where-Object State -eq 'Enabled' |
            Sort-Object @{Expression={$_.Id -ne $SubscriptionId}},Name | ForEach-Object {
                [pscustomobject]@{Name="$($_.Name) [$($_.Id)]";Id=$_.Id}
            })
        $subscription = Select-Item $subscriptions 'Select subscription'
        $SubscriptionId = $subscription.Id
    }
    $script:SpnContext = Set-AzContext -Subscription $SubscriptionId -Tenant $TenantId
    if ($script:SpnContext.Account.Type -ne 'ServicePrincipal') { throw 'Deployment must run as the SPN.' }
    if ($script:SpnContext.Environment.Name -ne 'AzureCloud') { throw 'This script currently targets Azure public cloud.' }
    $script:Subscription = $SubscriptionId
    $script:Tenant = $TenantId
    $script:SubscriptionScope = "/subscriptions/$SubscriptionId"
    $script:AvdHistoryRoot = Join-Path $env:LOCALAPPDATA 'AVDEntraJoin\runs'
    $script:SpnObjectId = Get-SpnObjectId
    Show-AvdPanel 'CONNECTED AZURE SCOPE' @(
        "Subscription: $($script:SpnContext.Subscription.Name)",
        "Subscription ID: $SubscriptionId",
        "Tenant: $tenantLabel",
        "Service principal: $($script:SpnContext.Account.Id)"
    )
    $expansionPool=$null
    $startNewDeployment=$false
    $welcomeShown=$false
    while (-not $startNewDeployment) {
        # Existing deployments are discovered from Azure on every interactive run. Local run files
        # are only correlated as optional history and are never the source of truth.
        $existingPools = @()
        $poolDiscoveryRestricted = $false
        try { $existingPools = @(Get-ExistingAvdDeployment $script:SubscriptionScope) }
        catch {
            $poolDiscoveryRestricted = $true
            Write-Warning 'Host pool discovery was restricted or unavailable. Existing deployments could not be ruled out.'
            Write-Host 'Use Configure permissions to repair discovery access, or choose a new deployment with exact resource-name checks.'
        }
        if ($existingPools.Count) {
            Write-Host "Discovered $($existingPools.Count) host pool(s) in the selected subscription."
        } elseif (-not $poolDiscoveryRestricted) {
            Write-Host 'No host pools were returned for the current account in this subscription. Refresh discovery or search a resource group from Adjust an existing deployment.'
        }
        $actionItems = @(
            [pscustomobject]@{Name='New deployment';Kind='New'}
            [pscustomobject]@{Name='Adjust an existing deployment';Kind='Adjust'}
            [pscustomobject]@{Name='Refresh host pool discovery';Kind='Refresh'}
            [pscustomobject]@{Name='Configure permissions for the current SPN';Kind='Permissions'}
            [pscustomobject]@{Name='Exit';Kind='Exit'}
        )
        if (-not $welcomeShown) {
            Show-AvdPanel 'AZURE VIRTUAL DESKTOP | AZURE LOCAL' @(
        '       ___     _    __   ____       .------------------.',
        '      /   |   | |  / /  / __ \      |  AZURE  /  LOCAL  |',
        '     / /| |   | | / /  / / / /      |                  |',
        '    / ___ |   | |/ /  / /_/ /       |  [ desktop ]     |',
        '   /_/  |_|   |___/  /_____/        |          [ + ]   |',
        '                                   ''------------------''',
        '                                           _|__|_',
        '',
        '   YOUR DESKTOPS. YOUR INFRASTRUCTURE.',
        '   Microsoft Entra joined | Powered by Azure Local',
        '',
        '   DEPLOY   /   CONFIGURE   /   SCALE   /   MAINTAIN',
        '',
        '   Connected. Select an action from the menu below.'
    )
            $welcomeShown=$true
        }
        $avdDeploymentChoice = Select-Item $actionItems 'Choose deployment action'
        if ($avdDeploymentChoice.Kind -eq 'Exit') { return }
        if ($avdDeploymentChoice.Kind -eq 'Refresh') { continue }
        if ($avdDeploymentChoice.Kind -eq 'Permissions') { try { Invoke-AvdPermissionMenu } catch { Write-Warning "Permission configuration stopped: $($_.Exception.Message). Completed grants are retained." }; continue }
        if ($avdDeploymentChoice.Kind -eq 'New') { $startNewDeployment=$true; break }

        $returnToDeploymentMenu=$false
        while (-not $returnToDeploymentMenu) {
            $poolChoices = @($existingPools | ForEach-Object {
                [pscustomobject]@{Name="$($_.Name) [$($_.ResourceGroup)] | $($_.HostPoolType) | $($_.Location)";Kind='Pool';Deployment=$_}
            })
            $poolChoices += [pscustomobject]@{Name='Refresh subscription discovery';Kind='Refresh';Deployment=$null}
            $poolChoices += [pscustomobject]@{Name='Discover host pools in a resource group';Kind='ResourceGroup';Deployment=$null}
            $poolChoices += [pscustomobject]@{Name='Back';Kind='Back';Deployment=$null}
            $poolChoices += [pscustomobject]@{Name='Exit';Kind='Exit';Deployment=$null}
            $poolChoice = Select-Item $poolChoices 'Select the host pool to adjust' 'Name'
            if ($poolChoice.Kind -eq 'Exit') { return }
            if ($poolChoice.Kind -eq 'Back') { $returnToDeploymentMenu=$true; continue }
            if ($poolChoice.Kind -in @('Refresh','ResourceGroup')) {
                try {
                    $discoveryScope=$script:SubscriptionScope
                    if ($poolChoice.Kind -eq 'ResourceGroup') {
                        $discoveryGroup=Select-ResourceGroup 'Select resource group containing the host pool' ''
                        $discoveryScope="$script:SubscriptionScope/resourceGroups/$discoveryGroup"
                    }
                    $discoveredPools=@(Get-ExistingAvdDeployment $discoveryScope)
                    if ($poolChoice.Kind -eq 'Refresh') { $existingPools=$discoveredPools }
                    else { $existingPools=@($existingPools | Where-Object { $_.Id -notlike "$discoveryScope/providers/*" })+@($discoveredPools) }
                    Write-Host "Discovered $($discoveredPools.Count) host pool(s) at $discoveryScope."
                    if (-not $discoveredPools.Count) { Write-Host 'Check the selected subscription/resource group and discovery permissions. Back returns to the main menu.' }
                } catch {
                    Write-Host '[FAILED] Host pool discovery could not be completed. Existing menu entries were retained. Use Configure permissions from the main menu if access is missing.' -ForegroundColor Red
                    Write-Verbose $_.Exception.Message
                }
                continue
            }
            $selectedPool=$poolChoice.Deployment

            $returnToPoolMenu=$false
            while (-not $returnToPoolMenu) {
                $adjustmentItems = @([pscustomobject]@{Name='Inspect deployment';Kind='Inspect'})
                if ($selectedPool.SessionHostReadState -eq 'Succeeded' -and @($selectedPool.SessionHosts | Where-Object { $_.properties.resourceId }).Count) {
                    $adjustmentItems += [pscustomobject]@{Name='Run selected guest scripts';Kind='GuestTasks'}
                }
                $adjustmentItems += [pscustomobject]@{Name='Add session hosts';Kind='AddHosts'}
                $adjustmentItems += [pscustomobject]@{Name='Configure host pool properties and RDP Shortpath';Kind='PoolSettings'}
                $adjustmentItems += [pscustomobject]@{Name='Start VM on Connect (enable/disable and permissions)';Kind='StartOnConnect'}
                $adjustmentItems += [pscustomobject]@{Name='Scaling Plans (create, inspect, enable or disable)';Kind='Scaling'}
                $adjustmentItems += [pscustomobject]@{Name='Maintenance (blue/green updates and switch)';Kind='Maintenance'}
                if ($selectedPool.SessionHostReadState -eq 'Succeeded' -and @($selectedPool.SessionHosts).Count) {
                    $adjustmentItems += [pscustomobject]@{Name='Remove session hosts and their Entra devices';Kind='RemoveHosts'}
                }
                $adjustmentItems += [pscustomobject]@{Name='Remove complete host pool and associated resources';Kind='RemoveDeployment'}
                $adjustmentItems += [pscustomobject]@{Name='Back';Kind='Back'}
                $adjustmentItems += [pscustomobject]@{Name='Exit';Kind='Exit'}
                $adjustment = Select-Item $adjustmentItems 'Choose how to adjust the deployment'
                if ($adjustment.Kind -eq 'Exit') { return }
                if ($adjustment.Kind -eq 'Back') { $returnToPoolMenu=$true; continue }
                if ($adjustment.Kind -eq 'PoolSettings') {
                    try { Set-AvdHostPoolConfiguration $selectedPool } catch { Write-Warning $_.Exception.Message }
                    $script:RemovalPermissionBatch=$false
                    $existingPools=@(Get-ExistingAvdDeployment $script:SubscriptionScope)
                    $selectedPool=@($existingPools | Where-Object Id -eq $selectedPool.Id)[0]
                    continue
                }
                if ($adjustment.Kind -eq 'StartOnConnect') { try { Set-AvdHostPoolConfiguration $selectedPool -StartOnConnectOnly } catch { Write-Warning $_.Exception.Message }; continue }
                if ($adjustment.Kind -eq 'Scaling') { Invoke-AvdScalingMenu $selectedPool; continue }
                if ($adjustment.Kind -eq 'Maintenance') { Invoke-AvdMaintenanceMenu $selectedPool; continue }
                if ($adjustment.Kind -eq 'AddHosts') {
                    if ($selectedPool.HostPoolType -notin @('Pooled','Personal')) { Write-Host 'Unsupported host pool type.' -ForegroundColor Red; continue }
                    Write-Host 'New hosts will be Entra joined only. Existing pool settings and existing hosts will be retained.'
                    if ((Read-Value 'Confirm this pool is intended for Entra-joined Azure Local hosts? (Y/N)' 'N' '^[YyNn]$') -ne 'Y') { continue }
                    $expansionPool=$selectedPool; $startNewDeployment=$true; $returnToPoolMenu=$true; $returnToDeploymentMenu=$true; break
                }
                if ($adjustment.Kind -eq 'RemoveDeployment') {
                    try { Confirm-AvdRemovalPermissions $selectedPool; $script:RemovalPermissionBatch=$true; Remove-AvdDeployment $selectedPool }
                    catch { Write-Host ("[FAILED] " + $_.Exception.Message) -ForegroundColor Red }
                    finally { $script:RemovalPermissionBatch=$false }
                    $existingPools=@(Get-ExistingAvdDeployment $script:SubscriptionScope)
                    $returnToPoolMenu=$true
                    continue
                }
                if ($adjustment.Kind -eq 'RemoveHosts') {
                    try { Confirm-AvdRemovalPermissions $selectedPool; $script:RemovalPermissionBatch=$true; Remove-AvdSessionHost $selectedPool } catch {
                        Write-Warning $_.Exception.Message
                        if ($script:Run -and $script:Run.PSObject.Properties['removals'] -and $script:Run.status -notin @('Succeeded','Cancelled')) {
                            $script:Run.status='RemovalIncomplete'; Save-Run
                        }
                        if ($script:RunFile) { Write-Host "Inspect the saved operation stages before retrying: $script:RunFile" }
                    }
                    $script:RemovalPermissionBatch=$false
                    $existingPools=@(Get-ExistingAvdDeployment $script:SubscriptionScope)
                    $selectedPool=@($existingPools | Where-Object Id -eq $selectedPool.Id)[0]
                    continue
                }
                if ($adjustment.Kind -eq 'Inspect') { Show-ExistingAvdDeployment $selectedPool; continue }
                if ($adjustment.Kind -eq 'GuestTasks') { Invoke-GuestTaskWorkflow $selectedPool; continue }
            }
        }
    }
    # Graph checks are needed for creating resource-provider and user assignments, not for
    # read-only inspection. Ask only after the caller has chosen the new-deployment path.
    $null = Confirm-GraphAccess

    # Expansion can target a different VM RG. Check the existing pool and DAG
    # before infrastructure selection or a potentially long image import.
    if ($expansionPool) {
        Confirm-Permission $expansionPool.Id @('Microsoft.DesktopVirtualization/hostPools/read','Microsoft.DesktopVirtualization/hostPools/write','Microsoft.DesktopVirtualization/hostPools/retrieveRegistrationToken/action','Microsoft.DesktopVirtualization/hostPools/sessionHosts/read') @($script:Roles.Contributor)
        $desktopGroups=@($expansionPool.ApplicationGroups | Where-Object { $_.properties.applicationGroupType -eq 'Desktop' })
        if (-not $desktopGroups.Count) { throw 'This expansion requires an existing desktop application group.' }
        $expansionDag=Select-Item $desktopGroups 'Select the existing desktop application group for access assignments'
        Confirm-Permission $expansionDag.id @('Microsoft.Authorization/roleAssignments/write','Microsoft.Authorization/roleAssignments/read') @($script:Roles.RbacAdministrator)
    }

    if ($expansionPool) { $OutputDirectory=Join-Path $OutputDirectory ('add-'+[guid]::NewGuid().ToString('N').Substring(0,8)) }
    $OutputDirectory=New-AvdRunDirectory $OutputDirectory -Operation deployment
    $script:RunFile = Join-Path $OutputDirectory 'run.json'
    $script:Run = [pscustomobject]@{runId=((Get-Date -Format 'yyyyMMddHHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0,6));subscriptionId=$SubscriptionId;tenantId=$TenantId;
        status='Preflight';updatedUtc='';deployments=@();hostPoolId='';sessionHosts=@();registrationSubmitted=$false}
    Save-Run

    if ($CustomLocationId -and -not $InfrastructureResourceGroup) {
        if ($CustomLocationId -notmatch '^/subscriptions/([^/]+)/resourceGroups/([^/]+)/providers/Microsoft.ExtendedLocation/customLocations/[^/]+$' -or $Matches[1] -ne $SubscriptionId) {
            throw 'CustomLocationId must belong to the selected subscription.'
        }
        $InfrastructureResourceGroup = $Matches[2]
    }
    if (-not $InfrastructureResourceGroup) { $InfrastructureResourceGroup = Select-ResourceGroup 'Select Azure Local infrastructure resource group' $env:AZSHCI_RESOURCE_GROUP }
    # An empty infrastructure group is a recoverable selection, not a deployment failure.
    while ($true) {
        $script:InfraScope = "$script:SubscriptionScope/resourceGroups/$InfrastructureResourceGroup"
        Confirm-Permission $script:InfraScope @('Microsoft.ExtendedLocation/customLocations/read','Microsoft.AzureStackHCI/logicalNetworks/read','Microsoft.AzureStackHCI/galleryImages/read','Microsoft.AzureStackHCI/marketplaceGalleryImages/read','Microsoft.AzureStackHCI/storageContainers/read','Microsoft.ResourceConnector/appliances/read') @($script:Roles.Reader)
        $locations = @(Get-ArmList "$script:InfraScope/providers/Microsoft.ExtendedLocation/customLocations?api-version=2021-08-15")
        if ($locations.Count -or $CustomLocationId) { break }
        Write-Warning "Resource group '$InfrastructureResourceGroup' contains no Azure Local custom locations. Select the resource group containing the Azure Local infrastructure, which can differ from the session host resource group."
        $InfrastructureResourceGroup = Select-ResourceGroup 'Select another Azure Local infrastructure resource group' ''
    }
    if ($CustomLocationId) {
        $selected = @($locations | Where-Object id -eq $CustomLocationId)
        if ($selected.Count -ne 1) { throw 'CustomLocationId was not found in the selected infrastructure resource group.' }
        $custom = $selected[0]
    } else { $custom = Select-Item $locations 'Select Azure Local custom location' }
    if ($custom.properties.provisioningState -ne 'Succeeded') { throw 'The custom location is not provisioned successfully.' }
    $bridgeId = $custom.properties.hostResourceId
    if ($bridgeId -notmatch '/providers/Microsoft.ResourceConnector/appliances/') { throw 'The custom location is not backed by an Arc resource bridge.' }
    $bridge = Invoke-Arm "$bridgeId`?api-version=2022-10-27"
    if ($bridge.properties.provisioningState -ne 'Succeeded' -or $bridge.properties.status -ne 'Running') { throw 'The Arc resource bridge must be provisioned and Running.' }
    $location = $custom.location
    Write-Event "Selected $($custom.name), bridge $($bridge.name), Azure region $location."
    :InfrastructureSelection while ($true) {
    $network = Select-AvdLogicalNetwork $custom.id
    if (-not $network) {
        $script:Run.status='Cancelled'; Save-Run
        Write-Host 'Deployment cancelled before resource submission. Create a VM logical network and run the workflow again.'
        return
    }
    $storage = Select-Item @(Get-LocalResource 'storageContainers' $custom.id) 'Select storage container'
    Write-Host 'The network must provide DHCP or an Azure Local IP pool, DNS and outbound AVD/Entra connectivity. The cluster must run supported Azure Local 23H2 or later.'
    if ((Read-Value 'Confirm cluster version, network IP allocation and capacity prerequisites? (Y/N)' 'N' '^[YyNn]$') -ne 'Y') { Write-Host 'Prerequisites not confirmed. Returning to logical network and storage selection.'; continue InfrastructureSelection }
    break InfrastructureSelection
    }

    $avdProvider = Get-AzResourceProvider -ProviderNamespace 'Microsoft.DesktopVirtualization'
    $supportedRegions = @($avdProvider.ResourceTypes | Where-Object ResourceTypeName -eq 'hostPools' | ForEach-Object { $_.Locations })
    $regionChoices = @(Get-AzLocation | Where-Object { $_.DisplayName -in $supportedRegions } |
        Sort-Object @{Expression={$_.Location -ne $location}},DisplayName | ForEach-Object {
            [pscustomobject]@{Name="$($_.DisplayName) ($($_.Location))";Location=$_.Location}
        })
    $avdLocation = if ($expansionPool) { $expansionPool.Location } else { (Select-Item $regionChoices 'Select Azure region for AVD service metadata').Location }
    $regionCodes = @{westeurope='weu';northeurope='neu';eastus='eus';eastus2='eus2';westus2='wus2';uksouth='uks';germanywestcentral='gwc'}
    $regionCode = if ($regionCodes.ContainsKey($avdLocation)) { $regionCodes[$avdLocation] } else { $avdLocation }
    if ($expansionPool) {
        $stem = $expansionPool.Name -replace '^hp[-_]',''
        Write-Host "Keeping naming suffix '$stem' from existing host pool '$($expansionPool.Name)'. Existing resource names are retained."
    } else {
        $stem = Read-Value 'Naming suffix (workload-environment-region-instance)' "avd-lab-$regionCode-001" '^[a-z][a-z0-9-]{2,55}$'
    }
    $preferredRg=if ($expansionPool) { $expansionPool.ResourceGroup } else { "rg-$stem" }
    while ($true) {
        $rgName = Select-ResourceGroup 'Select AVD resource group' $preferredRg -AllowCreate
        try {
            $script:AvdScope = "$script:SubscriptionScope/resourceGroups/$rgName"
            try { $rg = Invoke-Arm "$script:AvdScope`?api-version=2022-09-01" -AllowNotFound }
            catch { $rg = $null; Write-Warning 'The SPN could not inspect this resource group. An alternate user can check it before creating anything.' }
            $deploymentActions = @('Microsoft.Resources/deployments/read','Microsoft.Resources/deployments/write','Microsoft.Resources/deployments/validate/action','Microsoft.Resources/deployments/operations/read',
                'Microsoft.DesktopVirtualization/hostPools/read','Microsoft.DesktopVirtualization/hostPools/write','Microsoft.DesktopVirtualization/hostPools/retrieveRegistrationToken/action',
                'Microsoft.DesktopVirtualization/hostPools/sessionHosts/read','Microsoft.DesktopVirtualization/applicationGroups/read','Microsoft.DesktopVirtualization/applicationGroups/write','Microsoft.DesktopVirtualization/workspaces/read','Microsoft.DesktopVirtualization/workspaces/write',
                'Microsoft.HybridCompute/machines/write','Microsoft.HybridCompute/machines/read','Microsoft.HybridCompute/machines/extensions/read','Microsoft.HybridCompute/machines/extensions/write',
                'Microsoft.HybridCompute/machines/runCommands/write','Microsoft.HybridCompute/machines/runCommands/read',
                'Microsoft.AzureStackHCI/virtualMachineInstances/read','Microsoft.AzureStackHCI/virtualMachineInstances/write','Microsoft.AzureStackHCI/networkInterfaces/read','Microsoft.AzureStackHCI/networkInterfaces/write','Microsoft.Authorization/roleAssignments/read','Microsoft.Authorization/roleAssignments/write')
            if (-not $rg) {
                Write-Host "Use resource group $rgName or create it in $avdLocation if it does not exist."
                if ((Read-Value 'Check/create it with an alternate user and grant SPN Contributor + RBAC Administrator at this RG? (Y/N)' 'Y' '^[YyNn]$') -ne 'Y') { throw 'Resource group preparation declined.' }
                Invoke-AlternateUser {
                    if (-not (Invoke-Arm "$script:AvdScope`?api-version=2022-09-01" -AllowNotFound)) {
                        $null = Invoke-Arm "$script:AvdScope`?api-version=2022-09-01" PUT @{location=$avdLocation;tags=@{workload='AVD';environment='lab'}}
                    }
                    Grant-Role $script:AvdScope $script:SpnObjectId $script:Roles.Contributor
                    Grant-Role $script:AvdScope $script:SpnObjectId $script:Roles.RbacAdministrator
                }
                # Allow time for a new RG assignment before offering another repair login.
                $deadline = [datetime]::UtcNow.AddMinutes(10)
                do {
                    try { $pending = @(Get-MissingAction $script:AvdScope $deploymentActions) } catch { $pending = @('Pending') }
                    if (-not $pending.Count) { break }
                    Write-Verbose ("Waiting for all required resource group permissions to propagate. Pending: " + ($pending -join ', '))
                    Write-Host 'Waiting for the new resource group permissions to become effective...' -ForegroundColor Cyan
                    Start-Sleep -Seconds $PollSeconds
                } while ([datetime]::UtcNow -lt $deadline)
            }
            Confirm-Permission $script:AvdScope $deploymentActions @($script:Roles.Contributor,$script:Roles.RbacAdministrator)
            break
        } catch {
            Write-Warning ("Resource group '$rgName' was not accepted: " + $_.Exception.Message)
            Write-Host 'Returning to AVD resource group selection. Your infrastructure and naming selections are retained. Any resource group or role assignments already created are preserved.' -ForegroundColor Yellow
            $script:AvdScope = $null
        }
    }
    # Joining shared infrastructure is checked on the resources actually selected.
    Confirm-Permission $custom.id @('Microsoft.ExtendedLocation/customLocations/read','Microsoft.ExtendedLocation/customLocations/deploy/action') @($script:Roles.Contributor)
    Confirm-Permission $network.id @('Microsoft.AzureStackHCI/logicalNetworks/read','Microsoft.AzureStackHCI/logicalNetworks/join/action') @($script:Roles.Contributor)
    Confirm-Permission $storage.id @('Microsoft.AzureStackHCI/storageContainers/read') @($script:Roles.Reader)
    foreach ($namespace in @('Microsoft.DesktopVirtualization','Microsoft.AzureStackHCI','Microsoft.HybridCompute','Microsoft.ExtendedLocation')) { Confirm-ResourceProvider $namespace }
    $entraVersions = @(Get-ArmList "$script:SubscriptionScope/providers/Microsoft.HybridCompute/locations/$location/publishers/Microsoft.Azure.ActiveDirectory/extensionTypes/AADLoginForWindows/versions?api-version=$script:ArcApi")
    if (-not @($entraVersions | Where-Object { $_.properties.version -match '^2\.' -or $_.name -match '^2\.' }).Count) {
        throw "AADLoginForWindows 2.x is not available in the Arc extension catalogue for $location. No session hosts have been created."
    }
    # AADLoginForWindows itself reads this setting during the Entra join and, when it matches the
    # well-known Intune MDM app ID, triggers MDM enrollment as part of that same join - no separate
    # ARM call or extra permission is needed either way.
    $mdmId = if ((Read-Value 'Automatically enroll session hosts in Microsoft Intune (MDM) during Entra join? (Y/N)' 'N' '^[YyNn]$') -eq 'Y') { '0000000a-0000-0000-c000-000000000000' } else { '' }

    # The resource provider needs rights in a new VM resource group too.
    # This is the RBAC role definition name, not the enterprise application's display name
    # (that one is looked up separately below, via appId) - Azure has no role definition
    # called "Microsoft.AzureStackHCI", only this one plus a few unrelated roles that start
    # with that prefix, confirmed live via Get-AzRoleDefinition.
    $rpRole = (Get-AzRoleDefinition -Name 'Azure Connected Machine Resource Manager').Id
    if (-not $rpRole) { throw "The 'Azure Connected Machine Resource Manager' RBAC role definition could not be resolved in this subscription." }
    $rpAppId = '1412d89f-b8a8-4111-b4fd-e82905cbd85d'
    $rpObjectId = $null
    # Tried unconditionally, not gated on Confirm-GraphAccess's cached all-or-nothing verdict:
    # Application.Read.All alone is enough for this specific call, and may already be granted
    # even when some other permission in the catalog isn't.
    try { $rpObjectId = @(Get-GraphList "/servicePrincipals?`$filter=appId eq '$rpAppId'&`$select=id") | Select-Object -First 1 -ExpandProperty id } catch {}
    if (-not $rpObjectId) {
        Write-Host "Look it up manually: Microsoft Entra admin center > Enterprise applications > search 'Microsoft.AzureStackHCI' (application ID $rpAppId)."
        $rpObjectId = Read-Value 'Microsoft.AzureStackHCI enterprise application object ID' '' '^[0-9a-fA-F-]{36}$'
    }
    if (-not $rpObjectId) { throw 'The Azure Local resource provider enterprise application could not be resolved.' }
    try { Grant-Role $script:AvdScope $rpObjectId $rpRole }
    catch {
        Write-Warning 'SPN could not grant the resource provider role. A conditional RBAC assignment may restrict this role.'
        if ((Read-Value 'Use an alternate user for this resource provider assignment? (Y/N)' 'Y' '^[YyNn]$') -ne 'Y') { throw }
        Invoke-AlternateUser { Grant-Role $script:AvdScope $rpObjectId $rpRole }
    }

    $hostPoolType = if ($expansionPool) { $expansionPool.HostPoolType } else {
        (Select-Item @([pscustomobject]@{Name='Pooled - shared desktops, multiple users per host';Id='Pooled'},[pscustomobject]@{Name='Personal - a dedicated desktop per user';Id='Personal'}) 'Select host pool type').Id
    }
    $personalAssignment='Automatic'
    if ($hostPoolType -eq 'Personal') {
        Write-Host 'Personal desktops use persistent user-to-host assignments. Existing pool assignments are retained.'
        if (-not $expansionPool) {
            $personalAssignment=(Select-Item @([pscustomobject]@{Name='Automatic - assign a desktop on first connection';Id='Automatic'},[pscustomobject]@{Name='Direct - assign each user to a host in the portal';Id='Direct'}) 'Personal desktop assignment').Id
        }
        Write-Host 'With Direct assignment, DAG access alone is not sufficient: assign a user to each session host in the Azure portal before sign-in.'
    }
    :ImageSelection while ($true) {
    $images = @(@(Get-LocalResource 'galleryImages' $custom.id) + @(Get-LocalResource 'marketplaceGalleryImages' $custom.id) |
        Where-Object { $_.properties.osType -eq 'Windows' -and $_.properties.hyperVGeneration -eq 'V2' })
    Write-Host 'Only provisioned Windows generation 2 images in the selected custom location are listed.'
    $import = if ($images.Count) { (Read-Value 'Import a new Windows 11 Marketplace image? (Y/N)' 'N' '^[YyNn]$') -eq 'Y' } else { $true }
    if ($import) {
        Confirm-ResourceProvider 'Microsoft.EdgeMarketplace'
        Confirm-Permission $script:InfraScope @('Microsoft.AzureStackHCI/marketplaceGalleryImages/read','Microsoft.AzureStackHCI/marketplaceGalleryImages/write','Microsoft.AzureStackHCI/marketplaceGalleryImages/delete','Microsoft.Resources/deployments/write','Microsoft.Resources/deployments/validate/action','Microsoft.Resources/deployments/read','Microsoft.Resources/deployments/operations/read') @($script:Roles.Contributor)
        # Images live beside the cluster so they remain available to other host pools.
        try { Grant-Role $script:InfraScope $rpObjectId $rpRole }
        catch {
            if ((Read-Value 'Use an alternate user to grant the resource provider image permissions in the infrastructure RG? (Y/N)' 'Y' '^[YyNn]$') -ne 'Y') { throw }
            Invoke-AlternateUser { Grant-Role $script:InfraScope $rpObjectId $rpRole }
        }
        $offers = @(Get-AzVMImageOffer -Location $location -PublisherName 'microsoftwindowsdesktop' | Where-Object Offer -in @('windows-11','office-365'))
        $offer = (Select-Item $offers 'Select Windows Marketplace offer' 'Offer').Offer
        $skus = @(Get-AzVMImageSku -Location $location -PublisherName 'microsoftwindowsdesktop' -Offer $offer | Where-Object { if ($hostPoolType -eq 'Personal') { $_.Skus -match '^win11-.*-ent' } else { $_.Skus -match '^win11-.*-avd' } })
        $sku = (Select-Item $skus 'Select Windows 11 SKU for the selected host pool type' 'Skus').Skus
        # CLI's optional --version is not an optional ARM property: the RP rejects an empty name.
        # A Compute catalogue entry is not proof that Edge Marketplace can issue its download token.
        $versions = @([pscustomobject]@{Name='Latest Azure catalogue version (resolved before import)';Version='latest'}) +
            @(Get-AzVMImage -Location $location -PublisherName 'microsoftwindowsdesktop' -Offer $offer -Skus $sku |
                Sort-Object { [version]$_.Version } -Descending |
                ForEach-Object { [pscustomobject]@{Name="Pin $($_.Version)";Version=$_.Version} })
        $versions += [pscustomobject]@{Name='Enter a specific version manually';Version='manual'}
        Write-Host 'The Azure catalogue lists candidates. Availability for download on Azure Local is verified during import.'
        $version = (Select-Item $versions 'Select image version').Version
        if ($version -eq 'manual') { $version = Read-Value 'Image version' '' '^\d+\.\d+\.\d+$' }
        $imageName = Read-Value 'Azure Local image name' "img-$sku" '^[a-zA-Z0-9][a-zA-Z0-9.-]{0,78}[a-zA-Z0-9]$'
        $imageId = "$script:InfraScope/providers/Microsoft.AzureStackHCI/marketplaceGalleryImages/$imageName"
        Assert-NewResource $imageId $script:HciApi
        $imageAttempt = 0
        do {
            $imageAttempt++
            $resolvedVersion = Resolve-MarketplaceImageVersion $location $offer $sku $version
            $imageTemplate = New-MarketplaceImageTemplate $imageName $location $custom.id $storage.id $offer $sku $resolvedVersion
            Write-Host "Download $offer / $sku / $resolvedVersion to $($custom.name), storage $($storage.name)."
            if ((Read-Value 'Start the image download? (Y/N)' 'Y' '^[YyNn]$') -ne 'Y') { Write-Host 'Download not confirmed. Returning to image selection.'; continue ImageSelection }
            try { Start-Deployment $script:InfraScope "image-$imageAttempt" $imageTemplate -ImageId $imageId; break }
            catch {
                $failedImage = Invoke-Arm "$imageId`?api-version=$script:HciApi" -AllowNotFound
                if ($failedImage.properties.provisioningState -ne 'Failed') { throw }
                Write-Warning (Format-ImageImportStatus $failedImage)
                if ($failedImage.properties.status.errorCode -eq 'GenerateTokenFromEdgeMarketplaceServiceFailed') {
                    Write-Warning 'Edge Marketplace could not issue a download token. Check the publisher/offer/SKU/version, resource provider registration and the resource provider role. A newer image version is only one possible cause.'
                }
                if ((Read-Value 'Remove this failed image and retry with another version? (Y/N)' 'N' '^[YyNn]$') -ne 'Y') { throw }
                $nextVersion = (Select-Item @($versions | Where-Object { $_.Version -ne $version -and $_.Version -ne $resolvedVersion }) 'Select retry version').Version
                if ($nextVersion -eq 'manual') { $nextVersion = Read-Value 'Image version' '' '^\d+\.\d+\.\d+$' }
                # Only this attempt's failed image is removed, after explicit retry selection.
                $null = Invoke-Arm "$imageId`?api-version=$script:HciApi" DELETE -AllowNotFound
                $deadline = [datetime]::UtcNow.AddMinutes(10)
                while ((Invoke-Arm "$imageId`?api-version=$script:HciApi" -AllowNotFound) -and [datetime]::UtcNow -lt $deadline) {
                    Write-Event 'Waiting for the failed image resource to be removed...'
                    Start-Sleep -Seconds $PollSeconds
                }
                if (Invoke-Arm "$imageId`?api-version=$script:HciApi" -AllowNotFound) { throw 'Failed image deletion has not completed. Retry after Azure removes the resource.' }
                $version = $nextVersion
            }
        } while ($true)
        $image = Invoke-Arm "$imageId`?api-version=$script:HciApi"
    } else { $image = Select-Item $images 'Select session host image' }
    if ($image.properties.provisioningState -ne 'Succeeded') { throw 'Image provisioning has not succeeded.' }
    if ($hostPoolType -eq 'Personal') { Write-Host 'Select a generalized Windows 11 Enterprise generation 2 image for dedicated desktops. Confirm licensing and activation for this edition.' } else { Write-Host 'Select a generalized Windows 11 Enterprise multi-session generation 2 image for pooled desktops.' }
    Write-Host 'Custom images must not already be domain joined or contain registered AVD agents.'
    if ((Read-Value 'Confirm that the selected image meets these requirements? (Y/N)' 'N' '^[YyNn]$') -ne 'Y') { Write-Host 'Image suitability not confirmed. Returning to image selection.'; continue ImageSelection }
    break ImageSelection
    }
    $imageReadAction = $image.type + '/read'
    Confirm-Permission $image.id @($imageReadAction) @($script:Roles.Reader)

    :DeploymentConfiguration while ($true) {
    if (-not $expansionPool) {
    $hpName = Read-Value 'Host pool name' "hp-$stem" '^[a-zA-Z0-9][a-zA-Z0-9-]{2,63}$'
    $dagName = Read-Value 'Desktop application group name' "dag-$stem" '^[a-zA-Z0-9][a-zA-Z0-9-]{2,63}$'
    $wsName = Read-Value 'Workspace name' "vdws-$stem" '^[a-zA-Z0-9][a-zA-Z0-9-]{2,63}$'
    } else {
        $hpName=$expansionPool.Name
        $dagName=$expansionDag.name; $wsName=''
        Write-Host 'The existing host pool, workspace and application group settings will be retained. Selected access assignments can be added to the existing desktop application group.'
    }
    $defaultPrefix = Get-AvdSessionHostPrefix $hpName
    Write-Host "Suggested from host pool '$hpName': $defaultPrefix-001 (maximum 15-character computer name). Existing hosts are not renamed."
    $vmPrefix = Read-Value 'Session host prefix (up to 11 characters)' $defaultPrefix '^[a-zA-Z][a-zA-Z0-9-]{0,10}$'
    $count = [int](Read-Value 'Number of session hosts (1-20)' '1' '^(20|1[0-9]|[1-9])$')
    $cpu = [int](Read-Value 'vCPUs per session host (2-32)' '4' '^([2-9]|[12][0-9]|3[0-2])$')
    $memory = [int](Read-Value 'Memory per session host in GB (4-128)' '8' '^([4-9]|[1-9][0-9]|1[01][0-9]|12[0-8])$') * 1024
    $maxSessions = if ($hostPoolType -eq 'Personal') { 1 } elseif ($expansionPool) { $expansionPool.MaxSessionLimit } else { [int](Read-Value 'Maximum sessions per host (size for your workload)' '4' '^[1-9][0-9]{0,2}$') }
    $adminUser = Read-Value 'Local VM administrator username' 'avdadmin' '^[a-zA-Z][a-zA-Z0-9]{2,19}$'
    Write-Host 'Select the users and security groups that will get Desktop Virtualization User on the DAG and VM User Login on each session host.'
    $principals = @()
    if ($expansionPool) {
        $access=@(Get-ArmList "$($expansionDag.id)/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01&`$filter=atScope()" |
            Where-Object { $_.properties.roleDefinitionId -like "*/$($script:Roles.DesktopUser)" -and $_.properties.principalType -in @('User','Group') })
        if ($access.Count) {
            Write-Host 'Existing Desktop Virtualization User assignments available for VM login on the new hosts:'
            foreach ($assignment in $access) { Write-Host "  $($assignment.properties.principalType): $($assignment.properties.principalId)" }
            if ((Read-Value 'Reuse these existing user/group assignments for the new hosts? (Y/N)' 'Y' '^[YyNn]$') -eq 'Y') {
                $principals=@($access | ForEach-Object { @{id=$_.properties.principalId;type=$_.properties.principalType} })
            }
        }
    }
    if (-not $principals.Count) {
    do {
        # Always offer the choice, regardless of Confirm-GraphAccess's cached all-or-nothing
        # verdict from start-up: this SPN can have User.Read.All but not Group.Read.All (or vice
        # versa), and Search-GraphPrincipals degrades to an empty result for whichever kind isn't
        # actually available, so a real permission gap surfaces as "no matches", not a missing menu.
        $mode = Select-Item @(
            [pscustomobject]@{Name='Search for a user by name or UPN'}
            [pscustomobject]@{Name='Search for a security group by name'}
            [pscustomobject]@{Name='Enter an object ID directly'}
        ) 'Add a user or group'
        if ($mode.Name -eq 'Enter an object ID directly') {
            $objectId = Read-Value 'User or security group object ID in this tenant' '' '^[0-9a-fA-F-]{36}$'
            $type = Read-Value 'Principal type (Group/User)' 'Group' '^(Group|User)$'
            $principals += @{id=$objectId;type=$type}
        } else {
            $kind = if ($mode.Name -like 'Search for a user*') { 'User' } else { 'Group' }
            $term = Read-Value "Search term ($(if ($kind -eq 'User') { 'name or UPN' } else { 'group name' }))" ''
            $found = if ($term) { @(Search-GraphPrincipals $term $kind) } else { @() }
            foreach ($picked in (Select-Multiple $found "Select ${kind}s to add")) {
                if (-not @($principals | Where-Object { $_.id -eq $picked.Id }).Count) { $principals += @{id=$picked.Id;type=$picked.Type} }
            }
        }
        Write-Host "Selected so far: $($principals.Count)"
    } while ((Read-Value 'Add another user or group? (Y/N)' 'N' '^[YyNn]$') -eq 'Y')
    }
    if (-not $principals.Count) { throw 'At least one user or group must be assigned to the desktop application group.' }
    $hpId = "$script:AvdScope/providers/Microsoft.DesktopVirtualization/hostPools/$hpName"
    $dagId = "$script:AvdScope/providers/Microsoft.DesktopVirtualization/applicationGroups/$dagName"
    $wsId = "$script:AvdScope/providers/Microsoft.DesktopVirtualization/workspaces/$wsName"
    if ($expansionPool) {
        $hpId=$expansionPool.Id; $dagId=$expansionDag.id; $wsId=''
        Confirm-Permission $hpId @('Microsoft.DesktopVirtualization/hostPools/read','Microsoft.DesktopVirtualization/hostPools/write','Microsoft.DesktopVirtualization/hostPools/retrieveRegistrationToken/action','Microsoft.DesktopVirtualization/hostPools/sessionHosts/read') @($script:Roles.Contributor)
        Confirm-Permission $dagId @('Microsoft.Authorization/roleAssignments/write','Microsoft.Authorization/roleAssignments/read') @($script:Roles.RbacAdministrator)
    } else { foreach ($id in @($hpId,$dagId,$wsId)) { Assert-NewResource $id $script:AvdApi } }
    $firstIndex=1
    if ($expansionPool) {
        $usedNames=@(Get-ArmList "$script:AvdScope/providers/Microsoft.HybridCompute/machines?api-version=$script:ArcApi" | ForEach-Object name)
        $usedNames+=@(Get-ArmList "$script:AvdScope/providers/Microsoft.AzureStackHCI/networkInterfaces?api-version=$script:HciApi" | ForEach-Object { $_.name -replace '^nic-','' })
        $usedNames+=@($expansionPool.SessionHosts | ForEach-Object { ($_.name -split '/')[-1] -replace '\..*$','' })
        $indices=@($usedNames | ForEach-Object { if ($_ -match ('^'+[regex]::Escape($vmPrefix)+'-(\d+)$')) { [int]$Matches[1] } })
        if ($indices.Count) { $firstIndex=1+[int]($indices | Measure-Object -Maximum).Maximum }
        $firstIndex=[int](Read-Value 'First new session host number' ([string]$firstIndex) '^[1-9][0-9]{0,2}$')
    }
    if ($firstIndex+$count-1 -gt 999) { throw 'Session host numbering must not exceed 999.' }
    $vmNames = @($firstIndex..($firstIndex+$count-1) | ForEach-Object { '{0}-{1:d3}' -f $vmPrefix,$_ })
    if ($expansionPool) {
        $existingNames=@(Get-ArmList "$hpId/sessionHosts?api-version=$script:AvdApi" | ForEach-Object { (($_.name -split '/')[-1] -split '\.')[0] })
        if (@($vmNames | Where-Object { $_ -in $existingNames }).Count) { throw 'A new computer name already exists in the selected pool. Choose a different prefix or starting number.' }
    }
    foreach ($vm in $vmNames) {
        Assert-NewResource "$script:AvdScope/providers/Microsoft.HybridCompute/machines/$vm" $script:ArcApi
        Assert-NewResource "$script:AvdScope/providers/Microsoft.AzureStackHCI/networkInterfaces/nic-$vm" $script:HciApi
    }
    $script:Run.hostPoolId = $hpId
    $script:Run.sessionHosts = $vmNames
    Save-Run
    if ($expansionPool) { Write-Host "Add hosts to $hpId. New VM resource group: $rgName. Names: $($vmNames -join ', ')." } else { Write-Host "Create $hpName, $dagName and $wsName in $rgName ($avdLocation)." }
    Write-Host "Host pool type: $hostPoolType. Personal desktops retain user assignments; pooled desktops share hosts."
    if ($hostPoolType -eq 'Personal' -and -not $expansionPool) { Write-Host "Personal desktop assignment: $personalAssignment" }
    Write-Host "Create $count VM(s) on $($custom.name) using $($image.name), network $($network.name) and storage $($storage.name)."
    Write-Host "Each VM: $cpu vCPUs, $($memory/1024) GB RAM. Assign $($principals.Count) principal(s) Desktop Virtualization User at the DAG and VM User Login on each new VM."
    Write-Host 'Entra join only, without Intune enrollment. Password-based AVD access uses targetisaadjoined:i:1. Configure tenant SSO separately if required.'
    if ((Read-Value 'Deploy this configuration? (Y/N)' 'Y' '^[YyNn]$') -ne 'Y') { Write-Host 'Deployment not confirmed. Returning to deployment configuration.'; continue DeploymentConfiguration }
    break DeploymentConfiguration
    }
    $adminPassword = Read-Host 'Local VM administrator password (Azure password complexity requirements apply)' -AsSecureString

    $core = @(
        @{type='Microsoft.DesktopVirtualization/hostPools';apiVersion=$script:AvdApi;name=$hpName;location=$avdLocation;properties=@{
            hostPoolType=$hostPoolType;loadBalancerType=$(if ($hostPoolType -eq 'Personal') {'Persistent'} else {'BreadthFirst'});maxSessionLimit=$maxSessions;preferredAppGroupType='Desktop';validationEnvironment=$false;
            startVMOnConnect=$false;customRdpProperty='targetisaadjoined:i:1;';friendlyName=$hpName}},
        @{type='Microsoft.DesktopVirtualization/applicationGroups';apiVersion=$script:AvdApi;name=$dagName;location=$avdLocation;dependsOn=@($hpId);properties=@{hostPoolArmPath=$hpId;applicationGroupType='Desktop';friendlyName=$dagName}},
        @{type='Microsoft.DesktopVirtualization/workspaces';apiVersion=$script:AvdApi;name=$wsName;location=$avdLocation;dependsOn=@($dagId);properties=@{applicationGroupReferences=@($dagId);friendlyName=$wsName}}
    )
    $script:Run.status = 'Deploying'
    Save-Run
    if ($hostPoolType -eq 'Personal') { $core[0].properties.personalDesktopAssignmentType=$personalAssignment; $core[0].properties.Remove('maxSessionLimit') }
    if (-not $expansionPool) { Start-Deployment $script:AvdScope 'core' (New-Template $core) }
    # Actual assignment is authoritative for conditional RBAC and deny assignments.
    foreach ($principal in $principals) {
        try { Grant-Role $dagId $principal.id $script:Roles.DesktopUser $principal.type }
        catch {
            if ((Read-Value 'DAG assignment failed. Use an alternate user to assign this principal? (Y/N)' 'Y' '^[YyNn]$') -ne 'Y') { throw }
            Invoke-AlternateUser { Grant-Role $dagId $principal.id $script:Roles.DesktopUser $principal.type }
        }
    }
    $vmTemplate = New-SessionHostTemplate $vmNames $location $custom.id $image.id $network.id $storage.id $cpu $memory $adminUser
    try {
        # The REST serializer needs plaintext in memory. ARM marks this parameter secure.
        $passwordValue = [pscredential]::new($adminUser,$adminPassword).GetNetworkCredential().Password
        Start-Deployment $script:AvdScope 'vms' $vmTemplate @{adminPassword=@{value=$passwordValue}}
    } finally { $passwordValue = $null; $adminPassword = $null }
    foreach ($vm in $vmNames) {
        $machineId = "$script:AvdScope/providers/Microsoft.HybridCompute/machines/$vm"
        $deadline = [datetime]::UtcNow.AddMinutes(20)
        do {
            $machine = Invoke-Arm "$machineId`?api-version=$script:ArcApi"
            if ($machine.properties.status -eq 'Connected' -and $machine.identity.principalId) { break }
            if ([datetime]::UtcNow -ge $deadline) { throw "Arc agent on $vm did not connect with a managed identity." }
            Write-Event "Waiting for Arc guest management on $vm."
            Start-Sleep -Seconds $PollSeconds
        } while ($true)
        foreach ($principal in $principals) {
            try { Grant-Role $machineId $principal.id $script:Roles.VmUser $principal.type }
            catch {
                if ((Read-Value 'VM login assignment failed. Use an alternate user? (Y/N)' 'Y' '^[YyNn]$') -ne 'Y') { throw }
                Invoke-AlternateUser { Grant-Role $machineId $principal.id $script:Roles.VmUser $principal.type }
            }
        }
    }
    Start-Deployment $script:AvdScope 'entra-join' (New-ExtensionTemplate $vmNames $location -MdmId $mdmId)

    # Generate the short-lived token after image download, VM creation and Entra join.
    $expiration = [datetime]::UtcNow.AddHours(4).ToString('o')
    $null = Invoke-Arm "$hpId`?api-version=$script:AvdApi" PATCH @{properties=@{registrationInfo=@{expirationTime=$expiration;registrationTokenOperation='Update'}}}
    $registration = Invoke-Arm "$hpId/retrieveRegistrationToken?api-version=$script:AvdApi" POST @{}
    if (-not $registration.token) { throw 'AVD did not return a registration token.' }
    try {
        $commandIds = @($vmNames | ForEach-Object { "$script:AvdScope/providers/Microsoft.HybridCompute/machines/$_/runCommands/AVDRegistration" })
        $script:Run | Add-Member -NotePropertyName registrationCommands -NotePropertyValue $commandIds -Force
        Start-Deployment $script:AvdScope 'avd-agent' (New-RegistrationTemplate $vmNames $location) @{registrationToken=@{value=$registration.token}}
        Wait-Registration $commandIds
        Wait-SessionHosts
        $null = Invoke-Arm "$hpId`?api-version=$script:AvdApi" PATCH @{properties=@{registrationInfo=@{registrationTokenOperation='Delete'}}}
    } finally { $registration=$null }
    $script:Run.status = 'Succeeded'
    Save-Run
    Write-Event "Deployment succeeded and all $count session hosts are Available. Run history: $script:RunFile"
    if ($hostPoolType -eq 'Personal') { Write-Host "Review personal desktop assignments: https://portal.azure.com/#resource$hpId/overview" }
    Write-Host 'Restart the new VMs in a maintenance window, verify Windows activation using the method supported by the selected Windows edition and test a Windows App sign-in with an assigned user. Profile storage and tenant SSO are separate post-deployment tasks.'
    if ((Read-Value 'Run optional guest configuration tasks on the new session hosts now? (Y/N)' 'N' '^[YyNn]$') -eq 'Y') {
        $newHosts=@(Get-ArmList "$hpId/sessionHosts?api-version=$script:AvdApi" | Where-Object { (($_.name -split '/')[-1] -split '\.')[0] -in $vmNames })
        $newDeployment=[pscustomobject]@{Id=$hpId;Name=$hpName;SessionHostReadState='Succeeded';SessionHosts=$newHosts}
        Invoke-GuestTaskWorkflow $newDeployment
    }
} catch {
    if ($script:Run -and -not $Monitor) {
        if ($script:Run.status -eq 'Succeeded' -and @($script:Run.deployments).Count) {
            if (-not $script:Run.PSObject.Properties['guestTaskStatus']) { $script:Run | Add-Member -NotePropertyName guestTaskStatus -NotePropertyValue 'NotRun' }
            if (@($script:Run.guestTasks).Count) { $script:Run.guestTaskStatus='Partial' }
        }
        else { $script:Run.status = 'Incomplete' }
        Save-Run
    }
    Write-Warning 'The workflow stopped. Submitted Azure deployments are not cancelled and created resources are preserved.'
    if ($script:RunFile) { Write-Host "Track submitted deployments: .\30_AVDAzureLocal.ps1 -Monitor '$script:RunFile'" }
    throw
} finally {
    $WarningPreference = $script:SavedAvdWarningPreference
    if ($script:SpnContext) { $null = Set-AzContext -Context $script:SpnContext }
}
#endregion
