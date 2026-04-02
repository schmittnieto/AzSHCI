# Registers each Arc node with the Azure Stack HCI edge management system.
# Required before the LcmController extension can communicate with ARM
# during deployment settings validation and deployment.
#
# The ARM quickstart template creates edgeDevices BEFORE the cluster resource.
# Without this registration, the LcmController on the node cannot download
# deployment settings and reports "not reachable".
#
# Uses azapi_resource_action (fire-and-forget PUT) because the Azure API
# does not support deleting edgeDevices on physical Arc-registered nodes.
# On destroy, Terraform simply removes the entry from state.
#
# Portal wizard order: role assignments → edgeDevices → extensions → deploymentSettings

resource "azapi_resource_action" "edge_device" {
  for_each = data.azurerm_arc_machine.arcservers

  type        = "Microsoft.AzureStackHCI/edgeDevices@2025-09-15-preview"
  resource_id = "${each.value.id}/providers/Microsoft.AzureStackHCI/edgeDevices/default"
  method      = "PUT"

  body = {
    kind       = "HCI"
    properties = {}
  }

  depends_on = [
    azurerm_role_assignment.service_principal_role_assign,
    azurerm_role_assignment.machine_rg_role_assign,
  ]
}
