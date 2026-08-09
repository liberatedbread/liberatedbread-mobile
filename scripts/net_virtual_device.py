#!/usr/bin/env python3
# Copyright 2026 Pigs Can Fly Labs LLC
# SPDX-License-Identifier: Apache-2.0
"""Emulated devices on the local network: an mDNS/DNS-SD responder and an SSDP
responder, in one process, answering on the real multicast groups.

WHAT THIS IS FOR

RealNetworkScanService discovers hardware the way the hardware expects to be
found: a DNS-SD meta-query over mDNS (224.0.0.251:5353) and an SSDP M-SEARCH
(239.255.255.250:1900). Neither has a plugin seam to substitute — they are
`dart:io` sockets and package:multicast_dns — so the only way to run that code
for real is to put something on the wire that answers. That is this.

It is deliberately a RESPONDER and not a replay: it decodes each query and
answers only what was asked, in the order DNS-SD requires. So the app's actual
query sequence is exercised — enumerate service types, resolve instances to
PTR, then TXT and SRV, then A — rather than a canned burst that would pass no
matter what the client asked for.

Everything is stdlib. An mDNS library would be less code, but it would also
answer queries this app never sends and hide the ones it does.

MULTICAST, AND WHY IT WORKS WITHOUT A NETWORK

Both sockets join their multicast group on the loopback path with
IP_MULTICAST_LOOP on, so responder and app exchange datagrams on one host with
no second machine, no router and no privileges. The mDNS socket sets
SO_REUSEPORT because package:multicast_dns binds 5353 the same way; without it
the second binder loses.

There is no wrapper script: the tests that need this start it themselves (see
test/services/real_network_scan_service_live_test.dart) and wait on --ready-file
rather than on a sleep. Run it by hand to watch a scan happen against the real
app — `./scripts/run-linux.sh` in another terminal — or to try a scenario out.

Usage:
    python3 scripts/net_virtual_device.py --verbose
    python3 scripts/net_virtual_device.py --scenario my-devices.json
    python3 scripts/net_virtual_device.py --ready-file /tmp/ready --seconds 30
"""

from __future__ import annotations

import argparse
import json
import os
import selectors
import socket
import struct
import sys
import time

MDNS_GROUP = '224.0.0.251'
MDNS_PORT = 5353
SSDP_GROUP = '239.255.255.250'
SSDP_PORT = 1900

# DNS record types this responder knows how to speak.
TYPE_A = 1
TYPE_PTR = 12
TYPE_TXT = 16
TYPE_SRV = 33
TYPE_ANY = 255

CLASS_IN = 1
# The cache-flush bit real responders set on unique records. Clients mask it
# off; setting it keeps the packets honest.
CLASS_IN_FLUSH = 0x8001

SERVICE_ENUMERATION = '_services._dns-sd._udp.local'

# Two devices, chosen to cover the two halves of discovery that do not overlap.
#
#   * A Hue bridge answers BOTH mDNS (_hue._tcp) and SSDP, which is what makes
#     it the right device for testing coalescing: one host, two transports, and
#     the list must show one row.
#   * A Wemo-style plug is SSDP-only, the case that exists precisely because
#     running mDNS alone would miss it.
#
# The advertised addresses are TEST-NET-2 (RFC 5737), which is documentation
# space and never routable — so they are unmistakably fake, and they cannot
# collide with anything on a developer's real network. They are also DISTINCT,
# which is load-bearing: discovery coalesces sightings by host, so two devices
# sharing one address would correctly merge into a single row and the scenario
# would quietly stop being two devices. Nothing ever connects to them; the
# address is data the responder hands out, not a place it listens.
DEFAULT_SCENARIO = [
    {
        'name': 'Philips Hue Bridge',
        'address': '198.51.100.11',
        'mdns': [
            {
                'instance': 'Philips Hue - 123456',
                'type': '_hue._tcp.local',
                'target': 'hue-bridge.local',
                'port': 443,
                'txt': {
                    'bridgeid': '001788FFFE123456',
                    'modelid': 'BSB002',
                },
            },
        ],
        'ssdp': {
            'st': 'upnp:rootdevice',
            'server': 'Hue/1.0 UPnP/1.0 IpBridge/1.62.0',
            'location_path': '/description.xml',
            'location_port': 80,
        },
    },
    {
        'name': 'Wemo Mini Smart Plug',
        'address': '198.51.100.12',
        'mdns': [],
        'ssdp': {
            'st': 'urn:Belkin:device:controllee:1',
            'server': 'Unspecified, UPnP/1.0, Unspecified',
            'location_path': '/setup.xml',
            'location_port': 49153,
        },
    },
]


