"""Tests for one-time credential collection and owner-only storage."""
import json
from pathlib import Path
import stat
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).parents[1]))
import credential_store


CONFIG = {
    "source": {"user": "root", "password_env": "V1"},
    "target": {"user": "root", "password_env": "TARGET"},
    "proxy_admin": {"user": "admin", "password_env": "PROXY_ADMIN"},
    "proxy_app": {"user": "stockspoon", "password_env": "APP"},
    "forward_replication": {"user": "repl", "password_env": "FORWARD"},
    "reverse_replication": {"user": "reverse", "password_env": "REVERSE"},
}


class CredentialStoreTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.config = self.root / "config.json"
        self.config.write_text(json.dumps(CONFIG), encoding="utf-8")
        self.path = self.root / "private" / "credentials.json"

    def test_setup_prompts_once_per_distinct_password_and_saves_mode_0600(self):
        entered = ["v1", "target", "admin", "app", "forward", "reverse"]
        with patch.object(credential_store.getpass, "getpass", side_effect=entered) as prompt:
            credential_store.setup(self.config, self.path)
        self.assertEqual(prompt.call_count, len(entered))
        self.assertEqual(stat.S_IMODE(self.path.stat().st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(self.path.parent.stat().st_mode), 0o700)
        saved = credential_store.load_passwords(self.path, credential_store.credential_entries(CONFIG))
        self.assertEqual(list(saved.values()), entered)

    def test_group_or_world_readable_file_is_rejected(self):
        credential_store.save_passwords(self.path, {"V1": "secret"})
        self.path.chmod(0o640)
        with self.assertRaisesRegex(PermissionError, "mode 0600"):
            credential_store.load_passwords(self.path, ["V1"])

    def test_missing_secret_is_reported_by_name(self):
        credential_store.save_passwords(self.path, {"V1": "secret"})
        with self.assertRaisesRegex(RuntimeError, "TARGET"):
            credential_store.load_passwords(self.path, ["V1", "TARGET"])

    def test_repeated_password_env_is_prompted_and_stored_once(self):
        config = {**CONFIG, "target": {"user": "root", "password_env": "V1"}}
        self.config.write_text(json.dumps(config), encoding="utf-8")
        with patch.object(credential_store.getpass, "getpass", return_value="same") as prompt:
            credential_store.setup(self.config, self.path)
        self.assertEqual(prompt.call_count, len(credential_store.credential_entries(config)))


if __name__ == "__main__":
    unittest.main()
