# Terraform - Azure Local Deployment Changelog

All significant changes to the Terraform configuration are documented here,
ordered newest-first. Each entry records **what** changed, **why** it was
necessary, and **where** the change lives.

---

## 2026-04-02 - Document staged deployment defaults; require RBAC before `edgeDevices`

### terraform/README.md + terraform/terraform.tfvars.example: Current lab flow and sample values documented

**Problem**: The Terraform folder had no dedicated README and the current sample configuration
had drifted away from earlier documentation. The example file now starts in Validate mode,
uses placeholder secrets instead of committed lab passwords, and documents the single-node
MGMT1-only converged networking pattern, but those expectations were not captured in one
Terraform-focused document.

**Fix**: Added `terraform/README.md` and aligned the documentation with the current
`terraform.tfvars.example` behaviour:

- staged deployment flow (`is_exported = false` first, then `true`)
- `deployment_completed = false` until the full deployment succeeds
- MGMT1-only single-node networking sample (`management_adapters = ["MGMT1"]`)
- converged intent workaround via `storage_networks = [{ ... MGMT1 ... }]`
- placeholder credentials / secrets (`TODO-*`)
- `witness_type = ""`, `networking_type = ""`, `networking_pattern = ""`
- recovery helpers (`import_deployment_settings`, `import_machine_rg_role_assignment_ids`)

This makes the Terraform folder self-contained and matches the values users actually copy
from the example file.

---

### modules/azurelocal/edgedevices.tf + modules/azurelocal/variables.tf: Enforce role-assignment order before node registration

**Problem**: `edgeDevices` registration was not explicitly ordered after the required RBAC
resources, and the resource provider SPN role assignment remained opt-in even though Arc
extension installation depends on it.

**Fix**:

- Added `depends_on` to `azapi_resource_action.edge_device` so registration happens only
  after `service_principal_role_assign` and `machine_rg_role_assign` exist.
- Changed `create_hci_rp_role_assignments` default from `false` to `true`.
- Clarified the variable description: the `Azure Connected Machine Resource Manager` role on
  the Microsoft.AzureStackHCI resource provider SPN is required before Arc extensions can
  be installed.

**Impact**: Fresh deployments now follow a safer dependency order closer to the portal/ARM
sequence: role assignments -> `edgeDevices` -> `deploymentSettings`.

---

## 2026-04-02 - Guard `arc_settings` data source; import block for machine RG role assignments

### modules/azurelocal/main.tf + outputs.tf: `arc_settings` data source made conditional

**Problem**: `data.azapi_resource.arc_settings` had no `count` guard. Terraform always
evaluates data sources at plan/apply time regardless of `depends_on`, so during any
operation before a full deployment completes (validate stage, partial apply recovery,
`terraform import`) the read failed with `Resource not found` because the
`Microsoft.AzureStackHCI/clusters/ArcSettings/default` resource is only created by the
Azure deployment engine after all deployment steps succeed.

**Fix**: Added `count = var.deployment_completed ? 1 : 0` to the data source, matching
the existing pattern on `arcbridge` and `customlocation`. Updated `outputs.tf` to return
`null` when `deployment_completed = false`, consistent with the `arcbridge` and
`customlocation` outputs.

---

### terraform/main.tf + variables.tf + terraform.tfvars.example: Import block for machine RG role assignments

**Problem**: `azurerm_role_assignment.machine_rg_role_assign` resources (keys `<SERVER>_DMR`
and `<SERVER>_INFRA`) are scoped to the resource group, not to any randomly-suffixed
resource (Key Vault, storage account). If Terraform state is lost after a successful apply,
these role assignments remain in Azure and the next `terraform apply` fails with:

```
Error: unexpected status 409 (409 Conflict) with error: RoleAssignmentExists:
The role assignment already exists. The ID of the existing role assignment is <guid>.
```

The provider does not handle 409 on role assignments gracefully; it has no built-in
"adopt if exists" behaviour. The only recovery path is to import the existing assignments
into state before the next apply.

**Fix**: Added a `for_each` import block in `terraform/main.tf` controlled by the new
`import_machine_rg_role_assignment_ids` variable (default `{}`). Follows the same
pattern as the existing `import_deployment_settings` import block.

