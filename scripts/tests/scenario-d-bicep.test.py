"""Compile D templates locally, inspecting nested AVM templates (never deploys Azure)."""
import argparse
import json
import subprocess
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser()
parser.add_argument("--cli", choices=("bicep", "az"), default="bicep")
arguments, rest = parser.parse_known_args()
CLI = arguments.cli
sys.argv = [sys.argv[0], *rest]


def nested_templates(template):
    yield template
    resources = template.get("resources", [])
    if isinstance(resources, dict):
        resources = resources.values()
    for resource in resources:
        if resource.get("type") == "Microsoft.Resources/deployments":
            child = resource.get("properties", {}).get("template")
            if child:
                yield from nested_templates(child)


class ScenarioDBicepTests(unittest.TestCase):
    def test_compiled_stages_never_output_credentials_or_use_workspace_shared_keys(self):
        paths = sorted((ROOT / "infra" / "scenario-d").glob("*.bicep"))
        self.assertEqual({p.name for p in paths}, {
            "main.bicep", "foundations.bicep", "agents.bicep", "apps.bicep",
            "connectors-alerts.bicep", "external-roles.bicep", "dns.bicep",
            "runner-peering.bicep", "observability-role.bicep", "observability-settings.bicep",
        })
        for path in paths:
            with self.subTest(stage=path.name):
                command = (["az", "bicep", "build", "--file", str(path), "--stdout"]
                           if CLI == "az" else ["bicep", "build", str(path), "--stdout"])
                result = subprocess.run(command, capture_output=True, text=True, timeout=180, cwd=ROOT)
                self.assertEqual(result.returncode, 0, result.stderr)
                template = json.loads(result.stdout)
                if path.name == "agents.bicep":
                    agents = [resource for resource in template["resources"]
                              if resource["type"] == "Microsoft.App/agents"]
                    self.assertEqual(len(agents), 1)
                    self.assertEqual(agents[0]["properties"]["monthlyAgentUnitLimit"], 500)
                    self.assertEqual(agents[0]["properties"]["actionConfiguration"]["mode"], "Review")
                    oba = next(r for r in template["resources"] if r["type"] == "Microsoft.Monitor/observabilityAgents")
                    target = next(r for r in template["resources"] if r["type"].endswith("/monitoredResources"))
                    self.assertEqual(oba["properties"]["enabled"], "[variables('autonomous')]")
                    self.assertEqual(target["properties"]["isAutonomous"], "[variables('autonomous')]")
                    self.assertIn("false", template["variables"]["autonomous"])
                    self.assertEqual([op["mode"] for op in oba["properties"]["operations"]], ["Auto", "Auto"])
                    self.assertIn("alert-payment-failures-", oba["properties"]["operations"][0]["instructions"])
                    self.assertIn("alert-checkout-failures-", oba["properties"]["operations"][0]["instructions"])
                if path.name == "foundations.bicep":
                    self.assertEqual(template["parameters"]["notificationEmail"]["type"].lower(), "securestring")
                    groups = [r for r in template["resources"] if r["type"] == "Microsoft.Insights/actionGroups"]
                    self.assertEqual(len(groups), 1)
                    self.assertIn("parameters('notificationEmail')", groups[0]["properties"]["emailReceivers"])
                    amw = next(r for r in template["resources"] if r["type"] == "Microsoft.Monitor/accounts")
                    self.assertEqual(amw["apiVersion"], "2026-04-03-preview")
                    self.assertIn("defaultActionGroups", amw["properties"])
                    self.assertIn("publicNetworkAccess", amw["properties"])
                if path.name == "connectors-alerts.bicep":
                    self.assertFalse(any(r["type"] == "Microsoft.Insights/actionGroups" for r in template["resources"]))
                    self.assertEqual(len([r for r in template["resources"] if r["type"] == "Microsoft.Insights/scheduledQueryRules"]), 1)
                if path.name == "observability-settings.bicep":
                    settings = template["resources"][0]
                    self.assertEqual(settings["apiVersion"], "2025-06-03-preview")
                    self.assertEqual(settings["name"], "default")
                    self.assertEqual(settings["properties"]["defaultAzureMonitorWorkspace"], "[parameters('amwId')]")
                if path.name == "observability-role.bicep":
                    grant = template["resources"][0]
                    self.assertEqual(grant["properties"]["principalId"], "[parameters('obaPrincipalId')]")
                    self.assertEqual(template["variables"]["monitoringReader"], "43d0d8ad-25c7-4714-9337-8ba259a9fe05")
                if path.name == "main.bicep":
                    self.assertFalse(template["parameters"]["observabilityAutonomous"]["defaultValue"])
                    self.assertNotIn("notificationEmail", template["parameters"])
                    compiled = json.dumps(template)
                    self.assertNotIn("subscriptionResourceId(variables('rgName')", compiled)
                    self.assertNotIn("subscriptionResourceId(parameters('runnerResourceGroup')", compiled)
                    self.assertEqual(
                        (path.read_text().count("resourceId(")),
                        (path.read_text().count("resourceId(subscription().subscriptionId,")),
                        "Subscription-scope ledger paths require explicit subscription and RG arguments.",
                    )
                self.assertNotIn("listkeys(", json.dumps(template).lower())
                for nested in nested_templates(template):
                    for name, output in nested.get("outputs", {}).items():
                        self.assertFalse(any(marker in name.lower() for marker in (
                            "secret", "connectionstring", "instrumentationkey", "sharedkey", "accesstoken", "email", "recipient"
                        )), f"Credential-bearing output: {path.name}:{name}")
                        self.assertNotIn("listkeys(", json.dumps(output).lower())
                lint = (["az", "bicep", "lint", "--file", str(path)]
                        if CLI == "az" else ["bicep", "lint", str(path)])
                result = subprocess.run(lint, capture_output=True, text=True, timeout=180, cwd=ROOT)
                self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == "__main__":
    unittest.main()
