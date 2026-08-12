#!/usr/bin/env python3
"""
vector_status.py — Query Anki Vector robot status via gRPC / REST gateway.

Connects to a Vector robot on the local network and retrieves:
  - Battery state (level, charging status, voltage)
  - Version state (OS, firmware, serial number)
  - Robot state (pose, on-charger, carrying state)

Uses the gRPC-gateway REST endpoints exposed on port 443.
Requires the robot's TLS certificate for certificate pinning and an
authentication GUID (client_token_guid).

Usage:
    python vector_status.py <robot-ip> --cert <path> --guid <guid>
    python vector_status.py <robot-ip> --cert <path> --guid <guid> --json

Credentials:
    The robot certificate and GUID are obtained during BLE onboarding.
    - The cert is stored at ~/.anki_vector/Vector-XXXX-<serial>.cert
      (when using the official anki_vector SDK), or transferred via
      BLE RTS protocol during pairing.
    - The GUID is returned by the UserAuthentication RPC after
      authenticating with a cloud session token or wire-pod.

Requires:
    pip install requests   (for REST fallback)
    pip install grpcio     (for raw gRPC, preferred)
"""

from __future__ import annotations

import argparse
import json
import os
import ssl
import sys
from datetime import datetime
from typing import Any, Optional
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

# ---------------------------------------------------------------------------
# Fix sys.path: omnigent's Python 3.12 site-packages may shadow our venv
# ---------------------------------------------------------------------------
for p in list(sys.path):
    if "omnigent" in p and "site-packages" in p:
        sys.path.remove(p)


# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
DEFAULT_PORT = 443
VECTOR_SDK_DIR = os.path.expanduser("~/.anki_vector")
_DEFAULT_TIMEOUT = 10  # seconds
_timeout: float = _DEFAULT_TIMEOUT  # mutable by main()


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
def _find_cert(robot_name: str) -> Optional[str]:
    """Try to find a robot certificate from the official SDK directory."""
    if not os.path.isdir(VECTOR_SDK_DIR):
        return None
    for fname in os.listdir(VECTOR_SDK_DIR):
        if fname.startswith(robot_name) and fname.endswith(".cert"):
            return os.path.join(VECTOR_SDK_DIR, fname)
    return None


def _create_ssl_context(cert_path: str) -> ssl.SSLContext:
    """Create an SSL context with robot certificate pinning.

    Uses the robot's self-signed certificate as the trusted CA.
    This pins the TLS connection to the specific robot's certificate.
    """
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_REQUIRED
    ctx.load_verify_locations(cafile=cert_path)
    return ctx


def _post_json(
    url: str, payload: dict, cert_path: str, guid: str
) -> dict[str, Any]:
    """Send a JSON POST request to the gRPC-gateway REST endpoint.

    The robot's vic-gateway serves gRPC-gateway REST endpoints for
    all RPCs annotated with google.api.http in the proto file.
    Authentication is via the client_token_guid in the Authorization header.
    """
    data = json.dumps(payload).encode("utf-8")
    req = Request(
        url,
        data=data,
        headers={
            "Content-Type": "application/json",
            "Authorization": f"Bearer {guid}",
        },
        method="POST",
    )

    ctx = _create_ssl_context(cert_path)

    try:
        with urlopen(req, context=ctx, timeout=_timeout) as resp:
            body = resp.read().decode("utf-8")
            return json.loads(body)
    except HTTPError as e:
        body = e.read().decode("utf-8", errors="replace") if e.fp else ""
        raise RuntimeError(
            f"HTTP {e.code} from robot: {body[:500]}"
        ) from e
    except URLError as e:
        raise RuntimeError(f"Connection failed: {e.reason}") from e


# ---------------------------------------------------------------------------
# Status RPC calls
# ---------------------------------------------------------------------------
def get_battery_state(host: str, port: int, cert_path: str, guid: str) -> dict:
    """Call BatteryState RPC via REST gateway.

    Returns raw protobuf-JSON response with fields like:
      - battery_level (enum: LOW, NOMINAL, FULL)
      - battery_volts (float)
      - is_charging (bool)
      - is_on_charger_platform (bool)
      - suggested_charger_sec (float)
      - status (enum: CHARGING, DISCHARGING, ON_CHARGER)
    """
    url = f"https://{host}:{port}/v1/battery_state"
    return _post_json(url, {}, cert_path, guid)


def get_version_state(host: str, port: int, cert_path: str, guid: str) -> dict:
    """Call VersionState RPC via REST gateway.

    Returns raw protobuf-JSON response with fields like:
      - os_version (string)
      - engine_build_id (string)
      - robot_serial (string)
    """
    url = f"https://{host}:{port}/v1/version_state"
    return _post_json(url, {}, cert_path, guid)


