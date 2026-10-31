#!/usr/bin/env python3
"""MySQL 8.4 planned switchover. Never auto-roll back an uncertain promotion."""
import argparse
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
from fnmatch import fnmatchcase
import getpass
import hashlib
from ipaddress import ip_address, ip_network
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

from credential_store import load_passwords
# Migration-only write replay is disabled; keep its helper in the repository
# without importing it into the normal switchover path.
# from write_replay import drain_aws, validate_options as validate_replay_options


class SafetyError(RuntimeError):
    pass


def require(condition, message):
    if not condition:
        raise SafetyError(message)


def identifier(value):
    return "`" + value.replace("`", "``") + "`"


def stamp():
    return datetime.now(timezone.utc).isoformat()


def save_json(path, value):
    path = Path(path)
    temporary = path.with_suffix(path.suffix + ".tmp")
    with open(temporary, "w", encoding="utf-8") as stream:
        os.chmod(temporary, 0o600)
        json.dump(value, stream, indent=2, default=str)
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(temporary, path)
    fd = os.open(path.parent, os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


class Journal:
    def __init__(self, directory, command):
        self.directory = Path(directory).resolve()
        self.directory.mkdir(mode=0o700, parents=True, exist_ok=False)
        self.state = {"command": command, "status": "running", "started_at": stamp(), "events": []}
        self.started = time.monotonic()
        self.event("started")

    def event(self, phase, **values):
        event = {"at": stamp(), "elapsed_seconds": round(time.monotonic() - self.started, 3),
                 "phase": phase, **values}
        self.state["phase"] = phase
        self.state["events"].append(event)
        save_json(self.directory / "state.json", self.state)
        print(json.dumps(event, ensure_ascii=False, default=str), flush=True)


class DB:
    def __init__(self, cfg, password, timeout):
        import pymysql
        # Endpoints are authenticated SSM tunnels. MySQL TLS matches the existing
        # self-signed-server setup; CA identity verification is not claimed here.
        tls = {"ssl": {"check_hostname": False, "verify_mode": False}} if cfg.get("tls") else {}
        self.connection = pymysql.connect(
            host=cfg["host"], port=int(cfg["port"]), user=cfg["user"], password=password,
            connect_timeout=5, read_timeout=timeout, write_timeout=timeout,
            autocommit=True, charset="utf8mb4", cursorclass=pymysql.cursors.DictCursor, **tls,
        )

    def rows(self, sql, params=()):
        with self.connection.cursor() as cursor:
            cursor.execute(sql, params)
            return list(cursor.fetchall())

    def scalar(self, sql, params=()):
        rows = self.rows(sql, params)
        require(len(rows) == 1, "Expected exactly one SQL result row")
        return next(iter(rows[0].values()))

    def close(self):
        self.connection.close()


SERVER_SQL = """SELECT @@server_uuid AS uuid, @@server_id AS server_id, @@version AS version,
 @@global.read_only AS ro, @@global.super_read_only AS sro,
 @@global.gtid_mode AS gtid_mode, @@global.enforce_gtid_consistency AS enforce_gtid,
 @@global.gtid_executed AS gtids, @@global.gtid_purged AS purged,
 @@global.log_bin AS log_bin, @@global.log_replica_updates AS log_replica_updates,
 @@global.sync_binlog AS sync_binlog, @@global.innodb_flush_log_at_trx_commit AS flush_commit,
 @@global.persisted_globals_load AS persisted_globals_load,
 @@global.relay_log_basename AS relay_log_basename, @@global.relay_log_index AS relay_log_index,
 @@global.replica_parallel_workers AS parallel_workers,
 @@global.replica_preserve_commit_order AS preserve_commit_order"""


def server(db):
    return db.rows(SERVER_SQL)[0]


def redact_secrets(value, secrets):
    if isinstance(value, dict):
        return {key: redact_secrets(item, secrets) for key, item in value.items()}
    if isinstance(value, (list, tuple)):
        return [redact_secrets(item, secrets) for item in value]
    if isinstance(value, str):
        for secret in secrets:
            if secret:
                value = value.replace(secret, "[REDACTED]")
    return value


def replication_source_account_audit(db, username, replica_host):
    """Check the source-side replica account before either DB is fenced."""
    rows = db.rows("SELECT user, host, account_locked, ssl_type FROM mysql.user WHERE user=%s", (username,))
    accounts = []
    for row in rows:
        account_user = db.connection.escape(row["user"])
        account_host = db.connection.escape(row["host"])
        if isinstance(account_user, bytes):
            account_user = account_user.decode("utf-8")
        if isinstance(account_host, bytes):
            account_host = account_host.decode("utf-8")
        grants = db.rows(f"SHOW GRANTS FOR {account_user}@{account_host}")
        grant_text = [str(next(iter(grant.values()))).upper() for grant in grants]
        replication_privilege = any(
            ("REPLICATION SLAVE" in grant or "REPLICATION REPLICA" in grant)
            and " ON *.* " in grant
            for grant in grant_text
        )
        host_pattern = str(row["host"])
        if replica_host is None:
            host_matches = None
        else:
            try:
                host_matches = ip_address(replica_host) in ip_network(host_pattern, strict=False)
            except ValueError:
                host_matches = fnmatchcase(replica_host, host_pattern.replace("%", "*").replace("_", "?"))
        summary = {
            "user": row["user"],
            "host": host_pattern,
            "account_locked": row["account_locked"],
            "ssl_type": row["ssl_type"],
            "replica_host_matches": host_matches,
            "has_replication_privilege": replication_privilege,
        }
        accounts.append(summary)
    usable = any(
        str(account["account_locked"]).upper() in ("N", "NO", "0")
        and account["replica_host_matches"] is not False
        and account["has_replication_privilege"]
        for account in accounts
    )
    require(usable, f"Replication account is missing or unusable on source: "
            + json.dumps({"user": username, "replica_host": replica_host, "accounts": accounts},
                         ensure_ascii=False, default=str))
    return accounts


def replication_diagnostics(db, secrets=()):
    """Best-effort, credential-safe snapshot for replication setup failures."""
    snapshot = {}

    def read(name, sql):
        try:
            value = db.rows(sql)
            snapshot[name] = value
        except Exception as error:
            snapshot[name] = {"unavailable": str(error)}

    read("server_and_relay_variables", """SELECT @@hostname AS hostname, @@server_uuid AS server_uuid,
        @@server_id AS server_id, @@datadir AS datadir, @@global.relay_log AS relay_log,
        @@global.relay_log_basename AS relay_log_basename,
        @@global.relay_log_index AS relay_log_index,
        @@global.relay_log_recovery AS relay_log_recovery,
        @@global.log_error AS log_error""")
    read("show_replica_status", "SHOW REPLICA STATUS")
    read("replication_connection_status", """SELECT CHANNEL_NAME, SOURCE_UUID, SERVICE_STATE,
        RECEIVED_TRANSACTION_SET, LAST_ERROR_NUMBER, LAST_ERROR_MESSAGE, LAST_ERROR_TIMESTAMP
        FROM performance_schema.replication_connection_status""")
    read("replication_applier_status", """SELECT CHANNEL_NAME, SERVICE_STATE
        FROM performance_schema.replication_applier_status""")
    read("replication_applier_status_by_coordinator", """SELECT CHANNEL_NAME, SERVICE_STATE,
        LAST_ERROR_NUMBER, LAST_ERROR_MESSAGE, LAST_ERROR_TIMESTAMP
        FROM performance_schema.replication_applier_status_by_coordinator""")
    read("replication_applier_status_by_worker", """SELECT CHANNEL_NAME, WORKER_ID, SERVICE_STATE,
        LAST_ERROR_NUMBER, LAST_ERROR_MESSAGE, LAST_ERROR_TIMESTAMP
        FROM performance_schema.replication_applier_status_by_worker ORDER BY WORKER_ID""")
    # Do not read mysql.slave_master_info: it contains replication credentials.
    read("applier_metadata_repository", """SELECT Channel_name, Relay_log_name, Relay_log_pos,
        Master_log_name, Master_log_pos, Number_of_workers
        FROM mysql.slave_relay_log_info ORDER BY Channel_name""")
    read("recent_replication_error_log", """SELECT LOGGED, PRIO, ERROR_CODE, SUBSYSTEM, DATA
        FROM performance_schema.error_log
        WHERE SUBSYSTEM = 'Repl' OR DATA LIKE '%%relay%%' OR DATA LIKE '%%applier%%'
        ORDER BY LOGGED DESC LIMIT 100""")

    return redact_secrets(snapshot, secrets)


def replica(db, expected_uuid=None, running=True):
    rows = db.rows("SHOW REPLICA STATUS")
    require(len(rows) == 1, "Exactly one default replication channel is required")
    row = rows[0]
    require(row["Channel_Name"] == "", "Named/multiple channels are unsupported")
    for key in ("Replicate_Do_DB", "Replicate_Ignore_DB", "Replicate_Do_Table",
                "Replicate_Ignore_Table", "Replicate_Wild_Do_Table", "Replicate_Wild_Ignore_Table",
                "Replicate_Ignore_Server_Ids", "Replicate_Rewrite_DB"):
        require(not row.get(key), f"Replication filter found: {key}")
    require(int(row["SQL_Delay"]) == 0 and int(row["Skip_Counter"]) == 0,
            "Delayed/skipping replication is unsupported")
    require(int(row["Last_IO_Errno"]) == 0 and int(row["Last_SQL_Errno"]) == 0,
            "Replication has an IO/SQL error; inspect SHOW REPLICA STATUS")
    if running:
        require(row["Replica_IO_Running"] == "Yes" and row["Replica_SQL_Running"] == "Yes",
                "Both replication threads must be running")
        require(row["Source_UUID"] == expected_uuid, "Replica follows an unexpected source UUID")
    return row


def verify_replica_channel(db, source_cfg, username, auto_position, running=True):
    """Check that the default channel points at the intended source and mode."""
    row = replica(db, source_cfg["uuid"] if running else None, running=running)
    require(row["Source_Host"] == source_cfg["server_host"]
            and int(row["Source_Port"]) == int(source_cfg["server_port"]),
            "Replication channel points at an unexpected source address")
    require(row["Source_User"] == username, "Replication channel has an unexpected user")
    require(int(row["Auto_Position"]) == int(auto_position),
            "Replication channel has an unexpected GTID positioning mode")
    require(row["Source_SSL_Allowed"] == "Yes", "Encrypted replication is required")
    require(not any(row.get(k) for k in ("Source_SSL_CA_File", "Source_SSL_CA_Path", "Source_SSL_Cert", "Source_SSL_Key"))
            and row["Source_SSL_Verify_Server_Cert"] == "No",
            "Custom replication TLS settings differ from the audited configuration")
    return row


def require_no_unapplied_relay_gtids(db, status):
    retrieved = status.get("Retrieved_Gtid_Set") or ""
    if retrieved:
        applied = db.scalar("SELECT @@GLOBAL.gtid_executed")
        pending = db.scalar("SELECT GTID_SUBTRACT(%s, %s)", (retrieved, applied))
        require(not pending,
                "Receiver has unapplied relay GTIDs; refusing RESET REPLICA ALL because it deletes relay logs")


def no_incoming_replication(db):
    for row in db.rows("SHOW REPLICA STATUS"):
        require(row["Channel_Name"] == "" and row["Replica_IO_Running"] == "No"
                and row["Replica_SQL_Running"] == "No", "Primary has an active/extra incoming channel")
        replica(db, running=False)
        require(not any(row.get(k) for k in ("Source_SSL_CA_File", "Source_SSL_CA_Path", "Source_SSL_Cert", "Source_SSL_Key"))
                and row.get("Source_SSL_Verify_Server_Cert", "No") == "No",
                "Stopped primary channel has custom TLS verification; audit before repointing it")


def binlog(db):
    row = db.rows("SHOW BINARY LOG STATUS")[0]
    require(not row["Binlog_Do_DB"] and not row["Binlog_Ignore_DB"], "Source binlog filters found")
    return row


def no_active_query_rules(proxy):
    # ProxySQL Admin may expose SQLite aggregate results as text over the
    # MySQL protocol. Normalize before comparing so "0" is not mistaken for
    # a non-zero active-rule count.
    active_rules = int(proxy.scalar("SELECT COUNT(*) FROM runtime_mysql_query_rules WHERE active=1"))
    require(active_rules == 0,
            f"ProxySQL has {active_rules} active query rules; separate routing audit required")


def inventory(db, schema):
    schemas = db.rows("SELECT SCHEMA_NAME AS name FROM information_schema.schemata "
                      "WHERE SCHEMA_NAME NOT IN ('mysql','sys','information_schema','performance_schema')")
    require({r["name"] for r in schemas} == {schema}, "Additional application schemas need explicit migration coverage")
    rows = db.rows("SELECT TABLE_NAME AS name, ENGINE AS engine, TABLE_TYPE AS type "
                   "FROM information_schema.tables WHERE TABLE_SCHEMA=%s ORDER BY TABLE_NAME", (schema,))
    require(rows and all(r["engine"] == "InnoDB" and r["type"] == "BASE TABLE" for r in rows),
            "Schema must contain only InnoDB base tables (views need separate validation)")
    for table, column in (("triggers", "TRIGGER_SCHEMA"), ("routines", "ROUTINE_SCHEMA"),
                          ("events", "EVENT_SCHEMA")):
        require(db.scalar(f"SELECT COUNT(*) FROM information_schema.{table} WHERE {column}=%s", (schema,)) == 0,
                f"{table} found: this script requires a separate definition/behavior audit")
    return [r["name"] for r in rows]


def fingerprint(db, schema):
    result = {}
    for name in inventory(db, schema):
        table = identifier(schema) + "." + identifier(name)
        ddl = db.rows(f"SHOW CREATE TABLE {table}")[0]["Create Table"]
        checksum = db.rows(f"CHECKSUM TABLE {table} EXTENDED")[0]["Checksum"]
        require(checksum is not None, f"No checksum for {table}")
        result[name] = {"ddl_sha256": hashlib.sha256(ddl.encode()).hexdigest(),
                        "rows": int(db.scalar(f"SELECT COUNT(*) FROM {table}")), "checksum": int(checksum)}
    return result


def compare_data(primary, standby, schema):
    schema_sql = "SELECT DEFAULT_CHARACTER_SET_NAME, DEFAULT_COLLATION_NAME FROM information_schema.schemata WHERE SCHEMA_NAME=%s"
    require(primary.rows(schema_sql, (schema,)) == standby.rows(schema_sql, (schema,)), "Schema charset/collation mismatch")
    # One connection per worker; both databases are fenced and the applier is stopped.
    with ThreadPoolExecutor(max_workers=2) as pool:
        a = pool.submit(fingerprint, primary, schema)
        b = pool.submit(fingerprint, standby, schema)
        first, second = a.result(), b.result()
    differences = sorted(k for k in first.keys() | second.keys() if first.get(k) != second.get(k))
    require(not differences, "Schema/count/checksum mismatch: " + ", ".join(differences))
    return first


class Switch:
    LOCK = "stockspoon-planned-switchover"

    def __init__(self, cfg, dbs, connect_app, passwords, journal, restore_state=None):
        self.cfg, self.dbs, self.connect_app = cfg, dbs, connect_app
        self.passwords, self.journal = passwords, journal
        self.restore_state = restore_state
        self.primary_name, self.standby_name = ("target", "source") if restore_state else ("source", "target")
        self.primary, self.standby = dbs[self.primary_name], dbs[self.standby_name]
        self.proxy = dbs["proxy_admin"]
        self.primary_cfg, self.standby_cfg = cfg[self.primary_name], cfg[self.standby_name]
        self.deadline = None
        self.monitor_baseline = {}
        self.write_block_started_monotonic = None
        self.write_block_started_at = None

    def guard(self):
        require(self.deadline is None or time.monotonic() < self.deadline, "Cutover time budget exceeded")
        for db in (self.primary, self.standby):
            require(db.scalar("SELECT IS_USED_LOCK(%s)=CONNECTION_ID()", (self.LOCK,)) == 1,
                    "Switchover control connection/lock lost")

    def lock(self):
        for name in sorted(("source", "target"), key=lambda n: self.cfg[n]["uuid"]):
            require(self.dbs[name].scalar("SELECT GET_LOCK(%s, 0)", (self.LOCK,)) == 1,
                    f"Another switchover owns {name}")

    def monitor(self, endpoint):
        rows = self.proxy.rows("SELECT time_start_us, read_only, error FROM monitor.mysql_server_read_only_log "
                               "WHERE hostname=%s AND port=%s ORDER BY time_start_us DESC LIMIT 1",
                               (endpoint["server_host"], endpoint["server_port"]))
        require(rows, "No ProxySQL monitor observations")
        return rows[0]

    def routes(self, writer_name):
        rows = self.proxy.rows("SELECT hostgroup_id, hostname, port, status FROM runtime_mysql_servers "
                               "WHERE hostgroup_id IN (10,20)")
        actual = sorted((int(r["hostgroup_id"]), r["hostname"], int(r["port"]), r["status"]) for r in rows)
        expected = sorted((10 if n == writer_name else 20, self.cfg[n]["server_host"],
                           self.cfg[n]["server_port"], "ONLINE") for n in ("source", "target"))
        expected_hostgroup = {
            (self.cfg[n]["server_host"], self.cfg[n]["server_port"]):
            (10 if n == writer_name else 20)
            for n in ("source", "target")
        }
        actual_online = sorted(row for row in actual if row[3] == "ONLINE")
        # ProxySQL can retain the old writer-hostgroup row as OFFLINE_HARD
        # after read_only monitoring moves that server into the reader group.
        # OFFLINE_HARD receives no traffic, so allow only that known stale row;
        # all online memberships and all other statuses remain strict.
        stale_offline_hard = [
            row for row in actual
            if row[3] == "OFFLINE_HARD"
            and (row[1], row[2]) in expected_hostgroup
            and row[0] != expected_hostgroup[(row[1], row[2])]
        ]
        unexpected_rows = [row for row in actual if row not in actual_online and row not in stale_offline_hard]
        if actual_online != expected or unexpected_rows:
            monitor_snapshot = {}
            for name in ("source", "target"):
                try:
                    observation = self.monitor(self.cfg[name])
                    monitor_snapshot[name] = {
                        "time_start_us": observation.get("time_start_us"),
                        "read_only": observation.get("read_only"),
                        "error": observation.get("error"),
                    }
                except Exception as error:
                    monitor_snapshot[name] = {"query_error": str(error)}
            raise SafetyError(
                "Unexpected/offline ProxySQL hostgroup membership: "
                + json.dumps({"writer_expected": writer_name, "expected": expected,
                              "actual": actual, "unexpected_rows": unexpected_rows,
                              "allowed_stale_offline_hard": stale_offline_hard,
                              "monitor": monitor_snapshot},
                             ensure_ascii=False, default=str)
            )
        for name in ("source", "target"):
            cfg = self.cfg[name]
            monitor = self.monitor(cfg)
            expected_read_only = "0" if name == writer_name else "1"
            require(monitor["error"] is None and str(monitor["read_only"]) == expected_read_only,
                    "ProxySQL monitor role mismatch: "
                    + json.dumps({"database": name, "expected_read_only": expected_read_only,
                                  "observation": monitor}, ensure_ascii=False, default=str))
            baseline = self.monitor_baseline.get(name, -1)
            require(int(monitor["time_start_us"]) > baseline,
                    "Waiting for a fresh ProxySQL monitor observation: "
                    + json.dumps({"database": name, "baseline_time_start_us": baseline,
                                  "observation": monitor}, ensure_ascii=False, default=str))

    def app_probe(self, endpoint, expected_uuid):
        connection = self.connect_app(endpoint)
        try:
            row = connection.rows("SELECT @@server_uuid AS uuid, @@read_only AS ro")[0]
            require(row["uuid"] == expected_uuid, "App connection reached the wrong database")
            grants = [next(iter(r.values())) for r in connection.rows("SHOW GRANTS")]
            privileges = set()
            for grant in grants:
                for scope in ("*.*", identifier(self.cfg["schema"]) + ".*"):
                    prefix, found, _ = grant.partition(" ON " + scope + " TO ")
                    if found and prefix.startswith("GRANT "):
                        privileges.update(prefix[6:].split(", "))
            require("ALL PRIVILEGES" in privileges or {"SELECT", "INSERT", "UPDATE", "DELETE"} <= privileges,
                    "App user needs direct schema/global SELECT/INSERT/UPDATE/DELETE grants; role/table grants need an audit")
            connection.rows(f"USE {identifier(self.cfg['schema'])}")
            for table in inventory(self.standby, self.cfg["schema"]):
                connection.rows(f"SELECT 1 FROM {identifier(self.cfg['schema'])}.{identifier(table)} LIMIT 0")
            return row
        finally:
            connection.close()

    def preflight(self):
        self.lock()
        states = {name: server(self.dbs[name]) for name in ("source", "target")}
        for name, s in states.items():
            require(s["uuid"] == self.cfg[name]["uuid"] and int(s["server_id"]) == self.cfg[name]["server_id"],
                    f"{name}: UUID/server_id mismatch; check the actual container")
            require(s["gtid_mode"] == "ON" and s["enforce_gtid"] == "ON" and s["log_bin"] == 1
                    and s["log_replica_updates"] == 1, f"{name}: GTID/binlog configuration is unsuitable")
            require(s["sync_binlog"] == 1 and s["flush_commit"] == 1 and s["persisted_globals_load"] == 1,
                    f"{name}: durable commits and persisted_globals_load=ON are required")
            require(int(s["parallel_workers"]) == 0 or s["preserve_commit_order"] == 1,
                    f"{name}: parallel replication must preserve commit order")
            require(not self.dbs[name].rows("XA RECOVER"), f"{name}: prepared XA transactions exist")
            require(self.dbs[name].scalar("SELECT COUNT(*) FROM performance_schema.replication_group_members") == 0,
                    "Group Replication is unsupported")
            binlog(self.dbs[name])
        require(states["source"]["version"] == states["target"]["version"], "MySQL versions must match for checksum comparison")
        require(states[self.primary_name]["ro"] == 0 and states[self.primary_name]["sro"] == 0, "Primary is not writable")
        require(states[self.standby_name]["ro"] == 1, "Standby is not read_only")
        no_incoming_replication(self.primary)
        repl = replica(self.standby, self.primary_cfg["uuid"])
        require(int(repl["Auto_Position"]) == (0 if self.restore_state else 1), "Unexpected replication positioning mode")
        require(repl["Source_Host"] == self.primary_cfg["server_host"] and int(repl["Source_Port"]) == self.primary_cfg["server_port"],
                "Unexpected replication source address")
        if not self.restore_state:
            require(repl["Source_User"] == self.cfg["forward_replication"]["user"], "Forward replication username differs from config")
        else:
            require(repl["Source_User"] == self.cfg["reverse_replication"]["user"], "Reverse replication username differs from config")
        account_audit = {
            "forward_source_v1": replication_source_account_audit(
                self.dbs["source"], self.cfg["forward_replication"]["user"], None),
            "reverse_source_migration": replication_source_account_audit(
                self.dbs["target"], self.cfg["reverse_replication"]["user"], self.cfg["source"]["server_host"]),
        }
        self.journal.state["replication_account_audit"] = account_audit
        self.journal.event("replication_account_audit", accounts=account_audit)
        require(repl["Source_SSL_Allowed"] == "Yes", "Encrypted replication is required")
        require(not any(repl.get(k) for k in ("Source_SSL_CA_File", "Source_SSL_CA_Path", "Source_SSL_Cert", "Source_SSL_Key"))
                and repl["Source_SSL_Verify_Server_Cert"] == "No",
                "Custom replication certificates need explicit per-direction TLS configuration; refusing to downgrade")
        require(inventory(self.primary, self.cfg["schema"]) == inventory(self.standby, self.cfg["schema"]), "Table lists differ")
        groups = self.proxy.rows("SELECT writer_hostgroup,reader_hostgroup,check_type FROM runtime_mysql_replication_hostgroups")
        require(len(groups) == 1 and int(groups[0]["writer_hostgroup"]) == 10
                and int(groups[0]["reader_hostgroup"]) == 20 and groups[0]["check_type"] == "read_only", "Unexpected hostgroup mapping")
        no_active_query_rules(self.proxy)
        users = self.proxy.rows("SELECT default_hostgroup,active,transaction_persistent,fast_forward,frontend,backend "
                                "FROM runtime_mysql_users WHERE username=%s", (self.cfg["proxy_app"]["user"],))
        require(users and all(int(r["default_hostgroup"]) == 10 and int(r["active"]) == 1
                             and int(r["transaction_persistent"]) == 1 and int(r["fast_forward"]) == 0 for r in users)
                and any(int(r["frontend"]) == 1 for r in users) and any(int(r["backend"]) == 1 for r in users),
                "Unexpected ProxySQL app-user settings")
        self.routes(self.primary_name)
        self.app_probe(self.cfg["proxy_app"], self.primary_cfg["uuid"])
        self.app_probe(self.standby_cfg, self.standby_cfg["uuid"])
        self.monitor_baseline = {n: int(self.monitor(self.cfg[n])["time_start_us"]) for n in ("source", "target")}
        self.journal.state["identities"] = {n: self.cfg[n]["uuid"] for n in ("source", "target")}
        self.journal.state["schema"] = self.cfg["schema"]
        self.journal.state["before"] = {
            "servers": states, "replica": repl,
            "replication_diagnostics": {
                name: replication_diagnostics(self.dbs[name], self.passwords.values())
                for name in ("source", "target")
            },
            "primary_channels": self.primary.rows("SHOW REPLICA STATUS"),
            "proxy_servers": self.proxy.rows("SELECT hostgroup_id,hostname,port,status,weight,max_connections FROM runtime_mysql_servers"),
            "proxy_hostgroups": groups, "proxy_app_user": users,
            "proxy_variables": self.proxy.rows("SELECT variable_name,variable_value FROM runtime_global_variables "
                                               "WHERE variable_name IN ('mysql-monitor_read_only_interval',"
                                               "'mysql-monitor_read_only_timeout','mysql-monitor_writer_is_also_reader')"),
            "persisted_roles": {n: self.dbs[n].rows("SELECT VARIABLE_NAME,VARIABLE_VALUE FROM performance_schema.persisted_variables "
                                                    "WHERE VARIABLE_NAME IN ('read_only','super_read_only','skip_replica_start',"
                                                    "'relay_log','relay_log_index','relay_log_recovery')")
                                for n in ("source", "target")},
        }
        self.journal.event("preflight_ok", primary=self.primary_name, standby=self.standby_name)

    def wait(self, action, timeout):
        end = time.monotonic() + timeout
        while True:
            self.guard()
            try:
                return action()
            except SafetyError:
                if time.monotonic() >= end:
                    raise
                time.sleep(0.5)

    def wait_gtids(self, db, gtids):
        def check():
            require(db.scalar("SELECT WAIT_FOR_EXECUTED_GTID_SET(%s, 1)", (gtids,)) == 0, "GTID catch-up timed out")
        self.wait(check, self.cfg["sync_timeout_seconds"])

    def fence(self, db, label):
        self.guard()
        self.journal.event("fence_requested", database=label)
        db.rows("SET SESSION lock_wait_timeout=10")
        db.rows("SET PERSIST read_only=ON")
        if label == self.primary_name:
            # read_only=ON is the point where ordinary application writes to
            # the current primary are rejected. Use monotonic time for the
            # duration and UTC only for the persisted report.
            self.write_block_started_monotonic = time.monotonic()
            self.write_block_started_at = stamp()
            self.journal.state["write_blocked_started_at"] = self.write_block_started_at
            self.journal.event("write_blocked_started", database=label,
                               boundary="after SET PERSIST read_only=ON succeeded")
        db.rows("SET PERSIST super_read_only=ON")
        self.assert_fenced(db)
        paths = db.rows("SELECT @@global.relay_log_basename AS base, @@global.relay_log_index AS idx")[0]
        # relay_log and relay_log_index are startup-only/persist-restricted
        # variables. MySQL rejects SET PERSIST_ONLY for them unless the server
        # has the dedicated X.509 configuration; relay_log_index is nonpersistible.
        # Record the live paths for recovery diagnostics, but do not mutate them.
        self.journal.event("relay_paths_observed", database=label, **paths)
        db.rows("SET PERSIST_ONLY relay_log_recovery=ON")

    def clear_replica_channel(self, db, label):
        """Delete old channel and applier metadata before assigning a new source.

        This is deliberately called only after both servers are fenced and the
        data/GTID boundary has been checked. RESET REPLICA ALL removes stale
        connection and applier metadata as well as relay logs, while preserving
        user data and GTID execution history.
        """
        statuses = db.rows("SHOW REPLICA STATUS")
        if statuses:
            require(len(statuses) == 1 and statuses[0].get("Channel_Name") == "",
                    f"{label}: cannot reset an unexpected replication channel layout")
            status = statuses[0]
            if status["Replica_IO_Running"] != "No" or status["Replica_SQL_Running"] != "No":
                db.rows("STOP REPLICA")
                statuses = db.rows("SHOW REPLICA STATUS")
                require(len(statuses) == 1 and statuses[0]["Replica_IO_Running"] == "No"
                        and statuses[0]["Replica_SQL_Running"] == "No",
                        f"{label}: replication threads did not stop")
                status = statuses[0]
            require_no_unapplied_relay_gtids(db, status)

        self.journal.event("replica_metadata_reset_requested", database=label,
                           had_channel=bool(statuses),
                           diagnostics=replication_diagnostics(db, self.passwords.values()))
        try:
            db.rows("RESET REPLICA ALL")
            remaining = db.rows("SHOW REPLICA STATUS")
            require(not remaining, f"{label}: RESET REPLICA ALL left a configured channel")
            metadata = db.rows("SELECT Channel_name FROM mysql.slave_relay_log_info")
            require(not metadata, f"{label}: applier metadata remains after RESET REPLICA ALL")
        except Exception as error:
            self.journal.event("replication_diagnostics", operation="reset-replica-all",
                               database=label,
                               error=redact_secrets(str(error), self.passwords.values()),
                               snapshot=replication_diagnostics(db, self.passwords.values()))
            raise
        self.journal.event("replica_metadata_reset_complete", database=label,
                           diagnostics=replication_diagnostics(db, self.passwords.values()))

    @staticmethod
    def assert_fenced(db):
        r = db.rows("SELECT @@read_only AS ro, @@super_read_only AS sro")[0]
        require(r["ro"] == 1 and r["sro"] == 1, "Database write fence is not active")

    def configure_reverse(self, boundary):
        self.guard()
        credentials = self.cfg["forward_replication" if self.restore_state else "reverse_replication"]
        self.journal.event("reverse_configure_requested", receiver=self.primary_name,
                           source=self.standby_name, auto_position=bool(self.restore_state))
        # Both databases are fenced and checksummed before this call. Remove
        # the former channel completely: RESET REPLICA alone retains connection
        # parameters, while ALL also drops stale relay/applier metadata.
        self.clear_replica_channel(self.primary, self.primary_name)
        try:
            common = (self.standby_cfg["server_host"], self.standby_cfg["server_port"], credentials["user"],
                      self.passwords[credentials["password_env"]])
            retry = self.restore_state["before"]["replica"] if self.restore_state else {"Connect_Retry": 1, "Source_Retry_Count": 60}
            common += (int(retry["Connect_Retry"]), int(retry["Source_Retry_Count"]))
            sql = ("CHANGE REPLICATION SOURCE TO SOURCE_HOST=%s, SOURCE_PORT=%s, SOURCE_USER=%s, SOURCE_PASSWORD=%s, "
                   "SOURCE_SSL=1, SOURCE_SSL_VERIFY_SERVER_CERT=0, SOURCE_CONNECT_RETRY=%s, SOURCE_RETRY_COUNT=%s, ")
            if self.restore_state:
                # Restoring the original GTID direction must not request historical transactions it lacks.
                missing = self.primary.scalar("SELECT GTID_SUBTRACT(%s, @@GLOBAL.gtid_executed)", (boundary["Executed_Gtid_Set"],))
                require(not missing, "Cannot restore auto-position: former target lacks candidate history")
                self.primary.rows(sql + "SOURCE_AUTO_POSITION=1", common)
            else:
                # A consistent data boundary avoids replaying the seed server's local initialization/user GTIDs.
                self.primary.rows(sql + "SOURCE_AUTO_POSITION=0, SOURCE_LOG_FILE=%s, SOURCE_LOG_POS=%s",
                                  common + (boundary["File"], int(boundary["Position"])))
            verify_replica_channel(self.primary, self.standby_cfg, credentials["user"],
                                   auto_position=bool(self.restore_state), running=False)
            self.journal.event("reverse_source_configured", receiver=self.primary_name,
                               source=self.standby_name,
                               diagnostics=replication_diagnostics(self.primary, self.passwords.values()))
            self.primary.rows("SET PERSIST_ONLY skip_replica_start=OFF")
            self.primary.rows("START REPLICA")
            self.wait(lambda: verify_replica_channel(self.primary, self.standby_cfg, credentials["user"],
                                                     auto_position=bool(self.restore_state), running=True),
                      self.cfg["sync_timeout_seconds"])
        except Exception as error:
            self.journal.event("replication_diagnostics", operation="reset/configure/start/wait",
                               receiver=self.primary_name,
                               error=redact_secrets(str(error), self.passwords.values()),
                               snapshot=replication_diagnostics(self.primary, self.passwords.values()))
            raise
        self.journal.event("reverse_replication_ready")

    def run(self):
        # Disabled migration-only replay configuration and validation:
        # replay_options = self.cfg.get("write_replay", {})
        # replay_enabled = bool(replay_options) and replay_options.get("enabled", True)
        # if replay_enabled and not self.restore_state:
        #     validate_replay_options(replay_options)
        self.preflight()
        self.deadline = time.monotonic() + self.cfg["cutover_timeout_seconds"]
        self.fence(self.standby, self.standby_name)
        self.fence(self.primary, self.primary_name)
        # Prevent an old stopped channel from restarting if the old primary restarts mid-cutover.
        self.primary.rows("SET PERSIST_ONLY skip_replica_start=ON")
        frozen = self.primary.scalar("SELECT @@GLOBAL.gtid_executed")
        exempt = self.restore_state["target_only_gtids_at_switch"] if self.restore_state else ""
        required = self.primary.scalar("SELECT GTID_SUBTRACT(%s, %s)", (frozen, exempt))
        self.journal.state["frozen_primary_gtids"] = frozen
        self.journal.event("primary_fenced", required_gtids=required)
        self.wait_gtids(self.standby, required)
        replica(self.standby, self.primary_cfg["uuid"])
        self.journal.event("standby_stop_requested")
        self.standby.rows("STOP REPLICA")
        stopped = replica(self.standby, self.primary_cfg["uuid"], running=False)
        require_no_unapplied_relay_gtids(self.standby, stopped)
        self.standby.rows("SET PERSIST_ONLY skip_replica_start=ON")
        self.guard()
        self.assert_fenced(self.primary)
        self.assert_fenced(self.standby)
        fingerprints = compare_data(self.primary, self.standby, self.cfg["schema"])
        require(self.primary.scalar("SELECT @@GLOBAL.gtid_executed") == frozen, "Primary changed during verification")
        require(self.standby.scalar("SELECT GTID_SUBSET(%s, @@GLOBAL.gtid_executed)", (required,)) == 1, "Final GTID check failed")
        boundary = binlog(self.standby)
        extra = self.primary.scalar("SELECT GTID_SUBTRACT(%s,%s)", (boundary["Executed_Gtid_Set"], frozen))
        self.journal.state.update(boundary=boundary, target_only_gtids_at_switch=extra, fingerprints=fingerprints)
        self.journal.event("data_verified", tables=len(fingerprints), target_only_gtids=extra)
        # The promoted server must not retain a stopped channel to its former
        # primary. Clear it only after catch-up and data comparison succeed.
        self.clear_replica_channel(self.standby, self.standby_name)
        self.configure_reverse(boundary)
        self.wait(lambda: self.routes(None), self.cfg["routing_timeout_seconds"])
        self.guard()
        self.assert_fenced(self.primary)
        self.assert_fenced(self.standby)
        require(self.standby.scalar("SELECT @@GLOBAL.gtid_executed") == boundary["Executed_Gtid_Set"], "Standby changed after verification")
        # Durable marker BEFORE enabling writes: a lost response must never trigger automatic rollback.
        self.journal.event("promotion_attempted", database=self.standby_name)
        self.standby.rows("SET PERSIST super_read_only=OFF")
        self.standby.rows("SET PERSIST read_only=OFF")
        def routed():
            self.routes(self.standby_name)
            probe = self.app_probe(self.cfg["proxy_app"], self.standby_cfg["uuid"])
            require(probe["ro"] == 0, "ProxySQL app connection is still read-only")
        self.wait(routed, self.cfg["routing_timeout_seconds"])
        writer_ready_monotonic = time.monotonic()
        writer_ready_at = stamp()
        write_blocked_seconds = round(writer_ready_monotonic - self.write_block_started_monotonic, 3)
        self.journal.state["write_availability_window"] = {
            "started_at": self.write_block_started_at,
            "writer_ready_at": writer_ready_at,
            "duration_seconds": write_blocked_seconds,
            "start_boundary": "current primary SET PERSIST read_only=ON succeeded",
            "end_boundary": "ProxySQL roles are correct and a fresh app connection reaches the promoted DB with read_only=0",
        }
        # Capture the end timestamp before writing this result event or doing
        # post-promotion replication checks, so reporting time is not counted.
        self.journal.event("proxy_writer_ready", database=self.standby_name,
                           write_blocked_seconds=write_blocked_seconds,
                           write_blocked_started_at=self.write_block_started_at,
                           writer_ready_at=writer_ready_at)
        # Disabled migration-only SQS/Lambda drain. This block remains here as
        # source history, but this switchover no longer invokes the replay Lambda.
        # replay_result = {"status": "not_invoked_rollback" if self.restore_state else "disabled"}
        # if replay_enabled and not self.restore_state:
        #     self.journal.event("write_replay_recovery_started", function_name=replay_options["function_name"])
        #     try:
        #         replay_result = drain_aws(replay_options, self.journal.directory,
        #                                   self.cfg.get("aws", {}).get("region", "ap-northeast-2"))
        #     except Exception as error:
        #         replay_result = {"status": "invocation_unconfirmed", "drainComplete": False,
        #                          "errorType": type(error).__name__}
        #     self.journal.event("write_replay_recovery_finished", **replay_result)
        # self.journal.state["write_replay"] = replay_result
        # self.journal.state["requires_attention"] = (
        #     replay_enabled and not self.restore_state and not replay_result.get("drainComplete", False)
        # )
        # Give post-promotion replication verification its own budget so the
        # measured cutover deadline cannot interrupt verification of the new writer.
        self.deadline = None
        after = self.standby.scalar("SELECT @@GLOBAL.gtid_executed")
        new_gtids = self.standby.scalar("SELECT GTID_SUBTRACT(%s,%s)", (after, boundary["Executed_Gtid_Set"]))
        self.wait_gtids(self.primary, new_gtids)
        replica(self.primary, self.standby_cfg["uuid"])
        self.assert_fenced(self.primary)
        self.journal.state["status"] = "complete"
        self.journal.event("complete", primary=self.standby_name, standby=self.primary_name,
                           write_blocked_seconds=write_blocked_seconds,
                           replicated_post_promotion_gtids=new_gtids)


def load_previous(directory, command):
    path = Path(directory).resolve()
    state = json.loads((path / "state.json").read_text())
    require(state["status"] == "complete" and state["command"] == command, f"A successful {command} record is required")
    return path, state


def capture(flow, cfg, passwords):
    flow.preflight()
    journal = flow.journal
    # Schema dump preserves data for investigation; rollback never imports it or deletes test writes.
    source = cfg["source"]
    dump = journal.directory / "dump"
    expression = "util.dump_schemas(" + repr([cfg["schema"]]) + ", " + repr(str(dump)) + ", " + repr(
        {"consistent": True, "threads": 2, "maxRate": "10M", "checksum": True}) + ")"
    journal.event("dump_started")
    with open(journal.directory / "dump.log", "w") as log:
        result = subprocess.run(["mysqlsh", "--py", "--mysql", "--host=" + source["host"],
                                 "--port=" + str(source["port"]), "--user=" + source["user"],
                                 "--passwords-from-stdin", "--password", "--execute=" + expression],
                                input=passwords[source["password_env"]] + "\n", text=True,
                                stdout=log, stderr=subprocess.STDOUT, timeout=1800)
    require(result.returncode == 0 and (dump / "@.done.json").exists(), "Dump failed; inspect dump.log")
    metadata = json.loads((dump / "@.json").read_text())
    require(metadata.get("gtidExecuted") and metadata.get("binlogFile") and metadata.get("binlogPosition"),
            "Dump lacks its GTID/binlog boundary; check REPLICATION CLIENT privileges")
    journal.state["dump_metadata"] = {k: metadata[k] for k in ("gtidExecuted", "binlogFile", "binlogPosition")}
    journal.state["dump_sha256"] = {str(f.relative_to(dump)): hashlib.sha256(f.read_bytes()).hexdigest()
                                    for f in dump.rglob("*") if f.is_file()}
    journal.state["status"] = "complete"
    journal.event("capture_complete")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["check", "capture", "switch", "rollback", "restore"],
                        help="restore is a backwards-compatible alias for rollback")
    parser.add_argument("--config", required=True)
    parser.add_argument("--credentials-file", help="owner-only JSON file created by credential_store.py")
    parser.add_argument("--out", required=True, help="New directory; never overwrites an earlier run")
    parser.add_argument("--capture-dir", help="Successful capture required by switch")
    parser.add_argument("--switch-dir", help="Successful switch required by rollback")
    args = parser.parse_args()
    rollback = args.command in ("rollback", "restore")
    os.umask(0o077)
    cfg = json.loads(Path(args.config).read_text())
    require(cfg["source"]["uuid"] != cfg["target"]["uuid"], "Source and target must differ")
    prior = None
    if args.command == "switch":
        require(args.capture_dir, "--capture-dir is required")
        folder, prior = load_previous(args.capture_dir, "capture")
        for name, digest in prior["dump_sha256"].items():
            require(hashlib.sha256((folder / "dump" / name).read_bytes()).hexdigest() == digest, "Captured dump is incomplete/changed")
    if rollback:
        require(args.switch_dir, "--switch-dir is required")
        _, prior = load_previous(args.switch_dir, "switch")
    if prior:
        require(prior["identities"] == {n: cfg[n]["uuid"] for n in ("source", "target")}, "Record belongs to different databases")
        require(prior["schema"] == cfg["schema"], "Record belongs to a different schema")
    names = ["source", "target", "proxy_admin", "proxy_app"]
    if args.command == "switch" or rollback:
        names += ["forward_replication" if rollback else "reverse_replication"]
    required_passwords = [cfg[name]["password_env"] for name in names]
    saved_passwords = load_passwords(args.credentials_file, required_passwords) if args.credentials_file else {}
    journal = Journal(args.out, "rollback" if rollback else args.command)
    passwords, dbs = {}, {}
    try:
        for name in names:
            env = cfg[name]["password_env"]
            password = saved_passwords.get(env) if args.credentials_file else os.environ.get(env)
            if not password and not args.credentials_file:
                password = getpass.getpass(f"{name} ({cfg[name]['user']}) password: ")
            passwords[env] = password
            require(bool(passwords[env]), "Empty passwords are not accepted")
        for name in ("source", "target", "proxy_admin"):
            dbs[name] = DB(cfg[name], passwords[cfg[name]["password_env"]], cfg["query_timeout_seconds"])
        def app_connection(endpoint):
            app = cfg["proxy_app"]
            return DB({**endpoint, "user": app["user"]}, passwords[app["password_env"]], cfg["query_timeout_seconds"])
        flow = Switch(cfg, dbs, app_connection, passwords, journal, prior if rollback else None)
        if args.command == "capture":
            capture(flow, cfg, passwords)
        elif args.command == "check":
            flow.preflight()
            journal.state["status"] = "complete"
            journal.event("check_complete")
        else:
            flow.run()
    except (Exception, KeyboardInterrupt) as error:
        journal.state["status"] = "failed"
        last = journal.state["phase"]
        message = str(error)
        for password in passwords.values():
            message = message.replace(password, "[REDACTED]")
        journal.event("failed", stopped_after=last, error=message or type(error).__name__,
                      recovery="No automatic role rollback. Inspect actual read_only/replication state before recovery.")
        return 1
    finally:
        for db in dbs.values():
            try:
                db.close()
            except Exception:
                # A broken tunnel must not mask the recorded failure or prevent
                # releasing the remaining connections/advisory locks.
                pass
    return 0


if __name__ == "__main__":
    def interrupted(signum, frame):
        raise KeyboardInterrupt(f"signal {signum}")
    signal.signal(signal.SIGTERM, interrupted)
    sys.exit(main())
