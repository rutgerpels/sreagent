###############################################################################
# Optional Azure SRE Agents (Microsoft.App/agents), one per demo scenario.
#
#   * agent-a  (Scenario A — on-the-spot): accessLevel High  + Contributor,
#              so it can mitigate Azure directly after approval.
#   * agent-b  (Scenario B — full GitOps): accessLevel Low   + Reader only,
#              so it must remediate by opening a PR.
#
# Both get Monitoring Contributor at subscription scope because Azure SRE Agent
# requires it to manage the Azure Monitor alert lifecycle. Workload roles remain
# scoped to the demo resource group, and both agents run in Review mode.
#
# Still manual after apply (no ARM/data-plane parity): GitHub Code Access &
# Connector OAuth, the global Tool Access Policy deny, custom agents/knowledge,
# and the incident response plan. See docs/scenario-*.md.
###############################################################################

locals {
  sre_agents_enabled = var.enable_sre_agents && var.sre_agent_sponsor_group_id != null

  sre_agents = local.sre_agents_enabled ? {
    "a-direct" = { access = "High", role = "Contributor" } # Scenario A — direct mitigation
    "b-gitops" = { access = "Low", role = "Reader" }       # Scenario B — Reader workload access, PR remediation
  } : {}

  # Match the core resource-group roles assigned by the managed onboarding flow.
  sre_agent_resource_group_roles = merge([
    for key, agent in local.sre_agents : {
      "${key}-access"            = { agent = key, role = agent.role }
      "${key}-logs-reader"       = { agent = key, role = "Log Analytics Reader" }
      "${key}-monitoring-reader" = { agent = key, role = "Monitoring Reader" }
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
  for_each             = local.sre_agent_resource_group_roles
  scope                = azurerm_resource_group.this.id
  role_definition_name = each.value.role
  principal_id         = azurerm_user_assigned_identity.agent[each.value.agent].principal_id
}

# Subscription scope is required by Azure SRE Agent to acknowledge and close
# Azure Monitor alerts. No workload contributor role is granted at this scope.
resource "azurerm_role_assignment" "agent_monitoring" {
  for_each             = local.sre_agents
  scope                = "/subscriptions/${data.azurerm_client_config.current.subscription_id}"
  role_definition_name = "Monitoring Contributor"
  principal_id         = azurerm_user_assigned_identity.agent[each.key].principal_id
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

  depends_on = [
    azurerm_role_assignment.agent,
    azurerm_role_assignment.agent_monitoring,
  ]
}