**Usage**: Copy the GUIDs from the 409 error message (shown as
`The ID of the existing role assignment is <guid>`) into `terraform.tfvars`:

```hcl
import_machine_rg_role_assignment_ids = {
  "AZLN01_DMR"   = "db214d43-5a4d-f471-dcbb-0b9fc086dd66"
  "AZLN01_INFRA" = "3a405fd3-3175-685e-dc90-97e842c69f16"
}
```

Run `terraform apply`, then reset to `{}`.

**Files changed**:
- `terraform/variables.tf`: new `import_machine_rg_role_assignment_ids` map variable.
- `terraform/main.tf`: new `import` block using the variable.
- `terraform/terraform.tfvars.example`: entry with empty map default.

---

## 2026-04-02 - Fix endingAddress drift triggering unnecessary re-validation on Stage 2

### terraform/terraform.tfvars + terraform.tfvars.example: `ending_address` corrected to `172.19.18.30`

**Problem**: Stage 1 (`is_exported = false`) sent `endingAddress = "172.19.18.26"` to the Azure API.
Azure normalised the IP pool to a minimum of 11 addresses and internally stored
`endingAddress = "172.19.18.30"`. When Stage 2 (`is_exported = true`) ran, Terraform detected this
drift (`172.19.18.30 → 172.19.18.26`) and issued a PUT update to `validatedeploymentsetting`.
The update triggered a full re-validation (~30 minutes) before `deploymentsetting` could PATCH
`deploymentMode = "Deploy"`.

**Root cause**: The IP range had been intentionally widened between Stage 1 and Stage 2.
Azure Local requires ~6 infrastructure IPs for single-node; this lab reserves 10 (`.20`→`.30`)
to simplify the deployment. The tfvars was updated to `.30` only for Stage 2, causing drift.

**Fix**: Changed `ending_address` from `"172.19.18.26"` to `"172.19.18.30"` in both
`terraform.tfvars` and `terraform.tfvars.example`. Both stages now use the same value from the
start, eliminating drift and the unnecessary re-validation on Stage 2 and subsequent applies.

---

## 2026-04-02 - Extensions installed automatically during Terraform validate stage

### Arc extensions no longer require manual pre-staging

**Finding**: A successful end-to-end validation confirmed that the four required Azure Connected
Machine extensions (`AzureEdgeTelemetryAndDiagnostics`, `AzureEdgeDeviceManagement`,
`AzureEdgeLifecycleManager`, `AzureEdgeRemoteSupport`) are now installed automatically on the
Arc node during the first `terraform apply` (validate stage — `validatedeploymentsetting`
resource). No manual pre-staging step is needed before running Terraform.

**Impact**:
- `scripts/01Lab/03_TroubleshootingExtensions.ps1` is **no longer required** as a pre-requisite
  before `terraform apply`. The script remains available for troubleshooting environments where
  extensions are in a `Failed` state or need to be reconciled outside of Terraform.
- The README has been updated accordingly: the script section now describes it as an
  optional troubleshooting tool rather than a required pre-step.

---

## 2026-04-01 - Confirmed root cause + automated node hotfix via Arc Run Command

### Root cause confirmed: `GetTargetBuildManifest` bug in `DownloadHelpers.psm1`

**Summary**: The `UpdateDeploymentSettingsDataFailed` / empty-URL error was traced to a bug in
`Microsoft.AzureStack.Role.Deployment.Service.10.2601.0.1162` installed on the node by the
`AzureEdgeLifecycleManager` Arc extension. The node-side `0.settings` nulling workaround
documented in the 2026-03-27 "Real root cause" entry addressed the symptom; this entry documents
the confirmed code-level root cause and a proper fix applied via Arc Run Command.

**Root cause** `DownloadHelpers.psm1`, function `GetTargetBuildManifest` (line 335):

```powershell
# Bug: $assemblyPayload is a non-null PSCustomObject {CloudName, DeviceType, RegionName}
# [string]::IsNullOrEmpty(object) calls .ToString() → non-empty string → returns $false
# → cloud manifest fallback never activates → 4 empty URLs → BITS error
if ([string]::IsNullOrEmpty($assemblyPayload)) {
```

