###############################################################################
# Optional Azure SRE Agents (Microsoft.App/agents), one per demo scenario.
#
#   * agent-a  (Scenario A — on-the-spot): accessLevel High  + Contributor,
#              so it can mitigate Azure directly after approval.
#   * agent-b  (Scenario B — full GitOps): accessLevel Low   + Reader only,
#              so it must remediate by opening a PR.
#
# Both get Monitoring Contributor so the alert scanner can read fired alerts,
# and both run in Review mode (human approves). Provisioning is gated behind
# var.enable_sre_agents + a sponsor group id, because the resource is preview.
#
# Still manual after apply (no ARM/data-plane parity): GitHub Code Access &
# Connector OAuth, the global Tool Access Policy deny, custom agents/knowledge,
# and the incident response plan. See docs/scenario-*.md.
###############################################################################

locals {
  sre_agents_enabled = var.enable_sre_agents && var.sre_agent_sponsor_group_id != null

  sre_agents = local.sre_agents_enabled ? {
    "a-direct" = { access = "High", role = "Contributor" } # Scenario A — direct mitigation
    "b-gitops" = { access = "Low", role = "Reader" }       # Scenario B — read-only, PR remediation
  } : {}

  # Each agent's RBAC: its scenario role + Monitoring Contributor for the scanner.
  sre_agent_roles = merge([
    for k, v in local.sre_agents : {
      "${k}-scenario"   = { agent = k, role = v.role }
      "${k}-monitoring" = { agent = k, role = "Monitoring Contributor" }
    }
  ]...)
}

resource "azurerm_user_assigned_identity" "agent" {
  for_each            = local.sre_agents
  name                = "id-sre-${each.key}-${local.suffix}"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  tags                = local.tags
}

resource "azurerm_role_assignment" "agent" {
  for_each             = local.sre_agent_roles
  scope                = azurerm_resource_group.this.id
  role_definition_name = each.value.role
  principal_id         = azurerm_user_assigned_identity.agent[each.value.agent].principal_id
}

resource "azapi_resource" "agent" {
  for_each  = local.sre_agents
  type      = "Microsoft.App/agents@2026-01-01"
  name      = "sre-${var.prefix}-${each.key}-${local.suffix}"
  location  = azurerm_resource_group.this.location
  parent_id = azurerm_resource_group.this.id
  tags      = local.tags

  # Microsoft.App/agents is preview; the azapi bundled schema may not know it yet.
  schema_validation_enabled = false

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.agent[each.key].id]
  }

  body = {
    properties = {
      actionConfiguration = {
        accessLevel = each.value.access
        mode        = "Review" # human approves; never Autonomous in this demo
        identity    = azurerm_user_assigned_identity.agent[each.key].id
      }
      agentIdentity = {
        initialSponsorGroupId = var.sre_agent_sponsor_group_id
      }
      defaultModel = {
        name     = var.sre_agent_model_name
        provider = var.sre_agent_model_provider
      }
      incidentManagementConfiguration = {
        type           = "AzureMonitor"
        connectionName = "azure-monitor"
      }
      knowledgeGraphConfiguration = {
        identity         = azurerm_user_assigned_identity.agent[each.key].id
        managedResources = [azurerm_resource_group.this.id]
      }
      logConfiguration = {
        applicationInsightsConfiguration = {
          connectionString = azurerm_application_insights.this.connection_string
        }
      }
      upgradeChannel = "Stable"
    }
  }

  depends_on = [azurerm_role_assignment.agent]
}
