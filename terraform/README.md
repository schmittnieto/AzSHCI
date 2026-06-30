# Terraform - Azure Local Lab Deployment

This folder contains the Terraform path for deploying the Azure Local cluster after the node has been prepared and Arc-registered by `scripts/01Lab/02_Cluster.ps1`.

It uses a local fork of the Azure Verified Module (AVM) for Azure Local plus a small root configuration that creates the shared prerequisites first:

- Key Vault
- Witness storage account
- Azure Local cluster deployment settings
- Required role assignments and Arc edge device registration

## Authenticate with the service principal

Terraform authenticates through the Azure CLI session. Before running `terraform init`, `plan` or `apply`, sign in as the service principal so Terraform runs against the correct SPN, tenant and subscription.

`Connect-Spn.ps1` automates a clean login. It reads `service_principal_id`, `service_principal_secret` and `subscription_id` from `terraform.tfvars`. It reads the tenant id from `scripts/01Lab/.env` (`AZSHCI_TENANT_ID`), which is the same service principal the 01Lab scripts use. It clears any cached Azure CLI session first so a stale or wrong-tenant login cannot leak into the run.

The script is gitignored. Copy the template once, then run it at the start of each session:

```powershell
Copy-Item Connect-Spn.ps1.example Connect-Spn.ps1
.\Connect-Spn.ps1
```

It runs the equivalent of:

```powershell
az account clear
az login --service-principal --username "<service_principal_id>" --password "<service_principal_secret>" --tenant "<AZSHCI_TENANT_ID>"
az account set --subscription "<subscription_id>"
```

At the end it prints the active subscription and tenant so you can confirm the login matches the lab. If the tenant is not present in `scripts/01Lab/.env`, pass it explicitly with `-TenantId`.

> Why this matters: if a service principal from another account or tenant stays cached in the CLI, Terraform authenticates against the wrong directory and the deployment fails or targets the wrong subscription. Starting from a cleared session avoids that.

## Current deployment flow

The example in `terraform.tfvars.example` is intentionally staged.

### Stage 1 - Validate

Start with:

```hcl
is_exported = false
```

Then run:

```powershell
terraform init
terraform apply
```

This creates the Key Vault and storage account, applies the required RBAC, registers `edgeDevices`, and submits the Azure Local configuration for validation.

### Stage 2 - Deploy

After validation succeeds in Azure, change:

```hcl
is_exported = true
```

Then run:

```powershell
terraform apply
```

This switches the deployment mode from `Validate` to `Deploy` and starts the full cluster provisioning.

## Important inputs

Copy `terraform.tfvars.example` to `terraform.tfvars` and replace every `TODO` value before running Terraform.

The current sample is aligned to the single-node lab used in this repository:

- `management_adapters = ["MGMT1"]`
- `storage_networks` also uses `MGMT1` to force a converged single-node intent
- `rdma_enabled = false`
- `networking_type = ""`
- `networking_pattern = ""`
- `witness_type = ""`
- `deployment_completed = false`

The example also uses placeholder secrets instead of committed lab credentials:

- `deployment_user_password = "TODO-change-me"`
- `local_admin_password = "TODO-change-me"`
- `service_principal_secret = "TODO-your-spn-client-secret"`

## Role assignments and edgeDevices

The local module now assumes the Microsoft.AzureStackHCI resource provider service principal must receive the `Azure Connected Machine Resource Manager` role assignment during deployment. In `modules/azurelocal/variables.tf`, `create_hci_rp_role_assignments` defaults to `true`.

`modules/azurelocal/edgedevices.tf` also registers each Arc node only after the required role assignments exist:

1. Required role assignments
2. `edgeDevices`
3. `deploymentSettings`

This ordering matches the effective portal/ARM workflow more closely and avoids trying to validate deployment settings before the node is fully authorized.

`edgeDevices` is created with `azapi_resource_action`, so Terraform performs the registration PUT call but does not try to delete the resource on destroy.

## Clean teardown and role assignments

`scripts/01Lab/99_Offboarding.ps1` removes only the Hyper-V VMs, virtual switch, NAT and lab folders on the host. It does not touch anything in Azure. The Key Vault, storage account, Arc registration and RBAC role assignments created by Terraform are Azure resources, so the correct way to remove them is `terraform destroy` from this folder.

Run the teardown in this order:

```powershell
cd terraform
terraform destroy
# then, on the host:
..\scripts\01Lab\99_Offboarding.ps1
```

If you tear the lab down with `99_Offboarding.ps1` alone (or lose the Terraform state) the role assignments stay behind in Azure. The next `terraform apply` then fails with `409 RoleAssignmentExists`, because Terraform tries to create an assignment that already exists. The recovery is to import the orphaned assignment instead of recreating it (see below), or delete it in Azure and let Terraform recreate it:

```powershell
az role assignment delete `
  --assignee "<rp_service_principal_object_id>" `
  --role "Azure Connected Machine Resource Manager" `
  --scope "/subscriptions/<subscription_id>/resourceGroups/<resource_group_name>"
terraform apply
```

## Recovery helpers

Recovery variables documented in `terraform.tfvars.example`:

- `import_deployment_settings`
- `import_machine_rg_role_assignment_ids`
- `import_service_principal_role_assignment_ids`

Use them only when Azure resources already exist but Terraform state was lost or was never destroyed during a previous teardown. Reset them after the recovery apply succeeds.

`import_service_principal_role_assignment_ids` handles the resource provider role assignment (ACMRM, the `Azure Connected Machine Resource Manager` role on the Microsoft.AzureStackHCI service principal). When a previous deployment was removed with the host offboarding only, this assignment survives and the next apply fails with `409 RoleAssignmentExists` on `service_principal_role_assign["ACMRM"]`. Take the GUID from the error message and import it:

```hcl
import_service_principal_role_assignment_ids = {
  "ACMRM" = "<guid-from-the-409-error>"
}
```

Run `terraform apply`, then reset the value to `{}`. If the error shows the GUID without dashes, reformat it as `8-4-4-4-12`, or read the exact id with:

```powershell
az role assignment list `
  --assignee "<rp_service_principal_object_id>" `
  --scope "/subscriptions/<subscription_id>/resourceGroups/<resource_group_name>" `
  --query "[?roleDefinitionName=='Azure Connected Machine Resource Manager'].{name:name, id:id}" -o table
```

If the Arc machine was manually deleted from Azure and you need to run `terraform destroy`, set:

```hcl
enable_cluster_module = false
```

This skips the cluster module and avoids failing Arc data-source lookups during destroy.

## After a successful deployment

Keep:

```hcl
deployment_completed = false
```

while validation, deployment, or retry operations are still in progress.

Set it to `true` only after the full deployment has finished successfully. That enables post-deployment reads for resources such as `arcbridge`, `customlocation`, and related outputs that do not exist before Azure completes the deployment.
