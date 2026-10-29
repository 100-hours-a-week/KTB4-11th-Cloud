import importlib.util
import json
import tarfile
import tempfile
import time
import unittest
from pathlib import Path
from unittest.mock import patch

spec = importlib.util.spec_from_file_location(
    "fis_capture", Path(__file__).with_name("capture.py")
)
capture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(capture)
TASK_ID = "a" * 32
ARN = (
    f"arn:aws:ecs:ap-northeast-2:250832562715:task/stockspoon-v2-prod-cluster/{TASK_ID}"
)


class CaptureTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()

    def test_resolves_task_limit_not_unlimited_container_or_host(self):
        proc = self.root / "proc/123"
        proc.mkdir(parents=True)
        proc.joinpath("cgroup").write_text(f"0::/ecs/{TASK_ID}/docker-child\n")
        task = self.root / "cgroup/ecs" / TASK_ID
        child = task / "docker-child"
        child.mkdir(parents=True)
        task.joinpath("memory.max").write_text(str(2 * 1024**3))
        child.joinpath("memory.max").write_text("max")
        self.assertEqual(
            capture.task_cgroup(
                123, TASK_ID, 2 * 1024**3, self.root / "proc", self.root / "cgroup"
            ),
            task,
        )
        with self.assertRaises(ValueError):
            capture.task_cgroup(
                123, "b" * 32, 2 * 1024**3, self.root / "proc", self.root / "cgroup"
            )

    def test_runtime_hostname_selects_actual_namespace_not_config_guess(self):
        container = {
            "Config": {
                "Hostname": "config-guess",
                "Labels": {
                    "com.amazonaws.ecs.task-definition-family": capture.FAMILY,
                    "com.amazonaws.ecs.container-name": "market-http",
                    "com.amazonaws.ecs.task-arn": ARN,
                },
            },
            "State": {"Running": True, "Pid": 123},
        }
        with patch.object(
            capture.subprocess,
            "check_output",
            side_effect=[json.dumps([container]), "runtime-host\n"],
        ):
            result = capture.inspect_task("target")
        self.assertEqual(result["Config"]["Hostname"], "runtime-host")

    def test_rejects_backend_container_before_any_capture(self):
        container = {
            "Config": {
                "Labels": {
                    "com.amazonaws.ecs.task-definition-family": "stockspoon-v2-prod-backend"
                }
            },
            "State": {"Running": True, "Pid": 123},
        }
        with patch.object(
            capture.subprocess, "check_output", return_value=json.dumps([container])
        ):
            with self.assertRaises(ValueError):
                capture.inspect_task("backend")

    def test_rejects_cgroup_path_escape(self):
        proc = self.root / "proc/123"
        proc.mkdir(parents=True)
        proc.joinpath("cgroup").write_text("0::/../../outside\n")
        group = self.root / "cgroup"
        group.mkdir()
        with self.assertRaises(ValueError):
            capture.task_cgroup(123, TASK_ID, 2**31, self.root / "proc", group)

    def test_oom_removed_process_and_cgroup_are_recorded_as_missing(self):
        result = capture.memory_sample(
            self.root / "gone-group", 987, self.root / "proc"
        )
        self.assertIsNone(result["memory.current"])
        self.assertIsNone(result["memory.events"])
        self.assertIsNone(result["process_rss_bytes"])

    def test_reused_pid_is_not_reported_as_original_process(self):
        proc = self.root / "proc/123"
        proc.mkdir(parents=True)
        proc.joinpath("stat").write_text(
            "123 (python worker) " + " ".join(["S"] + ["0"] * 18 + ["999"])
        )
        proc.joinpath("statm").write_text("100 50")
        result = capture.memory_sample(
            self.root / "gone-group", 123, self.root / "proc", expected_start="100"
        )
        self.assertIsNone(result["process_rss_bytes"])

    def make_profiles(self):
        source = self.root / "source"
        run = source / "run"
        run.mkdir(parents=True)
        state = {
            "hostname": "target",
            "pid": 1,
            "status": "armed",
            "utc": "2026-10-29T00:00:01+00:00",
        }
        run.joinpath("profile-state.json").write_text(json.dumps(state))
        run.joinpath("1.snapshot").write_bytes(b"complete")
        run.joinpath("1.json").write_text("{}")
        run.joinpath("2.snapshot.partial").write_bytes(b"incomplete")
        run.joinpath("3.snapshot").write_bytes(b"manifest-not-written")
        return source, run

    def test_complete_snapshot_mirror_survives_source_loss_and_archives(self):
        source, run = self.make_profiles()
        destination = self.root / "evidence/profiles"
        result = capture.mirror_profiles(source, destination, "target")
        self.assertEqual(result["copied_files"], 3)
        self.assertEqual((destination / "run/1.snapshot").read_bytes(), b"complete")
        self.assertFalse((destination / "run/2.snapshot.partial").exists())
        self.assertFalse((destination / "run/3.snapshot").exists())
        run.joinpath("1.snapshot").unlink()
        evidence = destination.parent
        evidence.joinpath("manifest.json").write_text(
            json.dumps({"tool": "market-http-fis-capture-v1"})
        )
        archive = self.root / "evidence.tar.gz"
        capture.archive(evidence, archive)
        with tarfile.open(archive) as tar:
            self.assertEqual(
                tar.extractfile("profiles/run/1.snapshot").read(), b"complete"
            )
            self.assertIn("sha256.json", tar.getnames())
        capture.archive(evidence, self.root / "second.tar.gz")
        with tarfile.open(self.root / "second.tar.gz") as tar:
            self.assertEqual(tar.getnames().count("sha256.json"), 1)

    def test_trigger_selects_only_current_container_and_is_exclusive(self):
        source, run = self.make_profiles()
        container = {
            "Config": {"Hostname": "target"},
            "State": {"StartedAt": "2026-10-29T00:00:00Z"},
        }
        with patch.object(capture, "profile_source", return_value=source):
            self.assertEqual(Path(capture.trigger(container)), run / "capture.trigger")
            with self.assertRaises(FileExistsError):
                capture.trigger(container)
        container["State"]["StartedAt"] = "2026-10-29T00:00:02Z"
        with self.assertRaises(ValueError):
            capture.armed_profile(container, source)

    def test_wrong_hostname_and_symlinks_are_not_mirrored(self):
        source, run = self.make_profiles()
        outside = self.root / "private"
        outside.write_text("private")
        run.joinpath("secret.json").symlink_to(outside)
        dest = self.root / "copy"
        self.assertEqual(
            capture.mirror_profiles(source, dest, "other")["copied_files"], 0
        )
        capture.mirror_profiles(source, dest, "target")
        self.assertFalse(dest.joinpath("run/secret.json").exists())

    def test_slow_metrics_do_not_block_memory_sampling(self):
        source, selected = self.make_profiles()
        group = self.root / "group"
        container = {
            "Id": "container",
            "Image": "sha256:test",
            "verified_task_id": TASK_ID,
            "State": {"Pid": 123},
            "Config": {
                "Hostname": "target",
                "Labels": {"com.amazonaws.ecs.task-arn": ARN},
            },
        }

        def slow_metrics(url):
            time.sleep(0.7)
            return {"metrics": []}

        output = self.root / "capture"
        with (
            patch.object(capture, "profile_source", return_value=source),
            patch.object(
                capture, "armed_profile", return_value=selected / "profile-state.json"
            ),
            patch.object(capture, "task_cgroup", return_value=group),
            patch.object(capture, "metrics_address", return_value="unused"),
            patch.object(capture, "process_start", return_value="100"),
            patch.object(capture, "fetch_metrics", side_effect=slow_metrics),
        ):
            capture.record(container, output, 1.1, 0.1)
        samples = [
            json.loads(x) for x in (output / "memory.jsonl").read_text().splitlines()
        ]
        self.assertGreaterEqual(len(samples), 8)
        self.assertLess(
            max(
                b["monotonic"] - a["monotonic"]
                for a, b in zip(samples, samples[1:], strict=False)
            ),
            0.5,
        )
        self.assertEqual(
            json.loads((output / "manifest.json").read_text())["status"], "finished"
        )

    def test_recover_after_container_loss_needs_only_persisted_manifest(self):
        source, selected = self.make_profiles()
        evidence = self.root / "recovery"
        evidence.mkdir()
        evidence.joinpath("manifest.json").write_text(
            json.dumps(
                {
                    "tool": "market-http-fis-capture-v1",
                    "task_arn": ARN,
                    "profile_root": str(source),
                    "profile_state": str(selected / "profile-state.json"),
                    "hostname": "target",
                }
            )
        )
        with (
            patch.object(capture, "PROFILE_ROOT", source),
            patch.object(
                capture, "inspect_task", side_effect=AssertionError("Task is gone")
            ),
        ):
            self.assertEqual(capture.recover(evidence)["copied_files"], 3)
        self.assertTrue((evidence / "profiles/run/1.snapshot").exists())

    def test_burst_requires_baseline_ready(self):
        source, selected = self.make_profiles()
        container = {
            "Config": {"Hostname": "target"},
            "State": {"StartedAt": "2026-10-29T00:00:00Z"},
        }
        with patch.object(capture, "profile_source", return_value=source):
            with self.assertRaises(ValueError):
                capture.trigger(container, burst=True)
            state_path = selected / "profile-state.json"
            state = json.loads(state_path.read_text())
            state["status"] = "baseline_ready"
            state_path.write_text(json.dumps(state))
            self.assertEqual(
                Path(capture.trigger(container, burst=True)).name, "capture.burst"
            )

    def test_awsvpc_namespace_address_fallback(self):
        container = {"Id": "target", "HostConfig": {"NetworkMode": "container:pause"}}
        pause = {"NetworkSettings": {"Networks": {}}}
        with patch.object(
            capture.subprocess,
            "check_output",
            side_effect=[json.dumps([pause]), "10.0.11.129\n"],
        ):
            self.assertEqual(
                capture.metrics_address(container), "http://10.0.11.129:9101/metrics"
            )

    def test_nanosecond_docker_timestamp_is_supported(self):
        self.assertEqual(
            capture.parse_time("2026-10-29T01:02:03.123456789Z").microsecond, 123456
        )

    def test_archive_rejects_self_destination(self):
        folder = self.root / "run"
        folder.mkdir()
        folder.joinpath("manifest.json").write_text(
            json.dumps({"tool": "market-http-fis-capture-v1"})
        )
        with self.assertRaises(ValueError):
            capture.archive(folder, folder / "self.tar.gz")


