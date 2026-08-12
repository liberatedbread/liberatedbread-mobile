#!/usr/bin/env python3
# Copyright 2026 Pigs Can Fly Labs LLC
# SPDX-License-Identifier: Apache-2.0
"""Discover Dyson local MQTT brokers via mDNS."""

from __future__ import annotations

import argparse
import re

from _lan_discovery import browse_mdns, print_records

SERVICE = "_dyson_mqtt._tcp.local."


def main() -> None:
    parser = argparse.ArgumentParser(description="Discover Dyson MQTT devices via mDNS.")
    parser.add_argument("--timeout", type=float, default=5.0)
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()

    records = browse_mdns([SERVICE], args.timeout)
    for record in records:
        match = re.match(r"([^.]*)", record.hostname or "")
        if match:
            record.txt.setdefault("serial", match.group(1))
    print_records(records, args.json)


if __name__ == "__main__":
    main()

