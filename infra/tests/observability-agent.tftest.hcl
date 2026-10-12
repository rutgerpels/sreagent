mock_provider "azurerm" {
  mock_data "azurerm_virtual_network" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-runner-test/providers/Microsoft.Network/virtualNetworks/runner-test"
    }
  }

  mock_resource "azurerm_resource_group" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test"
    }
  }

  mock_data "azurerm_client_config" {
    defaults = {
      subscription_id = "00000000-0000-0000-0000-000000000000"
      tenant_id       = "00000000-0000-0000-0000-000000000000"
      client_id       = "00000000-0000-0000-0000-000000000000"
      object_id       = "00000000-0000-0000-0000-000000000000"
    }
  }

  mock_resource "azurerm_monitor_workspace" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.Monitor/accounts/amw-test"
    }
  }

  mock_resource "azurerm_log_analytics_workspace" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.OperationalInsights/workspaces/law-test"
    }
  }

  mock_resource "azurerm_application_insights" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.Insights/components/appi-test"
    }
  }

  mock_resource "azurerm_user_assigned_identity" {
    defaults = {
      id           = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-test"
      principal_id = "00000000-0000-0000-0000-000000000000"
    }
  }
}

mock_provider "azapi" {
  mock_resource "azapi_resource" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.Monitor/observabilityAgents/obs-test"
    }
  }
}
mock_provider "random" {}
mock_provider "time" {}

variables {
  deploy_apps            = false
  enable_grafana         = false
  enable_sre_agents      = false
  enable_sre_code_access = false
}

run "scenario_a_prerequisites" {
  command = apply

  variables {
    scenario = "A"
    location = "swedencentral"
  }

  plan_options {
    target = [
      azurerm_monitor_workspace.observability_agent,
      azurerm_user_assigned_identity.observability_agent,
      azurerm_role_assignment.observability_agent_issues,
      azurerm_role_assignment.observability_agent_monitoring,
      azapi_resource.observability_agent,
      azapi_resource.observability_application,
    ]
  }

  assert {
    condition = (
      length(azurerm_monitor_workspace.observability_agent) == 1 &&
      length(azurerm_user_assigned_identity.observability_agent) == 1 &&
      length(azurerm_role_assignment.observability_agent_issues) == 1 &&
      length(azurerm_role_assignment.observability_agent_monitoring) == 1
    )
    error_message = "Scenario A must provision the issue workspace, dedicated identity and both required roles."
  }

  assert {
    condition = (
      length(azapi_resource.observability_agent) == 0 &&
      length(azapi_resource.observability_application) == 0 &&
      azurerm_monitor_workspace.observability_agent[0].public_network_access_enabled
    )
    error_message = "Scenario A must preserve its existing operator-owned agent and networking."
  }

  assert {
    condition = (
      azurerm_monitor_workspace.observability_agent[0].location == "westeurope" &&
      azurerm_user_assigned_identity.observability_agent[0].location == "westeurope" &&
      azurerm_resource_group.this.location == "swedencentral"
    )
    error_message = "Preview prerequisites must share West Europe without moving the application resource group."
  }

  assert {
    condition = (
      azurerm_monitor_workspace.observability_agent[0].tags.scenario == "A" &&
      azurerm_user_assigned_identity.observability_agent[0].tags.managed_by == "terraform"
    )
    error_message = "Observability prerequisites must preserve the repository's scenario and ownership tags."
  }

  assert {
    condition = (
      azurerm_role_assignment.observability_agent_issues[0].role_definition_name == "Issue Contributor" &&
      azurerm_role_assignment.observability_agent_issues[0].scope == azurerm_monitor_workspace.observability_agent[0].id &&
      azurerm_role_assignment.observability_agent_monitoring[0].role_definition_name == "Monitoring Reader" &&
      azurerm_role_assignment.observability_agent_monitoring[0].scope == "/subscriptions/00000000-0000-0000-0000-000000000000" &&
      azurerm_role_assignment.observability_agent_issues[0].principal_id == azurerm_user_assigned_identity.observability_agent[0].principal_id &&
      azurerm_role_assignment.observability_agent_monitoring[0].principal_id == azurerm_user_assigned_identity.observability_agent[0].principal_id
    )
    error_message = "The Observability identity may write issues only at workspace scope and must have monitoring-only subscription access."
  }
}

