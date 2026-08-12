#!/usr/bin/env python3
# Copyright 2026 Pigs Can Fly Labs LLC
# SPDX-License-Identifier: Apache-2.0
"""Discover LIFX Z strips via HAP mDNS and UDP GetService."""

from __future__ import annotations

import argparse
import json
import socket
import struct
from dataclasses import asdict

from _lan_discovery import browse_mdns

HAP_SERVICE = "_hap._tcp.local."
LIFX_PORT = 56700


def lifx_get_service_packet() -> bytes:
    """Build a minimal 36-byte LIFX LAN GetService packet."""
    size = 36
    protocol = 1024
    addressable = 1 << 12
    tagged = 1 << 13
    frame = struct.pack("<HHI", size, protocol | addressable | tagged, 0)
    target = b"\x00" * 8
    frame_address = target + b"\x00" * 6 + b"\x00" + b"\x01"
    protocol_header = b"\x00" * 8 + struct.pack("<H", 2) + b"\x00\x00"
    return frame + frame_address + protocol_header


def udp_probe(address: str, timeout: float) -> dict[str, str | int]:
    if not address:
        return {"status": "not_resolved"}
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.settimeout(timeout)
    try:
        sock.sendto(lifx_get_service_packet(), (address, LIFX_PORT))
        data, _ = sock.recvfrom(512)
        msg_type = struct.unpack_from("<H", data, 32)[0] if len(data) >= 34 else 0
        service = data[36] if len(data) > 36 else 0
        port = struct.unpack_from("<I", data, 37)[0] if len(data) >= 41 else 0
        return {"status": "ok", "message_type": msg_type, "service": service, "port": port}
    except Exception as exc:  # noqa: BLE001
        return {"status": "error", "error": str(exc)}
    finally:
        sock.close()


def main() -> None:
    parser = argparse.ArgumentParser(description="Discover LIFX Z strips via mDNS and UDP.")
    parser.add_argument("--timeout", type=float, default=5.0)
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()

    records = [
        record for record in browse_mdns([HAP_SERVICE], args.timeout)
        if record.txt.get("md", "").lower() == "lifx z"
    ]
    output = []
    for record in records:
        data = asdict(record)
        data["lifx_get_service"] = udp_probe(record.address, min(args.timeout, 2.0))
        output.append(data)

    if args.json:
        print(json.dumps(output, indent=2))
        return
    if not output:
        print("No LIFX Z strips found.")
        return
    for record in output:
        print(f"{record['name']}  {record['address']}:{LIFX_PORT}")
        print(f"  Host: {record['hostname']}")
        print(f"  HAP ID: {record['txt'].get('id', '')}")
        print(f"  UDP: {record['lifx_get_service']}")


if __name__ == "__main__":
    main()
