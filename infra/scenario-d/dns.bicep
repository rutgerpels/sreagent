param zoneName string
param createZone bool
param kind string
param appVnetId string
param runnerVnetId string
param stem string
param tags object
resource zone 'Microsoft.Network/privateDnsZones@2024-06-01' = if (createZone) { name: zoneName, location: 'global', tags: tags }
resource existingZone 'Microsoft.Network/privateDnsZones@2024-06-01' existing = { name: zoneName }
resource appLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = {
  parent: existingZone
  name: 'app-${kind}-${stem}'
  location: 'global'
  tags: tags
  properties: { virtualNetwork: { id: appVnetId }, registrationEnabled: false }
  dependsOn: [zone]
}
resource runnerLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = if (createZone) {
  parent: existingZone
  name: 'runner-${kind}-${stem}'
  location: 'global'
  tags: tags
  properties: { virtualNetwork: { id: runnerVnetId }, registrationEnabled: false }
  dependsOn: [zone]
}
