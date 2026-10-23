"""CI plans must preserve production telemetry without ignored local tfvars."""
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / ".github/scripts"))
spec = importlib.util.spec_from_file_location(
    "terraform_plan", ROOT / ".github/scripts/terraform_plan.py"
)
plan = importlib.util.module_from_spec(spec)
spec.loader.exec_module(plan)


class ProductionPlanSettingsTest(unittest.TestCase):
    def test_clean_checkout_plan_passes_committed_production_settings(self):
        for root in ["monitoring", "ecs"]:
            with self.subTest(root=root), tempfile.TemporaryDirectory() as directory:
                calls = []

                def run(root_id, *args, **kwargs):
                    calls.append(args)
                    if args[0] == "plan":
                        # No ignored *.auto.tfvars files are available in this checkout.
                        flags = [arg for arg in args if arg.startswith("-var-file=")]
                        self.assertEqual(len(flags), 1)
                        config = Path(directory) / root_id / flags[0].split("=", 1)[1]
                        self.assertTrue(config.is_file())
                        self.assertRegex(config.read_text(), r"plg_tempo_enabled\s*=\s*true")
                    return SimpleNamespace(stdout=json.dumps({"resource_changes": []}))

                relative = Path(root) / plan.VAR_FILES[root]
                destination = Path(directory) / relative
                destination.parent.mkdir(parents=True)
                destination.write_text((ROOT / relative).read_text())
                with patch.object(plan, "run", side_effect=run):
                    plan.create_plan(root, Path(directory) / "tfplan")
                self.assertEqual([args[0] for args in calls], ["plan", "show"])


if __name__ == "__main__":
    unittest.main()
