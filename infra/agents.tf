###############################################################################
# Optional Azure SRE Agent (Microsoft.App/agents): exactly one selected profile.
# A is High/Contributor/Autonomous; B and C are Low/Reader/Review. Scenario B's
# built-in GitHub MCP connector and short-lived fine-grained PAT are configured
# manually. Scenario C automates read-only Code Access when explicitly enabled;
# the constrained remediation broker stays dormant while its required remote MCP
# managed-identity authentication is unsupported.
###############################################################################

locals {
  sre_agents = var.enable_sre_agents ? {
    (local.profile.agent_key) = local.profile.agent
  } : {}

  sre_agent_administrator_role_id = "e79298df-d852-4c6d-84f9-5d13249d1e55"
  sre_code_access_agents          = var.enable_sre_code_access ? local.sre_agents : {}

  # Match the core resource-group roles assigned by the managed onboarding flow.
  # Both identities receive query-only roles in B/C; only Scenario A retains its
  # immutable resource-group Contributor profile.
  sre_agent_resource_group_roles = merge([for key, agent in local.sre_agents : {
    "${key}-access"            = { agent = key, role = agent.role }
    "${key}-logs-reader"       = { agent = key, role = "Log Analytics Reader" }
    "${key}-monitoring-reader" = { agent = key, role = "Monitoring Reader" }
  }]...)

  sre_agent_connectors = merge([for key, _ in local.sre_agents : {
    "${key}-app-insights" = {
      agent = key
      name  = "app-insights"
      properties = {
        dataConnectorType = "AppInsights"
        dataSource        = azurerm_application_insights.this.id
        extendedProperties = {
          armResourceId = azurerm_application_insights.this.id
          resource      = { name = azurerm_application_insights.this.name }
          appId         = azurerm_application_insights.this.app_id
        }
        identity = "system"
      }
    }
    "${key}-log-analytics" = {
      agent = key
      name  = "log-analytics"
      properties = {
        dataConnectorType = "LogAnalytics"
        dataSource        = azurerm_log_analytics_workspace.this.id
        extendedProperties = {
          armResourceId = azurerm_log_analytics_workspace.this.id
          resource      = { name = azurerm_log_analytics_workspace.this.name }
        }
        identity = "system"
      }
    }
    "${key}-azure-monitor" = {
      agent = key
      name  = "azure-monitor"
      properties = {
        dataConnectorType = "AzureMonitor"
        dataSource        = "/subscriptions/${data.azurerm_client_config.current.subscription_id}"
        extendedProperties = {
          armResourceId = "/subscriptions/${data.azurerm_client_config.current.subscription_id}"
          lookbackDays  = 7
        }
        identity = "system"
      }
    }
  }]...)
}

resource "azurerm_user_assigned_identity" "agent" {
  for_each            = local.sre_agents
  name                = "id-sre-${each.key}-${local.suffix}"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  tags                = local.tags
}

resource "azurerm_user_assigned_identity" "agent_code_access" {
  for_each            = local.sre_code_access_agents
  name                = "id-sre-code-${each.key}-${local.suffix}"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  tags                = local.tags
}

resource "azurerm_role_assignment" "agent" {
  for_each                         = local.sre_agent_resource_group_roles
  scope                            = azurerm_resource_group.this.id
  role_definition_name             = each.value.role
  principal_id                     = azurerm_user_assigned_identity.agent[each.value.agent].principal_id
  skip_service_principal_aad_check = true
}