run "scenario_b_excludes_prerequisites" {
  command = plan

  variables {
    scenario = "B"
  }

  plan_options {
    target = [
      azurerm_monitor_workspace.observability_agent,
      azurerm_user_assigned_identity.observability_agent,
      azurerm_role_assignment.observability_agent_issues,
      azurerm_role_assignment.observability_agent_monitoring,
      azapi_resource.observability_agent,
      azapi_resource.observability_application,
    ]
  }

  assert {
    condition = (
      length(azurerm_monitor_workspace.observability_agent) == 0 &&
      length(azurerm_user_assigned_identity.observability_agent) == 0 &&
      length(azurerm_role_assignment.observability_agent_issues) == 0 &&
      length(azurerm_role_assignment.observability_agent_monitoring) == 0 &&
      length(azapi_resource.observability_agent) == 0 &&
      length(azapi_resource.observability_application) == 0
    )
    error_message = "Scenario B must not provision paired Observability resources."
  }
}

run "scenario_c_managed_autonomy" {
  command = apply

  variables {
    scenario = "C"
  }

  plan_options {
    target = [
      azurerm_monitor_workspace.observability_agent,
      azurerm_user_assigned_identity.observability_agent,
      azurerm_role_assignment.observability_agent_issues,
      azurerm_role_assignment.observability_agent_monitoring,
      azapi_resource.observability_agent,
      azapi_resource.observability_application,
    ]
  }

  assert {
    condition = (
      length(azurerm_monitor_workspace.observability_agent) == 1 &&
      length(azurerm_user_assigned_identity.observability_agent) == 1 &&
      length(azurerm_role_assignment.observability_agent_issues) == 1 &&
      length(azurerm_role_assignment.observability_agent_monitoring) == 1 &&
      length(azapi_resource.observability_agent) == 1 &&
      length(azapi_resource.observability_application) == 1
    )
    error_message = "Scenario C must own both the Observability Agent and its dedicated prerequisites."
  }

  assert {
    condition = (
      !azurerm_monitor_workspace.observability_agent[0].public_network_access_enabled &&
      azurerm_monitor_workspace.observability_agent[0].location == "westeurope" &&
      azurerm_monitor_workspace.observability_agent[0].tags.scenario == "C" &&
      azapi_resource.observability_agent[0].identity[0].type == "UserAssigned" &&
      azapi_resource.observability_agent[0].identity[0].identity_ids == tolist([azurerm_user_assigned_identity.observability_agent[0].id])
    )
    error_message = "C must retain restricted workspace networking and use its dedicated monitoring identity."
  }

  assert {
    condition = (
      azapi_resource.observability_agent[0].body.properties.enabled &&
      azapi_resource.observability_agent[0].body.properties.monitoringAccountId == azurerm_monitor_workspace.observability_agent[0].id &&
      azapi_resource.observability_agent[0].body.properties.operations[0].type == "IssueCreation" &&
      azapi_resource.observability_agent[0].body.properties.operations[0].mode == "Auto" &&
      azapi_resource.observability_agent[0].body.properties.operations[0].instructions == local.observability_instructions &&
      azapi_resource.observability_agent[0].body.properties.operations[1].type == "Investigation" &&
      azapi_resource.observability_agent[0].body.properties.operations[1].mode == "Auto" &&
      azapi_resource.observability_application[0].body.properties.resourceId == azurerm_application_insights.this.id &&
      azapi_resource.observability_application[0].body.properties.enabled &&
      azapi_resource.observability_application[0].body.properties.isAutonomous
    )
    error_message = "Issue creation and Investigation must both run autonomously for only this Application Insights target."
  }

  assert {
    condition = (
      azurerm_role_assignment.observability_agent_issues[0].role_definition_name == "Issue Contributor" &&
      azurerm_role_assignment.observability_agent_issues[0].scope == azurerm_monitor_workspace.observability_agent[0].id &&
      azurerm_role_assignment.observability_agent_monitoring[0].role_definition_name == "Monitoring Reader" &&
      azurerm_role_assignment.observability_agent_monitoring[0].scope == "/subscriptions/00000000-0000-0000-0000-000000000000" &&
      local.profile.agent.role == "Reader" &&
      local.profile.agent.mode == "Review" &&
      local.profile.agent.access == "Low"
    )
    error_message = "Observability may write issues, not workloads; SRE must keep C's Low/Reader/Review boundary."
  }
}
