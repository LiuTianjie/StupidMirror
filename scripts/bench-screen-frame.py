#!/usr/bin/env python3
"""Measure screen_frame latency against the running StupidMirror app.

Polls screen_frame the way the Codex panel and viewer do (known shell_id,
include_frame true, after_seq advancing) and prints latency percentiles.
The MainActor tool router answers screen_frame, so slow calls here mean
the app's main thread is busy.

  python3 -I scripts/bench-screen-frame.py [--seconds 20] [--interval 0.1] [--no-frame] [device_id ...]

With no device ids it polls every device whose mirror is running.
"""

import argparse
import json
import pathlib
import statistics
import sys
import threading
import time
import urllib.request

CONNECTION = pathlib.Path.home() / "Library/Application Support/StupidMirror/MCP/connection.json"


class Client:
    def __init__(self):
        record = json.loads(CONNECTION.read_text())
        self.endpoint = record["endpoint"]
        self.token = record["bearerToken"]
        self.session = None
        self.next_id = 1
        self.lock = threading.Lock()
        self.request("initialize", {
            "protocolVersion": "2025-06-18",
            "capabilities": {},
            "clientInfo": {"name": "bench-screen-frame", "version": "1"},
        })
        self.post({"jsonrpc": "2.0", "method": "notifications/initialized"})

    def post(self, body):
        headers = {
            "Authorization": f"Bearer {self.token}",
            "Content-Type": "application/json",
            "Accept": "application/json, text/event-stream",
            "MCP-Protocol-Version": "2025-06-18",
        }
        if self.session:
            headers["Mcp-Session-Id"] = self.session
        request = urllib.request.Request(self.endpoint, json.dumps(body).encode(), headers, method="POST")
        with urllib.request.urlopen(request, timeout=30) as response:
            self.session = response.headers.get("Mcp-Session-Id") or self.session
            raw = response.read().decode()
        if not raw.strip():
            return None
        if raw.lstrip().startswith("{"):
            return json.loads(raw)
        for line in raw.splitlines():
            if line.startswith("data:") and line[5:].strip():
                return json.loads(line[5:])
        return None

    def request(self, method, params):
        with self.lock:
            request_id = self.next_id
            self.next_id += 1
        reply = self.post({"jsonrpc": "2.0", "id": request_id, "method": method, "params": params})
        if reply is None or "error" in reply:
            raise RuntimeError(f"{method} failed: {reply}")
        return reply["result"]

    def tool(self, name, arguments):
        result = self.request("tools/call", {"name": name, "arguments": arguments})
        return result.get("structuredContent") or {}


def poll(client, device_id, deadline, interval, include_frame, samples):
    shell_id = None
    after_seq = 0
    while time.monotonic() < deadline:
        arguments = {"device_id": device_id, "after_seq": after_seq, "include_frame": include_frame}
        if shell_id:
            arguments["shell_id"] = shell_id
        started = time.monotonic()
        try:
            state = client.tool("screen_frame", arguments)
        except Exception as error:  # noqa: BLE001 - report and keep polling
            print(f"{device_id}: {error}", file=sys.stderr)
            continue
        elapsed = (time.monotonic() - started) * 1000
        shell = state.get("shell") or {}
        frame = state.get("frame") or {}
        if shell_id is None:
            shell_id = shell.get("id")
        else:
            samples.append(elapsed)
        after_seq = frame.get("seq", after_seq)
        time.sleep(interval)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("devices", nargs="*")
    parser.add_argument("--seconds", type=float, default=20)
    parser.add_argument("--interval", type=float, default=0.1)
    parser.add_argument("--no-frame", action="store_true",
                        help="include_frame false, as the panel sends while WebRTC video is live")
    args = parser.parse_args()

    client = Client()
    devices = args.devices
    if not devices:
        listed = client.tool("list_devices", {}).get("devices", [])
        devices = [d["device_id"] for d in listed if d.get("mirror_state") == "running"]
    if not devices:
        sys.exit("No running mirrors; pass device ids or start show_screen first.")

    deadline = time.monotonic() + args.seconds
    results = {device: [] for device in devices}
    threads = [
        threading.Thread(target=poll, args=(client, device, deadline, args.interval, not args.no_frame, results[device]))
        for device in devices
    ]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join()

    every = [ms for samples in results.values() for ms in samples]
    for device, samples in list(results.items()) + [("all", every)]:
        if not samples:
            print(f"{device}: no samples")
            continue
        ordered = sorted(samples)
        p = lambda q: ordered[min(len(ordered) - 1, int(q * len(ordered)))]  # noqa: E731
        print(
            f"{device}: n={len(ordered)} median={statistics.median(ordered):.1f}ms "
            f"p95={p(0.95):.1f}ms p99={p(0.99):.1f}ms max={ordered[-1]:.1f}ms "
            f"over100ms={sum(ms > 100 for ms in ordered)}"
        )


if __name__ == "__main__":
    main()