When `terraform apply` creates the `deploymentSettings` resource, Azure writes only minimal
`publicSettings` to the LcmController RuntimeSettings file (`0.settings`):

```json
{"runtimeSettings":[{"handlerSettings":{"publicSettings":{"CloudName":"AzureCloud","DeviceType":"AzureEdge","RegionName":"westeurope"}}}]}
```

`FetchSpecificBuildNumber` (line 315) reads this file, assigns the `publicSettings` PSCustomObject
to `$assemblyPayload`, and returns it. The object is non-null but has no `AssemblyDeployPackage`
or `Payload`, it is just the cloud identity markers.

`GetTargetBuildManifest` was supposed to detect this and use the cloud manifest fallback
(downloading from `https://aka.ms/AzureStackHCI/CloudDeploymentManifest`), but `[string]::IsNullOrEmpty()`
returns `$false` for any non-null object. The code enters the `else` branch, reads
`$assemblyPayload.Payload` (which is `$null`), and produces four empty URLs.

**Fix** patch line 335 of `DownloadHelpers.psm1` on the node:

```powershell
# Fixed: also check that AssemblyDeployPackage is populated before taking the specific-build path
if ([string]::IsNullOrEmpty($assemblyPayload) -or [string]::IsNullOrEmpty($assemblyPayload.AssemblyDeployPackage)) {
```

This makes the fallback activate whenever `publicSettings` exists but does not carry a valid
`AssemblyDeployPackage`, which is exactly the case for the minimal settings Azure pushes.
After the fix the node downloads the cloud manifest, retrieves the correct package URLs and
proceeds with the deployment validation.

---

### scripts/01Lab/03_TroubleshootingExtensions.ps1: New Step 11, LcmController NuGet hotfix via Arc Run Command

**Problem**: Applying the patch above required manual RDP/SSH access to the node, contradicting
the goal of a fully automated deployment where the node is not touched after Arc registration.

**Fix**: Added Step 11 to `03_TroubleshootingExtensions.ps1`. The new step uses
**Azure Arc Run Command** (`Microsoft.HybridCompute/machines/runCommands`, API
`2024-07-31-preview`) to deliver the patch to the node through the Arc agent, no direct
network path to the node is required. `asyncExecution = false` means the PUT operation waits
for script completion and returns stdout/stderr inline.

The script delivered via Arc Run Command:
1. Checks that the affected NuGet package (`10.2601.0.1162`) is present at the expected path.
2. Verifies whether the patch has already been applied (idempotent).
3. Applies the one-line fix to `DownloadHelpers.psm1`.
4. Restarts the `LcmController` Windows service so the patched module is reloaded from disk.

From this point, running `03_TroubleshootingExtensions.ps1` after Arc registration and before
`terraform apply` is sufficient to prepare the node for a fully automated, zero-touch Terraform
deployment.

> **Note**: This bug is in the `10.2601.0.1162` build of
> `Microsoft.AzureStack.Role.Deployment.Service`. If Microsoft releases a newer build of the
> `AzureEdgeLifecycleManager` extension that ships a fixed NuGet version, the patch step can
> be removed and the extension version pin in `$ExtensionList` updated accordingly.

---

## 2026-03-27 - Conditional post-deployment data sources; fix deprecated keyvault argument; remove redundant ignore_changes

### modules/azurelocal/main.tf: `arcbridge` and `customlocation` data sources made conditional

**Problem**: `data.azapi_resource.arcbridge` and `data.azapi_resource.customlocation` are
unconditional in the AVM module. Terraform always reads data sources at plan time, regardless
of any `depends_on`. These resources are only created by the Azure deployment engine after all
deployment steps succeed. While the deployment is in progress or has failed mid-way, the
resources do not exist, so every `terraform plan` fails with `Resource not found`.

**Fix**: Added `count = var.deployment_completed ? 1 : 0` to both data sources.
- `deployment_completed = false` (default, during/retrying deployment): data sources skipped,
  plan succeeds.
- `deployment_completed = true` (set after all deployment steps succeed): data sources read
  and exposed via outputs.

Also updated:
- `locals.tf` line 146 (`owned_user_storages`): changed `data.azapi_resource.customlocation.id`
  → `data.azapi_resource.customlocation[0].id` with conditional guard.
