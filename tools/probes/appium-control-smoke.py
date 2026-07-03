#!/usr/bin/env python3
import argparse
import base64
import json
import pathlib
import sys
import time
import urllib.error
import urllib.request


def request_json(method, url, payload=None, timeout=120):
    data = None
    headers = {"Content-Type": "application/json"}
    if payload is not None:
        data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as response:
            body = response.read().decode("utf-8")
    except urllib.error.HTTPError as error:
        body = error.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"{method} {url} failed: HTTP {error.code}\n{body}") from error
    except urllib.error.URLError as error:
        raise RuntimeError(f"{method} {url} failed: {error}") from error
    return json.loads(body) if body else {}


def create_session(args):
    caps = {
        "platformName": "iOS",
        "appium:automationName": "XCUITest",
        "appium:udid": args.udid,
        "appium:bundleId": args.bundle_id,
        "appium:noReset": True,
        "appium:mjpegServerPort": args.mjpeg_port,
        "appium:usePrebuiltWDA": args.use_prebuilt_wda,
        "appium:useNewWDA": args.use_new_wda,
        "appium:wdaStartupRetries": args.wda_startup_retries,
        "appium:wdaStartupRetryInterval": args.wda_startup_retry_interval_ms,
    }
    if args.xcode_org_id:
        caps["appium:xcodeOrgId"] = args.xcode_org_id
    if args.xcode_signing_id:
        caps["appium:xcodeSigningId"] = args.xcode_signing_id
    if args.wda_bundle_id:
        caps["appium:updatedWDABundleId"] = args.wda_bundle_id
    if args.show_xcode_log:
        caps["appium:showXcodeLog"] = True
    payload = {"capabilities": {"alwaysMatch": caps, "firstMatch": [{}]}}
    result = request_json("POST", f"{args.server.rstrip('/')}/session", payload)
    session_id = result.get("sessionId") or result.get("value", {}).get("sessionId")
    if not session_id:
        raise RuntimeError(f"Could not create session. Response:\n{json.dumps(result, indent=2)}")
    return session_id, result


def delete_session(server, session_id):
    try:
        request_json("DELETE", f"{server}/session/{session_id}", timeout=30)
    except Exception as error:
        print(f"warning: failed to delete session cleanly: {error}", file=sys.stderr)


def perform_tap(server, session_id, x, y):
    payload = {
        "actions": [
            {
                "type": "pointer",
                "id": "finger1",
                "parameters": {"pointerType": "touch"},
                "actions": [
                    {"type": "pointerMove", "duration": 0, "x": x, "y": y},
                    {"type": "pointerDown", "button": 0},
                    {"type": "pause", "duration": 100},
                    {"type": "pointerUp", "button": 0},
                ],
            }
        ]
    }
    request_json("POST", f"{server}/session/{session_id}/actions", payload)


def perform_swipe(server, session_id, start, end, duration_ms):
    payload = {
        "actions": [
            {
                "type": "pointer",
                "id": "finger1",
                "parameters": {"pointerType": "touch"},
                "actions": [
                    {"type": "pointerMove", "duration": 0, "x": start[0], "y": start[1]},
                    {"type": "pointerDown", "button": 0},
                    {"type": "pointerMove", "duration": duration_ms, "x": end[0], "y": end[1]},
                    {"type": "pointerUp", "button": 0},
                ],
            }
        ]
    }
    request_json("POST", f"{server}/session/{session_id}/actions", payload)


def save_screenshot(server, session_id, path):
    result = request_json("GET", f"{server}/session/{session_id}/screenshot", timeout=60)
    encoded = result.get("value")
    if not encoded:
        raise RuntimeError(f"No screenshot value in response:\n{json.dumps(result, indent=2)}")
    output = pathlib.Path(path)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_bytes(base64.b64decode(encoded))
    print(f"screenshot: {output}")


def parse_point(value):
    try:
        x_text, y_text = value.split(",", 1)
        return int(x_text), int(y_text)
    except ValueError as error:
        raise argparse.ArgumentTypeError("point must be X,Y") from error


def main():
    parser = argparse.ArgumentParser(description="Create an Appium/XCUITest session and run a small control smoke test.")
    parser.add_argument("--server", default="http://127.0.0.1:4723", help="Appium server URL")
    parser.add_argument("--udid", required=True, help="real iOS device UDID")
    parser.add_argument("--bundle-id", default="com.apple.Preferences", help="bundle id to launch")
    parser.add_argument("--mjpeg-port", type=int, default=9100, help="WDA MJPEG server port")
    parser.add_argument("--xcode-org-id", help="Apple developer Team ID for WDA signing")
    parser.add_argument("--xcode-signing-id", default="Apple Development", help="Xcode signing identity")
    parser.add_argument("--wda-bundle-id", help="custom WebDriverAgentRunner bundle id")
    parser.add_argument("--use-prebuilt-wda", action="store_true", help="reuse an already built/signed WebDriverAgentRunner")
    parser.add_argument("--use-new-wda", action="store_true", help="force Appium to uninstall and rebuild WDA")
    parser.add_argument("--wda-startup-retries", type=int, default=2, help="number of WDA startup retries")
    parser.add_argument("--wda-startup-retry-interval-ms", type=int, default=10000, help="WDA retry interval in milliseconds")
    parser.add_argument("--show-xcode-log", action="store_true", help="ask Appium to print xcodebuild logs")
    parser.add_argument("--tap", type=parse_point, help="tap point as X,Y")
    parser.add_argument("--swipe-from", dest="swipe_from", type=parse_point, help="swipe start point as X,Y")
    parser.add_argument("--swipe-to", dest="swipe_to", type=parse_point, help="swipe end point as X,Y")
    parser.add_argument("--swipe-duration-ms", type=int, default=500, help="swipe duration in milliseconds")
    parser.add_argument("--screenshot", help="write a screenshot to this path")
    args = parser.parse_args()

    server = args.server.rstrip("/")
    print(f"server: {server}")
    print("checking /status...")
    print(json.dumps(request_json("GET", f"{server}/status", timeout=10), indent=2, ensure_ascii=False))

    session_id = None
    started_at = time.time()
    try:
        session_id, response = create_session(args)
        print(f"session: {session_id}")
        print(f"session startup seconds: {time.time() - started_at:.2f}")
        print(json.dumps(response.get("value", {}), indent=2, ensure_ascii=False))

        if args.tap:
            print(f"tap: {args.tap}")
            perform_tap(server, session_id, args.tap[0], args.tap[1])

        if args.swipe_from or args.swipe_to:
            if not args.swipe_from or not args.swipe_to:
                raise RuntimeError("--swipe-from and --swipe-to must be used together")
            print(f"swipe: {args.swipe_from} -> {args.swipe_to}")
            perform_swipe(server, session_id, args.swipe_from, args.swipe_to, args.swipe_duration_ms)

        if args.screenshot:
            save_screenshot(server, session_id, args.screenshot)
    finally:
        if session_id:
            delete_session(server, session_id)


if __name__ == "__main__":
    main()
