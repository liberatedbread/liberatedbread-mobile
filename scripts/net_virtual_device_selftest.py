#!/usr/bin/env python3
# Copyright 2026 Pigs Can Fly Labs LLC
# SPDX-License-Identifier: Apache-2.0
"""Asserts that scripts/net_virtual_device.py answers only what was asked.

The responder's whole value is that it is a RESPONDER and not a replay: the
netdisco suites pass only if the app sends the right queries. The SSDP half
did not hold up its end — it returned every device for every M-SEARCH,
whatever the ST said — so a scan that searched for a device type nothing
implements still found both devices, and no test could tell a targeted search
from a wildcard. That is the difference between "the vendor search targets are
still being sent" and "something answered", which is exactly what the extra
targets in RealNetworkScanService._runSsdp exist to guarantee.

Stdlib only, no sockets, no network: it imports the responder and asks it
directly. Runs in scripts/test.sh and CI's gate job; the netdisco suites
themselves need ports 5353/1900 and a real scan.
"""

from __future__ import annotations

import importlib.util
import pathlib
import sys

HERE = pathlib.Path(__file__).resolve().parent
MODULE = HERE / 'net_virtual_device.py'

_status = 0


def check(label: str, ok: bool, detail: str = '') -> None:
    global _status
    if ok:
        print(f'  ok    {label}')
    else:
        _status = 1
        print(f'  FAIL  {label}{": " + detail if detail else ""}',
              file=sys.stderr)


def load():
    spec = importlib.util.spec_from_file_location('net_virtual_device', MODULE)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def headers(reply: bytes) -> dict[str, str]:
    out = {}
    for line in reply.decode('utf-8').split('\r\n'):
        name, sep, value = line.partition(':')
        if sep:
            out[name.strip().lower()] = value.strip()
    return out


def search_targets(replies: list[bytes]) -> set[str]:
    return {headers(r).get('st', '') for r in replies}


def main() -> int:
    nvd = load()
    net = nvd.VirtualNetwork(nvd.DEFAULT_SCENARIO, '127.0.0.1')

    declared = {d['ssdp']['st'] for d in nvd.DEFAULT_SCENARIO if d.get('ssdp')}
    check('the bundled scenario declares more than one ST to tell apart',
          len(declared) > 1, f'declared: {sorted(declared)}')

    # ── the ST header, off the wire ─────────────────────────────────────────
    request = ('M-SEARCH * HTTP/1.1\r\n'
               'HOST: 239.255.255.250:1900\r\n'
               'MAN: "ssdp:discover"\r\n'
               'MX: 3\r\n'
               'st: urn:Belkin:device:controllee:1\r\n'
               '\r\n')
    check('the ST header is read case-insensitively and trimmed',
          nvd.ssdp_search_target(request) == 'urn:Belkin:device:controllee:1',
          repr(nvd.ssdp_search_target(request)))
    check('an M-SEARCH with no ST header reads as no search target',
          nvd.ssdp_search_target('M-SEARCH * HTTP/1.1\r\nHOST: x\r\n\r\n') == '')

    # ── the wildcard still finds everything ─────────────────────────────────
    every = net.ssdp_replies('ssdp:all')
    check('ssdp:all is answered by every device',
          search_targets(every) == declared,
          f'{sorted(search_targets(every))} != {sorted(declared)}')
    check('ssdp:all matches whatever the case',
          len(net.ssdp_replies('SSDP:All')) == len(every))

    # ── a targeted search is answered by its device and no other ────────────
    belkin = net.ssdp_replies('urn:Belkin:device:controllee:1')
    check('a vendor ST is answered by that device alone',
          len(belkin) == 1
          and headers(belkin[0])['st'] == 'urn:Belkin:device:controllee:1',
          f'{len(belkin)} reply/replies: {sorted(search_targets(belkin))}')
    if belkin:
        head = headers(belkin[0])
        check('the reply carries that device LOCATION and a matching USN',
              head.get('location', '').endswith(':49153/setup.xml')
              and head.get('usn', '').endswith(
                  '::urn:Belkin:device:controllee:1'),
              f"location={head.get('location')} usn={head.get('usn')}")

    roots = net.ssdp_replies('upnp:rootdevice')
    check('upnp:rootdevice is answered by the device declaring it, alone',
          search_targets(roots) == {'upnp:rootdevice'},
          f'{sorted(search_targets(roots))}')

    # ── and a search for something nothing implements finds nothing ─────────
    absent = net.ssdp_replies('urn:schemas-upnp-org:device:MediaRenderer:1')
    check('an ST no device declares is answered by nobody',
          absent == [], f'{len(absent)} reply/replies')
    check('an M-SEARCH with no ST is answered by nobody',
          net.ssdp_replies('') == [])

    # ── the Roku case the extra search targets exist for ────────────────────
    scenario = [{
        'name': 'Deaf Vendor Box',
        'address': '198.51.100.90',
        'mdns': [],
        'ssdp': {'st': 'roku:ecp', 'deaf_to_wildcard': True,
                 'location_port': 8060, 'location_path': '/'},
    }]
    deaf = nvd.VirtualNetwork(scenario, '127.0.0.1')
    check('a wildcard-deaf device is silent on ssdp:all',
          deaf.ssdp_replies('ssdp:all') == [])
    check('a wildcard-deaf device answers its own ST',
          len(deaf.ssdp_replies('roku:ecp')) == 1)

    if _status == 0:
        print('net_virtual_device selftest: all passed')
    return _status


if __name__ == '__main__':
    raise SystemExit(main())
