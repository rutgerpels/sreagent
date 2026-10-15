targetScope = 'subscription'
param ownership object
param actionPrincipalId string
param systemPrincipalId string
// Sole subscription-wide exception: SRE Monitor incident lifecycle requirement.
resource grants 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for (role, i) in ownership.externalRoles: {
  name: last(split(role.id, '/'))
  properties: { roleDefinitionId: role.roleDefinitionId, principalId: i == 0 ? actionPrincipalId : systemPrincipalId, principalType: 'ServicePrincipal' }
}]
output roleAssignmentIds array = [for (role, i) in ownership.externalRoles: grants[i].id]