def primary_address() -> str:
    """This host's outbound IPv4 address, or loopback when it has none.

    Connecting a UDP socket sends nothing; it just asks the routing table which
    source address would be used, which is the address a device on this link
    would advertise.
    """
    probe = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        probe.connect(('192.0.2.1', 9))  # TEST-NET-1: reserved, never routed
        return probe.getsockname()[0]
    except OSError:
        return '127.0.0.1'
    finally:
        probe.close()


# ── DNS wire format ────────────────────────────────────────────────────────


def encode_name(name: str) -> bytes:
    out = bytearray()
    for label in name.rstrip('.').split('.'):
        encoded = label.encode('utf-8')
        if len(encoded) > 63:
            raise ValueError(f'label too long: {label}')
        out.append(len(encoded))
        out += encoded
    out.append(0)
    return bytes(out)


def decode_name(data: bytes, offset: int) -> tuple[str, int]:
    """Read a (possibly compressed) name, returning it and the offset after it.

    Compression pointers are followed for the VALUE but do not advance the
    caller's offset past the pointer, which is what the format requires.
    """
    labels: list[str] = []
    after: int | None = None
    seen = 0
    while True:
        if offset >= len(data):
            raise ValueError('name ran off the end of the packet')
        length = data[offset]
        if length & 0xC0 == 0xC0:
            if offset + 1 >= len(data):
                raise ValueError('truncated compression pointer')
            pointer = struct.unpack_from('>H', data, offset)[0] & 0x3FFF
            if after is None:
                after = offset + 2
            offset = pointer
            seen += 1
            if seen > 32:
                raise ValueError('compression pointer loop')
            continue
        offset += 1
        if length == 0:
            break
        labels.append(data[offset:offset + length].decode('utf-8', 'replace'))
        offset += length
    return '.'.join(labels), (after if after is not None else offset)


def record(name: str, rtype: int, rdata: bytes, ttl: int = 120,
           rclass: int = CLASS_IN_FLUSH) -> bytes:
    return (encode_name(name) + struct.pack('>HHIH', rtype, rclass, ttl,
                                            len(rdata)) + rdata)


def txt_rdata(txt: dict[str, str]) -> bytes:
    out = bytearray()
    for key, value in txt.items():
        entry = f'{key}={value}'.encode('utf-8') if value != '' else key.encode()
        out.append(len(entry))
        out += entry
    # A TXT record must carry at least one string; an empty one is a single
    # zero-length string, not zero strings.
    return bytes(out) if out else b'\x00'


def srv_rdata(target: str, port: int, priority: int = 0, weight: int = 0) -> bytes:
    return struct.pack('>HHH', priority, weight, port) + encode_name(target)


def response_packet(answers: list[bytes]) -> bytes:
    # QR=1, AA=1. QDCOUNT 0: an mDNS response does not echo the question.
    header = struct.pack('>HHHHHH', 0, 0x8400, 0, len(answers), 0, 0)
    return header + b''.join(answers)