- `outputs.tf`: `arcbridge` and `customlocation` outputs use `[0]` with conditional expression,
  returning `null` when `deployment_completed = false`.
- `modules/azurelocal/variables.tf`: new `deployment_completed` bool variable (default `false`).
- `terraform/variables.tf`: pass-through variable with description.
- `terraform/main.tf`: `deployment_completed = var.deployment_completed` passed to module.
- `terraform/terraform.tfvars`: `deployment_completed = false` (set to `true` after success).

---

### modules/azurelocal/keyvault.tf: Fix deprecated `enable_rbac_authorization`

**Problem**: The azurerm provider renamed `enable_rbac_authorization` to
`rbac_authorization_enabled`. The old name still works but produces a deprecation
warning on every plan/apply and will be removed in provider v5.0.

**Fix**: Renamed the argument to `rbac_authorization_enabled`.

---

### modules/azurelocal/validate.tf: Remove redundant `output` from `ignore_changes`

**Problem**: The azapi provider warned that including `output` in `lifecycle.ignore_changes`
has no effect - `output` is a provider-decided computed attribute that the `ignore_changes`
mechanism does not cover.

**Fix**: Removed `output` from `ignore_changes`. The remaining entry
(`body.properties.deploymentMode`) is still valid and needed.

---

## 2026-03-27 - Fix inverted `count` in deploymentsetting (full deployment triggered on validate stage)

### modules/azurelocal/deploy.tf: `count` condition corrected

**Problem**: The `azapi_update_resource.deploymentsetting` resource had
`count = var.is_exported ? 0 : 1`. In Terraform, `false ? 0 : 1 = 1`, so when
`is_exported = false` (Stage 1 / Validate) the resource was **active** and
immediately patched `deploymentMode = "Deploy"` on the deploymentSettings
resource right after validation completed. This caused the full CloudDeployment
(57-step FullCloudDeployment plan) to start even though the user had not yet
set `is_exported = true`.

**Fix**: Changed to `count = var.is_exported ? 1 : 0` so that:
- `is_exported = false` (Stage 1): count = 0, the Deploy update is inactive.
  Azure runs only the Validate action plan (~10 min).
- `is_exported = true` (Stage 2): count = 1, the Deploy update patches
  deploymentMode to "Deploy". Azure runs FullCloudDeployment (~30-60 min).

---

## 2026-03-27 - Ignore `output` on validatedeploymentsetting (azapi inconsistency bug)

### modules/azurelocal/validate.tf: `ignore_changes = [output]`

**Problem**: After importing `deploymentSettings/default` with state from a previous
run and then applying body changes (sbePartnerInfo, API version), Azure re-ran
the validation and returned updated timestamps. The azapi provider compared the
old cached output with the new result and reported
`"Provider produced inconsistent result after apply"` for every
`validationStatus.steps[*].startTimeUtc` and `endTimeUtc` field.

This is a known azapi provider limitation: `output` is a computed attribute
populated from the raw API response body. Its contents (validation step timestamps,
provisioningState, etc.) change with every validation run, making it inherently
unstable across applies when the provider tries to compare pre- and post-apply
values.

**Fix**: Added `output` to `lifecycle.ignore_changes`. Terraform will no longer
compare the output attribute between the planned state and the actual post-apply
response, eliminating the false inconsistency errors. The validation result is
still visible in the Azure portal and via az CLI; it just is not tracked in
Terraform state.

---

## 2026-03-27 - Import block for existing deploymentSettings (post-timeout recovery)

### terraform/main.tf: Conditional import block for deploymentSettings

**Problem**: After the previous `terraform apply` hit `context deadline exceeded`
at ~29 minutes, the `deploymentSettings/default` resource was left in Azure but
not recorded in Terraform state. The next `apply` immediately failed with
`"Resource already exists"`.

**Fix**: Added a Terraform 1.7+ `import` block (same pattern as `edgeDevices`)
controlled by the new `import_deployment_settings` variable (default `false`).
When `true`, Terraform imports the pre-existing `deploymentSettings/default`
into state before the plan phase, preventing the "already exists" error.

