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
