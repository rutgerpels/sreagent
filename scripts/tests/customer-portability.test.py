"""Offline regressions for customer-owned infrastructure and repository bindings."""
import re
import os
import shutil
import subprocess
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCOPES = ("infra", "scripts", ".github/workflows", ".github/actions",
          "terraform.tfvars.example", "scenario-d.tfvars.example")
BUILT_IN_ROLES = {
    "e79298df-d852-4c6d-84f9-5d13249d1e55",  # SRE Agent Administrator
    "b24988ac-6180-42a0-ab88-20f7382dd24c",  # Contributor
    "43d0d8ad-25c7-4714-9337-8ba259a9fe05",  # Monitoring Reader
    "73c42c96-874c-492b-b04d-ab87d138a893",  # Log Analytics Reader
    "749f88d5-cbae-40b8-bcfc-e573ddc772fa",  # Monitoring Contributor
    "7f951dda-4ed3-4680-a7ca-43fe172d538d",  # AcrPull
    "8311e382-0749-4cb8-b61a-304f252e45ec",  # AcrPush
    "4633458b-17de-408a-b874-0445c86b69e6",  # Key Vault Secrets User
    "b86a8fe4-44ce-4948-aee5-eccb2c155cd7",  # Key Vault Secrets Officer
    "3913510d-42f4-4e42-8a64-420c390055eb",  # Monitoring Metrics Publisher
}


class CustomerPortabilityTests(unittest.TestCase):
    def test_no_personal_repository_or_identity_bindings_in_deployment_sources(self):
        paths = subprocess.check_output(
            ["git", "ls-files", "--", *SCOPES], cwd=ROOT, text=True).splitlines()
        for name in paths:
            if "/tests/" in name:
                continue
            text = (ROOT / name).read_text(encoding="utf-8")
            with self.subTest(path=name):
                self.assertNotRegex(text.lower(), r"rutgerpels[/\\]sreagent")
                for match in re.finditer(
                        r"\b[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\b",
                        text, flags=re.I):
                    self.assertIn(match[0].lower(), BUILT_IN_ROLES,
                                  "Literal identity ID is not a recognized built-in Azure role.")

    def test_private_workflows_require_customer_network_and_support_runner_labels(self):
        for name in ("deploy.yml", "destroy.yml", "apply-infra.yml", "deploy-apps.yml"):
            text = (ROOT / ".github" / "workflows" / name).read_text()
            with self.subTest(workflow=name):
                self.assertIn("vars.PRIVATE_RUNNER_LABELS_JSON", text)
                self.assertIn("RUNNER_NETWORK_RG: ${{ vars.RUNNER_NETWORK_RG }}", text)
                self.assertIn("${RUNNER_NETWORK_RG:?", text)
                self.assertIn("${RUNNER_VNET_NAME:?", text)
        lifecycle = (ROOT / ".github/workflows/scenario-d-bicep.yml").read_text()
        self.assertIn("vars.D_PRIVATE_RUNNER_LABELS_JSON", lifecycle)
        self.assertIn("D_RUNNER_NETWORK_RG: ${{ vars.D_RUNNER_NETWORK_RG }}", lifecycle)
        self.assertIn("D_RUNNER_VNET_NAME: ${{ vars.D_RUNNER_VNET_NAME }}", lifecycle)

    def test_d_bicep_has_no_implicit_existing_runner(self):
        text = (ROOT / "infra/scenario-d/main.bicep").read_text()
        for name in ("runnerResourceGroup", "runnerVnetName"):
            self.assertRegex(text, rf"(?m)^param {name} string$")

    def test_incident_helpers_never_use_gh_fork_default_repository(self):
        for suffix in ("sh", "ps1"):
            text = (ROOT / f"scripts/trigger-incident-gitops.{suffix}").read_text()
            self.assertNotIn("gh repo view", text)
            self.assertIn("remote get-url --push --all origin", text)
            self.assertIn("gh pr create --repo", text)

    def test_bash_incident_helper_rejects_wrong_repo_before_mutation(self):
        bash = shutil.which("bash")
        if os.name == "nt" and shutil.which("git"):
            git_bash = Path(shutil.which("git")).parents[1] / "bin" / "bash.exe"
            if git_bash.exists():
                bash = str(git_bash)
        if not bash:
            self.skipTest("Bash is unavailable")
        result = subprocess.run(
            [bash, "scripts/trigger-incident-gitops.sh", "--no-pr",
             "--repo", "portability-test/never-a-customer-origin"],
            cwd=ROOT, capture_output=True, text=True, timeout=30)
        self.assertNotEqual(result.returncode, 0)
        self.assertRegex(result.stderr, r"must match origin|origin must push")
        self.assertNotIn("Will ", result.stdout)

    def test_powershell_incident_helper_rejects_wrong_repo_before_mutation(self):
        if not shutil.which("pwsh"):
            self.skipTest("PowerShell is unavailable")
        result = subprocess.run(
            ["pwsh", "-NoProfile", "-File", "scripts/trigger-incident-gitops.ps1",
             "-NoPr", "-WhatIf", "-Repository", "portability-test/never-a-customer-origin"],
            cwd=ROOT, capture_output=True, text=True, timeout=30)
        self.assertNotEqual(result.returncode, 0)
        self.assertRegex(result.stderr, r"must match origin|origin must push")
        self.assertNotIn("Will ", result.stdout)


if __name__ == "__main__":
    unittest.main()
