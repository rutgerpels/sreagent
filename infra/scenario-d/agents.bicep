param ownership object
param foundations object
param deployerPrincipalId string
param modelProvider string = 'MicrosoftFoundry'
param modelName string = 'Automatic'
var stem = ownership.stem
var contributor = 'b24988ac-6180-42a0-ab88-20f7382dd24c'
var monitoringReader = '43d0d8ad-25c7-4714-9337-8ba259a9fe05'
var logsReader = '73c42c96-874c-492b-b04d-ab87d138a893'
resource actionRoles 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for role in [contributor, monitoringReader, logsReader]: {
  name: guid(resourceGroup().id, foundations.actionIdentityId, role)
  properties: { roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', role), principalId: foundations.actionPrincipalId, principalType: 'ServicePrincipal' }
}]
resource sre 'Microsoft.App/agents@2025-05-01-preview' = {
  name: 'sre-${first(split(ownership.profile, '-'))}-${stem}'
  location: ownership.workloadLocation
  tags: ownership.tags
  identity: { type: 'SystemAssigned, UserAssigned', userAssignedIdentities: { '${foundations.actionIdentityId}': {} } }
  properties: {
    actionConfiguration: { accessLevel: 'High', mode: 'Review', identity: foundations.actionIdentityId }
    defaultModel: { provider: modelProvider, name: modelName }
    incidentManagementConfiguration: { type: 'AzMonitor', connectionName: 'azure-monitor' }
    knowledgeGraphConfiguration: { identity: foundations.actionIdentityId, managedResources: [resourceGroup().id] }
    // No secret-bearing connection string in ARM properties or deployment outputs.
    monthlyAgentUnitLimit: 500
    upgradeChannel: 'Stable'
    experimentalSettings: { EnableHttpTriggers: true, EnableV2AgentLoop: true, EnableWorkspaceTools: true }
    vnetConfiguration: { subnetResourceId: '${ownership.appVnetId}/subnets/sre-agent' }
    sandboxConfiguration: { egress: { mode: 'AzureVNet', allowedHosts: [], allowedRegistries: [], allowedCodeRepositories: [], allowHttpMcpServerNetworkAccess: false, vnetConfiguration: { usePrivateDnsResolution: true } } }
  }
  dependsOn: [actionRoles]
}
resource systemRoles 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for role in [contributor, monitoringReader, logsReader]: {
  name: guid(resourceGroup().id, sre.id, role)
  properties: { roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', role), principalId: sre.identity.principalId!, principalType: 'ServicePrincipal' }
}]
resource administrator 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: sre
  name: guid(sre.id, deployerPrincipalId, 'e79298df-d852-4c6d-84f9-5d13249d1e55')
  properties: { roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'e79298df-d852-4c6d-84f9-5d13249d1e55'), principalId: deployerPrincipalId, principalType: 'ServicePrincipal' }
}
resource oba 'Microsoft.Monitor/observabilityAgents@2026-05-01-preview' = {
  name: 'oba-${stem}'
  location: ownership.observabilityLocation
  tags: ownership.tags
  identity: { type: 'UserAssigned', userAssignedIdentities: { '${foundations.obaIdentityId}': {} } }
  properties: {
    monitoringAccountId: foundations.amwId
    // Keep autonomous operations PAUSED. Auto is the documented schema value;
    // do not invent a Manual enum. On-demand investigation is a separate UI flow.
    enabled: false
    operations: [
      { type: 'IssueCreation', mode: 'Auto', instructions: 'Group payment and downstream checkout failures from this resource group only. Include [OPS-REVIEW] in issue titles.' }
      { type: 'Investigation', mode: 'Auto' }
    ]
  }
  dependsOn: [obaWorkspaceRole, obaTelemetryRole]
}
resource target 'Microsoft.Monitor/observabilityAgents/monitoredResources@2026-05-01-preview' = {
  parent: oba
  name: 'appi-${stem}'
  properties: { resourceId: foundations.appInsightsId, enabled: true, isAutonomous: false }
}
resource amw 'Microsoft.Monitor/accounts@2023-04-03' existing = { name: 'amw-observability-${stem}' }
// Match Microsoft's UAMI template: Monitoring Contributor on this AMW only.
resource obaWorkspaceRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: amw
  name: guid(amw.id, foundations.obaIdentityId, '749f88d5-cbae-40b8-bcfc-e573ddc772fa')
  properties: { roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '749f88d5-cbae-40b8-bcfc-e573ddc772fa'), principalId: foundations.obaPrincipalId, principalType: 'ServicePrincipal' }
}
resource ai 'Microsoft.Insights/components@2020-02-02' existing = { name: 'appi-${stem}' }
resource obaTelemetryRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: ai
  name: guid(ai.id, foundations.obaIdentityId, monitoringReader)
  properties: { roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', monitoringReader), principalId: foundations.obaPrincipalId, principalType: 'ServicePrincipal' }
}
output agents object = { sreId: sre.id, sreName: sre.name, sreEndpoint: sre.properties.agentEndpoint!, systemPrincipalId: sre.identity.principalId!, obaId: oba.id, obaName: oba.name, amwId: amw.id }