if __name__ == "__main__":
    unittest.main()


class NoProfileCaptureTests(unittest.TestCase):
    def test_no_profile_mode_does_not_require_mount_or_arm_and_recovers_after_exit(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            output = root / 'evidence'
            group = root / 'group'
            group.mkdir()
            (group / 'memory.max').write_text(str(2 * 1024**3))
            container = {'State': {'Pid': 123}, 'verified_task_id': TASK_ID, 'Id': 'c1', 'Image': 'image',
                         'Config': {'Hostname': 'market', 'Labels': {'com.amazonaws.ecs.task-arn': ARN}}}
            with patch.object(capture, 'profile_source', side_effect=AssertionError('must not require profiles')), \
                 patch.object(capture, 'armed_profile', side_effect=AssertionError('must not arm')), \
                 patch.object(capture, 'task_cgroup', return_value=group), \
                 patch.object(capture, 'metrics_address', return_value='http://127.0.0.1:9101/metrics'), \
                 patch.object(capture, 'process_start', return_value=1), \
                 patch.object(capture, 'memory_sample', return_value={'memory.current': 10}), \
                 patch.object(capture, 'fetch_metrics', return_value={'metrics': []}), \
                 patch.object(capture, 'mirror_profiles', side_effect=AssertionError('must not mirror')):
                capture.record(container, output, .03, .01, profiles=False)
                self.assertEqual(capture.recover(output), {'copied_files': 0, 'profiles_enabled': False})
            manifest = json.loads((output / 'manifest.json').read_text())
            self.assertEqual(manifest['status'], 'finished')
            self.assertIsNone(manifest['profile_root'])
            self.assertTrue((output / 'memory.jsonl').read_text())
