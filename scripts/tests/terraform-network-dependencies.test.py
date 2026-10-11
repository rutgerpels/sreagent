import re
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
FIXTURE = Path(__file__).resolve().parent / "fixtures" / "network"


class PrivateDnsDependencyTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.directory = tempfile.TemporaryDirectory(prefix="sre-network-test-")
        cls.addClassCleanup(cls.directory.cleanup)
        cls.workdir = Path(cls.directory.name)
        for source in FIXTURE.iterdir():
            shutil.copy2(source, cls.workdir / source.name)
        shutil.copy2(ROOT / "infra" / "network.tf", cls.workdir / "network.tf")
        shutil.copy2(
            ROOT / "infra" / ".terraform.lock.hcl",
            cls.workdir / ".terraform.lock.hcl",
        )
        cls.terraform("init", "-backend=false", "-input=false", "-no-color")

    @classmethod
    def terraform(cls, *arguments):
        result = subprocess.run(
            ["terraform", *arguments],
            cwd=cls.workdir,
            capture_output=True,
            text=True,
            timeout=300,
        )
        if result.returncode:
            raise AssertionError(
                f"terraform {' '.join(arguments)} failed:\n"
                f"{result.stdout}\n{result.stderr}"
            )
        return result.stdout

    @staticmethod
    def edges(graph):
        return set(
            re.findall(r'^\s*"([^"]+)" -> "([^"]+)"\s*$', graph, re.MULTILINE)
        )

    def test_managed_zone_dependency_edges(self):
        edges = self.edges(self.terraform("graph", "-type=plan"))
        for zone in ("key_vault", "acr"):
            with self.subTest(zone=zone):
                self.assertIn(
                    (
                        f"[root] azurerm_private_dns_zone_virtual_network_link.{zone}_app (expand)",
                        f"[root] azurerm_private_dns_zone.{zone} (expand)",
                    ),
                    edges,
                )

    def test_comments_do_not_create_dependencies(self):
        target = self.workdir / "network.tf"
        original = target.read_text(encoding="utf-8")
        try:
            for zone, name in (
                ("key_vault", "privatelink.vaultcore.azure.net"),
                ("acr", "privatelink.azurecr.io"),
            ):
                expression = (
                    f'local.{zone}_zone_shared ? "{name}" : '
                    f"azurerm_private_dns_zone.{zone}[0].name"
                )
                self.assertIn(expression, original)
                target.write_text(
                    original.replace(
                        expression,
                        f'"{name}" # azurerm_private_dns_zone.{zone}[0].name',
                    ),
                    encoding="utf-8",
                )
                edges = self.edges(self.terraform("graph", "-type=plan"))
                with self.subTest(zone=zone):
                    self.assertNotIn(
                        (
                            f"[root] azurerm_private_dns_zone_virtual_network_link.{zone}_app (expand)",
                            f"[root] azurerm_private_dns_zone.{zone} (expand)",
                        ),
                        edges,
                    )
        finally:
            target.write_text(original, encoding="utf-8")

    def test_profile_matrix(self):
        self.terraform("validate", "-no-color")
        result = self.terraform("test", "-no-color", "-test-directory=.")
        self.assertIn("6 passed, 0 failed", result)


if __name__ == "__main__":
    unittest.main()