def get_robot_state(host: str, port: int, cert_path: str, guid: str) -> dict:
    """Request robot state via EventStream.

    Subscribes briefly to the EventStream to capture the current
    RobotState event.  This is a streaming endpoint but we only read
    the first RobotState event.
    """
    # The EventStream REST endpoint sends newline-delimited JSON.
    # We poll briefly for the first RobotState event.
    url = f"https://{host}:{port}/v1/event_stream"
    payload = {
        "whiteList": {
            "list": ["robot_state"]
        },
        "connectionId": f"vector_status_{int(datetime.now().timestamp())}",
    }
    data = json.dumps(payload).encode("utf-8")
    req = Request(
        url,
        data=data,
        headers={
            "Content-Type": "application/json",
            "Authorization": f"Bearer {guid}",
        },
        method="POST",
    )

    ctx = _create_ssl_context(cert_path)

    try:
        with urlopen(req, context=ctx, timeout=_timeout) as resp:
            # Read first line of newline-delimited JSON stream
            chunk = resp.read(4096)
            lines = chunk.decode("utf-8").strip().split("\n")
            for line in lines:
                if "robotState" in line.lower() or "robot_state" in line.lower():
                    return json.loads(line)
            # Return raw first event
            if lines:
                return json.loads(lines[0])
            return {"note": "no robot_state event received in first chunk"}
    except HTTPError as e:
        body = e.read().decode("utf-8", errors="replace") if e.fp else ""
        raise RuntimeError(
            f"HTTP {e.code} from robot: {body[:500]}"
        ) from e
    except URLError as e:
        raise RuntimeError(f"Connection failed: {e.reason}") from e


# ---------------------------------------------------------------------------
# Display helpers
# ---------------------------------------------------------------------------
BATTERY_LEVEL_MAP = {
    0: "UNKNOWN",
    1: "LOW",
    2: "NOMINAL",
    3: "FULL",
}

BATTERY_STATUS_MAP = {
    0: "UNKNOWN",
    1: "CHARGING",
    2: "ON_CHARGER",
    3: "DISCHARGING",
}


def _safe_get(d: dict, *keys: str, default: Any = None) -> Any:
    """Safely traverse nested dict keys."""
    for k in keys:
        if isinstance(d, dict):
            d = d.get(k, default)
        else:
            return default
    return d


def print_status(
    host: str,
    port: int,
    battery: Optional[dict],
    version: Optional[dict],
    robot_state: Optional[dict],
    cert_path: str,
) -> None:
    """Print status in human-readable format."""
    now = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    print(f"Vector Robot Status — {now}")
    print(f"  Host:           {host}:{port}")
    print(f"  Certificate:    {cert_path}")
    print()

    # ---- Battery ----
    if battery:
        level_val = battery.get("batteryLevel", battery.get("battery_level", "?"))
        if isinstance(level_val, int):
            level = BATTERY_LEVEL_MAP.get(level_val, str(level_val))
        else:
            level = level_val

        volts = battery.get("batteryVolts", battery.get("battery_volts", "?"))
        charging = battery.get("isCharging", battery.get("is_charging", False))
        on_platform = battery.get(
            "isOnChargerPlatform", battery.get("is_on_charger_platform", False)
        )
        status_val = battery.get("status", "?")
        if isinstance(status_val, int):
            status = BATTERY_STATUS_MAP.get(status_val, str(status_val))
        else:
            status = status_val

        charger_sec = battery.get(
            "suggestedChargerSec", battery.get("suggested_charger_sec", "?")
        )

        print("  ── Battery ──")
        print(f"    Level:         {level}")
        print(f"    Voltage:       {volts}V")
        print(f"    Charging:      {charging}")
        print(f"    On Charger:    {on_platform}")
        print(f"    Status:        {status}")
        if isinstance(charger_sec, (int, float)):
            print(f"    Time to empty: {charger_sec:.0f}s")
        print()

    # ---- Version ----
    if version:
        os_ver = _safe_get(version, "osVersion", "os_version", default="?")
        engine = _safe_get(version, "engineBuildId", "engine_build_id", default="?")
        serial = _safe_get(version, "robotSerial", "robot_serial", default="?")

        print("  ── Version ──")
        print(f"    OS:            {os_ver}")
        print(f"    Engine build:  {engine}")
        print(f"    Serial:        {serial}")
        print()

    # ---- Robot State ----
    if robot_state:
        event = robot_state.get("event", robot_state)
        robot = event.get("robotState", event.get("robot_state", event))

        if isinstance(robot, dict):
            pose = robot.get("pose", {})
            if pose:
                x = pose.get("x", "?")
                y = pose.get("y", "?")
                z = pose.get("z", "?")
                print("  ── Pose ──")
                print(f"    X:             {x}")
                print(f"    Y:             {y}")
                print(f"    Z (angle):     {z}")
                print()

            carrying = robot.get("carryingObjectID", robot.get(
                "carrying_object_id", "?"
            ))
            head_angle = robot.get(
                "headAngleRad", robot.get("head_angle_rad", "?")
            )
            lift_height = robot.get(
                "liftHeightMm", robot.get("lift_height_mm", "?")
            )

            print("  ── State ──")
            print(f"    Carrying:      {carrying}")
            print(f"    Head angle:    {head_angle} rad")
            print(f"    Lift height:   {lift_height} mm")
            print()


