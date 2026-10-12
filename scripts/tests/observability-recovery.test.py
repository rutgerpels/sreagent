import copy
import json
import os
import re
import subprocess
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SUBSCRIPTION = "/subscriptions/00000000-0000-0000-0000-000000000000"
PRINCIPAL = "00000000-0000-0000-0000-000000000001"


class ObservabilityRecoveryTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.workflow = (ROOT / ".github" / "workflows" / "destroy.yml").read_text()
        match = re.search(
            r'OBSERVABILITY_ROLES="\$\(jq -ce --arg scope "[^"]+" \''
            r"\n(.*?)\n\s*' \"\$\{STATE_FILE\}\"\)\"",
            cls.workflow,
            re.DOTALL,
        )
        if match is None:
            raise AssertionError("The verified-state recovery selector is missing.")
        cls.selector = match.group(1)

    def state(self):
        return {
            "resources": [
                {
                    "mode": "managed",
                    "type": "azurerm_user_assigned_identity",
                    "name": "observability_agent",
                    "instances": [{"attributes": {"principal_id": PRINCIPAL}}],
                },
                {
                    "mode": "managed",
                    "type": "azurerm_role_assignment",
                    "name": "observability_agent_monitoring",
                    "instances": [
                        {
                            "attributes": {
                                "id": SUBSCRIPTION
                                + "/providers/Microsoft.Authorization/roleAssignments/"
                                + "00000000-0000-0000-0000-000000000002",
                                "scope": SUBSCRIPTION,
                                "principal_id": PRINCIPAL,
                            }
                        }
                    ],
                },
            ]
        }

    def select(self, state):
        return subprocess.run(
            [os.environ.get("JQ", "jq"), "-ce", "--arg", "scope", SUBSCRIPTION, self.selector],
            input=json.dumps(state),
            capture_output=True,
            text=True,
            timeout=10,
        )

    def test_exact_owned_assignment_only(self):
        state = self.state()
        unrelated = copy.deepcopy(state["resources"][1])
        unrelated["name"] = "unrelated_role"
        unrelated["instances"][0]["attributes"]["principal_id"] = "another-principal"
        state["resources"].append(unrelated)
        result = self.select(state)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            json.loads(result.stdout),
            [state["resources"][1]["instances"][0]["attributes"]],
        )

    def test_absent_observability_is_noop(self):
        result = self.select({"resources": []})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), [])

    def test_foreign_scope_or_principal_fails(self):
        for field, value in (("scope", "/subscriptions/foreign"), ("principal_id", "foreign")):
            with self.subTest(field=field):
                state = self.state()
                state["resources"][1]["instances"][0]["attributes"][field] = value
                self.assertNotEqual(self.select(state).returncode, 0)

    def test_duplicate_assignment_fails(self):
        state = self.state()
        state["resources"][1]["instances"].append(
            copy.deepcopy(state["resources"][1]["instances"][0])
        )
        self.assertNotEqual(self.select(state).returncode, 0)

    def test_cleanup_precedes_identity_and_state_removal(self):
        cleanup = self.workflow.index('az role assignment delete --ids "${assignment_id}"')
        verify = self.workflow.index("Observability monitoring assignment remains")
        agent = self.workflow.index("Deleting Observability Agent before its identity")
        identity = self.workflow.index("Deleting orphaned Scenario C identity")
        state_reset = self.workflow.index("delete_state_blob()")
        self.assertLess(cleanup, verify)
        self.assertLess(verify, agent)
        self.assertLess(agent, identity)
        self.assertLess(identity, state_reset)
        self.assertIn("retaining state", self.workflow[cleanup:identity])


if __name__ == "__main__":
    unittest.main()
