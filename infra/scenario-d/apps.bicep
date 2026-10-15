param ownership object
param foundations object
@description('Digests produced by locked, checkout-built ACR manifests. No placeholder/tag deployments.')
param imageDigests object
var stem = ownership.stem
var names = ['frontend', 'checkout-api', 'payment-service']
var shortNames = ['frontend', 'checkout', 'payment']
module apps 'br/public:avm/res/app/container-app:0.9.0' = [for (app, i) in names: {
  name: 'app-${app}'
  params: {
    name: 'ca-${shortNames[i]}-${stem}'
    location: ownership.workloadLocation
    tags: ownership.tags
    enableTelemetry: false
    environmentResourceId: foundations.environmentId
    workloadProfileName: 'Consumption'
    managedIdentities: { userAssignedResourceIds: [foundations.identities[i].id] }
    registries: [{ server: foundations.acrLoginServer, identity: foundations.identities[i].id }]
    secrets: { secureList: [{ name: 'appinsights-connection-string', keyVaultUrl: '${foundations.keyVaultUri}secrets/appinsights-connection-string', identity: foundations.identities[i].id }] }
    ingressExternal: i == 0
    ingressAllowInsecure: false
    ingressTargetPort: 8080
    activeRevisionsMode: 'Single'
    trafficLatestRevision: true
    trafficWeight: 100
    scaleMinReplicas: 1
    scaleMaxReplicas: 3
    containers: [{
      name: app
      image: '${foundations.acrLoginServer}/${app}@${imageDigests[app]}'
      resources: { cpu: json('0.25'), memory: '0.5Gi' }
      env: concat([
        { name: 'SERVICE_NAME', value: app }
        { name: 'PORT', value: '8080' }
        { name: 'APPLICATIONINSIGHTS_CONNECTION_STRING', secretRef: 'appinsights-connection-string' }
        { name: 'TELEMETRY_MANAGED_IDENTITY_CLIENT_ID', value: foundations.identities[i].clientId }
      ], i == 0 ? [{ name: 'CHECKOUT_API_URL', value: 'https://ca-checkout-${stem}.internal.${foundations.environmentDomain}' }] : i == 1 ? [{ name: 'PAYMENT_SERVICE_URL', value: 'https://ca-payment-${stem}.internal.${foundations.environmentDomain}' }] : [
        { name: 'ENABLE_SLOW_LEAK', value: 'false' }
        { name: 'PAYMENT_FAILURE_MODE', value: 'off' }
      ])
      probes: [
        { type: 'Liveness', httpGet: { path: '/health', port: 8080 }, initialDelaySeconds: 10, periodSeconds: 30 }
        { type: 'Readiness', httpGet: { path: '/ready', port: 8080 }, periodSeconds: 15, successThreshold: 1, failureThreshold: 3 }
      ]
    }]
  }
}]
output frontendUrl string = 'https://${apps[0].outputs.fqdn}'
output appIds array = [for (app, i) in names: apps[i].outputs.resourceId]
