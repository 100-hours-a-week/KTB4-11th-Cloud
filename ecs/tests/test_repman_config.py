"""Render the actual startup shell with fixture credentials; never contacts AWS."""
import os
from pathlib import Path
import re
import subprocess
import tempfile
import textwrap
import tomllib
import unittest

ROOT = Path(__file__).resolve().parents[1]


class RepmanStartupTests(unittest.TestCase):
    def test_credentials_are_environment_values_and_not_shell_pid_prefixes(self):
        source = (ROOT / "svc_repman.tf").read_text()
        command = textwrap.dedent(re.search(r"repman_startup_command = <<-EOT\n(.*?)\n  EOT", source, re.S)[1])
        replacements = {
            "local.proxysql_primary_host": "10.0.1.1", "local.proxysql_private_replica_host": "10.0.2.1",
            "var.v1_mysql_port": "3306", "local.repman_proxy_dns_name": "proxy.internal", "var.proxysql_port": "6033",
        }
        for key, value in replacements.items():
            command = command.replace("${" + key + "}", value)
        with tempfile.TemporaryDirectory() as folder:
            target = Path(folder) / "config.toml"
            command = command.replace("/var/lib/replication-manager", folder)
            command = command.replace("/tmp/replication-manager.toml", str(target))
            command = command.split("# The Docker image")[0]
            fixtures = {"REPMAN_DATABASE_PASSWORD": "fixture_db_secret", "REPMAN_API_PASSWORD": "fixture_api_secret",
                        "REPMAN_REPLICATION_PASSWORD": "fixture_repl_secret", "REPMAN_PROXYSQL_PASSWORD": "fixture_proxy_secret"}
            subprocess.run(["/bin/sh", "-ec", command], env={**os.environ, **fixtures}, check=True, capture_output=True)
            value = tomllib.loads(target.read_text())
            self.assertEqual(value["Default"]["api-credentials"], "admin:" + fixtures["REPMAN_API_PASSWORD"])
            self.assertEqual(value["stockspoon"]["db-servers-credential"], "repman:" + fixtures["REPMAN_DATABASE_PASSWORD"])
            self.assertEqual(value["stockspoon"]["replication-credential"], "repman_repl:" + fixtures["REPMAN_REPLICATION_PASSWORD"])
            self.assertEqual(value["stockspoon"]["proxysql-password"], fixtures["REPMAN_PROXYSQL_PASSWORD"])
            self.assertEqual(value["stockspoon"]["failover-mode"], "automatic")
            self.assertTrue(value["stockspoon"]["failover-at-sync"])
            self.assertEqual(target.stat().st_mode & 0o777, 0o600)


if __name__ == "__main__":
    unittest.main()
