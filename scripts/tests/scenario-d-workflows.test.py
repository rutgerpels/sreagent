import re
import unittest
from pathlib import Path


WORKFLOWS = Path(__file__).resolve().parents[2] / ".github" / "workflows"


def read(name):
    return (WORKFLOWS / name).read_text(encoding="utf-8")


class ScenarioDWorkflowTests(unittest.TestCase):
    def test_manual_workflows_offer_and_accept_d(self):
        for name in ("deploy.yml", "destroy.yml"):
            with self.subTest(workflow=name):
                text = read(name)
                self.assertIn("options: [A, B, C, D]", text)
                self.assertIn("SCENARIO_PATTERN='^(A|B|C|D)$'", text)
                self.assertIn("azure-private-d", text)
                self.assertIn("scenario-d", text)

    def test_repository_active_scenario_never_includes_d(self):
        for name in ("deploy.yml", "destroy.yml"):
            with self.subTest(workflow=name):
                self.assertIn("ACTIVE_SCENARIO_PATTERN='^(A|B|C)$'", read(name))

    def test_push_routed_workflows_reject_d(self):
        for name in ("apply-infra.yml", "deploy-apps.yml"):
            with self.subTest(workflow=name):
                text = read(name)
                self.assertIn("SCENARIO_PATTERN='^(A|B|C)$'", text)
                self.assertNotRegex(text, r"SCENARIO_PATTERN='\^\(A\|B\|C\|D\)\$'")

    def test_deploy_starts_fault_disarmed(self):
        apps = (WORKFLOWS.parents[1] / "infra" / "scenario-d" / "apps.bicep").read_text(encoding="utf-8")
        self.assertIn("PAYMENT_FAILURE_MODE', value: 'off'", apps)
        self.assertIn("ENABLE_SLOW_LEAK', value: 'false'", apps)

    def test_d_routes_to_reusable_bicep_and_terraform_jobs_are_gated_out(self):
        for name, job in (("deploy.yml", "deploy"), ("destroy.yml", "destroy")):
            text = read(name)
            self.assertIn("uses: ./.github/workflows/scenario-d-bicep.yml", text)
            self.assertRegex(text, rf"  {job}:\s+if: \$\{{\{{ inputs.scenario != 'D' \}}\}}")
        lifecycle = (WORKFLOWS.parents[1] / "scripts" / "lib" / "scenario-d-lifecycle.mjs").read_text(encoding="utf-8")
        self.assertIn("'agent/scenario-d'", lifecycle)
        self.assertNotIn("terraform", lifecycle.lower())
        # A/B/C still use the original validated Terraform path and C reconciler.
        self.assertIn("needs: validate-profile", read("deploy.yml"))
        self.assertIn("agent/scenario-c", read("deploy.yml"))

    def test_opt_in_is_explicit_default_false_and_recipient_is_step_scoped(self):
        text = read("scenario-d-bicep.yml")
        self.assertEqual(len(re.findall(r"observability_autonomous:\s+(?:description: [^\n]+\s+)?type: boolean\s+default: false", text)), 2)
        self.assertIn("OBA_NOTIFICATION_EMAIL:", text)
        self.assertEqual(text.count("D_NOTIFICATION_EMAIL:"), 2)
        self.assertEqual(text.count("inputs.action == 'deploy' && inputs.observability_autonomous && secrets.OBA_NOTIFICATION_EMAIL || ''"), 2)
        job_env = text.split("    env:", 1)[1].split("    steps:", 1)[0]
        self.assertNotIn("OBA_NOTIFICATION_EMAIL", job_env)
        self.assertIn("D_OBSERVABILITY_AUTONOMOUS: ${{ inputs.observability_autonomous || false }}", job_env)
        self.assertLess(text.index("optionsFromEnv(process.env)"), text.index("uses: azure/login@"))
        self.assertNotIn("observability_autonomous", read("deploy.yml"))
        self.assertNotIn("observability_autonomous", read("destroy.yml"))
        for reference in re.findall(r"uses: ([^\n]+)", text):
            self.assertRegex(reference, r"@[0-9a-f]{40}(?: |$)")
        self.assertIn("environment: scenario-d", text)
        self.assertIn("id-token: write", text)

    def test_d_destroy_rejects_ephemeral_mode(self):
        self.assertRegex(read("destroy.yml"), r"(?is)D.{0,200}ephemeral|ephemeral.{0,200}D")


if __name__ == "__main__":
    unittest.main()
