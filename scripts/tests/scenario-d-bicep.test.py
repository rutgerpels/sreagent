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
        self.assertEqual(len(paths), 8)
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
                if path.name == "main.bicep":
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
                            "secret", "connectionstring", "instrumentationkey", "sharedkey", "accesstoken"
                        )), f"Credential-bearing output: {path.name}:{name}")
                        self.assertNotIn("listkeys(", json.dumps(output).lower())
                lint = (["az", "bicep", "lint", "--file", str(path)]
                        if CLI == "az" else ["bicep", "lint", str(path)])
                result = subprocess.run(lint, capture_output=True, text=True, timeout=180, cwd=ROOT)
                self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == "__main__":
    unittest.main()
