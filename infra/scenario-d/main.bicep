targetScope = 'subscription'
@minLength(2)
@maxLength(8)
param prefix string = 'payd'
param environment string = 'demo'
@description('Change only after complete destroy. A new generation avoids soft-deleted vault names.')
param generation string = 'bicep1'
param workloadLocation string = 'swedencentral'
param observabilityLocation string = 'westeurope'
param runnerResourceGroup string = 'agentrg-d'
param runnerVnetName string = 'agent-vnet-d'
param keyVaultZoneId string = ''
param acrZoneId string = ''
@description('Immutable lifecycle mode. Opt-in requires lifecycle preflight, secure recipient and absence-only subscription settings creation.')
param observabilityAutonomous bool = false
var profile = '${prefix}-${environment}-d'
var suffix = take(uniqueString(subscription().id, profile, generation), 8)
var stem = 'd-${suffix}'
var rgName = 'rg-${profile}-${suffix}'
var appVnetId = resourceId(subscription().subscriptionId, rgName, 'Microsoft.Network/virtualNetworks', 'vnet-${stem}')
var runnerVnetId = resourceId(subscription().subscriptionId, runnerResourceGroup, 'Microsoft.Network/virtualNetworks', runnerVnetName)
var sreId = resourceId(subscription().subscriptionId, rgName, 'Microsoft.App/agents', 'sre-${prefix}-${stem}')
var actionId = resourceId(subscription().subscriptionId, rgName, 'Microsoft.ManagedIdentity/userAssignedIdentities', 'id-sre-${stem}')
var obaId = resourceId(subscription().subscriptionId, rgName, 'Microsoft.ManagedIdentity/userAssignedIdentities', 'id-oba-${stem}')
var amwId = resourceId(subscription().subscriptionId, rgName, 'Microsoft.Monitor/accounts', 'amw-observability-${stem}')
var monitoringReader = '43d0d8ad-25c7-4714-9337-8ba259a9fe05'
var monitoringContributor = '749f88d5-cbae-40b8-bcfc-e573ddc772fa'
var tags = {
  project: 'sre-agent-demo'
  scenario: 'D'
  env: environment
  managed_by: 'bicep'
  lifecycle_owner: deployment().name
  lifecycle_generation: generation
}
resource appRg 'Microsoft.Resources/resourceGroups@2025-04-01' = {
  name: rgName
  location: workloadLocation
  tags: tags
}
// This subscription deployment is the durable cleanup ledger. Never delete it
// until RG absence and every exact external resource deletion are verified.
output ownership object = union({
  version: observabilityAutonomous ? 2 : 1
  subscriptionId: subscription().subscriptionId
  deploymentName: deployment().name
  resourceGroupName: appRg.name
  resourceGroupId: appRg.id
  infrastructureResourceGroupName: 'rg-${profile}-infra-${suffix}'
  profile: profile
  generation: generation
  stem: stem
  tags: tags
  workloadLocation: workloadLocation
  observabilityLocation: observabilityLocation
  appVnetId: appVnetId
  runnerVnetId: runnerVnetId
  runnerPeeringId: '${runnerVnetId}/virtualNetworkPeerings/peer-runner-to-app-${stem}'
  keyVaultZoneId: empty(keyVaultZoneId) ? resourceId(subscription().subscriptionId, rgName, 'Microsoft.Network/privateDnsZones', 'privatelink.vaultcore.azure.net') : keyVaultZoneId
  acrZoneId: empty(acrZoneId) ? resourceId(subscription().subscriptionId, rgName, 'Microsoft.Network/privateDnsZones', 'privatelink.azurecr.io') : acrZoneId
  sharedDnsLinks: concat(empty(keyVaultZoneId) ? [] : [{
    id: '${keyVaultZoneId}/virtualNetworkLinks/app-kv-${stem}'
    virtualNetworkId: appVnetId
  }], empty(acrZoneId) ? [] : [{
    id: '${acrZoneId}/virtualNetworkLinks/app-acr-${stem}'
    virtualNetworkId: appVnetId
  }])
  // Intent is persisted BEFORE any external grant or singleton setting is created.
  // Default v1 keeps exactly two SRE grants; v2 adds only OBA Monitoring Reader.
  auxiliaryDeployments: concat([
    { id: subscriptionResourceId('Microsoft.Resources/deployments', '${deployment().name}-roles') }
    { id: resourceId(subscription().subscriptionId, runnerResourceGroup, 'Microsoft.Resources/deployments', 'runner-peering-${stem}') }
  ], observabilityAutonomous ? [
    { id: subscriptionResourceId('Microsoft.Resources/deployments', '${deployment().name}-oba-role') }
    { id: subscriptionResourceId('Microsoft.Resources/deployments', '${deployment().name}-oba-settings') }
  ] : [], empty(keyVaultZoneId) ? [] : [{ id: resourceId(subscription().subscriptionId, split(keyVaultZoneId, '/')[4], 'Microsoft.Resources/deployments', 'dns-kv-${stem}') }], empty(acrZoneId) ? [] : [{ id: resourceId(subscription().subscriptionId, split(acrZoneId, '/')[4], 'Microsoft.Resources/deployments', 'dns-acr-${stem}') }])
  externalRoles: concat(externalRoles, observabilityAutonomous ? [{
    id: subscriptionResourceId('Microsoft.Authorization/roleAssignments', guid(subscription().id, obaId, monitoringReader))
    identityResourceId: obaId
    identityApiVersion: '2023-01-31'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', monitoringReader)
    scope: subscription().id
  }] : [])
}, observabilityAutonomous ? {
  observabilityAutonomous: true
  defaultSettings: {
    id: subscriptionResourceId('Microsoft.Monitor/settings', 'default')
    defaultAzureMonitorWorkspace: amwId
  }
} : {})
var externalRoles = [for identityId in [actionId, sreId]: {
    id: subscriptionResourceId('Microsoft.Authorization/roleAssignments', guid(subscription().id, identityId, monitoringContributor))
    identityResourceId: identityId
    identityApiVersion: identityId == sreId ? '2025-05-01-preview' : '2023-01-31'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', monitoringContributor)
    scope: subscription().id
  }]
