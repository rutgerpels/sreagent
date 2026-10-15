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
var profile = '${prefix}-${environment}-d'
var suffix = take(uniqueString(subscription().id, profile, generation), 8)
var stem = 'd-${suffix}'
var rgName = 'rg-${profile}-${suffix}'
var appVnetId = resourceId(rgName, 'Microsoft.Network/virtualNetworks', 'vnet-${stem}')
var runnerVnetId = resourceId(runnerResourceGroup, 'Microsoft.Network/virtualNetworks', runnerVnetName)
var sreId = resourceId(rgName, 'Microsoft.App/agents', 'sre-${prefix}-${stem}')
var actionId = resourceId(rgName, 'Microsoft.ManagedIdentity/userAssignedIdentities', 'id-sre-${stem}')
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
output ownership object = {
  version: 1
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
  keyVaultZoneId: empty(keyVaultZoneId) ? resourceId(rgName, 'Microsoft.Network/privateDnsZones', 'privatelink.vaultcore.azure.net') : keyVaultZoneId
  acrZoneId: empty(acrZoneId) ? resourceId(rgName, 'Microsoft.Network/privateDnsZones', 'privatelink.azurecr.io') : acrZoneId
  sharedDnsLinks: concat(empty(keyVaultZoneId) ? [] : [{
    id: '${keyVaultZoneId}/virtualNetworkLinks/app-kv-${stem}'
    virtualNetworkId: appVnetId
  }], empty(acrZoneId) ? [] : [{
    id: '${acrZoneId}/virtualNetworkLinks/app-acr-${stem}'
    virtualNetworkId: appVnetId
  }])
  // Only the documented SRE Azure Monitor incident-lifecycle exception is
  // subscription scoped. OBA permissions are resource-scoped in agents.bicep.
  auxiliaryDeployments: concat([
    { id: subscriptionResourceId('Microsoft.Resources/deployments', '${deployment().name}-roles') }
    { id: resourceId(runnerResourceGroup, 'Microsoft.Resources/deployments', 'runner-peering-${stem}') }
  ], empty(keyVaultZoneId) ? [] : [{ id: resourceId(split(keyVaultZoneId, '/')[4], 'Microsoft.Resources/deployments', 'dns-kv-${stem}') }], empty(acrZoneId) ? [] : [{ id: resourceId(split(acrZoneId, '/')[4], 'Microsoft.Resources/deployments', 'dns-acr-${stem}') }])
  externalRoles: externalRoles
}
var externalRoles = [for identityId in [actionId, sreId]: {
    id: subscriptionResourceId('Microsoft.Authorization/roleAssignments', guid(subscription().id, identityId, monitoringContributor))
    identityResourceId: identityId
    identityApiVersion: identityId == sreId ? '2025-05-01-preview' : '2023-01-31'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', monitoringContributor)
    scope: subscription().id
  }]
