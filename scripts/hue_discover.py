#!/usr/bin/env python3
# Copyright 2026 Pigs Can Fly Labs LLC
# SPDX-License-Identifier: Apache-2.0
"""Discover Philips Hue Bridges with mDNS and SSDP fallback."""

from __future__ import annotations

import argparse
import json
import re
import socket
import time
import urllib.request
import xml.etree.ElementTree as ET
from dataclasses import asdict

from _lan_discovery import browse_mdns

MDNS_SERVICE = "_hue._tcp.local."
SSDP_ADDR = "239.255.255.250"
SSDP_PORT = 1900
SSDP_TARGETS = ["upnp:rootdevice", "urn:schemas-upnp-org:device:Basic:1"]


def msearch(st: str, timeout: float) -> list[str]:
    packet = (
        "M-SEARCH * HTTP/1.1\r\n"
        f"HOST: {SSDP_ADDR}:{SSDP_PORT}\r\n"
        'MAN: "ssdp:discover"\r\n'
        "MX: 1\r\n"
        f"ST: {st}\r\n\r\n"
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


def xml_find(root: ET.Element, local_name: str) -> str:
    for elem in root.iter():
        if elem.tag.rsplit("}", 1)[-1] == local_name and elem.text:
            return elem.text.strip()
    return ""


def fetch_description(location: str, timeout: float) -> dict[str, str]:
    with urllib.request.urlopen(location, timeout=timeout) as resp:
        root = ET.fromstring(resp.read())
    return {
        "friendlyName": xml_find(root, "friendlyName"),
        "serialNumber": xml_find(root, "serialNumber"),
        "UDN": xml_find(root, "UDN"),
        "modelName": xml_find(root, "modelName"),
    }


def ssdp_records(timeout: float) -> list[dict]:
    records: list[dict] = []
    seen: set[str] = set()
    for target in SSDP_TARGETS:
        for raw in msearch(target, timeout):
            location = header(raw, "location")
            if not location or location in seen:
                continue
            seen.add(location)
            record = {"source": "ssdp", "location": location, "st": header(raw, "st")}
            try:
                desc = fetch_description(location, min(timeout, 3.0))
                text = " ".join(desc.values()).lower()
                if "philips" not in text and "hue" not in text:
                    continue
                record.update(desc)
            except Exception as exc:  # noqa: BLE001
                record["error"] = str(exc)
            records.append(record)
    return records


def main() -> None:
    parser = argparse.ArgumentParser(description="Discover Philips Hue Bridges.")
    parser.add_argument("--timeout", type=float, default=5.0)
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()

    mdns = browse_mdns([MDNS_SERVICE], args.timeout)
    ssdp = ssdp_records(args.timeout)
    if args.json:
        print(json.dumps({"mdns": [asdict(r) for r in mdns], "ssdp": ssdp}, indent=2))
        return
    if not mdns and not ssdp:
        print("No Hue Bridges found.")
        return
    for record in mdns:
        print(f"{record.name}  {record.address}:{record.port}")
        print(f"  Host:     {record.hostname}")
        print(f"  BridgeID: {record.txt.get('bridgeid', '')}")
        print(f"  MAC:      {record.txt.get('mac', '')}")
        print(f"  API:      {record.txt.get('apiversion', '')}")
    for record in ssdp:
        print(f"SSDP {record.get('friendlyName') or record['location']}")
        print(f"  Serial: {record.get('serialNumber', '')}")
        print(f"  UDN:    {record.get('UDN', '')}")


if __name__ == "__main__":
    main()

