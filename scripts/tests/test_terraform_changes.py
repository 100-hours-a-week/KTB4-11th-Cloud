import importlib.util
import subprocess
import tempfile
import unittest
from pathlib import Path


spec = importlib.util.spec_from_file_location(
    "terraform_changes", Path(__file__).resolve().parents[2] / ".github/scripts/terraform_changes.py",
)
changes = importlib.util.module_from_spec(spec)
spec.loader.exec_module(changes)


class DeploymentChangesTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.repository = Path(self.temporary.name)
        self.git("init", "--initial-branch=main")
        self.git("config", "user.name", "Terraform workflow test")
        self.git("config", "user.email", "terraform-test@example.invalid")
        self.base = self.commit("shared-infra/network.tf", "base")

    def git(self, *args):
        return subprocess.check_output(["git", *args], cwd=self.repository, text=True, stderr=subprocess.PIPE).strip()

    def commit(self, path, content):
        destination = self.repository / path
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_text(content)
        self.git("add", path)
        self.git("commit", "-m", content)
        return self.git("rev-parse", "HEAD")

    def test_cancelled_or_failed_intermediate_pushes_are_included(self):
        self.commit("messaging/queues.tf", "pending run replaced by another push")
        head = self.commit("ecs/service.tf", "latest push")
        self.assertEqual(changes.changed_paths(self.base, head, self.repository), ["ecs/service.tf", "messaging/queues.tf"])

    def test_retrying_an_older_or_already_applied_commit_does_not_roll_back(self):
        head = self.commit("ecs/service.tf", "deployed")
        self.assertEqual(changes.changed_paths(head, self.base, self.repository), [])
        self.assertEqual(changes.changed_paths(head, head, self.repository), [])

    def test_first_deployment_and_missing_baseline_scan_all_tracked_files(self):
        head = self.commit("ecs/service.tf", "latest")
        expected = ["ecs/service.tf", "shared-infra/network.tf"]
        self.assertEqual(changes.changed_paths("", head, self.repository), expected)
        self.assertEqual(changes.changed_paths("0" * 40, head, self.repository), expected)

    def test_rewritten_history_scans_all_tracked_files(self):
        old = self.commit("storage/bucket.tf", "old main")
        self.git("checkout", "-b", "rewritten", self.base)
        new = self.commit("ecs/service.tf", "rewritten main")
        self.assertEqual(changes.changed_paths(old, new, self.repository), ["ecs/service.tf", "shared-infra/network.tf"])

    def test_deletions_are_included(self):
        self.git("rm", "shared-infra/network.tf")
        self.git("commit", "-m", "remove network config")
        head = self.git("rev-parse", "HEAD")
        self.assertEqual(changes.changed_paths(self.base, head, self.repository), ["shared-infra/network.tf"])

    def test_non_sha_inputs_are_rejected(self):
        for base, head in [("main", self.base), (self.base, "--help"), (self.base, ""), ("", "a" * 41)]:
            with self.subTest(base=base, head=head), self.assertRaises(ValueError):
                changes.changed_paths(base, head, self.repository)

    def test_missing_current_commit_is_rejected_instead_of_scanning_checkout(self):
        with self.assertRaisesRegex(ValueError, "current commit"):
            changes.changed_paths("", "0" * 40, self.repository)
