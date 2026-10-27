"""Shared CI must resolve a live, scoped Task without running FIS."""
import copy
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / ".github/scripts"))
import terraform_fis as fis
import terraform_plan as plan


class FisInputsTest(unittest.TestCase):
    def setUp(self):
        self.task = f"arn:aws:ecs:{fis.REGION}:{fis.ACCOUNT}:task/{fis.CLUSTER}/" + "a" * 32
        self.responses = [
            {"Account": fis.ACCOUNT},
            {"taskArns": [self.task]},
            {"tasks": [{"taskArn": self.task, "clusterArn": fis.CLUSTER_ARN,
                        "group": f"service:{fis.SERVICE}", "lastStatus": "RUNNING",
                        "desiredStatus": "RUNNING"}]},
            {"MetricAlarms": [{"AlarmArn": f"arn:aws:cloudwatch:{fis.REGION}:{fis.ACCOUNT}:alarm:{name}"}
                              for name in fis.ALARM_NAMES]},
        ]

    def test_verified_inputs_are_private_and_use_only_read_calls(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(fis, "aws", side_effect=self.responses) as aws:
            path = fis.write_ci_variables(Path(directory))
            variables = json.loads(path.read_text())
            self.assertEqual(variables["target_task_arn"], self.task)
            self.assertTrue(variables["use_ci_credentials"])
            self.assertIsNone(variables["deployment_profile"])
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            self.assertEqual([call.args[:2] for call in aws.call_args_list], [
                ("sts", "get-caller-identity"), ("ecs", "list-tasks"),
                ("ecs", "describe-tasks"), ("cloudwatch", "describe-alarms"),
            ])

    def test_wrong_account_empty_candidates_and_foreign_arn_fail_closed(self):
        for index, response in [(0, {"Account": "000000000000"}),
                                (1, {"taskArns": []}),
                                (1, {"taskArns": [self.task.replace(fis.CLUSTER, "backend")]})]:
            responses = copy.deepcopy(self.responses)
            responses[index] = response
            with self.subTest(response=response), patch.object(fis, "aws", side_effect=responses):
                with self.assertRaises(ValueError):
                    fis.resolve_ci_variables()

    def test_stopped_foreign_or_unresolved_tasks_are_rejected(self):
        for field, value in [("group", "service:backend"), ("lastStatus", "STOPPED"),
                             ("desiredStatus", "STOPPED"), ("clusterArn", "foreign"),
                             ("taskArn", "foreign")]:
            responses = copy.deepcopy(self.responses)
            responses[2]["tasks"][0][field] = value
            with self.subTest(field=field), patch.object(fis, "aws", side_effect=responses):
                with self.assertRaises(ValueError):
                    fis.resolve_ci_variables()
        for response in [{"tasks": [], "failures": [{"reason": "MISSING"}]}, {"tasks": []}]:
            with patch.object(fis, "aws", side_effect=self.responses[:2] + [response]):
                with self.assertRaises(ValueError):
                    fis.resolve_ci_variables()

    def test_missing_stop_alarm_or_aws_failure_produces_no_var_file(self):
        for failure in [{"MetricAlarms": []}, subprocess.CalledProcessError(1, ["aws"])]:
            with tempfile.TemporaryDirectory() as directory:
                with patch.object(fis, "aws", side_effect=self.responses[:3] + [failure]):
                    with self.assertRaises((ValueError, subprocess.CalledProcessError)):
                        fis.write_ci_variables(Path(directory))
                self.assertFalse((Path(directory) / "fis-ci.tfvars.json").exists())

    def test_each_fresh_plan_resolves_variables_and_passes_absolute_var_file(self):
        with tempfile.TemporaryDirectory() as directory:
            for index in range(2):
                destination = Path(directory) / str(index)
                destination.mkdir()
                with patch.object(fis, "aws", side_effect=self.responses) as aws:
                    with patch.object(plan, "run", return_value=type("Result", (), {"stdout": "{}"})()) as run:
                        plan.create_plan(fis.FIS_ROOT, destination / "tfplan")
                        args = run.call_args_list[0].args
                        self.assertIn(f"-var-file={(destination / 'fis-ci.tfvars.json').resolve()}", args)
                    self.assertEqual(aws.call_count, 4)

    def test_aws_uses_oidc_environment_without_named_profile(self):
        with patch.object(fis.subprocess, "run", return_value=type("Result", (), {"stdout": "{}"})()) as run:
            fis.aws("sts", "get-caller-identity")
        self.assertNotIn("--profile", run.call_args.args[0])
        self.assertTrue(run.call_args.kwargs["check"])


if __name__ == "__main__":
    unittest.main()
