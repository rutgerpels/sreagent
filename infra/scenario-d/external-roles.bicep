targetScope = 'subscription'
param ownership object
param actionPrincipalId string
param systemPrincipalId string
// Exactly the two SRE Monitor incident-lifecycle grants in both ledger versions.
// OBA is never mapped through the SRE index shortcut; it has its own role module.
resource grants 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for (role, i) in take(ownership.externalRoles, 2): {
  name: last(split(role.id, '/'))
  properties: { roleDefinitionId: role.roleDefinitionId, principalId: i == 0 ? actionPrincipalId : systemPrincipalId, principalType: 'ServicePrincipal' }
}]
output roleAssignmentIds array = [for (role, i) in take(ownership.externalRoles, 2): grants[i].id]