def parse_questions(packet: bytes) -> list[tuple[str, int]]:
    if len(packet) < 12:
        return []
    flags, qdcount = struct.unpack_from('>HH', packet, 2)
    # Ignore responses (QR set); we answer queries only.
    if flags & 0x8000:
        return []
    offset = 12
    questions = []
    for _ in range(qdcount):
        try:
            name, offset = decode_name(packet, offset)
            qtype, _qclass = struct.unpack_from('>HH', packet, offset)
            offset += 4
        except (ValueError, struct.error):
            break
        questions.append((name, qtype))
    return questions


# ── the emulated link ──────────────────────────────────────────────────────


class VirtualNetwork:
    """The devices, and the records they answer with."""

    def __init__(self, scenario: list[dict], address: str):
        self.address = address
        self.devices = []
        for entry in scenario:
            device = dict(entry)
            device['address'] = device.get('address') or address
            self.devices.append(device)

    @property
    def service_types(self) -> list[str]:
        types: list[str] = []
        for device in self.devices:
            for service in device.get('mdns', []):
                if service['type'] not in types:
                    types.append(service['type'])
        return types

    def answers_for(self, name: str, qtype: int) -> list[bytes]:
        """Records answering one question, or an empty list.

        Only what was asked: a responder that volunteered its whole database
        would let a client that asked the wrong question still pass.
        """
        lowered = name.lower().rstrip('.')
        answers: list[bytes] = []

        if lowered == SERVICE_ENUMERATION and qtype in (TYPE_PTR, TYPE_ANY):
            for service_type in self.service_types:
                answers.append(record(SERVICE_ENUMERATION, TYPE_PTR,
                                      encode_name(service_type),
                                      rclass=CLASS_IN))
            return answers

        for device in self.devices:
            for service in device.get('mdns', []):
                instance = f"{service['instance']}.{service['type']}"
                if (lowered == service['type'].lower()
                        and qtype in (TYPE_PTR, TYPE_ANY)):
                    answers.append(record(service['type'], TYPE_PTR,
                                          encode_name(instance),
                                          rclass=CLASS_IN))
                if lowered == instance.lower():
                    if qtype in (TYPE_TXT, TYPE_ANY):
                        answers.append(record(instance, TYPE_TXT,
                                              txt_rdata(service.get('txt', {}))))
                    if qtype in (TYPE_SRV, TYPE_ANY):
                        answers.append(record(
                            instance, TYPE_SRV,
                            srv_rdata(service['target'], service['port'])))
                if (lowered == service['target'].lower().rstrip('.')
                        and qtype in (TYPE_A, TYPE_ANY)):
                    answers.append(record(service['target'], TYPE_A,
                                          socket.inet_aton(device['address'])))
        return answers

    def ssdp_replies(self, host_header: str) -> list[bytes]:
        replies = []
        for device in self.devices:
            ssdp = device.get('ssdp')
            if not ssdp:
                continue
            location = ssdp.get('location') or (
                f"http://{device['address']}:{ssdp.get('location_port', 80)}"
                f"{ssdp.get('location_path', '/description.xml')}")
            usn = ssdp.get('usn') or f"uuid:{device['name'].lower().replace(' ', '-')}"
            payload = (
                'HTTP/1.1 200 OK\r\n'
                'CACHE-CONTROL: max-age=1800\r\n'
                f'LOCATION: {location}\r\n'
                f"SERVER: {ssdp.get('server', 'Virtual/1.0 UPnP/1.0')}\r\n"
                f"ST: {ssdp['st']}\r\n"
                f'USN: {usn}::{ssdp["st"]}\r\n'
                'EXT:\r\n'
                '\r\n'
            )
            replies.append(payload.encode('utf-8'))
        return replies


def open_mdns_socket() -> socket.socket:
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    # package:multicast_dns binds 5353 with reusePort too. Without this the
    # second binder simply loses, and which one that is depends on start order.
    if hasattr(socket, 'SO_REUSEPORT'):
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
    sock.bind(('', MDNS_PORT))
    sock.setsockopt(socket.IPPROTO_IP, socket.IP_ADD_MEMBERSHIP,
                    struct.pack('4s4s', socket.inet_aton(MDNS_GROUP),
                                socket.inet_aton('0.0.0.0')))
    sock.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_TTL, 1)
    sock.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_LOOP, 1)
    return sock


