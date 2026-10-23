import importlib.util
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location(
    "terraform_roots",
    Path(__file__).resolve().parents[2] / ".github/scripts/terraform_roots.py",
)
roots = importlib.util.module_from_spec(spec)
spec.loader.exec_module(roots)
REPOSITORY = Path(__file__).resolve().parents[2]


class DependencyGraphTest(unittest.TestCase):
    def test_every_dependency_is_applied_before_its_consumer(self):
        positions = {root: index for index, root in enumerate(roots.ROOT_ORDER)}
        for consumer, dependencies in roots.ROOT_DEPENDENCIES.items():
            for dependency in dependencies:
                with self.subTest(consumer=consumer, dependency=dependency):
                    self.assertLess(positions[dependency], positions[consumer])

    def test_cycles_are_rejected_before_selecting_a_subset(self):
        with self.assertRaisesRegex(ValueError, "dependency cycle"):
            roots.dependency_order({"a": {"b"}, "b": {"a"}, "c": set()}, {"c"})

    def test_unknown_dependencies_and_selected_roots_are_rejected(self):
        with self.assertRaisesRegex(ValueError, "unknown.*missing"):
            roots.dependency_order({"a": {"missing"}})
        with self.assertRaisesRegex(ValueError, "unknown.*missing"):
            roots.dependency_order({"a": set()}, {"missing"})

    def test_order_is_deterministic_and_excludes_unchanged_upstream_roots(self):
        graph = {"b": {"a"}, "c": set(), "a": set()}
        self.assertEqual(roots.dependency_order(graph), ["a", "c", "b"])
        self.assertEqual(roots.dependency_order(dict(reversed(list(graph.items())))), ["a", "c", "b"])
        self.assertEqual(roots.dependency_order(graph, {"b"}), ["b"])

    def test_remote_state_reads_are_registered_as_direct_dependencies(self):
        # 저장소가 사용하는 최상위 HCL 블록과 문자열·변수 key만 검사한다.
        # 새 표현식이 추가되면 조용히 무시하지 않고 계약 검사를 보완하도록 실패한다.
        state_keys = {}
        for root in roots.ROOT_ORDER:
            directory = REPOSITORY / roots.root_dir(root)
            if directory.name in {"messaging", "redis"}:
                environment = root.split("@", 1)[1] if "@" in root else "dev"
                source = (directory / "environments" / environment / "backend.hcl").read_text()
            else:
                source = "\n".join(path.read_text() for path in directory.glob("*.tf"))
                backend = re.findall(r'backend "s3" \{(.*?)^\s*\}', source, re.M | re.S)
                self.assertEqual(len(backend), 1, root)
                source = backend[0]
            key = re.search(r'^\s*key\s*=\s*"([^"]+)"', source, re.M)
            self.assertIsNotNone(key, root)
            self.assertNotIn(key[1], state_keys, root)
            state_keys[key[1]] = root

        checked = 0
        for consumer in roots.ROOT_ORDER:
            directory = REPOSITORY / roots.root_dir(consumer)
            source = "\n".join(path.read_text() for path in directory.glob("*.tf"))
            defaults = {
                name: value for name, value in re.findall(
                    r'^variable "([^"]+)" \{.*?^\s*default\s*=\s*"([^"]+)".*?^\}',
                    source, re.M | re.S,
                )
            }
            for name, body in re.findall(
                r'^data "terraform_remote_state" "([^"]+)" \{(.*?)^\}', source, re.M | re.S,
            ):
                if "count" in body and "local.is_dev" in body:
                    self.assertIn(consumer, {"redis", "redis@prod"})
                    active = re.search(r'count\s*=\s*local.is_dev\s*\?\s*([01])\s*:\s*([01])', body)
                    self.assertIsNotNone(active, name)
                    if active[1 if consumer == "redis" else 2] == "0":
                        continue
                key = re.search(r'^\s*key\s*=\s*"([^"]+)"', body, re.M)
                if key:
                    state_key = key[1]
                else:
                    variable = re.search(r'^\s*key\s*=\s*var\.([a-z_]+)', body, re.M)
                    self.assertIsNotNone(variable, f"{consumer}.{name}: unsupported state key")
                    state_key = defaults[variable[1]]
                producer = state_keys[state_key]
                with self.subTest(consumer=consumer, data=name, producer=producer):
                    self.assertIn(producer, roots.ROOT_DEPENDENCIES[consumer])
                checked += 1
        self.assertGreater(checked, 20)


