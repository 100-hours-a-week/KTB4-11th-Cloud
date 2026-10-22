from contextlib import redirect_stdout
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("telemetry_deploy", ROOT / "scripts" / "render-deploy.py")
deploy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(deploy)


def outputs():
    return {
        "plg_tempo": {"value": {
            "instance_id": "i-0123456789abcdef0", "private_ip": "10.0.11.236",
            "aws_region": "ap-northeast-2", "compose_project_name": "stockspoon-v2-prod-telemetry",
            "loki_bucket": "stockspoon-telemetry-loki", "tempo_bucket": "stockspoon-telemetry-tempo",
            "grafana_url": "https://monitoring.stock-spoon.com/",
        }},
        "development_telemetry": {"value": {
            "instance_id": "i-0fedcba9876543210", "environment": "dev",
            "cluster": "stockspoon-v2-dev",
            "loki_push_url": "http://10.0.11.236:3100/loki/api/v1/push",
            "prometheus_write_url": "http://10.0.11.236:9090/api/v1/write",
            "otlp_http_endpoint": "http://10.0.11.236:4318",
        }},
    }


class DeploymentTest(unittest.TestCase):
    def test_development_target_and_environment_are_separate_from_production(self):
        payload = deploy.make_payload("dev-agent", outputs())
        self.assertEqual(payload["InstanceIds"], ["i-0fedcba9876543210"])
        files = deploy.deployment_files("dev-agent", outputs()["development_telemetry"]["value"])
        for service in ["backend", "frontend"]:
            env = files[f"{service}.otel.env"].decode()
            self.assertIn(f"OTEL_SERVICE_NAME={service}\n", env)
            self.assertIn("deployment.environment.name=dev", env)
            self.assertIn("OTEL_METRICS_EXPORTER=none", env)
            self.assertIn("OTEL_LOGS_EXPORTER=none", env)
        self.assertNotIn("dev-agent/docker-compose.yaml", files)

    def test_missing_development_state_cannot_fall_back_to_production(self):
        state = outputs()
        state["development_telemetry"]["value"] = None
        with self.assertRaises(ValueError):
            deploy.make_payload("dev-agent", state)

    def test_public_and_injected_endpoints_are_rejected(self):
        for endpoint in ["http://8.8.8.8:4318", "http://10.0.0.1:3100",
                         "http://user:password@10.0.0.1:4318", "http://10.0.0.1:4318/v1/traces"]:
            with self.subTest(endpoint=endpoint), self.assertRaises(ValueError):
                deploy.checked_endpoint(endpoint, 4318)

    def test_server_bundle_has_dashboards_but_no_runtime_secrets_or_data(self):
        files = deploy.deployment_files("server", outputs()["plg_tempo"]["value"])
        self.assertIn("config/grafana/dashboards/overview.json", files)
        self.assertIn("config/grafana/provisioning/dashboards/main.yaml", files)
        self.assertEqual([name for name in files if name.endswith(".env")], ["server.env"])
        self.assertIn("GRAFANA_COOKIE_SECURE=true", files["server.env"].decode())
        self.assertNotIn("PASSWORD", files["server.env"].decode())
        self.assertFalse(any("password" in name or "tfstate" in name for name in files))

    def test_payload_is_bash_syntax_checked_and_under_ssm_limit(self):
        for target in ["server", "dev-agent"]:
            payload = deploy.make_payload(target, outputs())
            commands = payload["Parameters"]["commands"][0]
            self.assertLess(len(commands.encode()), 24000)
            subprocess.run(["bash", "-n"], input=commands, text=True, check=True)
            # The payload only writes its packaged configs; it contains no Terraform command.
            self.assertNotIn("terraform", commands)

    def test_cli_only_renders_a_payload_without_submitting_commands(self):
        with tempfile.TemporaryDirectory() as directory:
            source, destination = Path(directory) / "state.json", Path(directory) / "payload.json"
            source.write_text(json.dumps(outputs()))
            with patch("sys.argv", [str(ROOT / "scripts" / "render-deploy.py"), "dev-agent", "--state-json", str(source), "--output", str(destination)]), patch.object(deploy.subprocess, "run") as run, redirect_stdout(io.StringIO()):
                deploy.main()
            run.assert_not_called()
            self.assertEqual(json.loads(destination.read_text())["InstanceIds"], ["i-0fedcba9876543210"])


if __name__ == "__main__":
    unittest.main()