def open_ssdp_socket() -> socket.socket:
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    if hasattr(socket, 'SO_REUSEPORT'):
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
    sock.bind(('', SSDP_PORT))
    sock.setsockopt(socket.IPPROTO_IP, socket.IP_ADD_MEMBERSHIP,
                    struct.pack('4s4s', socket.inet_aton(SSDP_GROUP),
                                socket.inet_aton('0.0.0.0')))
    sock.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_LOOP, 1)
    return sock


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--scenario',
                        help='Path to a JSON device list; the bundled '
                             'two-device scenario by default.')
    parser.add_argument('--ready-file',
                        help='File to create once both sockets are listening. '
                             'Lets a caller wait on a fact, not a sleep.')
    parser.add_argument('--address',
                        help='Fallback IPv4 address for scenario entries that '
                             'name none. Defaults to this host\'s outbound '
                             'address.')
    parser.add_argument('--seconds', type=float, default=0,
                        help='Exit after this many seconds. 0 runs until '
                             'killed.')
    parser.add_argument('--verbose', action='store_true',
                        help='Log every query answered.')
    args = parser.parse_args()

    scenario = DEFAULT_SCENARIO
    if args.scenario:
        with open(args.scenario) as handle:
            scenario = json.load(handle)

    network = VirtualNetwork(scenario, args.address or primary_address())

    try:
        mdns = open_mdns_socket()
        ssdp = open_ssdp_socket()
    except OSError as error:
        sys.stderr.write(
            f'could not open the multicast sockets: {error}\n'
            'Ports 5353 and 1900 must be free and the host must have a '
            'multicast-capable interface. A system mDNS responder (avahi-daemon,\n'
            'systemd-resolved) holding 5353 exclusively is the usual cause.\n')
        return 2

    selector = selectors.DefaultSelector()
    selector.register(mdns, selectors.EVENT_READ, 'mdns')
    selector.register(ssdp, selectors.EVENT_READ, 'ssdp')

    if args.ready_file:
        with open(args.ready_file, 'w') as handle:
            handle.write(network.address)

    names = ', '.join(d['name'] for d in network.devices)
    print(f'virtual network devices up on {network.address}: {names}',
          flush=True)

    deadline = time.monotonic() + args.seconds if args.seconds else None
    try:
        while True:
            if deadline is not None and time.monotonic() >= deadline:
                return 0
            for key, _ in selector.select(timeout=0.5):
                if key.data == 'mdns':
                    packet, sender = mdns.recvfrom(9000)
                    answers: list[bytes] = []
                    for name, qtype in parse_questions(packet):
                        found = network.answers_for(name, qtype)
                        if found and args.verbose:
                            print(f'mdns {name} type {qtype} -> '
                                  f'{len(found)} record(s)', flush=True)
                        answers.extend(found)
                    if answers:
                        # Multicast the reply, as a responder does: the querier
                        # may have asked from an ephemeral port it is not
                        # listening on, and other clients get to cache it.
                        mdns.sendto(response_packet(answers),
                                    (MDNS_GROUP, MDNS_PORT))
                else:
                    packet, sender = ssdp.recvfrom(9000)
                    text = packet.decode('utf-8', 'replace')
                    if not text.upper().startswith('M-SEARCH'):
                        continue
                    if args.verbose:
                        print(f'ssdp M-SEARCH from {sender}', flush=True)
                    for reply in network.ssdp_replies(''):
                        # Unicast back to the searcher, which is what the
                        # protocol says and what the app listens for.
                        ssdp.sendto(reply, sender)
    except KeyboardInterrupt:
        return 0
    finally:
        selector.close()
        mdns.close()
        ssdp.close()
        if args.ready_file and os.path.exists(args.ready_file):
            os.unlink(args.ready_file)


if __name__ == '__main__':
    raise SystemExit(main())