def print_status_json(
    host: str,
    port: int,
    battery: Optional[dict],
    version: Optional[dict],
    robot_state: Optional[dict],
) -> None:
    """Print status as JSON."""
    output = {
        "host": host,
        "port": port,
        "battery": battery,
        "version": version,
        "robot_state": robot_state,
    }
    print(json.dumps(output, indent=2, default=str))


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
def main() -> None:
    parser = argparse.ArgumentParser(
        description="Query Anki Vector robot status via gRPC/REST gateway",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  python vector_status.py 192.168.1.42 --cert ~/.anki_vector/Vector-A1B2-00e00000.cert --guid abc123def
  python vector_status.py vector-a1b2.local --cert robot.cert --guid abc123def
  python vector_status.py 192.168.1.42 --cert robot.cert --guid abc123def --json

Credentials:
  The robot certificate and GUID are obtained during BLE onboarding.
  If you used the official anki_vector SDK before, certificates can be
  found in ~/.anki_vector/.
""",
    )
    parser.add_argument(
        "host",
        help="Robot IP address or hostname (e.g., 192.168.1.42 or vector-a1b2.local)",
    )
    parser.add_argument(
        "--port",
        type=int,
        default=DEFAULT_PORT,
        help=f"gRPC/REST gateway port (default: {DEFAULT_PORT})",
    )
    parser.add_argument(
        "--cert",
        help="Path to robot's TLS certificate (.cert file). Auto-detected from ~/.anki_vector/ if omitted.",
    )
    parser.add_argument(
        "--guid",
        default=os.environ.get("VECTOR_GUID", ""),
        help="Client token GUID for authentication (or set VECTOR_GUID env var)",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="Output results as JSON",
    )
    parser.add_argument(
        "--timeout",
        type=float,
        default=_DEFAULT_TIMEOUT,
        help=f"Request timeout in seconds (default: {_DEFAULT_TIMEOUT})",
    )
    args = parser.parse_args()

    global _timeout
    _timeout = args.timeout

    # Resolve hostname to a display name for cert auto-detection
    host_display = args.host
    robot_name = args.host.split(".")[0]  # e.g., "Vector-A1B2" from hostname

    # --- Certificate resolution ---
    cert_path = args.cert
    if not cert_path:
        cert_path = _find_cert(robot_name)
        if cert_path:
            print(f"Auto-detected certificate: {cert_path}", file=sys.stderr)
        else:
            print(
                "error: No certificate specified and none found in ~/.anki_vector/.\n"
                "The robot's TLS certificate is required for secure connection.\n"
                "Obtain it during BLE onboarding, or provide it with --cert.",
                file=sys.stderr,
            )
            sys.exit(1)

    if not os.path.isfile(cert_path):
        print(f"error: Certificate file not found: {cert_path}", file=sys.stderr)
        sys.exit(1)

    # --- GUID resolution ---
    guid = args.guid
    if not guid:
        print(
            "error: No authentication GUID provided.\n"
            "Set VECTOR_GUID environment variable or use --guid.\n"
            "The GUID is returned by the UserAuthentication RPC during onboarding.\n"
            "If using wire-pod, the GUID is provided after pairing.",
            file=sys.stderr,
        )
        sys.exit(1)

    # --- Attempt status queries ---
    battery = None
    version = None
    robot_state = None
    errors: list[str] = []

    print(f"Connecting to {host_display}:{args.port} ...\n", file=sys.stderr)

    try:
        battery = get_battery_state(args.host, args.port, cert_path, guid)
        print("  ✓ Battery state retrieved", file=sys.stderr)
    except Exception as e:
        errors.append(f"BatteryState: {e}")

    try:
        version = get_version_state(args.host, args.port, cert_path, guid)
        print("  ✓ Version state retrieved", file=sys.stderr)
    except Exception as e:
        errors.append(f"VersionState: {e}")

    try:
        robot_state = get_robot_state(args.host, args.port, cert_path, guid)
        print("  ✓ Robot state retrieved", file=sys.stderr)
    except Exception as e:
        errors.append(f"RobotState: {e}")

    if errors:
        print("\n  ⚠ Warnings:", file=sys.stderr)
        for err in errors:
            print(f"    {err}", file=sys.stderr)
        print(file=sys.stderr)

    if battery is None and version is None and robot_state is None:
        print(
            "\nAll queries failed. Possible causes:\n"
            "  - Robot is not reachable (check network and firewall)\n"
            "  - Certificate doesn't match robot (re-pair to get a new cert)\n"
            "  - GUID is invalid or expired (re-authenticate)\n"
            "  - Robot firmware is too old or too new for these RPCs\n"
            "  - vic-gateway REST proxy may not be enabled on this firmware",
            file=sys.stderr,
        )
        sys.exit(2)

    print(file=sys.stderr)

    if args.json:
        print_status_json(args.host, args.port, battery, version, robot_state)
    else:
        print_status(args.host, args.port, battery, version, robot_state, cert_path)


if __name__ == "__main__":
    main()
