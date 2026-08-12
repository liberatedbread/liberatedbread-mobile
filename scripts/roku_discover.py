#!/usr/bin/env python3
# Copyright 2026 Pigs Can Fly Labs LLC
# SPDX-License-Identifier: Apache-2.0
"""Discover Roku ECP devices with SSDP and fetch /query/device-info."""

from __future__ import annotations

import argparse
import json
import re
import socket
import time
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET

SSDP_ADDR = "239.255.255.250"
SSDP_PORT = 1900
ST = "roku:ecp"


def msearch(timeout: float) -> list[str]:
    packet = (
        "M-SEARCH * HTTP/1.1\r\n"
        f"HOST: {SSDP_ADDR}:{SSDP_PORT}\r\n"
        'MAN: "ssdp:discover"\r\n'
        "MX: 1\r\n"
        f"ST: {ST}\r\n\r\n"
    ).encode()
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
    sock.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_TTL, 2)
    sock.settimeout(timeout)
    responses: list[str] = []
    try:
        sock.sendto(packet, (SSDP_ADDR, SSDP_PORT))
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            try:
                sock.settimeout(max(0.1, deadline - time.monotonic()))
                data, _ = sock.recvfrom(4096)
                responses.append(data.decode("utf-8", errors="replace"))
            except socket.timeout:
                break
    finally:
        sock.close()
    return responses


def header(raw: str, name: str) -> str:
    match = re.search(rf"(?im)^{re.escape(name)}:\s*(.+)$", raw)
    return match.group(1).strip() if match else ""


def xml_text(root: ET.Element, tag: str) -> str:
    found = root.find(tag)
    return found.text.strip() if found is not None and found.text else ""


def fetch_device_info(location: str, timeout: float) -> dict:
    url = urllib.parse.urljoin(location.rstrip("/") + "/", "query/device-info")
    with urllib.request.urlopen(url, timeout=timeout) as resp:
        root = ET.fromstring(resp.read())
    return {
        "device_info_url": url,
        "name": xml_text(root, "user-device-name"),
        "model": xml_text(root, "model-name"),
        "model_number": xml_text(root, "model-number"),
        "serial": xml_text(root, "serial-number"),
        "device_id": xml_text(root, "device-id"),
        "software_version": xml_text(root, "software-version"),
        "network_type": xml_text(root, "network-type"),
    }


def main() -> None:
    parser = argparse.ArgumentParser(description="Discover Roku ECP devices via SSDP.")
    parser.add_argument("--timeout", type=float, default=5.0)
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()

    seen: set[str] = set()
    devices = []
    for raw in msearch(args.timeout):
        location = header(raw, "location")
        if not location or location in seen:
            continue
        seen.add(location)
        record = {"location": location, "usn": header(raw, "usn"), "st": header(raw, "st")}
        try:
            record.update(fetch_device_info(location, args.timeout))
        except Exception as exc:  # noqa: BLE001 - discovery should report partial records.
            record["error"] = str(exc)
        devices.append(record)

    if args.json:
        print(json.dumps(devices, indent=2))
        return
    if not devices:
        print("No Roku ECP devices found.")
        return
    for device in devices:
        print(f"{device.get('name') or '(unnamed)'}  {device.get('location')}")
        print(f"  Model:  {device.get('model')} ({device.get('model_number')})")
        print(f"  Serial: {device.get('serial')}")
        print(f"  ID:     {device.get('device_id')}")
        if device.get("error"):
            print(f"  Error:  {device['error']}")


if __name__ == "__main__":
    main()