Set `import_deployment_settings = false` on a completely fresh environment where
no prior `terraform apply` has reached the `deploymentSettings` creation step.

### terraform/variables.tf: `import_deployment_settings` variable

New `bool` variable, default `false`, documented with the same pattern as
`import_edge_devices`.

### terraform/terraform.tfvars: `import_deployment_settings = true`

Set to `true` for the current environment (deploymentSettings already exists in
Azure from the previous timed-out apply).

---

## 2026-03-27 - Explicit timeouts on validatedeploymentsetting and deploymentsetting

### modules/azurelocal/validate.tf: `timeouts` block on `validatedeploymentsetting`

**Problem**: No explicit timeout. The full environment validation
(`EnvironmentValidatorFull`, ~10 steps) takes 30-60 minutes. The azapi provider's
default HTTP timeout fired with `context deadline exceeded` even though the Azure
operation was progressing correctly (Connectivity and ExternalAD both passed
before the cut-off).

**Fix**: Added `timeouts { create = "2h"; update = "2h"; delete = "1h" }`.

---

### modules/azurelocal/deploy.tf: Add `update` timeout to `deploymentsetting`

**Problem**: The existing `timeouts` block only declared `create = "24h"` and
`delete = "60m"`. If Terraform triggers an update on this resource (e.g. on
re-apply after state drift) the provider's default timeout would apply, which
may be shorter than the full cluster provisioning time (~30-60 minutes).

**Fix**: Added `update = "24h"` to match the `create` timeout so any re-apply
during the Deploy stage has the same headroom.

---

## 2026-03-27 - Real root cause of empty download URLs; API version rollback to 2025-09-15-preview

### Node remediation: `0.settings` is the actual stale file (not `*.json`)

**Problem**: All previous cleanup attempts used `Get-ChildItem -Filter "*.json"`, which
matched nothing relevant. The LcmController Arc extension stores its runtime
settings in `<version>\RuntimeSettings\0.settings` - a `.settings` file, not
`.json`. This file was **never deleted** and has been causing every failure.

`0.settings` on AZLN01 contains:
```json
{"runtimeSettings":[{"handlerSettings":{"publicSettings":{"CloudName":"AzureCloud","DeviceType":"AzureEdge","RegionName":"westeurope"}}}]}
```

`FetchSpecificBuildNumber` (DownloadHelpers.psm1:315) reads every `*.settings` file,
assigns `publicSettings` to `$assemblyPayload`, and only breaks early if
`$assemblyPayload.AssemblyDeployPackage` is non-empty. After the loop the last value
of `$assemblyPayload` is returned. With only `0.settings` (which has no
`AssemblyDeployPackage`), the loop completes and returns the PSCustomObject
`{CloudName, DeviceType, RegionName}`.

`GetTargetBuildManifest` (DownloadHelpers.psm1:332) then calls
`[string]::IsNullOrEmpty($assemblyPayload)`. A non-null PSCustomObject converts to
a non-empty string, so this check returns **false**, sending the code into the
"specific build" branch. `$assemblyPayload.Payload` is absent → all four download
URLs are null → BITS fails with "Cannot bind argument to parameter 'Source' because
it is an empty string."

For `GetTargetBuildManifest` to use the cloud manifest path, `FetchSpecificBuildNumber`
must return `$null`. This happens only when no `.settings` files exist, or every file
has `"publicSettings": null`.

**Root-cause chain** (revised and definitive):
1. `0.settings` was written once when the LcmController Arc extension was first
   enabled (sequence 0). Azure does **not** push new settings files during
   `deploymentSettings` operations - confirmed by `state.json`
   (`SequenceNumberFinished=0`) remaining unchanged across all applies.
2. The file has a non-null `publicSettings` object (`CloudName`/`DeviceType`/
   `RegionName`) that never contains `AssemblyDeployPackage` or `Payload`.
3. `FetchSpecificBuildNumber` returns this PSCustomObject instead of `$null`.
4. `GetTargetBuildManifest` misidentifies it as a valid specific-build payload.
5. Empty URLs → BITS error.

**Fix** - run on **AZLN01** once, then re-run `terraform apply`:

