import copy
import importlib.util
from pathlib import Path
import unittest


spec = importlib.util.spec_from_file_location("prepare_tracing", Path(__file__).resolve().parents[1] / "prepare-tracing.py")
prepare = importlib.util.module_from_spec(spec)
spec.loader.exec_module(prepare)


def environment(service):
    return {
        "OTEL_SERVICE_NAME": service,
        "OTEL_EXPORTER_OTLP_ENDPOINT": "http://10.0.11.236:4318",
        "OTEL_EXPORTER_OTLP_PROTOCOL": "http/protobuf",
        "OTEL_RESOURCE_ATTRIBUTES": "deployment.environment.name=prod",
        "OTEL_TRACES_EXPORTER": "otlp",
        "OTEL_METRICS_EXPORTER": "none",
        "OTEL_LOGS_EXPORTER": "none",
    }


def snapshot(service="backend"):
    return {
        "tags": [{"key": "owner", "value": "application"}],
        "taskDefinition": {
            "family": "stockspoon-v2-prod-" + service, "cpu": "1024", "memory": "2048",
            "taskDefinitionArn": "arn:task:34", "revision": 34, "status": "ACTIVE",
            "networkMode": "awsvpc", "taskRoleArn": "arn:original-role",
            "containerDefinitions": [{
                "name": "market-http" if service == "market-http" else "backend",
                "image": "public.ecr.aws/example/app:application-commit",
                "command": ["market-http"] if service == "market-http" else ["java", "-jar", "/app/application.jar"],
                "environment": [
                    {"name": "JAVA_TOOL_OPTIONS", "value": "-XX:MaxRAMPercentage=75 -Dexisting=true"},
                    {"name": "REDIS_HOST", "value": "existing.valkey.internal"},
                ],
                "secrets": [{"name": "MYSQL_PASSWORD", "valueFrom": "arn:existing-parameter"}],
                "healthCheck": {"command": ["CMD-SHELL", "existing-healthcheck"]},
            }, {"name": "existing-sidecar", "image": "example:1", "essential": False}],
        },
    }


class TracingPreparationTest(unittest.TestCase):
    def test_keep_running_resources_roles_secrets_healthcheck_and_sidecars(self):
        source = snapshot()
        original = copy.deepcopy(source)
        task = prepare.instrumented_task(source, "backend", environment("backend"), "public.ecr.aws/example/app:tempo-test")
        expected = source["taskDefinition"]
        for key in ["cpu", "memory", "networkMode", "taskRoleArn"]:
            self.assertEqual(task[key], expected[key])
        for key in ["secrets", "healthCheck", "command"]:
            self.assertEqual(task["containerDefinitions"][0][key], expected["containerDefinitions"][0][key])
        self.assertEqual(task["containerDefinitions"][1], expected["containerDefinitions"][1])
        self.assertEqual(task["tags"], source["tags"])
        self.assertNotIn("revision", task)
        self.assertNotIn("taskDefinitionArn", task)
        self.assertEqual(source, original)

    def test_image_bound_agent_leaves_existing_jvm_flags_unchanged(self):
        source = snapshot()
        for _ in range(2):
            task = prepare.instrumented_task(source, "backend", environment("backend"), "public.ecr.aws/example/app:tempo-test")
            source = {"taskDefinition": task}
        env = {item["name"]: item["value"] for item in task["containerDefinitions"][0]["environment"]}
        self.assertEqual(env["JAVA_TOOL_OPTIONS"], "-XX:MaxRAMPercentage=75 -Dexisting=true")
        self.assertNotIn("-javaagent", env["JAVA_TOOL_OPTIONS"])

    def test_collector_has_a_distinct_service_name(self):
        task = prepare.instrumented_task(snapshot("backend-collector"), "backend-collector", environment("backend-collector"), "public.ecr.aws/example/app:tempo-collector")
        env = {item["name"]: item["value"] for item in task["containerDefinitions"][0]["environment"]}
        self.assertEqual(env["OTEL_SERVICE_NAME"], "backend-collector")

    def test_reject_conflicting_java_agent_and_python_entrypoint(self):
        java = snapshot()
        java["taskDefinition"]["containerDefinitions"][0]["environment"][0]["value"] = "-javaagent:/existing.jar"
        with self.assertRaises(ValueError):
            prepare.instrumented_task(java, "backend", environment("backend"), "public.ecr.aws/example/app:tempo")
        python = snapshot("market-http")
        python["taskDefinition"]["containerDefinitions"][0]["entryPoint"] = ["custom-launcher"]
        with self.assertRaises(ValueError):
            prepare.instrumented_task(python, "market-http", environment("market-http"), "public.ecr.aws/example/app:tempo")

    def test_pin_the_running_digest_and_reject_mixed_rollouts(self):
        digest = "sha256:" + "a" * 64
        self.assertEqual(prepare.running_image("public.ecr.aws/example/app:old-tag", [digest, digest]), "public.ecr.aws/example/app@" + digest)
        for digests in [[], [""], [digest, "sha256:" + "b" * 64]]:
            with self.subTest(digests=digests), self.assertRaises(ValueError):
                prepare.running_image("public.ecr.aws/example/app:old-tag", digests)

    def test_reject_mismatched_service_and_non_trace_exporters(self):
        for key, value in [("OTEL_SERVICE_NAME", "backend-collector"), ("OTEL_METRICS_EXPORTER", "otlp"), ("OTEL_LOGS_EXPORTER", "otlp")]:
            env = environment("backend")
            env[key] = value
            with self.subTest(key=key), self.assertRaises(ValueError):
                prepare.instrumented_task(snapshot(), "backend", env, "public.ecr.aws/example/app:tempo")


if __name__ == "__main__":
    unittest.main()
