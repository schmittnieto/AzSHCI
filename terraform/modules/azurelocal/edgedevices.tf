# Creates Microsoft.AzureStackHCI/edgeDevices scoped to each Arc machine.
# This resource registers each node with the HCI edge management system and
# enables the LcmController's EdgeArmClient to communicate with ARM during
# deployment settings validation and deployment.
#
# The ARM template (azure-quickstart-templates) creates edgeDevices BEFORE the
# cluster resource. Without this registration, the LcmController on the node
# cannot download deployment settings and reports "not reachable".
#
# Uses azapi_resource_action (fire-and-forget PUT) instead of azapi_resource
# because the Azure API does not support deleting edgeDevices on physical
# Arc-registered nodes. The DELETE call hangs indefinitely. With
# azapi_resource_action, Terraform does not attempt a DELETE on destroy - it
# simply drops the entry from state.

resource "azapi_resource_action" "edge_device" {
  for_each = data.azurerm_arc_machine.arcservers

  type        = "Microsoft.AzureStackHCI/edgeDevices@2025-09-15-preview"
  resource_id = "${each.value.id}/providers/Microsoft.AzureStackHCI/edgeDevices/default"
  method      = "PUT"

  body = {
    kind       = "HCI"
    properties = {}
  }
}
