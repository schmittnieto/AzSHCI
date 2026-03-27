# Creates Microsoft.AzureStackHCI/edgeDevices scoped to each Arc machine.
# This resource registers each node with the HCI edge management system and
# enables the LcmController's EdgeArmClient to communicate with ARM during
# deployment settings validation and deployment.
#
# The ARM template (azure-quickstart-templates) creates edgeDevices BEFORE the
# cluster resource. Without this registration, the LcmController on the node
# cannot download deployment settings and reports "not reachable".

resource "azapi_resource" "edge_device" {
  for_each = data.azurerm_arc_machine.arcservers

  type                      = "Microsoft.AzureStackHCI/edgeDevices@2025-09-15-preview"
  name                      = "default"
  parent_id                 = each.value.id
  schema_validation_enabled = false

  body = {
    kind       = "HCI"
    properties = {}
  }

  lifecycle {
    ignore_changes = all
  }
}
