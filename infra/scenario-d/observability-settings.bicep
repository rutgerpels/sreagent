targetScope = 'subscription'
param amwId string
// No AVM surface for this preview singleton. Lifecycle records intent and verifies
// GET absence before preview AND immediately before create. Never deploy standalone.
// Shape: https://learn.microsoft.com/azure/azure-monitor/aiops/issues-how-to
#disable-next-line BCP081
resource settings 'Microsoft.Monitor/settings@2025-06-03-preview' = {
  name: 'default'
  properties: { defaultAzureMonitorWorkspace: amwId }
}
