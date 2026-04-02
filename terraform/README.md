# Terraform - Azure Local Lab Deployment

This folder contains the Terraform path for deploying the Azure Local cluster after the node has been prepared and Arc-registered by `scripts/01Lab/02_Cluster.ps1`.

It uses a local fork of the Azure Verified Module (AVM) for Azure Local plus a small root configuration that creates the shared prerequisites first:

- Key Vault
- Witness storage account
- Azure Local cluster deployment settings
- Required role assignments and Arc edge device registration

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

## Recovery helpers

Two recovery variables are documented in `terraform.tfvars.example`:

- `import_deployment_settings`
- `import_machine_rg_role_assignment_ids`

Use them only when Azure resources already exist but Terraform state was lost during a previous apply. Reset them after the recovery apply succeeds.

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
