#!/usr/bin/env python3
"""Exercise SSE reconnection against a local fake server; never contacts the application."""
import argparse
import datetime as dt
import json
import subprocess
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlsplit

ROOT = Path(__file__).resolve().parent
generation = 0
source_delay_seconds = 5


def payload(code, book=False):
    stamp = dt.datetime.now(dt.timezone.utc) - dt.timedelta(seconds=source_delay_seconds)
    data = {"code": code, "timestamp": stamp.isoformat(), "price": 100}
    if book:
        data.update(asks=[{"price": 101 + n, "qty": 1} for n in range(10)],
                    bids=[{"price": 99 - n, "qty": 1} for n in range(10)])
    return data


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_):
        pass

    def do_GET(self):
        url = urlsplit(self.path)
        codes = parse_qs(url.query).get("codes", [""])[0].split(",")
        book = "orderbooks" in url.path
        self.send_response(200)
        if not url.path.endswith("/stream"):
            # An empty price snapshot is valid; live SSE ticks can still follow.
            body = json.dumps([payload(code, book) for code in codes] if book else []).encode()
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.end_headers()
        opened_generation = generation
        try:
            while opened_generation == generation:
                for code in codes:
                    body = json.dumps(payload(code, book))
                    self.wfile.write(f"event: {'orderbook' if book else 'price'}\ndata: {body}\n\n".encode())
                self.wfile.flush()
                time.sleep(0.05)
        except (BrokenPipeError, ConnectionResetError):
            pass
        finally:
            self.close_connection = True


def cli(*args):
    process = subprocess.run(["python3", str(ROOT / "fis.py"), *args], capture_output=True, text=True)
    if process.returncode:
        raise RuntimeError(process.stdout + process.stderr)
    return json.loads(process.stdout)


def main():
    global generation, source_delay_seconds
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", default="/usr/local/bin/k6-sse")
    args = parser.parse_args()
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    server.daemon_threads = True
    threading.Thread(target=server.serve_forever, daemon=True).start()
    folder = None
    try:
        with tempfile.TemporaryDirectory(prefix="fis-local-fixture-") as temp:
            codes = Path(temp) / "fixture-codes.txt"
            codes.write_text("\n".join(f"{i:06}" for i in range(14)))
            plan = Path(temp) / "plan.json"
            cli("plan", "--base-url", f"http://127.0.0.1:{server.server_port}/market", "--connections", "5",
                "--ramp", "1", "--baseline", "2", "--fault-wait", "8", "--observe", "4",
                "--price-codes", str(codes), "--orderbook-codes", str(codes), "--output", str(plan))
            folder = Path(cli("start", "--plan", str(plan), "--binary", args.binary)["run"])
            deadline = time.monotonic() + 25
            fault_recorded = False
            while time.monotonic() < deadline:
                status = json.loads((folder / "status.json").read_text())
                if status.get("ready_for_manual_fault") and not fault_recorded:
                    assert status["clients_with_fresh_data"] == 0, status
                    at = dt.datetime.now(dt.timezone.utc).isoformat()
                    source_delay_seconds = 0
                    generation += 1  # Close only localhost fake SSE connections.
                    cli("mark", "--run", str(folder), "--event", "fault-start", "--at", at,
                        "--experiment-id", "EXPLOCALFIXTURE", "--note", "loopback fake disconnect, not AWS FIS")
                    fault_recorded = True
                if not status.get("running"):
                    break
                time.sleep(0.2)
            result = json.loads((folder / "result.json").read_text())
            assert fault_recorded, status
            assert result["affected_clients"] == 5, result
            assert result["advancing_data_recovered_episodes"] == 5, result
            assert result["fresh_data_recovered_episodes"] == 5, result
            assert not result["unrecovered"], result
            assert "NOT_MEASURED" in result["latest_quote_recovery"]
            print(json.dumps({"fixture": "localhost only", "result": "passed", "run": str(folder),
                              "affected": result["affected_clients"], "recovered": result["advancing_data_recovered_episodes"],
                              "fresh_recovered": result["fresh_data_recovered_episodes"],
                              "aws_operations": 0, "application_requests": 0}))
    finally:
        if folder and (folder / "status.json").exists():
            if json.loads((folder / "status.json").read_text()).get("running"):
                cli("stop", "--run", str(folder))
        server.shutdown()


if __name__ == "__main__":
    main()
