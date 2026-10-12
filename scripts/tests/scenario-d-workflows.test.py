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
        self.assertRegex(read("deploy.yml"), r"TF_VAR_payment_failure_mode=off")

    def test_d_destroy_rejects_ephemeral_mode(self):
        self.assertRegex(read("destroy.yml"), r"(?is)D.{0,200}ephemeral|ephemeral.{0,200}D")


if __name__ == "__main__":
    unittest.main()
