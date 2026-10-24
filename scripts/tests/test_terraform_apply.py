import contextlib
import importlib.util
import io
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch


SCRIPTS = Path(__file__).resolve().parents[2] / ".github/scripts"
sys.path.insert(0, str(SCRIPTS))
try:
    spec = importlib.util.spec_from_file_location("terraform_apply", SCRIPTS / "terraform_apply.py")
    apply = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(apply)
finally:
    sys.path.pop(0)


class ApplyRootsTest(unittest.TestCase):
    def test_monitoring_plan_uses_the_deployed_configuration(self):
        plan_module = sys.modules["terraform_plan"]
        with patch.object(plan_module, "run") as command:
            command.return_value.stdout = '{}'
            plan_module.create_plan("monitoring", Path("/tmp/test-monitoring-plan"))
        self.assertIn("-var-file=development.tfvars.example", command.call_args_list[0].args)

    def test_selected_roots_are_ordered_and_deduplicated_without_adding_ancestors(self):
        self.assertEqual(
            apply.selected_roots('["ecs", "monitoring", "ai-server/infra", "ecs"]'),
            ["ai-server/infra", "monitoring", "ecs"],
        )
        self.assertEqual(apply.selected_roots('["ecs"]'), ["ecs"])

    def test_invalid_roots_fail_before_any_terraform_command(self):
        for payload in ['["ecs", "unknown"]', '[]', '"ecs"', '{}', '[null]', '[1]', 'invalid json']:
            with self.subTest(payload=payload), patch.object(sys, "argv", ["terraform_apply.py", payload]):
                with patch.object(apply.subprocess, "run") as command, self.assertRaises(SystemExit):
                    apply.main()
                command.assert_not_called()

    def test_apply_streams_progress_and_stops_after_failure(self):
        with tempfile.TemporaryDirectory() as directory, contextlib.chdir(directory):
            with patch.dict(os.environ, {"GITHUB_STEP_SUMMARY": str(Path(directory) / "summary.md")}):
                with patch.object(sys, "argv", ["terraform_apply.py", '["monitoring", "ecs"]']):
                    with patch.object(apply, "prepare"), patch.object(apply, "create_plan", return_value={}):
                        with patch.object(apply, "render_summary", return_value="root summary\n"):
                            failure = subprocess.CalledProcessError(1, ["terraform", "apply"])
                            with patch.object(apply.subprocess, "run", side_effect=failure) as command:
                                output = io.StringIO()
                                with contextlib.redirect_stdout(output), contextlib.redirect_stderr(output):
                                    with self.assertRaises(subprocess.CalledProcessError):
                                        apply.main()
                            command.assert_called_once()
                            self.assertIn("-chdir=monitoring", command.call_args.args[0])
                            self.assertNotIn("capture_output", command.call_args.kwargs)
                            self.assertTrue(command.call_args.kwargs["check"])
                            self.assertIn("::endgroup::", output.getvalue())
                            self.assertIn("Apply failed for `monitoring`", Path("summary.md").read_text())
