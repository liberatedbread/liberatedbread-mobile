#!/usr/bin/env python3
"""Basic BLE packet capture parser for IoT protocol analysis.

Reads a btsnoop or pcap/pcapng file and extracts BLE ATT (Attribute Protocol)
operations -- writes, reads, and notifications -- grouped by characteristic
handle.  Useful as a starting point for reverse engineering device protocols.

Requires: pip install dpkt  (for pcap parsing)

Usage:
    python pcap_parser.py capture.pcap
    python pcap_parser.py capture.pcap --handle 0x0025
    python pcap_parser.py capture.pcap -v

Copyright 2026 Pigs Can Fly Labs LLC
SPDX-License-Identifier: Apache-2.0
"""
from __future__ import annotations

import argparse
import struct
import sys
from collections import defaultdict
from pathlib import Path

# ATT opcodes we care about.
ATT_WRITE_REQUEST = 0x12
ATT_WRITE_COMMAND = 0x52  # write-without-response
ATT_READ_RESPONSE = 0x0B
ATT_NOTIFICATION = 0x1B
ATT_INDICATION = 0x1D

OPCODE_NAMES = {
    ATT_WRITE_REQUEST: "Write Request",
    ATT_WRITE_COMMAND: "Write Command",
    ATT_READ_RESPONSE: "Read Response",
    ATT_NOTIFICATION: "Notification",
    ATT_INDICATION: "Indication",
}


def format_hex(data: bytes) -> str:
    """Format bytes as a hex string like '01 ff 0a'."""
    return " ".join(f"{b:02x}" for b in data)


def parse_att_pdu(pdu: bytes) -> tuple[int, int, bytes] | None:
    """Parse a BLE ATT PDU and return (opcode, handle, value) or None."""
    if len(pdu) < 1:
        return None
    opcode = pdu[0]
    if opcode in (ATT_WRITE_REQUEST, ATT_WRITE_COMMAND) and len(pdu) >= 3:
        handle = struct.unpack_from("<H", pdu, 1)[0]
        value = pdu[3:]
        return opcode, handle, value
    if opcode in (ATT_NOTIFICATION, ATT_INDICATION) and len(pdu) >= 3:
        handle = struct.unpack_from("<H", pdu, 1)[0]
        value = pdu[3:]
        return opcode, handle, value
    if opcode == ATT_READ_RESPONSE and len(pdu) >= 2:
        # Read responses don't include a handle in the PDU; we use 0 as
        # a placeholder — correlation with the preceding Read Request
        # requires sequence tracking which is out of scope here.
        return opcode, 0, pdu[1:]
    return None


def try_parse_pcap(filepath: Path) -> list[tuple[int, int, bytes]]:
    """Attempt to parse a pcap/pcapng file using dpkt.

    Returns a list of (opcode, handle, value) tuples.
    """
    try:
        import dpkt  # type: ignore[import-untyped]
    except ImportError:
        print(
            "Warning: dpkt not installed. Install with: pip install dpkt",
            file=sys.stderr,
        )
        print(
            "Without dpkt, only raw HCI/btsnoop analysis is available.",
            file=sys.stderr,
        )
        return []

    results: list[tuple[int, int, bytes]] = []
    with open(filepath, "rb") as f:
        try:
            reader = dpkt.pcapng.Reader(f)
        except ValueError:
            f.seek(0)
            try:
                reader = dpkt.pcap.Reader(f)
            except ValueError:
                print(f"Error: {filepath} is not a valid pcap/pcapng file.", file=sys.stderr)
                return []

        for _ts, buf in reader:
            # Walk through the packet looking for ATT PDUs.
            # This is a simplified heuristic — real parsers should decode the
            # full BLE link layer, but for RE purposes scanning for ATT opcodes
            # in the payload is often good enough.
            for offset in range(len(buf)):
                if buf[offset] in OPCODE_NAMES:
                    parsed = parse_att_pdu(buf[offset:])
                    if parsed is not None:
                        results.append(parsed)
                        break  # one ATT PDU per packet
    return results


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Parse BLE packet captures for IoT device protocol analysis"
    )
    parser.add_argument("pcap_file", help="Path to the pcap file to analyze")
    parser.add_argument(
        "--handle",
        help="Filter by characteristic handle (hex, e.g. 0x0025)",
        default=None,
    )
    parser.add_argument("-v", "--verbose", action="store_true", help="Verbose output")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    filepath = Path(args.pcap_file)

    if not filepath.exists():
        print(f"Error: {filepath} does not exist.", file=sys.stderr)
        return 1

    print("OpenGreenIoT pcap parser")
    print(f"File: {filepath}")
    print()

    results = try_parse_pcap(filepath)
    if not results:
        print("No ATT operations found (or dpkt not installed).")
        print()
        print("If you're working with an Android HCI snoop log, convert it first:")
        print("  wireshark -r btsnoop_hci.log -w capture.pcapng")
        return 0

    # Optionally filter by handle.
    handle_filter = None
    if args.handle:
        handle_filter = int(args.handle, 16)
        results = [(op, h, v) for op, h, v in results if h == handle_filter]

    # Group by handle.
    by_handle: dict[int, list[tuple[int, bytes]]] = defaultdict(list)
    for opcode, handle, value in results:
        by_handle[handle].append((opcode, value))

    for handle in sorted(by_handle):
        ops = by_handle[handle]
        print(f"Handle 0x{handle:04x}  ({len(ops)} operations)")
        print("-" * 60)
        for opcode, value in ops:
            name = OPCODE_NAMES.get(opcode, f"0x{opcode:02x}")
            print(f"  {name:20s}  {format_hex(value)}")
            if args.verbose and all(0x20 <= b < 0x7F for b in value):
                print(f"  {'(ASCII)':20s}  {value.decode('ascii')}")
        print()

    print(f"Summary: {len(results)} ATT operations across {len(by_handle)} handle(s).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
