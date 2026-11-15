#!/usr/bin/env python3
"""
vector_discover.py — Discover Anki Vector robots on the local network via mDNS.

Uses mDNS (Zeroconf/Bonjour) to find robots advertising as
_ankivector._tcp.local. and prints their details.

Usage:
    python vector_discover.py [--timeout SECONDS] [--json]

Requires:
    pip install zeroconf
"""

from __future__ import annotations

import argparse
import json
import socket
import sys
import time
from dataclasses import dataclass, field

# ---------------------------------------------------------------------------
# Fix sys.path: omnigent's Python 3.12 site-packages may shadow our venv
# ---------------------------------------------------------------------------
for p in list(sys.path):
    if "omnigent" in p and "site-packages" in p:
        sys.path.remove(p)

try:
    from zeroconf import ServiceBrowser, ServiceListener, Zeroconf
except ImportError:
    sys.exit(
        "error: zeroconf package not installed.\n"
        "Install with: pip install zeroconf"
    )

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
MDNS_SERVICE_TYPE = "_ankivector._tcp.local."


# ---------------------------------------------------------------------------
# Data model
# ---------------------------------------------------------------------------
@dataclass
class VectorRobot:
    """Discovered Vector robot metadata."""

    name: str = ""
    hostname: str = ""
    address: str = ""
    port: int = 443
    serial: str = ""
    txt: dict[str, str] = field(default_factory=dict)


# ---------------------------------------------------------------------------
# mDNS listener
# ---------------------------------------------------------------------------
class VectorListener(ServiceListener):
    """Zeroconf listener for _ankivector._tcp.local. services."""

    def __init__(self) -> None:
        super().__init__()
        self.robots: dict[str, VectorRobot] = {}

    def add_service(self, zc: Zeroconf, type_: str, name: str) -> None:
        info = zc.get_service_info(type_, name)
        self._store(info)

    def update_service(self, zc: Zeroconf, type_: str, name: str) -> None:
        # Re-resolve on update to pick up any changes
        info = zc.get_service_info(type_, name)
        self._store(info)

    def remove_service(self, zc: Zeroconf, type_: str, name: str) -> None:
        key = name.lower()
        if key in self.robots:
            del self.robots[key]

    def _store(self, info) -> None:
        if info is None:
            return

        key = info.name.lower()
        robot = VectorRobot()

        # Human-readable name from the service name
        # Format: "Vector-X1X2._ankivector._tcp.local."
        robot.name = info.name.split(".")[0]

        # Hostname: typically "Vector-XXXX.local."
        robot.hostname = info.server

        # IP address
        if info.addresses:
            addr_bytes = info.addresses[0]
            robot.address = socket.inet_ntoa(addr_bytes)

        # Port (default: 443)
        robot.port = info.port or 443

        # TXT records: may contain serial, version, etc.
        if info.properties:
            txt = {}
            for k, v in info.properties.items():
                k_str = k.decode("utf-8", errors="replace") if isinstance(k, bytes) else k
                v_str = v.decode("utf-8", errors="replace") if isinstance(v, bytes) else v
                txt[k_str] = v_str
            robot.txt = txt
            robot.serial = txt.get("esn", txt.get("serial", ""))

        self.robots[key] = robot


# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------
def print_text(robots: dict[str, VectorRobot]) -> None:
    """Print discovered robots in human-readable table format."""
    if not robots:
        print("No Anki Vector robots found on the local network.")
        print(f"(Scanned for: {MDNS_SERVICE_TYPE})")
        return

    print(f"Found {len(robots)} Vector robot(s):\n")
    for robot in robots.values():
        print(f"  Name:       {robot.name}")
        print(f"  Hostname:   {robot.hostname}")
        print(f"  Address:    {robot.address}")
        print(f"  Port:       {robot.port}")
        print(f"  Serial:     {robot.serial or '(not advertised)'}")
        if robot.txt:
            print("  TXT records:")
            for k, v in sorted(robot.txt.items()):
                print(f"    {k}: {v}")
        print()


def print_json(robots: dict[str, VectorRobot]) -> None:
    """Print discovered robots as JSON."""
    data = []
    for robot in robots.values():
        data.append(
            {
                "name": robot.name,
                "hostname": robot.hostname,
                "address": robot.address,
                "port": robot.port,
                "serial": robot.serial or None,
                "txt": robot.txt,
            }
        )
    print(json.dumps(data, indent=2))


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
def main() -> None:
    parser = argparse.ArgumentParser(
        description="Discover Anki Vector robots via mDNS (_ankivector._tcp.local.)"
    )
    parser.add_argument(
        "--timeout",
        type=float,
        default=10.0,
        help="mDNS scan duration in seconds (default: 10)",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="Output results as JSON",
    )
    args = parser.parse_args()

    print(f"Scanning for {MDNS_SERVICE_TYPE} (timeout={args.timeout}s)...\n", file=sys.stderr)

    listener = VectorListener()
    zc = Zeroconf()

    browser = None
    try:
        browser = ServiceBrowser(zc, MDNS_SERVICE_TYPE, listener)
        time.sleep(args.timeout)
    except KeyboardInterrupt:
        print("\nScan interrupted.", file=sys.stderr)
    finally:
        if browser is not None:
            browser.cancel()
        zc.close()

    if args.json:
        print_json(listener.robots)
    else:
        print_text(listener.robots)


if __name__ == "__main__":
    main()
