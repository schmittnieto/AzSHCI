resource "azapi_update_resource" "deploymentsetting" {
  count = var.is_exported ? 1 : 0

  type = "Microsoft.AzureStackHCI/clusters/deploymentSettings@2025-09-15-preview"
  body = {
    properties = {
      deploymentMode = "Deploy"
    }
  }
  name      = "default"
  parent_id = azapi_resource.cluster.id

  timeouts {
    create = "24h"
    update = "24h"
    delete = "60m"
  }

  depends_on = [azapi_resource.validatedeploymentsetting]
}
