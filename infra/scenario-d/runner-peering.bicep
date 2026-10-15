param runnerVnetName string
param appVnetId string
param stem string
resource runner 'Microsoft.Network/virtualNetworks@2024-05-01' existing = { name: runnerVnetName }
resource peering 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2024-05-01' = {
  parent: runner
  name: 'peer-runner-to-app-${stem}'
  properties: { remoteVirtualNetwork: { id: appVnetId }, allowVirtualNetworkAccess: true, allowForwardedTraffic: false, allowGatewayTransit: false, useRemoteGateways: false }
}