class ChangedRootSelectionTest(unittest.TestCase):
    def test_nested_sse_k6_changes_select_only_its_own_root(self):
        self.assertEqual(
            roots.affected_roots(["test-infra/sse-k6/compute.tf"]),
            ["test-infra/sse-k6"],
        )

    def test_test_infra_changes_include_sse_k6_consumer(self):
        self.assertIn(
            "test-infra/sse-k6", roots.affected_roots(["test-infra/network.tf"]),
        )

    def test_production_ai_changes_select_ai_before_monitoring_and_ecs(self):
        self.assertEqual(
            roots.affected_roots(["ai-server/infra/compute.tf"]),
            ["ai-server/infra", "monitoring", "ecs", "test-infra/sse-k6"],
        )

    def test_shared_network_changes_include_both_messaging_environments(self):
        selected = roots.affected_roots(["shared-infra/private_network.tf"])
        for consumer in ["messaging", "messaging@prod"]:
            self.assertIn(consumer, selected)
            self.assertLess(selected.index("shared-infra"), selected.index(consumer))

    def test_production_messaging_config_does_not_select_development_messaging(self):
        self.assertEqual(
            roots.affected_roots(["messaging/environments/prod/backend.hcl"]),
            ["messaging@prod", "ai-server/infra", "monitoring", "ecs", "test-infra/sse-k6"],
        )

    def test_development_messaging_config_does_not_select_production_messaging(self):
        selected = roots.affected_roots(["messaging/environments/dev/terraform.tfvars.example"])
        self.assertIn("messaging", selected)
        self.assertIn("redis", selected)
        self.assertIn("monitoring", selected)
        self.assertNotIn("messaging@prod", selected)
        self.assertNotIn("ai-server/infra", selected)

    def test_shared_messaging_code_selects_both_environments(self):
        selected = roots.affected_roots(["messaging/db_write_replay_consumer.tf"])
        self.assertIn("messaging", selected)
        self.assertIn("messaging@prod", selected)

    def test_redis_production_config_does_not_select_development_redis(self):
        selected = roots.affected_roots(["redis/environments/prod/backend.hcl"])
        self.assertIn("redis@prod", selected)
        self.assertNotIn("redis", selected)
        self.assertLess(selected.index("redis@prod"), selected.index("ai-server/infra"))

    def test_unregistered_environment_is_rejected_instead_of_skipping_deployment(self):
        with self.assertRaisesRegex(ValueError, "unknown Terraform environment"):
            roots.affected_roots(["messaging/environments/staging/backend.hcl"])

    def test_ecr_changes_order_repository_before_publisher(self):
        selected = roots.affected_roots(["ecr/repositories.tf"])
        self.assertLess(selected.index("ecr"), selected.index("app-server"))
        self.assertLess(selected.index("app-server"), selected.index("ai-server/infra"))
        self.assertLess(selected.index("ai-server/infra"), selected.index("monitoring"))

    def test_workflow_and_helper_changes_validate_all_roots(self):
        for path in [".github/workflows/terraform-apply.yml", ".github/workflows/terraform-plan.yml",
                     ".github/scripts/terraform_roots.py", ".github/scripts/terraform_apply.py"]:
            with self.subTest(path=path):
                self.assertEqual(roots.affected_roots([path]), roots.ROOT_ORDER)

    def test_root_prefixes_and_unrelated_paths_do_not_match(self):
        self.assertEqual(roots.affected_roots(["ecs-other/main.tf", "docs/deploy.md", "nginx/nginx.conf"]), [])

    def test_cli_preserves_dependency_order_and_only_selected_roots(self):
        with tempfile.TemporaryDirectory() as directory:
            changed = Path(directory) / "changed.txt"
            changed.write_text("ecs/svc_backend.tf\n")
            result = subprocess.run([sys.executable, str(REPOSITORY / ".github/scripts/terraform_roots.py"), str(changed)],
                                    text=True, capture_output=True, check=True)
        self.assertIn('roots=["ecs","test-infra/sse-k6"]', result.stdout)
        self.assertIn('matrix={"include":[{"root":"ecs","dir":"ecs"},{"root":"test-infra/sse-k6","dir":"test-infra/sse-k6"}]}', result.stdout)


class ModuleConsumersTest(unittest.TestCase):
    def test_development_network_selects_monitoring_before_ecs(self):
        selected = roots.affected_roots(["test-infra/network.tf"])
        self.assertLess(selected.index("test-infra"), selected.index("monitoring"))
        self.assertLess(selected.index("monitoring"), selected.index("ecs"))

    def test_application_edge_changes_include_monitoring_consumer(self):
        selected = roots.affected_roots(["app-server/alb.tf"])
        self.assertLess(selected.index("app-server"), selected.index("monitoring"))
        self.assertLess(selected.index("monitoring"), selected.index("ecs"))

    def test_monitoring_changes_select_server_before_ecs_consumer(self):
        self.assertEqual(
            roots.affected_roots(["monitoring/config/compose.yaml"]),
            ["monitoring", "ecs", "test-infra/sse-k6"],
        )

    def test_ecs_does_not_trigger_its_monitoring_dependency(self):
        self.assertEqual(roots.affected_roots(["ecs/monitoring.tf"]), ["ecs", "test-infra/sse-k6"])

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
