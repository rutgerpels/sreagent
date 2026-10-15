targetScope = 'subscription'
param obaIdentityId string
param obaPrincipalId string
// Documented subscription alert/resource-read prerequisite. Never Contributor/MC.
var monitoringReader = '43d0d8ad-25c7-4714-9337-8ba259a9fe05'
resource grant 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(subscription().id, obaIdentityId, monitoringReader)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', monitoringReader)
    principalId: obaPrincipalId
    principalType: 'ServicePrincipal'
  }
}
