#!/usr/bin/env python3
# Copyright 2026 Pigs Can Fly Labs LLC
# SPDX-License-Identifier: Apache-2.0
"""Small helpers for LAN discovery scripts."""

from __future__ import annotations

import json
import socket
import sys
import time
from dataclasses import asdict, dataclass, field


@dataclass
class ServiceRecord:
    name: str = ""
    service_type: str = ""
    hostname: str = ""
    address: str = ""
    port: int = 0
    txt: dict[str, str] = field(default_factory=dict)


def load_zeroconf():
    try:
        from zeroconf import ServiceBrowser, ServiceListener, Zeroconf
    except ImportError:
        sys.exit("error: zeroconf package not installed.\nInstall with: pip install zeroconf")
    return ServiceBrowser, ServiceListener, Zeroconf


def decode_txt(properties) -> dict[str, str]:
    txt: dict[str, str] = {}
    for key, value in (properties or {}).items():
        k = key.decode("utf-8", errors="replace") if isinstance(key, bytes) else str(key)
        v = value.decode("utf-8", errors="replace") if isinstance(value, bytes) else str(value)
        txt[k] = v
    return txt


def first_ipv4(info) -> str:
    for addr in getattr(info, "addresses", []) or []:
        if len(addr) == 4:
            return socket.inet_ntoa(addr)
    return ""


def browse_mdns(service_types: list[str], timeout: float) -> list[ServiceRecord]:
    ServiceBrowser, ServiceListener, Zeroconf = load_zeroconf()

    class Listener(ServiceListener):
        def __init__(self) -> None:
            self.records: dict[str, ServiceRecord] = {}

        def add_service(self, zc, type_, name) -> None:
            self._store(zc, type_, name)

        def update_service(self, zc, type_, name) -> None:
            self._store(zc, type_, name)

        def remove_service(self, zc, type_, name) -> None:
            self.records.pop(f"{type_}|{name}".lower(), None)

        def _store(self, zc, type_, name) -> None:
            info = zc.get_service_info(type_, name, timeout=2000)
            if info is None:
                return
            record = ServiceRecord(
                name=info.name.split(".")[0],
                service_type=type_,
                hostname=info.server,
                address=first_ipv4(info),
                port=info.port or 0,
                txt=decode_txt(info.properties),
            )
            self.records[f"{type_}|{name}".lower()] = record

    listener = Listener()
    zc = Zeroconf()
    browsers = []
    try:
        for service_type in service_types:
            browsers.append(ServiceBrowser(zc, service_type, listener))
        time.sleep(timeout)
    finally:
        for browser in browsers:
            browser.cancel()
        zc.close()
    return sorted(listener.records.values(), key=lambda r: (r.service_type, r.name, r.hostname))


def print_records(records: list[ServiceRecord], json_output: bool) -> None:
    if json_output:
        print(json.dumps([asdict(record) for record in records], indent=2))
        return
    if not records:
        print("No services found.")
        return
    for record in records:
        print(f"Name:     {record.name}")
        print(f"Service:  {record.service_type}")
        print(f"Host:     {record.hostname}")
        print(f"Address:  {record.address or '(not resolved)'}")
        print(f"Port:     {record.port}")
        if record.txt:
            print("TXT:")
            for key, value in sorted(record.txt.items()):
                print(f"  {key}: {value}")
        print()