```powershell
$lcmPath  = "C:\Packages\Plugins\Microsoft.AzureStack.Orchestration.LcmController"
$versionDir  = Get-ChildItem $lcmPath -Directory |
               Sort-Object LastWriteTimeUtc -Descending |
               Select-Object -First 1
$settingsFile = Join-Path $versionDir.FullName "RuntimeSettings\0.settings"

# Confirm the problematic content
Get-Content $settingsFile

# Null out publicSettings: FetchSpecificBuildNumber will now return $null
# → GetTargetBuildManifest uses cloud manifest path
# → DownloadCloudManifestHelper downloads from https://aka.ms/AzureStackHCI/CloudDeploymentManifest
Set-Content $settingsFile `
  '{"runtimeSettings":[{"handlerSettings":{"publicSettings":null}}]}' -Force

# Confirm
Get-Content $settingsFile

# Clear any partial download from previous failed runs
@("C:\LCMBITSStage", "C:\DeploymentPackage") |
    Where-Object { Test-Path $_ } |
    ForEach-Object { Remove-Item $_ -Recurse -Force -Verbose }
```

Azure will not overwrite this file during `deploymentSettings` processing
(no sequence-number increment observed across multiple applies). The null
`publicSettings` persists until the LcmController extension itself is updated.

---

### modules/azurelocal/validate.tf + deploy.tf + main.tf: Revert API version to `2025-09-15-preview`

**Problem**: All three resources were previously bumped to `2026-03-01-preview`.
The ARM QuickStart template (`ARM/azuredeploy.json`) uses `2025-09-15-preview`
for both `Microsoft.AzureStackHCI/clusters` and
`Microsoft.AzureStackHCI/clusters/deploymentSettings`. Using a newer API version
may change how the Azure control plane processes the request and what settings it
pushes to the LcmController Arc extension.

**Fix**: Reverted all three resource type strings back to `@2025-09-15-preview`:
- `modules/azurelocal/validate.tf` - `validatedeploymentsetting`
- `modules/azurelocal/deploy.tf` - `deploymentsetting`
- `modules/azurelocal/main.tf` - `cluster`

`schema_validation_enabled = false` on `validatedeploymentsetting` is retained
(preview API, not in local provider schema cache).

---

## 2026-03-27 - Add sbePartnerInfo; revert secretsLocation; node remediation guide

### modules/azurelocal/locals.tf: Add empty `sbePartnerInfo` to scaleUnit

> **False root cause - superseded**: The root-cause chain below was incorrect.
> The empty download URLs were caused by the stale `0.settings` file in the
> LcmController RuntimeSettings directory, not by the absence of `sbePartnerInfo`.
> See the "Real root cause" entry above for the confirmed analysis.
> Adding `sbePartnerInfo` brings the payload structurally closer to the ARM
> template and is retained as a defensive alignment fix, but it did not resolve
> the download failure on its own.

**Problem**: After deep-comparison of the ARM QuickStart template
(`ARM/azuredeploy.json`) against our Terraform payload, one structural
difference was identified: the ARM template **always** sends a
`sbePartnerInfo` block inside each `scaleUnit`, even when no OEM /
Solution Builder Extension (SBE) partner is involved (all fields are
empty strings or null).

Our Terraform was omitting `sbePartnerInfo` entirely. The Azure
deployment control-plane appears to use the presence of this block to
decide what settings to push to the node's
`Microsoft.AzureStack.Orchestration.LcmController` Arc extension
(`C:\Packages\Plugins\Microsoft.AzureStack.Orchestration.LcmController\`).

**Root-cause chain** (incorrect - superseded by "Real root cause" entry above):
1. `deploymentSettings` created → ARM processes → LcmController triggered.
2. Azure writes extension settings to `{LcmController}\{ver}\RuntimeSettings\*.json`.
3. Without `sbePartnerInfo`, Azure pushes a `publicSettings` object that
   is **non-null** but has an empty `AssemblyDeployPackage` and no `Payload`.
4. `FetchSpecificBuildNumber` (DownloadHelpers.psm1) iterates the
   RuntimeSettings files and returns the last `publicSettings` PSCustomObject.
5. `[string]::IsNullOrEmpty($assemblyPayload)` is **FALSE** for any
   non-null PSCustomObject, so `GetTargetBuildManifest` enters the else
   branch and attempts to read `$assemblyPayload.Payload`.
6. `Payload` is null/empty → `$packageUrl`, `$verifierUrl`, `$bootstrapToolUrl`
   are all null → BITS fails:
   `"Cannot bind argument to parameter 'Source' because it is an empty string."`
7. If `publicSettings` were null (or the files absent), the function
   would return null → `GetTargetBuildManifest` falls to the cloud
   manifest path → downloads from
   `https://aka.ms/AzureStackHCI/CloudDeploymentManifest` → works.

