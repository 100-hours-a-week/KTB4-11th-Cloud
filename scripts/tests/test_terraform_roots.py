import importlib.util
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location(
    "terraform_roots",
    Path(__file__).resolve().parents[2] / ".github/scripts/terraform_roots.py",
)
roots = importlib.util.module_from_spec(spec)
spec.loader.exec_module(roots)


class ModuleConsumersTest(unittest.TestCase):
    def test_monitoring_changes_select_server_before_ecs_consumer(self):
        self.assertEqual(
            roots.affected_roots(["monitoring/config/compose.yaml"]),
            ["monitoring", "ecs"],
        )

    def test_ecs_does_not_trigger_its_monitoring_dependency(self):
        self.assertEqual(roots.affected_roots(["ecs/monitoring.tf"]), ["ecs"])

    def test_shared_network_changes_include_monitoring_before_ecs(self):
        selected = roots.affected_roots(["shared-infra/network.tf"])
        self.assertLess(selected.index("shared-infra"), selected.index("monitoring"))
        self.assertLess(selected.index("monitoring"), selected.index("ecs"))

    def test_policy_module_triggers_owner_and_remote_state_consumers(self):
        self.assertEqual(
            roots.affected_roots(["modules/terraform-ci-policies/compute.tf"]),
            roots.affected_roots(["app-server/terraform_github_actions_policies.tf"]),
        )
        self.assertIn(
            "app-server", roots.affected_roots(["modules/terraform-ci-policies/compute.tf"])
        )

    def test_documentation_and_unrelated_modules_do_not_trigger_plans(self):
        self.assertEqual(
            roots.affected_roots([
                "modules/terraform-ci-policies/README.md",
                "modules/unrelated/main.tf",
            ]),
            [],
        )


if __name__ == "__main__":
    unittest.main()
