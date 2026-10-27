"""Pure planning and analysis helpers. No network or AWS operations."""
import hashlib
import json
import math
import re
from pathlib import Path
from urllib.parse import urlsplit

GROUPS = {
    "home_prices": (333, "prices", 5),
    "watchlist_prices": (95, "prices", 14),
    "detail_prices": (333, "prices", 1),
    "order_prices": (238, "prices", 1),
    "orderbooks": (238, "orderbooks", 1),
}


def allocation(total):
    denominator = sum(row[0] for row in GROUPS.values())
    counts = {key: total * row[0] // denominator for key, row in GROUPS.items()}
    ranked = sorted(GROUPS, key=lambda key: -(total * GROUPS[key][0] % denominator))
    for key in ranked[:total - sum(counts.values())]:
        counts[key] += 1
    return counts


def read_codes(path, minimum):
    raw = Path(path).read_bytes()
    codes = [line.strip() for line in raw.decode().splitlines()
             if line.strip() and not line.lstrip().startswith("#")]
    if len(codes) < minimum or len(set(codes)) != len(codes):
        raise ValueError(f"{path}: require at least {minimum} unique codes")
    if any(not re.fullmatch(r"[A-Z0-9]{6}", code) for code in codes):
        raise ValueError(f"{path}: codes must have six uppercase letters/digits")
    return codes, hashlib.sha256(raw).hexdigest()


def validate_url(value):
    url = urlsplit(value)
    local = url.hostname in {"127.0.0.1", "localhost", "::1"}
    if (url.username or url.password or url.query or url.fragment
            or (not local and (url.scheme != "https" or url.hostname != "stock-spoon.com"
                               or url.port not in (None, 443) or url.path.rstrip("/") != "/market"))
            or (local and url.scheme not in {"http", "https"})):
        raise ValueError("use https://stock-spoon.com/market or an explicit loopback fixture URL")


def validate_plan(plan):
    validate_url(plan["base_url"])
    if plan.get("experiment", "T1") not in {"T1", "T2", "T3", "R1", "R2", "R3"}:
        raise ValueError("invalid experiment label")
    if (plan.get("schema") != 1 or plan["mode"] not in {"baseline", "fault"}
            or not 5 <= plan["connections"] <= 2000 or not 1 <= plan["budget_seconds"] <= 7200):
        raise ValueError("invalid plan scope or execution budget")
    if sum(row["connections"] for row in plan["groups"].values()) != plan["connections"]:
        raise ValueError("scenario connection counts do not match the plan")
    for name, row in plan["groups"].items():
        if (name not in GROUPS or row["connections"] < 1 or row["stream"] != GROUPS[name][1]
                or row["code_count"] != GROUPS[name][2]):
            raise ValueError("invalid scenario")
        codes = plan["codes"][row["stream"]]
        if len(codes) < row["code_count"] or len(codes) != len(set(codes)):
            raise ValueError("insufficient or duplicate codes")
        if any(not re.fullmatch(r"[A-Z0-9]{6}", code) for code in codes):
            raise ValueError("invalid codes")
    if (not 1 <= plan["ramp_seconds"] < plan["budget_seconds"]
            or plan["baseline_seconds"] < 1 or plan["observe_seconds"] < 1
            or plan["fault_wait_seconds"] < 1 or plan["snapshot_interval_ms"] < 1000
            or not 0 < plan["retry_min_ms"] <= plan["retry_max_ms"] <= 30000):
        raise ValueError("invalid timing")
    if (not 1 <= plan.get("max_source_age_ms", 0) <= 60000
            or not 0 <= plan.get("max_future_skew_ms", -1) <= 1000):
        raise ValueError("invalid source freshness or clock skew bound; regenerate old plans")


def make_plan(args):
    if not 5 <= args.connections <= 2000:
        raise ValueError("connections must be between 5 and 2000")
    validate_url(args.base_url)
    for name in ("ramp", "baseline", "fault_wait", "observe"):
        if not 1 <= getattr(args, name) <= 3600:
            raise ValueError(f"{name} must be 1..3600 seconds")
    prices, price_hash = read_codes(args.price_codes, 14)
    books, book_hash = read_codes(args.orderbook_codes, 1)
    counts = allocation(args.connections)
    budget = args.ramp + args.baseline
    if args.mode == "fault":
        budget += args.fault_wait + args.observe
    if budget > 7200:
        raise ValueError("total execution budget must not exceed two hours")
    return {
        "schema": 1, "experiment": getattr(args, "experiment", "T1"), "mode": args.mode, "base_url": args.base_url.rstrip("/"),
        "connections": args.connections, "ramp_seconds": args.ramp,
        "baseline_seconds": args.baseline, "fault_wait_seconds": args.fault_wait,
        "observe_seconds": args.observe, "budget_seconds": budget,
        "codes": {"prices": prices, "orderbooks": books},
        "code_hashes": {"prices": price_hash, "orderbooks": book_hash},
        "groups": {key: {"connections": counts[key], "stream": row[1], "code_count": row[2]}
                   for key, row in GROUPS.items() if counts[key]},
        "retry_min_ms": 1000, "retry_max_ms": 3000, "snapshot_interval_ms": 5000,
        "source_age_sample_every": 20,
        "max_source_age_ms": getattr(args, "max_source_age_ms", 1000),
        "max_future_skew_ms": 100,
        "scope": "read-only REST/SSE client; no AWS calls or fault injection",
        "evaluation_policy": "exploratory; no predefined recovery or latency pass/fail thresholds",
        "latest_quote_watermark": "not configured; first advancing event is measured separately",
    }


def event_lines(lines):
    for line in lines:
        if "FIS_EVENT " not in line:
            continue
        yield json.loads(line.split("FIS_EVENT ", 1)[1])


def distribution(values):
    values = sorted(values)
    if not values:
        return {"count": 0, "p50_ms": None, "p95_ms": None, "p99_ms": None, "max_ms": None}
    return {"count": len(values), **{
        f"p{percent}_ms": values[max(0, math.ceil(len(values) * percent / 100) - 1)]
        for percent in (50, 95, 99)}, "max_ms": values[-1]}


class State:
    def __init__(self, max_source_age_ms=1000, max_future_skew_ms=100, sample_ttl_ms=15000):
        self.clients = {}
        self.bad_payloads = 0
        self.errors = 0
        self.events = 0
        self.max_source_age_ms = max_source_age_ms
        self.max_future_skew_ms = max_future_skew_ms
        self.sample_ttl_ms = sample_ttl_ms

    def feed(self, event):
        self.events += 1
        client = self.clients.setdefault(str(event["client_id"]), {})
        if event["kind"] == "bad_payload":
            self.bad_payloads += 1
        if event["kind"] in {"transport_error", "initial_rest_error"}:
            self.errors += 1
        if event["kind"] in {"connected", "snapshot"}:
            client.update(event)
            client["connected"] = True
        elif event["kind"] in {"disconnected", "session_ended"}:
            client.update(event)
            client["connected"] = False

    def snapshot(self, now_ms):
        connected = [row for row in self.clients.values() if row.get("connected")]
        advancing = [row for row in connected if row.get("post_initial_updates", 0) > 0]
        fresh = [row for row in connected if row.get("oldest_advancing_source_ms") is not None
                 and now_ms - row["at_ms"] <= self.sample_ttl_ms
                 and row["at_ms"] - row["oldest_advancing_source_ms"] <= self.max_source_age_ms
                 and row["newest_advancing_source_ms"] - row["at_ms"] <= self.max_future_skew_ms]
        return {
            "observed_clients": len(self.clients), "connected_clients": len(connected),
            "clients_with_advancing_data": len(advancing), "bad_payloads": self.bad_payloads,
            "transport_or_rest_errors": self.errors, "events_processed": self.events,
            "clients_with_fresh_data": len(fresh),
            "connected_without_fresh_data": len(connected) - len(fresh),
            "max_data_silence_ms": max((now_ms - row["last_update_ms"] for row in advancing), default=None),
        }


def report(events, markers, end_ms, reason, max_source_age_ms=1000):
    fault = next((m for m in markers if m["event"] == "fault-start"), None)
    fault_ms = fault["at_ms"] if fault else None
    cohort = set()
    current = set()
    captured = False
    outages = {}
    for e in sorted(events, key=lambda row: row["at_ms"]):
        if e["at_ms"] >= end_ms:
            continue
        client = str(e["client_id"])
        if fault_ms is not None and e["at_ms"] >= fault_ms and not captured:
            cohort = current.copy()
            captured = True
        if e["kind"] == "connected":
            current.add(client)
        elif e["kind"] in {"disconnected", "session_ended"}:
            current.discard(client)
        oid = e.get("outage_id")
        if not oid or fault_ms is None:
            continue
        key = (client, oid)
        if e["kind"] == "disconnected" and e["at_ms"] >= fault_ms and client in cohort:
            outages.setdefault(key, {"client_id": client, "outage_id": oid,
                                     "disconnect_ms": e["at_ms"], "last_update_ms": e.get("last_update_ms")})
        elif key in outages and e["kind"] == "reconnected":
            outages[key].setdefault("connected_ms", e["at_ms"])
        elif key in outages and e["kind"] == "recovery_update":
            outages[key].setdefault("update_ms", e["at_ms"])
            outages[key].setdefault("source_age_ms", e["source_age_ms"])
        elif key in outages and e["kind"] == "fresh_recovery":
            outages[key].setdefault("fresh_ms", e["at_ms"])
            outages[key].setdefault("fresh_source_age_ms", e["max_source_age_ms"])
    if fault_ms is not None and not captured:
        cohort = current.copy()
    rows = list(outages.values())
    connected = [r["connected_ms"] - r["disconnect_ms"] for r in rows if "connected_ms" in r]
    updated = [r["update_ms"] - r["disconnect_ms"] for r in rows if "update_ms" in r]
    fresh = [r["fresh_ms"] - r["disconnect_ms"] for r in rows if "fresh_ms" in r]
    fresh_pending = [{**r, "freshness_unrecovered_for_at_least_ms": end_ms - r["disconnect_ms"]}
                     for r in rows if "fresh_ms" not in r]
    gaps = [r["update_ms"] - r["last_update_ms"] for r in rows
            if "update_ms" in r and r.get("last_update_ms") is not None]
    pending = [{**r, "unrecovered_for_at_least_ms": end_ms - r["disconnect_ms"]}
               for r in rows if "update_ms" not in r]
    times = {m["event"]: m["at_ms"] for m in markers if m["event"] != "note"}
    capacity = (times["capacity-restored"] - fault_ms
                if fault_ms is not None and "capacity-restored" in times else None)
    if reason.startswith("safety:"):
        outcome = "ABORTED_SAFETY"
    elif fault is None:
        outcome = "NOT_STARTED"
    elif not cohort or not rows:
        outcome = "INCONCLUSIVE"
    elif pending:
        outcome = "WINDOW_ENDED"
    else:
        outcome = "MEASURED"
    return {
        "outcome": outcome, "stop_reason": reason, "fault": fault,
        "evaluation_policy": "exploratory; measurement status is not a pass/fail verdict",
        "freshness_reference_only": True,
        "baseline_connected_cohort": len(cohort), "affected_clients": len({r["client_id"] for r in rows}),
        "disconnect_episodes": len(rows), "reconnected_episodes": len(connected),
        "advancing_data_recovered_episodes": len(updated), "unrecovered": pending,
        "reconnection_rate": len(connected) / len(rows) if rows else None,
        "advancing_data_recovery_rate": len(updated) / len(rows) if rows else None,
        "fresh_data_recovery_rate": len(fresh) / len(rows) if rows else None,
        "fresh_data_recovered_episodes": len(fresh), "fresh_data_unrecovered": fresh_pending,
        "reconnection": {"population": "observed recovered episodes", **distribution(connected)},
        "first_advancing_data": {"population": "observed recovered episodes", **distribution(updated)},
        "fresh_data": {"population": "episodes with all subscribed codes advancing and fresh",
                       "max_source_age_ms": max_source_age_ms, **distribution(fresh)},
        "fault_to_fresh_data": distribution([r["fresh_ms"] - fault_ms for r in rows if "fresh_ms" in r]),
        "data_gap": {"population": "observed recovered episodes with prior data", **distribution(gaps)},
        "whole_population_percentiles_available": bool(rows) and not pending,
        "fresh_population_percentiles_available": bool(rows) and not fresh_pending,
        "task_capacity_recovery_ms": capacity,
        "task_stop_delay_ms": times.get("task-stopped", 0) - fault_ms
        if fault_ms is not None and "task-stopped" in times else None,
        "latest_quote_recovery": "NOT_MEASURED: upstream watermark required",
        "safety_coverage": "generator/bad payload only; ECS/Valkey/FIS stop guard is external",
        "episodes": rows, "measurement_end_ms": end_ms,
    }
