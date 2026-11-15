#!/usr/bin/env python3
# Copyright 2026 Pigs Can Fly Labs LLC
# SPDX-License-Identifier: Apache-2.0
"""Discover Lutron Smart Bridge services via mDNS."""

from __future__ import annotations

import argparse

from _lan_discovery import browse_mdns, print_records

SERVICES = ["_leap._tcp.local.", "_lutron._tcp.local."]


def main() -> None:
    parser = argparse.ArgumentParser(description="Discover Lutron LEAP and status services.")
    parser.add_argument("--timeout", type=float, default=5.0)
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()

    print_records(browse_mdns(SERVICES, args.timeout), args.json)


if __name__ == "__main__":
    main()

