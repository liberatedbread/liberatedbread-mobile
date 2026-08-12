#!/usr/bin/env python3
# Copyright 2026 Pigs Can Fly Labs LLC
# SPDX-License-Identifier: Apache-2.0
"""Discover Enphase Envoy gateways and probe /production.json."""

from __future__ import annotations

import argparse
import json
import urllib.request
from dataclasses import asdict

from _lan_discovery import browse_mdns, print_records

SERVICE = "_enphase-envoy._tcp.local."


def probe(address: str, port: int, timeout: float) -> str:
    if not address:
        return "not_resolved"
    url = f"http://{address}:{port or 80}/production.json"
    try:
        with urllib.request.urlopen(url, timeout=timeout) as resp:
            return f"http_{resp.status}"
    except Exception as exc:  # noqa: BLE001
        return f"error:{exc}"


def main() -> None:
    parser = argparse.ArgumentParser(description="Discover Enphase Envoy via mDNS.")
    parser.add_argument("--timeout", type=float, default=5.0)
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()

    records = browse_mdns([SERVICE], args.timeout)
    for record in records:
        record.txt["production_json"] = probe(record.address, record.port, min(args.timeout, 3.0))
    if args.json:
        print(json.dumps([asdict(record) for record in records], indent=2))
    else:
        print_records(records, False)


if __name__ == "__main__":
    main()

