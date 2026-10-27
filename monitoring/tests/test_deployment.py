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
        "ai_telemetry": {"value": {
            environment: {
                "instance_id": instance, "environment": environment, "cluster": cluster,
                "loki_push_url": "http://10.0.11.236:3100/loki/api/v1/push",
                "prometheus_write_url": "http://10.0.11.236:9090/api/v1/write",
                "otlp_http_endpoint": "http://10.0.11.236:4318",
            } for environment, instance, cluster in [
                ("dev", "i-01111111111111111", "stockspoon-v2-dev"),
                ("prod", "i-02222222222222222", "stockspoon-v1-ai"),
            ]
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

    def test_ai_agents_use_distinct_targets_and_only_development_collects_market_http(self):
        for environment in ["dev", "prod"]:
            with self.subTest(environment=environment):
                target = environment + "-ai-agent"
                destination = outputs()["ai_telemetry"]["value"][environment]
                files = deploy.deployment_files(target, destination)
                payload = deploy.make_payload(target, outputs())
                self.assertEqual(payload["InstanceIds"], [destination["instance_id"]])
                env = files["agent.env"].decode()
                self.assertIn("DEPLOYMENT_ENVIRONMENT=" + environment, env)
                regex = next(line.split("=", 1)[1] for line in env.splitlines() if line.startswith("AI_SERVICE_REGEX="))
                self.assertEqual("market-http" in regex.split("|"), environment == "dev")
                self.assertFalse({"postgres", "questdb", "postgres-migrate", "questdb-migrate"} & set(regex.split("|")))
                self.assertNotIn("backend.otel.env", files)
                self.assertIn("/opt/stockspoon-ai-telemetry-agent", files["install.sh"].decode())
                self.assertNotIn("/home/ubuntu/ai", files["install.sh"].decode())

    def test_ai_agent_cannot_fall_back_to_another_environment(self):
        state = outputs()
        del state["ai_telemetry"]["value"]["dev"]
        with self.assertRaises(ValueError):
            deploy.make_payload("dev-ai-agent", state)
        with self.assertRaises(ValueError):
            deploy.deployment_files("prod-ai-agent", outputs()["ai_telemetry"]["value"]["dev"])

    def test_ai_tracing_uses_compose_settings_and_keeps_production_http_on_ecs(self):
        for environment in ["dev", "prod"]:
            settings = dict(line.split("=", 1) for line in deploy.ai_tracing_environment(environment + "-ai-tracing", outputs()).splitlines())
            services = ["MARKET_STREAMER", "MARKET_HTTP"] if environment == "dev" else ["MARKET_STREAMER"]
            for service in services:
                self.assertEqual(settings[service + "_OTEL_SDK_DISABLED"], "false")
                self.assertEqual(settings[service + "_OTEL_EXPORTER_OTLP_ENDPOINT"], "http://10.0.11.236:4318")
                self.assertEqual(settings[service + "_OTEL_RESOURCE_ATTRIBUTES"], "deployment.environment.name=" + environment)
                self.assertGreater(float(settings[service + "_OTEL_TRACES_SAMPLER_ARG"]), 0)
                self.assertLess(float(settings[service + "_OTEL_TRACES_SAMPLER_ARG"]), 1)
            if environment == "prod":
                self.assertFalse(any(name.startswith("MARKET_HTTP_") for name in settings))
            else:
                self.assertEqual(settings["MARKET_HTTP_TRACE_SPANS_PER_SECOND"], "100")
            self.assertFalse(any(name.startswith("OTEL_") for name in settings))

    def test_ai_tracing_rejects_cross_environment_and_public_destinations(self):
        state = outputs()
        state['ai_telemetry']['value']['dev'] = state['ai_telemetry']['value']['prod']
        with self.assertRaises(ValueError):
            deploy.ai_tracing_environment('dev-ai-tracing', state)
        state = outputs()
        state['ai_telemetry']['value']['dev']['otlp_http_endpoint'] = 'http://8.8.8.8:4318'
        with self.assertRaises(ValueError):
            deploy.ai_tracing_environment('dev-ai-tracing', state)
        del state['ai_telemetry']['value']['dev']
        with self.assertRaises(ValueError):
            deploy.ai_tracing_environment('dev-ai-tracing', state)

    def test_ai_tracing_cli_prepares_a_fragment_without_deploying(self):
        with tempfile.TemporaryDirectory() as directory:
            source, destination = Path(directory) / 'state.json', Path(directory) / 'ai-tracing.env'
            source.write_text(json.dumps(outputs()))
            for environment in ['dev', 'prod']:
                output = io.StringIO()
                with patch('sys.argv', ['render-deploy.py', environment + '-ai-tracing', '--state-json', str(source), '--output', str(destination)]), patch.object(deploy.subprocess, 'run') as run, redirect_stdout(output):
                    deploy.main()
                run.assert_not_called()
                self.assertEqual(destination.read_text(), deploy.ai_tracing_environment(environment + '-ai-tracing', outputs()))
                self.assertIn(environment.upper() + '_AI_ENV', output.getvalue())
                self.assertEqual(destination.stat().st_mode & 0o777, 0o600)

    def test_production_market_http_patch_uses_ecs_keys_and_parent_sampling(self):
        settings = deploy.market_http_tracing_environment(outputs())
        self.assertEqual(settings['OTEL_SERVICE_NAME'], 'market-http')
        self.assertEqual(settings['OTEL_SDK_DISABLED'], 'false')
        self.assertEqual(settings['OTEL_EXPORTER_OTLP_ENDPOINT'], 'http://10.0.11.236:4318')
        self.assertEqual(settings['OTEL_RESOURCE_ATTRIBUTES'], 'deployment.environment.name=prod')
        self.assertEqual(settings['OTEL_TRACES_SAMPLER'], 'parentbased_traceidratio')
        self.assertEqual(settings['OTEL_METRICS_EXPORTER'], 'none')
        self.assertEqual(settings['OTEL_LOGS_EXPORTER'], 'none')
        self.assertEqual(settings['MARKET_HTTP_TRACE_SPANS_PER_SECOND'], '100')
        self.assertFalse(any(name.startswith('MARKET_STREAMER_') for name in settings))
        with tempfile.TemporaryDirectory() as directory:
            source, destination = Path(directory) / 'state.json', Path(directory) / 'market-http-tracing.patch.json'
            source.write_text(json.dumps(outputs()))
            with patch('sys.argv', ['render-deploy.py', 'prod-market-http-tracing', '--state-json', str(source), '--output', str(destination)]), patch.object(deploy.subprocess, 'run') as run, redirect_stdout(io.StringIO()):
                deploy.main()
            run.assert_not_called()
            self.assertEqual(json.loads(destination.read_text()), settings)

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

    def test_server_bundle_has_no_runtime_secrets_or_data(self):
        files = deploy.deployment_files("server", outputs()["plg_tempo"]["value"])
        self.assertIn("config/grafana/provisioning/dashboards/main.yaml", files)
        self.assertFalse(any(name.startswith("config/grafana/dashboards/") for name in files))
        self.assertEqual([name for name in files if name.endswith(".env")], ["server.env"])
        self.assertIn("GRAFANA_COOKIE_SECURE=true", files["server.env"].decode())
        self.assertNotIn("PASSWORD", files["server.env"].decode())
        self.assertFalse(any("password" in name or "tfstate" in name for name in files))

    def test_dashboard_bundle_carries_every_dashboard_and_nothing_else(self):
        files = deploy.deployment_files("server-dashboards", outputs()["plg_tempo"]["value"])
        dashboards = {"config/" + p.relative_to(ROOT / "config").as_posix()
                      for p in (ROOT / "config/grafana/dashboards").rglob("*.json")}
        self.assertEqual(set(files) - {"install.sh"}, dashboards)
        installer = files["install.sh"].decode()
        self.assertNotIn("docker compose", installer)
        self.assertNotIn("configure-alerting", installer)

    def test_json_transport_compaction_preserves_configuration_values(self):
        destination = outputs()["plg_tempo"]["value"]
        files = {**deploy.deployment_files("server", destination),
                 **deploy.deployment_files("server-dashboards", destination)}
        for source in (ROOT / "config").rglob("*.json"):
            if not source.name.endswith(".local.json"):
                name = "config/" + source.relative_to(ROOT / "config").as_posix()
                self.assertEqual(json.loads(source.read_bytes()), json.loads(files[name]))

    def test_payload_is_bash_syntax_checked_and_under_ssm_limit(self):
        for target in ["server", "server-dashboards", "dev-agent", "dev-ai-agent", "prod-ai-agent"]:
            payload = deploy.make_payload(target, outputs())
            commands = payload["Parameters"]["commands"][0]
            self.assertLess(len(commands.encode()), 24000)
            subprocess.run(["bash", "-n"], input=commands, text=True, check=True)
            # The payload only writes its packaged configs; it contains no Terraform command.
            self.assertNotIn("terraform", commands)

    def test_agents_package_the_system_log_preflight_but_server_does_not(self):
        state = outputs()
        for target, destination in [
            ('dev-agent', state['development_telemetry']['value']),
            ('dev-ai-agent', state['ai_telemetry']['value']['dev']),
            ('prod-ai-agent', state['ai_telemetry']['value']['prod']),
        ]:
            with self.subTest(target=target):
                files = deploy.deployment_files(target, destination)
                self.assertEqual(files['system-logs.sh'], (ROOT / 'scripts/deploy/system-logs.sh').read_bytes())
                installer = files['install.sh'].decode()
                self.assertLess(installer.index('detect_system_journal'), installer.index('install -m'))
        for target in ['server', 'server-dashboards']:
            self.assertNotIn('system-logs.sh', deploy.deployment_files(target, state['plg_tempo']['value']))

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