**Fix**: Added `sbePartnerInfo` with empty values to the `scaleUnits` entry
in `locals.tf`, matching the ARM template exactly.

---

### terraform/main.tf: Revert spurious `secrets_location` parameter

**Problem**: A previous attempt added
`secrets_location = azurerm_key_vault.deployment_keyvault.vault_uri` to
the module call, on the theory that the `secretsLocation` field in the
deployment settings body was causing empty download URLs.

After source-code analysis of `DownloadHelpers.psm1` and comparison with
the ARM template it was confirmed that:
- The ARM template does **not** send `secretsLocation`; it uses only the
  `secrets` array (new model).
- The download-URL issue originates in the LcmController RuntimeSettings,
  not in how secrets are delivered.

**Fix**: Removed the `secrets_location` parameter. The payload now matches
the ARM template (new `secrets` model, no deprecated `secretsLocation`).

---

### Node remediation: stale LcmController RuntimeSettings on AZLN01

> **Incorrect remediation - superseded**: The script below uses
> `Get-ChildItem -Filter "*.json"` which does not match the actual problematic
> file (`0.settings`). This approach found nothing and did not fix the failure.
> Use the corrected remediation in the "Real root cause" entry above, which
> targets `0.settings` directly and nulls out `publicSettings`.

The above Terraform changes address the structural cause. However, AZLN01
may already have stale `RuntimeSettings` files from previous failed
attempts that will keep triggering the same code path until they are
cleared.

Run the following on **AZLN01** (e.g. via RDP or PowerShell remoting)
**once**, then re-run `terraform apply`:

```powershell
# Inspect current RuntimeSettings
$lcmPath = "C:\Packages\Plugins\Microsoft.AzureStack.Orchestration.LcmController"
Get-ChildItem $lcmPath -Recurse -Filter "*.json" |
    Where-Object DirectoryName -like "*RuntimeSettings*" |
    Sort-Object LastWriteTimeUtc -Descending |
    ForEach-Object {
        Write-Host "=== $($_.FullName) ($($_.LastWriteTimeUtc)) ==="
        $j  = Get-Content $_.FullName | ConvertFrom-Json
        $ps = $j.runtimeSettings.handlerSettings.publicSettings
        Write-Host "  AssemblyDeployPackage : $($ps.AssemblyDeployPackage)"
        Write-Host "  Payload count         : $($ps.Payload.Count)"
    }

# If AssemblyDeployPackage is empty for all files, delete them so the
# code falls back to downloading the cloud manifest instead:
Get-ChildItem $lcmPath -Recurse -Filter "*.json" |
    Where-Object DirectoryName -like "*RuntimeSettings*" |
    Remove-Item -Force -Verbose

# Also clear any partial deployment package download from previous runs:
$tmpPath = "C:\LCMBITSStage"
if (Test-Path $tmpPath) { Remove-Item $tmpPath -Recurse -Force -Verbose }

$pkgPath = "C:\DeploymentPackage"
if (Test-Path $pkgPath) { Remove-Item $pkgPath -Recurse -Force -Verbose }
```

After clearing the stale files, `FetchSpecificBuildNumber` will return
`$null` → `GetTargetBuildManifest` will enter the cloud-manifest path →
download from `https://aka.ms/AzureStackHCI/CloudDeploymentManifest` →
proceed with validation.

---

## 2026-03-27 - Fix "Resource already exists" for edgeDevices

### terraform/main.tf: Conditional import block for edgeDevices

**Problem**: `azapi_resource.edge_device["AZLN01"]` already existed in
Azure (created by a prior portal/ARM deployment) and was not in Terraform
state, causing `Error: Resource already exists`.

