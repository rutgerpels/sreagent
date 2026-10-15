param ownership object
param foundations object
param sreName string
var stem = ownership.stem
resource sre 'Microsoft.App/agents@2025-05-01-preview' existing = { name: sreName }
var definitions = [
  { name: 'app-insights', properties: { dataConnectorType: 'AppInsights', dataSource: foundations.appInsightsId, identity: 'system', extendedProperties: { armResourceId: foundations.appInsightsId, resource: { name: foundations.appInsightsName }, appId: foundations.appInsightsAppId } } }
  { name: 'log-analytics', properties: { dataConnectorType: 'LogAnalytics', dataSource: foundations.workspaceId, identity: 'system', extendedProperties: { armResourceId: foundations.workspaceId, resource: { name: 'law-${stem}' } } } }
  { name: 'azure-monitor', properties: { dataConnectorType: 'AzureMonitor', dataSource: subscription().id, identity: 'system', extendedProperties: { armResourceId: subscription().id, lookbackDays: 7 } } }
]
resource connectors 'Microsoft.App/agents/connectors@2025-05-01-preview' = [for connector in definitions: {
  parent: sre
  name: connector.name
  properties: connector.properties
}]
// Receiver ownership stays exclusively in foundations; redeploying alerts cannot wipe it.
resource actionGroup 'Microsoft.Insights/actionGroups@2023-01-01' existing = { name: 'ag-sre-${stem}' }
var queries = [
  { name: 'payment', role: 'payment-service', path: '/pay' }
  { name: 'checkout', role: 'checkout-api', path: '/checkout' }
]
resource alerts 'Microsoft.Insights/scheduledQueryRules@2023-12-01' = [for query in queries: {
  name: 'alert-${query.name}-failures-${stem}'
  location: ownership.workloadLocation
  tags: ownership.tags
  properties: {
    displayName: '${query.name} failures'
    description: 'Real payment-path failures; probes excluded.'
    enabled: true
    severity: 2
    evaluationFrequency: 'PT5M'
    windowSize: 'PT5M'
    scopes: [foundations.appInsightsId]
    autoMitigate: true
    criteria: { allOf: [{ query: 'requests | where cloud_RoleName == "${query.role}" | where name has "${query.path}" and name !has "health" and name !has "ready" | where success == false', timeAggregation: 'Count', operator: 'GreaterThanOrEqual', threshold: 3, failingPeriods: { numberOfEvaluationPeriods: 1, minFailingPeriodsToAlert: 1 } }] }
    actions: { actionGroups: [actionGroup.id] }
  }
}]

output paymentFailureAlertName string = alerts[0].name
