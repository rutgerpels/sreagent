import os
from pathlib import Path
import re
import subprocess
import unittest


ROOT = Path(__file__).resolve().parents[2]
BASH = os.environ.get("BASH", "bash")


class TerraformStateStreamTests(unittest.TestCase):
    def probe(self, predicate, target):
        script = """
set -euo pipefail
produce() {
  printf '%s\\n' "${TARGET}"
  for ((i = 0; i < 20000; i++)); do
    printf 'azurerm_other_resource.item[%s]\\n' "${i}"
  done
}
produce | """ + predicate
        return subprocess.run(
            [BASH, "--noprofile", "--norc", "-s"],
            input=script.encode(),
            env={**os.environ, "TARGET": target},
            capture_output=True,
            timeout=15,
        )

    def test_deployed_state_is_not_mistaken_for_absent(self):
        for workflow, target in (
            ("apply-infra.yml", "azurerm_resource_group.this"),
            ("deploy-apps.yml", 'azurerm_container_app.app["payment-service"]'),
        ):
            with self.subTest(workflow=workflow):
                text = (ROOT / ".github" / "workflows" / workflow).read_text()
                match = re.search(r"terraform state list \| (grep[^\n]+) \\", text)
                self.assertIsNotNone(match, "The state presence probe is missing.")
                result = self.probe(match.group(1), target)
                self.assertEqual(result.returncode, 0, result.stderr)
                missing = self.probe(match.group(1), "unrelated")
                self.assertNotEqual(missing.returncode, 0)

    def test_early_exit_reproduces_pipefail_false_negative(self):
        result = self.probe(
            "grep -Fxq 'azurerm_resource_group.this'",
            "azurerm_resource_group.this",
        )
        self.assertNotEqual(result.returncode, 0)


if __name__ == "__main__":
    unittest.main()