**Fix**: Added a Terraform 1.7+ `for_each` import block in root `main.tf`.
Controlled by the `import_edge_devices` variable (default `true`). Fresh
environments with no prior deployments set `import_edge_devices = false`.

---

## 2026-03-27 - Random name suffix for Key Vault and Storage Account

### terraform/main.tf: `random_integer` suffix

**Problem**: Key Vault and Storage Account names must be globally unique.
Using a fixed name caused conflicts across deployments or after `destroy`.

**Fix**: Added a `random_integer` resource (min 1000, max 9999) persisted
in Terraform state. The suffix is appended via `locals.kv_name` /
`locals.sa_name` so the same names are reused across `terraform apply`
runs.

---

## 2026-03-27 - Root cause: UpdateDeploymentSettingsDataFailed

### modules/azurelocal/edgedevices.tf: New file

**Problem**: After deep-comparison of the ARM QuickStart template with
our Terraform configuration, the `Microsoft.AzureStackHCI/edgeDevices`
resource was identified as completely missing from Terraform. This
resource registers each Arc machine with the HCI edge management system
and enables the LcmController's `EdgeArmClient` to communicate with ARM.
Without it, every deployment settings validation failed with:
`"Failed to download deployment settings file using edge Arm client"`.

**Fix**: Created `edgedevices.tf` in the module, creating
`Microsoft.AzureStackHCI/edgeDevices@2025-09-15-preview` scoped to each
Arc machine. `lifecycle { ignore_changes = all }` prevents drift on a
resource that is also managed by the HCI control plane.

---

### modules/azurelocal/rolebindings.tf: `machine_rg_role_assign`

**Problem**: The ARM QuickStart template assigns two roles to the Arc
machine identity at resource-group scope that the upstream AVM module
was not creating:
- `Azure Stack HCI Device Management Role`
  (865ae368-6a45-4bd1-8fbf-0d5151f56fc1)
- `Azure Stack HCI Connected InfraVMs`
  (c99c945f-8bd1-4fb1-a903-01460aae6068)

**Fix**: Added `machine_rg_role_assign` resource and supporting locals
(`rg_roles`, `rg_role_assignments`, `subscription_id`) to `locals.tf`.

---

### modules/azurelocal/validate.tf: API version and depends_on

**Problem**: API version mismatch and missing dependencies.

> **Note - partial rollback**: The API version was bumped here to `2026-03-01-preview`.
> It was later reverted to `2025-09-15-preview` in the "Real root cause" entry above,
> after the ARM QuickStart template confirmed `2025-09-15-preview` as the correct version.

**Fix**:
- Bumped API version to `2026-03-01-preview` (later reverted - see above).
- Added `schema_validation_enabled = false` (preview API, not in local
  provider schema cache).
- Expanded `depends_on` to include `edge_device` and both new role
  assignment resources so they are guaranteed to exist before the
  deployment settings request reaches the control plane.

---

### modules/azurelocal/main.tf (cluster resource)

> **Note - partial rollback**: The cluster API version was bumped to `2026-03-01-preview`
> here and later reverted to `2025-09-15-preview` in the "Real root cause" entry above.

**Fix**: Bumped cluster API version to `2026-03-01-preview` (later reverted); added
`azapi_resource.edge_device` to its `depends_on`.

---

## Earlier - networkingType / networkingPattern rejected by live API

### terraform/terraform.tfvars: Set both fields to `""`

**Problem**: API version `2025-09-15-preview` accepts `networkingType` and
`networkingPattern` in its schema, but the live endpoint rejects them with
HTTP 400 `ObjectAdditionalProperties`. Setting either field to a non-empty
string caused the deploy to fail.

**Fix**: Both variables default to `""` in `terraform.tfvars`. The
`merge()` logic in `locals.tf` omits the field from the JSON body when the
value is an empty string.

---

## Earlier - schema_validation_enabled not supported on azapi_update_resource

### modules/azurelocal/deploy.tf

**Problem**: `schema_validation_enabled` is an argument on `azapi_resource`
only; it is not accepted by `azapi_update_resource`, causing a Terraform
plan error.

**Fix**: Removed `schema_validation_enabled = false` from `deploy.tf`.
