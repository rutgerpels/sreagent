mock_provider "azurerm" {
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

  mock_resource "azurerm_user_assigned_identity" {
    defaults = {
      principal_id = "00000000-0000-0000-0000-000000000000"
    }
  }
}

mock_provider "azapi" {}
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
    ]
  }

  assert {
    condition = (
      length(azurerm_monitor_workspace.observability_agent) == 0 &&
      length(azurerm_user_assigned_identity.observability_agent) == 0 &&
      length(azurerm_role_assignment.observability_agent_issues) == 0 &&
      length(azurerm_role_assignment.observability_agent_monitoring) == 0
    )
    error_message = "Scenario B must not provision Scenario A Observability prerequisites."
  }
}

run "scenario_c_excludes_prerequisites" {
  command = plan

  variables {
    scenario = "C"
  }

  plan_options {
    target = [
      azurerm_monitor_workspace.observability_agent,
      azurerm_user_assigned_identity.observability_agent,
      azurerm_role_assignment.observability_agent_issues,
      azurerm_role_assignment.observability_agent_monitoring,
    ]
  }

  assert {
    condition = (
      length(azurerm_monitor_workspace.observability_agent) == 0 &&
      length(azurerm_user_assigned_identity.observability_agent) == 0 &&
      length(azurerm_role_assignment.observability_agent_issues) == 0 &&
      length(azurerm_role_assignment.observability_agent_monitoring) == 0
    )
    error_message = "Scenario C must not provision Scenario A Observability prerequisites."
  }
}
