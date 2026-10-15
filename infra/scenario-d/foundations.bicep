param ownership object
param deployerPrincipalId string
var stem = ownership.stem
var location = ownership.workloadLocation
var tags = ownership.tags
var apps = ['frontend', 'checkout-api', 'payment-service']
var kvReaders = [
{ principalId: identities[0].outputs.principalId, principalType: 'ServicePrincipal', roleDefinitionIdOrName: roleIds.vaultReader }
{ principalId: identities[1].outputs.principalId, principalType: 'ServicePrincipal', roleDefinitionIdOrName: roleIds.vaultReader }
{ principalId: identities[2].outputs.principalId, principalType: 'ServicePrincipal', roleDefinitionIdOrName: roleIds.vaultReader }
]
var acrReaders = [
{ principalId: identities[0].outputs.principalId, principalType: 'ServicePrincipal', roleDefinitionIdOrName: roleIds.acrPull }
{ principalId: identities[1].outputs.principalId, principalType: 'ServicePrincipal', roleDefinitionIdOrName: roleIds.acrPull }
{ principalId: identities[2].outputs.principalId, principalType: 'ServicePrincipal', roleDefinitionIdOrName: roleIds.acrPull }
]
var identityOutputs = [
{ app: apps[0], id: identities[0].outputs.resourceId, clientId: identities[0].outputs.clientId }
{ app: apps[1], id: identities[1].outputs.resourceId, clientId: identities[1].outputs.clientId }
{ app: apps[2], id: identities[2].outputs.resourceId, clientId: identities[2].outputs.clientId }
]
var roleIds = {
  acrPull: '7f951dda-4ed3-4680-a7ca-43fe172d538d'
  acrPush: '8311e382-0749-4cb8-b61a-304f252e45ec'
  vaultReader: '4633458b-17de-408a-b874-0445c86b69e6'
  vaultWriter: 'b86a8fe4-44ce-4948-aee5-eccb2c155cd7'
  metricsPublisher: '3913510d-42f4-4e42-8a64-420c390055eb'
}
module identities 'br/public:avm/res/managed-identity/user-assigned-identity:0.6.0' = [for app in apps: {
  name: 'identity-${app}'
  params: { name: 'id-${app}-${stem}', location: location, tags: tags, enableTelemetry: false }
}]
module actionIdentity 'br/public:avm/res/managed-identity/user-assigned-identity:0.6.0' = {
  name: 'identity-sre'
  params: { name: 'id-sre-${stem}', location: location, tags: tags, enableTelemetry: false }
}
module obaIdentity 'br/public:avm/res/managed-identity/user-assigned-identity:0.6.0' = {
  name: 'identity-oba'
  params: { name: 'id-oba-${stem}', location: ownership.observabilityLocation, tags: tags, enableTelemetry: false }
}
// Native telemetry declarations intentionally avoid AVM outputs that list and
// expose workspace shared keys / instrumentation credentials in deployment history.
resource law 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: 'law-${stem}'
  location: location
  tags: tags
  properties: { sku: { name: 'PerGB2018' }, retentionInDays: 30, features: { disableLocalAuth: true } }
}
resource ai 'Microsoft.Insights/components@2020-02-02' = {
  name: 'appi-${stem}'
  location: location
  kind: 'web'
  tags: tags
  properties: { Application_Type: 'web', WorkspaceResourceId: law.id, DisableLocalAuth: true, DisableIpMasking: false }
}
resource amw 'Microsoft.Monitor/accounts@2023-04-03' = {
  name: 'amw-observability-${stem}'
  location: ownership.observabilityLocation
  tags: tags
  // Public monitoring API is RBAC protected, not application ingress. The
  // hosted OBA preview/operator cannot query it through the app private link.
  properties: { publicNetworkAccess: 'Enabled' }
}
module vnet 'br/public:avm/res/network/virtual-network:0.9.0' = {
  name: 'network'
  params: {
    name: 'vnet-${stem}'
    location: location
    tags: tags
    enableTelemetry: false
    addressPrefixes: ['10.101.0.0/16']
    subnets: [
      { name: 'private-endpoints', addressPrefix: '10.101.0.0/27', privateEndpointNetworkPolicies: 'Disabled' }
      { name: 'container-apps', addressPrefix: '10.101.0.64/27', delegation: 'Microsoft.App/environments' }
      { name: 'sre-agent', addressPrefix: '10.101.0.96/27', delegation: 'Microsoft.App/environments' }
    ]
    peerings: [{ name: 'peer-app-to-runner-${stem}', remoteVirtualNetworkResourceId: ownership.runnerVnetId, allowForwardedTraffic: false, allowGatewayTransit: false, useRemoteGateways: false }]
  }
}
module runnerPeering 'runner-peering.bicep' = {
  name: 'runner-peering-${stem}'
  scope: resourceGroup(split(ownership.runnerVnetId, '/')[4])
  params: { runnerVnetName: last(split(ownership.runnerVnetId, '/')), appVnetId: vnet.outputs.resourceId, stem: stem }
}
var diag = [{ name: 'platform', workspaceResourceId: law.id, logCategoriesAndGroups: [{ categoryGroup: 'allLogs' }], metricCategories: [{ category: 'AllMetrics' }] }]
module vault 'br/public:avm/res/key-vault/vault:0.9.0' = {
  name: 'vault'
  params: {
    name: 'kv-${stem}'
    location: location
    tags: tags
    enableTelemetry: false
    sku: 'standard'
    enableRbacAuthorization: true
    enablePurgeProtection: true
    softDeleteRetentionInDays: 7
    enableVaultForDeployment: false
    enableVaultForTemplateDeployment: false
    enableVaultForDiskEncryption: false
    publicNetworkAccess: 'Disabled'
    networkAcls: { defaultAction: 'Deny', bypass: 'None' }
    diagnosticSettings: diag
    roleAssignments: concat([{ principalId: deployerPrincipalId, principalType: 'ServicePrincipal', roleDefinitionIdOrName: roleIds.vaultWriter }], kvReaders)
  }
}
module acr 'br/public:avm/res/container-registry/registry:0.9.3' = {
  name: 'registry'
  params: {
    name: 'acrpayd${replace(stem, '-', '')}'
    location: location
    tags: tags
    enableTelemetry: false
    acrSku: 'Premium'
    acrAdminUserEnabled: false
    anonymousPullEnabled: false
    publicNetworkAccess: 'Disabled'
    networkRuleSetDefaultAction: 'Deny'
    networkRuleBypassOptions: 'None'
    zoneRedundancy: 'Disabled'
    // az acr login uses the ARM audience. No admin credential or fallback.
    azureADAuthenticationAsArmPolicyStatus: 'enabled'
    diagnosticSettings: diag
    roleAssignments: concat([{ principalId: deployerPrincipalId, principalType: 'ServicePrincipal', roleDefinitionIdOrName: roleIds.acrPush }], acrReaders)
  }
}
resource publishers 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for (app, i) in apps: {
  name: guid(ai.id, resourceId('Microsoft.ManagedIdentity/userAssignedIdentities', 'id-${app}-${stem}'), roleIds.metricsPublisher)
  scope: ai
  properties: { roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleIds.metricsPublisher), principalId: identities[i].outputs.principalId, principalType: 'ServicePrincipal' }
}]
module dnsKv 'dns.bicep' = {
  name: 'dns-kv-${stem}'
  scope: resourceGroup(split(ownership.keyVaultZoneId, '/')[4])
  params: { zoneName: 'privatelink.vaultcore.azure.net', createZone: split(ownership.keyVaultZoneId, '/')[4] == resourceGroup().name, kind: 'kv', appVnetId: vnet.outputs.resourceId, runnerVnetId: ownership.runnerVnetId, stem: stem, tags: tags }
}
module dnsAcr 'dns.bicep' = {
  name: 'dns-acr-${stem}'
  scope: resourceGroup(split(ownership.acrZoneId, '/')[4])
  params: { zoneName: 'privatelink.azurecr.io', createZone: split(ownership.acrZoneId, '/')[4] == resourceGroup().name, kind: 'acr', appVnetId: vnet.outputs.resourceId, runnerVnetId: ownership.runnerVnetId, stem: stem, tags: tags }
}
module endpoints 'br/public:avm/res/network/private-endpoint:0.9.1' = [for (target, i) in [{group: 'vault', zone: ownership.keyVaultZoneId}, {group: 'registry', zone: ownership.acrZoneId}]: {
  name: 'endpoint-${i}'
  params: {
    name: 'pe-${target.group}-${stem}'
    location: location
    tags: tags
    enableTelemetry: false
    subnetResourceId: '${vnet.outputs.resourceId}/subnets/private-endpoints'
    privateLinkServiceConnections: [{ name: 'connection', properties: { privateLinkServiceId: i == 0 ? vault.outputs.resourceId : acr.outputs.resourceId, groupIds: [target.group] } }]
    privateDnsZoneGroup: { name: 'default', privateDnsZoneGroupConfigs: [{ name: 'zone', privateDnsZoneResourceId: target.zone }] }
  }
  dependsOn: [dnsKv, dnsAcr, runnerPeering]
}]
// The pinned AVM environment unconditionally calls LAW listKeys, even with
// azure-monitor destination. Native declaration preserves D's Entra-only contract.
resource cae 'Microsoft.App/managedEnvironments@2026-01-01' = {
  name: 'cae-${stem}'
  location: location
  tags: tags
  properties: {
    vnetConfiguration: { infrastructureSubnetId: '${vnet.outputs.resourceId}/subnets/container-apps', internal: false }
    infrastructureResourceGroup: ownership.infrastructureResourceGroupName
    publicNetworkAccess: 'Enabled'
    appLogsConfiguration: { destination: 'azure-monitor' }
    workloadProfiles: [{ name: 'Consumption', workloadProfileType: 'Consumption' }]
    zoneRedundant: false
  }
}
resource caeDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'platform'
  scope: cae
  properties: { workspaceId: law.id, logs: [{ categoryGroup: 'allLogs', enabled: true }], metrics: [{ category: 'AllMetrics', enabled: true }] }
}
output foundations object = {
  acrName: acr.outputs.name
  acrLoginServer: acr.outputs.loginServer
  keyVaultName: vault.outputs.name
  keyVaultUri: vault.outputs.uri
  appInsightsName: ai.name
  appInsightsId: ai.id
  appInsightsAppId: ai.properties.AppId
  workspaceId: law.id
  amwId: amw.id
  environmentId: cae.id
  environmentDomain: cae.properties.defaultDomain
  actionIdentityId: actionIdentity.outputs.resourceId
  actionPrincipalId: actionIdentity.outputs.principalId
  obaIdentityId: obaIdentity.outputs.resourceId
  obaPrincipalId: obaIdentity.outputs.principalId
  identities: identityOutputs
}