resource "azapi_resource" "agent" {
  for_each = local.sre_agents
  type     = "Microsoft.App/agents@2025-05-01-preview"
  # Microsoft.App/agents names are limited to 32 characters.
  name      = "sre-${substr(var.prefix, 0, 8)}-${lower(var.scenario)}-${random_string.suffix.result}"
  location  = azurerm_resource_group.this.location
  parent_id = azurerm_resource_group.this.id
  tags      = local.tags

  # Microsoft.App/agents is preview; the azapi bundled schema may not know it yet.
  schema_validation_enabled = false
  response_export_values = [
    "identity.principalId",
    "properties.agentEndpoint",
  ]

  identity {
    type = "SystemAssigned, UserAssigned"
    identity_ids = concat(
      [azurerm_user_assigned_identity.agent[each.key].id],
      var.enable_sre_code_access ? [azurerm_user_assigned_identity.agent_code_access[each.key].id] : [],
    )
  }

  body = {
    properties = merge(
      {
        actionConfiguration = {
          accessLevel = each.value.access
          mode        = each.value.mode
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
          type           = "AzMonitor"
          connectionName = "azure-monitor"
        }
        knowledgeGraphConfiguration = {
          identity         = azurerm_user_assigned_identity.agent[each.key].id
          managedResources = [azurerm_resource_group.this.id]
        }
        logConfiguration = {
          applicationInsightsConfiguration = {
            appId            = azurerm_application_insights.this.app_id
            connectionString = azurerm_application_insights.this.connection_string
          }
        }
        monthlyAgentUnitLimit = var.sre_agent_monthly_agent_unit_limit
        upgradeChannel        = "Stable"
        experimentalSettings = {
          EnableHttpTriggers   = true
          EnableV2AgentLoop    = true
          EnableWorkspaceTools = true
        }
      },
      jsondecode(local.profile.private_network_enabled ? jsonencode({
        # Azure VNet mode is egress-only in this preview. Empty bypass lists and a
        # disabled managed MCP path keep Scenario C traffic on the VNet; private DNS
        # enables resolution of private endpoints linked to the application VNet.
        vnetConfiguration = {
          subnetResourceId = azurerm_subnet.sre_agent[0].id
        }
        sandboxConfiguration = {
          egress = {
            mode                    = "AzureVNet"
            allowedHosts            = []
            allowedRegistries       = []
            allowedCodeRepositories = []
            # The dormant broker must not create a network path while its
            # required remote MCP authentication is unsupported.
            allowHttpMcpServerNetworkAccess = local.profile.broker_enabled
            vnetConfiguration = {
              usePrivateDnsResolution = true
            }
          }
        }
      }) : "{}"),
    )
  }

  depends_on = [azurerm_role_assignment.agent]
}

# The system-assigned identity is created with the agent and is used by the
# service for connector queries. Mirror the selected profile at demo-RG scope;
# the only broader role is the documented Monitoring Contributor exception below.
resource "azurerm_role_assignment" "agent_system" {
  for_each                         = local.sre_agent_resource_group_roles
  scope                            = azurerm_resource_group.this.id
  role_definition_name             = each.value.role
  principal_id                     = azapi_resource.agent[each.value.agent].identity[0].principal_id
  skip_service_principal_aad_check = true
}

# The Azure SRE Agent service requires Monitoring Contributor at subscription
# scope for the Azure Monitor incident lifecycle. This is the documented broad
# exception; workload access remains Reader at the demo resource group.
resource "azurerm_role_assignment" "agent_monitoring_contributor" {
  for_each                         = local.sre_agents
  scope                            = "/subscriptions/${data.azurerm_client_config.current.subscription_id}"
  role_definition_name             = "Monitoring Contributor"
  principal_id                     = azurerm_user_assigned_identity.agent[each.key].principal_id
  skip_service_principal_aad_check = true
}

resource "azurerm_role_assignment" "agent_system_monitoring_contributor" {
  for_each                         = local.sre_agents
  scope                            = "/subscriptions/${data.azurerm_client_config.current.subscription_id}"
  role_definition_name             = "Monitoring Contributor"
  principal_id                     = azapi_resource.agent[each.key].identity[0].principal_id
  skip_service_principal_aad_check = true
}

# ARM Contributor/Owner does not imply SRE Agent data-plane administration.
# Grant the deployment principal the product-specific role at the agent only so
# the post-deploy reconciler can configure supported data-plane resources.
resource "azurerm_role_assignment" "agent_deployer_administrator" {
  for_each           = local.sre_agents
  scope              = azapi_resource.agent[each.key].id
  role_definition_id = "/subscriptions/${data.azurerm_client_config.current.subscription_id}/providers/Microsoft.Authorization/roleDefinitions/${local.sre_agent_administrator_role_id}"
  principal_id       = data.azurerm_client_config.current.object_id
}

# First-party observability connectors are supported ARM child resources and
# therefore belong in Terraform rather than the data-plane reconciliation step.
resource "azapi_resource" "agent_connector" {
  for_each = local.sre_agent_connectors

  type                      = "Microsoft.App/agents/connectors@2025-05-01-preview"
  name                      = each.value.name
  parent_id                 = azapi_resource.agent[each.value.agent].id
  schema_validation_enabled = false

  body = {
    properties = each.value.properties
  }

  timeouts {
    create = "10m"
    update = "10m"
    delete = "10m"
  }

  depends_on = [
    azurerm_role_assignment.agent_system,
    azurerm_role_assignment.agent_system_monitoring_contributor,
  ]
}
