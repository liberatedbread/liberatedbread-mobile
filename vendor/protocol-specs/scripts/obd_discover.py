#!/usr/bin/env python3
# Copyright 2026 Pigs Can Fly Labs LLC
# SPDX-License-Identifier: Apache-2.0
"""Read-only OBD-II / UDS reconnaissance over an ELM327-class serial adapter.

Maps what a vehicle's diagnostic bus will answer *without writing anything*: which
transport it speaks, which ECU addresses respond, and which ReadDataByIdentifier (0x22)
DIDs return data. That last sweep is how you locate values such as an odometer or a
service-due distance before anyone works out how to change them.

Discovery is read-only: 0x22 (ReadDataByIdentifier), 0x09 (vehicle info) and 0x10 0x03
(enter extended session, when --extended is given). The DID sweep deliberately refuses to
touch RoutineControl (0x31) — "start routine" identifiers execute whatever they name, so
they are only ever invoked from a captured, understood trace.

Two vehicle-specific modes go further, because clearing a service reminder after doing the
service is the point of this repo:

* ``--triumph-sia`` / ``--triumph-reset`` — Triumph instrument cluster (CAN 0x701/0x704)
* ``--bmw-scan`` / ``--bmw-module`` — BMW D-CAN modules via the 0x6F1 addressing scheme

Only ``--triumph-reset`` writes, and it refuses to run without ``--yes-write``. It reads
the current state before and after, so a mistake is visible immediately.

SAFETY: vehicles are safety-critical. Run this on a vehicle you own, stationary, on a
stand or with the parking brake set, engine off and ignition on. Never while anyone is
riding or driving it.

Usage::

    python scripts/obd_discover.py --port /dev/rfcomm0
    python scripts/obd_discover.py --port /dev/ttyUSB0 --scan-dids 0xF180-0xF1FF
    python scripts/obd_discover.py --port /dev/rfcomm0 --ecu 0x7E0 --extended --json

Requires ``pyserial``. Pair a Bluetooth adapter first, e.g.::

    sudo rfcomm bind 0 <adapter-mac> 1
"""

from __future__ import annotations

import argparse
import json
import sys
import time

try:
    import serial  # type: ignore
except ImportError:  # pragma: no cover - dependency is optional for docs builds
    serial = None

# ELM327 protocol 6 = ISO 15765-4 CAN, 11-bit ID, 500 kbit/s: the usual OBD-II variant
# and the one Triumph's later ECUs use.
DEFAULT_PROTOCOL = "6"
# REQUEST IDs only. ATSH sets the header we transmit with, so a response ID such as
# 0x7E8 would put our requests on the ECU's own arbitration ID and simply look dead.
# 0x7E0 and 0x7E1 are the first two physically addressed ECUs on standard OBD-II.
DEFAULT_ECUS = ["0x7E0", "0x7E1"]

# UDS negative response codes worth naming; the first three are what a DID sweep sees.
NRC = {
    0x11: "serviceNotSupported",
    0x12: "subFunctionNotSupported",
    0x13: "incorrectMessageLengthOrInvalidFormat",
    0x22: "conditionsNotCorrect",
    0x31: "requestOutOfRange",
    0x33: "securityAccessDenied",
    0x35: "invalidKey",
    0x78: "responsePending",
    0x7E: "subFunctionNotSupportedInActiveSession",
    0x7F: "serviceNotSupportedInActiveSession",
}


class Elm327:
    """Minimal ELM327/STN command wrapper.

    Deliberately thin: this is a reconnaissance tool, so the raw adapter dialogue stays
    visible (``--verbose``) rather than being hidden behind an abstraction.
    """

    def __init__(self, port: str, baudrate: int, timeout: float, verbose: bool = False):
        if serial is None:
            raise SystemExit("pyserial is required: pip install pyserial")
        self.ser = serial.Serial(port, baudrate=baudrate, timeout=timeout)
        self.verbose = verbose

    def close(self) -> None:
        self.ser.close()

    def command(self, cmd: str, delay: float = 0.1) -> str:
        """Send one command, return the adapter's reply with the '>' prompt stripped."""
        self.ser.reset_input_buffer()
        self.ser.write((cmd + "\r").encode("ascii"))
        time.sleep(delay)
        raw = b""
        deadline = time.time() + self.ser.timeout
        while time.time() < deadline:
            chunk = self.ser.read(self.ser.in_waiting or 1)
            if not chunk:
                break
            raw += chunk
            if b">" in raw:
                break
        reply = raw.decode("ascii", errors="replace").replace(">", "").strip()
        if self.verbose:
            print(f"  >> {cmd}\n  << {reply!r}", file=sys.stderr)
        return reply

    def init(self, protocol: str) -> dict[str, str]:
        """Reset the adapter and select a protocol. Returns adapter identity info."""
        info = {}
        info["adapter"] = self.command("ATZ", delay=1.0)
        self.command("ATE0")
        self.command("ATL0")
        # Spaces ON (ATS1) deliberately: separated bytes are unambiguous to parse. The
        # parser also handles the compact form, since some adapters ignore this.
        self.command("ATS1")
        info["voltage"] = self.command("ATRV")
        info["protocol_set"] = self.command(f"ATSP{protocol}")
        info["protocol"] = self.command("ATDP")
        return info


def parse_response(reply: str) -> list[list[int]]:
    """Turn an adapter reply into a list of byte sequences, one per response line.

    Handles both adapter output styles, because whether spaces appear depends on the
    adapter's ATS setting and not every adapter honours ours:

        spaced   "7E8 06 62 F1 90 01"   (optional 3-digit CAN header when ATH1)
        compact  "7E80662F19001"        (same reply with spaces off)
    """
    frames = []
    for line in reply.splitlines():
        line = line.strip()
        if not line or line in {"OK", "SEARCHING..."}:
            continue
        if any(marker in line for marker in ("NO DATA", "ERROR", "UNABLE", "?", "STOPPED")):
            continue
        # An ISO-TP multi-line reply prefixes each line with a frame index ("0:", "1:").
        if ":" in line:
            line = line.split(":", 1)[1].strip()
        byte_values = _line_to_bytes(line)
        if byte_values:
            frames.append(byte_values)
    return frames


def _line_to_bytes(line: str) -> list[int]:
    """Decode one response line to bytes, spaced or compact."""
    tokens = line.split()
    if len(tokens) > 1:
        # Spaced: two-character tokens are payload bytes. A three-character token is
        # the 11-bit CAN header (present under ATH1) and is not payload.
        return [int(tok, 16) for tok in tokens if len(tok) == 2 and _is_hex(tok)]

    compact = tokens[0] if tokens else ""
    if not compact or not _is_hex(compact):
        return []
    if len(compact) % 2:
        # Odd length means either a leading 3-digit CAN header or a bare multi-frame
        # total-length line ("014"). Dropping three characters resolves the first and
        # empties the second, which is the right outcome for both.
        compact = compact[3:]
        if not compact or len(compact) % 2:
            return []
    return [int(compact[i : i + 2], 16) for i in range(0, len(compact), 2)]


def _is_hex(token: str) -> bool:
    try:
        int(token, 16)
    except ValueError:
        return False
    return True


def classify(frames: list[list[int]], service: int) -> dict[str, object]:
    """Classify a response as positive, negative (with NRC name), or empty.

    Adapters differ in whether they strip the ISO-TP PCI byte and the CAN header, so the
    service byte is looked for in the first two positions rather than only the first.
    """
    for data in frames:
        for offset in (0, 1):
            if len(data) <= offset:
                continue
            if data[offset] == service + 0x40:
                payload = data[offset:]
                return {"result": "positive", "data": " ".join(f"{b:02X}" for b in payload)}
            if data[offset] == 0x7F and len(data) >= offset + 3:
                nrc = data[offset + 2]
                return {
                    "result": "negative",
                    "nrc": f"0x{nrc:02X}",
                    "nrc_name": NRC.get(nrc, "unknown"),
                }
    return {"result": "no_response"}


def response_id_for(request_id: str) -> str | None:
    """Paired response ID for a standard OBD-II physical request ID (0x7E0 -> 0x7E8).

    Returns None outside that range, where the pairing is manufacturer-defined and
    guessing would filter out the very replies we are looking for.
    """
    value = int(request_id, 16)
    if 0x7E0 <= value <= 0x7E7:
        return f"0x{value + 8:03X}"
    return None


def probe_ecu(elm: Elm327, ecu_request_id: str, extended: bool) -> dict[str, object]:
    """Basic liveness probe of one ECU address. Read-only.

    `ecu_request_id` is a REQUEST id: it becomes the ATSH transmit header.
    """
    elm.command(f"ATSH {ecu_request_id[2:]}")
    response_id = response_id_for(ecu_request_id)
    if response_id:
        elm.command(f"ATCRA {response_id[2:]}")
    else:
        elm.command("ATCRA")  # clear any previous filter
    out: dict[str, object] = {"request_id": ecu_request_id, "response_id": response_id}

    vin = parse_response(elm.command("0902", delay=0.5))
    out["vin_request"] = classify(vin, 0x09)

    did_f190 = parse_response(elm.command("22F190", delay=0.3))
    out["did_F190"] = classify(did_f190, 0x22)

    if extended:
        session = parse_response(elm.command("1003", delay=0.3))
        out["extended_session"] = classify(session, 0x10)
    return out


def sweep_dids(
    elm: Elm327, start: int, end: int, delay: float, verbose: bool
) -> list[dict[str, object]]:
    """Walk 22 <DID> across a range and record everything that answers.

    Read-only by construction: service 0x22 cannot modify ECU state. Negative responses
    are recorded too — a `securityAccessDenied` on a DID is itself a finding, because it
    says the identifier exists.
    """
    hits = []
    for did in range(start, end + 1):
        reply = elm.command(f"22{did:04X}", delay=delay)
        verdict = classify(parse_response(reply), 0x22)
        if verdict["result"] == "no_response":
            continue
        if verdict["result"] == "negative" and verdict.get("nrc") == "0x31":
            # requestOutOfRange: the identifier simply does not exist. Not a finding.
            continue
        entry = {"did": f"0x{did:04X}", **verdict}
        hits.append(entry)
        if verbose:
            print(f"  hit {entry}", file=sys.stderr)
    return hits


# ---------------------------------------------------------------------------
# Vehicle-specific helpers.
#
# These implement the two protocols documented under docs/devices/. Both are
# derived from vendor tool binaries and have NOT yet been confirmed against a
# bike, so treat the first run as the confirmation.
# ---------------------------------------------------------------------------


def triumph_cluster_init(elm: Elm327) -> None:
    """Set up the Triumph instrument-cluster stack: 11-bit CAN 0x701 -> 0x704.

    Auto-formatting and flow control OFF — this stack is raw frames, not ISO-TP.
    Headers ON because the reply is matched on its `704 ` prefix.
    """
    for cmd in ("ATWS", "ATE0", "ATL0", "ATH1", "ATTP6",
                "ATCAF0", "ATCFC0", "ATSH701", "ATCRA704", "ATST7F"):
        elm.command(cmd)


def triumph_read_sia(elm: Elm327) -> dict[str, object]:
    """Read Triumph cluster state. Read-only.

    `0D 01` answers `704 8D 01 <b1> <b2> <b3>` where the three bytes are a 24-bit
    big-endian odometer in KILOMETRES. `5E 01` answers `704 DE` on TFT-dash bikes,
    which selects which mile divisor the tool uses (1.60934 vs 1.6099895 — the
    source of the ~1 mile discrepancy owners see between tool and dash).
    """
    out: dict[str, object] = {}
    reply = elm.command("0D01", delay=0.4)
    out["raw_odo_reply"] = reply.replace("\r", " ").strip()
    frames = parse_response(reply)
    for data in frames:
        # 8D 01 <b1> <b2> <b3>, with or without a leading header byte.
        for off in (0, 1):
            if len(data) >= off + 5 and data[off] == 0x8D and data[off + 1] == 0x01:
                km = (data[off + 2] << 16) | (data[off + 3] << 8) | data[off + 4]
                out["odometer_km"] = km
                out["odometer_miles"] = round(km / 1.60934, 1)
                break
    tft = elm.command("5E01", delay=0.4)
    out["tft_dash"] = "DE" in tft.upper()
    return out


def triumph_service_reset(elm: Elm327, distance: int, units: str) -> dict[str, object]:
    """Reset the Triumph service interval. THIS WRITES.

    `33 <km/100>` or `34 <miles/100>`; success is a reply beginning `704 B3`/`704 B4`.
    The value is divided by 100, so only multiples of 100 are expressible.
    """
    if distance % 100:
        raise SystemExit(f"interval must be a multiple of 100 (got {distance})")
    scaled = distance // 100
    if not 1 <= scaled <= 0xFF:
        raise SystemExit(f"interval {distance} does not fit the one-byte field")
    opcode = "33" if units == "km" else "34"
    reply = elm.command(f"{opcode}{scaled:02X}", delay=1.0)
    upper = reply.upper()
    return {
        "request": f"{opcode} {scaled:02X}",
        "reply": reply.replace("\r", " ").strip(),
        "ok": "B3" in upper or "B4" in upper,
    }


def bmw_module_init(elm: Elm327, addr: int) -> None:
    """Set up BMW D-CAN for one module address: tester 0x6F1, replies on 0x600+addr."""
    for cmd in ("ATWS", "ATE0", "ATL0", "ATH1", "ATSPB", "ATPBC101",
                "ATSH6F1", "ATFCSH6F1", f"ATFCSD{addr:02X}300008", "ATFCSM1",
                f"ATCEA{addr:02X}", "ATCM7FF", f"ATCF6{addr:02X}", "ATST90", "ATBI"):
        elm.command(cmd)


def bmw_scan_modules(elm: Elm327, addresses: range, verbose: bool) -> list[dict[str, object]]:
    """Sweep BMW module addresses and report which answer. Read-only.

    MotoScan's module addresses are not published, so find them: for each address,
    set up the 6F1 stack and ask for the standard VIN DID. Anything that answers —
    positively or with a negative response code — is a live module.
    """
    found = []
    for addr in addresses:
        bmw_module_init(elm, addr)
        verdict = classify(parse_response(elm.command("22F190", delay=0.3)), 0x22)
        if verdict["result"] == "no_response":
            continue
        entry = {"address": f"0x{addr:02X}", "reply_id": f"0x{0x600 + addr:03X}", **verdict}
        found.append(entry)
        if verbose:
            print(f"  module {entry}", file=sys.stderr)
    return found


def bmw_read_service(elm: Elm327) -> dict[str, object]:
    """Read BMW service state from the currently addressed module. Read-only.

    Payload starts at offset 3 in every reply.
    """
    out: dict[str, object] = {}
    for name, req, length in (
        ("odometer_km", "22E119", 7),
        ("clock", "22E12B", 10),
        ("service_date", "22E12C", 7),
        ("service_distance_km", "22E12D", 5),
    ):
        frames = parse_response(elm.command(req, delay=0.4))
        data = next((f for f in frames if len(f) >= length), None)
        if data is None:
            out[name] = None
            continue
        body = data[3:]
        if name == "odometer_km":
            out[name] = int.from_bytes(bytes(body[:4]), "big")
        elif name == "service_distance_km":
            out[name] = int.from_bytes(bytes(body[:2]), "big")
        elif name == "service_date":
            out[name] = f"{body[0]:02d}.{body[1]:02d}.{(body[2] << 8) | body[3]:04d}"
        else:
            out[name] = (
                f"{body[3]:02d}.{body[4]:02d}.{(body[5] << 8) | body[6]:04d} "
                f"{body[0]:02d}:{body[1]:02d}:{body[2]:02d}"
            )
    return out


def parse_range(text: str) -> tuple[int, int]:
    """Parse '0xF180-0xF1FF' or a single '0xF190' into an inclusive range."""
    if "-" in text:
        low, high = text.split("-", 1)
        return int(low, 16), int(high, 16)
    value = int(text, 16)
    return value, value


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Read-only OBD-II/UDS reconnaissance over an ELM327-class adapter.",
        epilog="Stationary, owned vehicle only. This tool never writes.",
    )
    parser.add_argument("--port", required=True, help="Serial port, e.g. /dev/rfcomm0")
    parser.add_argument("--baud", type=int, default=115200, help="Serial baud rate")
    parser.add_argument("--timeout", type=float, default=2.0, help="Serial read timeout (s)")
    parser.add_argument(
        "--protocol",
        default=DEFAULT_PROTOCOL,
        help="ELM327 protocol number (default 6 = ISO 15765-4, 11-bit, 500 kbit/s)",
    )
    parser.add_argument(
        "--ecu",
        action="append",
        default=None,
        help="Request CAN ID to probe, repeatable (default: 0x7E0, 0x7E8)",
    )
    parser.add_argument(
        "--extended",
        action="store_true",
        help="Also try entering the extended diagnostic session (10 03) on each ECU",
    )
    parser.add_argument(
        "--scan-dids",
        metavar="RANGE",
        help="Sweep ReadDataByIdentifier over a hex range, e.g. 0xF180-0xF1FF",
    )
    parser.add_argument(
        "--scan-delay", type=float, default=0.15, help="Delay between sweep requests (s)"
    )
    parser.add_argument(
        "--triumph-sia",
        action="store_true",
        help="Read Triumph cluster state (odometer, TFT dash). Read-only.",
    )
    parser.add_argument(
        "--triumph-reset",
        metavar="DISTANCE",
        type=int,
        help="Reset the Triumph service interval to DISTANCE (multiple of 100). WRITES; needs --yes-write.",
    )
    parser.add_argument(
        "--units", choices=["km", "miles"], default="km", help="Units for --triumph-reset"
    )
    parser.add_argument(
        "--bmw-scan",
        metavar="RANGE",
        help="Sweep BMW module addresses, e.g. 0x00-0x7F. Read-only.",
    )
    parser.add_argument(
        "--bmw-module",
        metavar="ADDR",
        help="Address a single BMW module (e.g. 0x60) and read its service state. Read-only.",
    )
    parser.add_argument(
        "--yes-write",
        action="store_true",
        help="Confirm you intend to write to the vehicle. Required for any write.",
    )
    parser.add_argument("--json", action="store_true", help="Emit JSON")
    parser.add_argument("--verbose", action="store_true", help="Echo the adapter dialogue")
    args = parser.parse_args()

    elm = Elm327(args.port, args.baud, args.timeout, args.verbose)
    report: dict[str, object] = {}
    try:
        # Vehicle-specific modes drive their own init and return early.
        if args.triumph_sia or args.triumph_reset is not None:
            elm.command("ATZ", delay=1.0)
            triumph_cluster_init(elm)
            report["before"] = triumph_read_sia(elm)
            if args.triumph_reset is not None:
                if not args.yes_write:
                    raise SystemExit(
                        "--triumph-reset writes to the cluster. Re-run with --yes-write "
                        "once the owner has agreed and the values above are recorded."
                    )
                report["reset"] = triumph_service_reset(elm, args.triumph_reset, args.units)
                report["after"] = triumph_read_sia(elm)
            print(json.dumps(report, indent=2))
            return

        if args.bmw_scan or args.bmw_module:
            elm.command("ATZ", delay=1.0)
            if args.bmw_scan:
                lo, hi = parse_range(args.bmw_scan)
                report["modules"] = bmw_scan_modules(elm, range(lo, hi + 1), args.verbose)
            if args.bmw_module:
                addr = int(args.bmw_module, 16)
                bmw_module_init(elm, addr)
                report["module"] = f"0x{addr:02X}"
                report["service"] = bmw_read_service(elm)
            print(json.dumps(report, indent=2))
            return

        report["adapter"] = elm.init(args.protocol)
        ecus = args.ecu or DEFAULT_ECUS
        report["ecus"] = [probe_ecu(elm, ecu, args.extended) for ecu in ecus]

        if args.scan_dids:
            start, end = parse_range(args.scan_dids)
            elm.command(f"ATSH {ecus[0][2:]}")
            sweep_response_id = response_id_for(ecus[0])
            elm.command(f"ATCRA {sweep_response_id[2:]}" if sweep_response_id else "ATCRA")
            report["did_sweep"] = {
                "request_id": ecus[0],
                "range": args.scan_dids,
                "hits": sweep_dids(elm, start, end, args.scan_delay, args.verbose),
            }
    finally:
        elm.close()

    if args.json:
        print(json.dumps(report, indent=2))
        return

    adapter = report["adapter"]
    print(f"Adapter: {adapter['adapter']}")
    print(f"Voltage: {adapter['voltage']}   Protocol: {adapter['protocol']}")
    for ecu in report["ecus"]:
        print(f"\nECU {ecu['request_id']}")
        for key, value in ecu.items():
            if key == "request_id":
                continue
            print(f"  {key}: {value}")
    sweep = report.get("did_sweep")
    if sweep:
        print(f"\nDID sweep {sweep['range']} on {sweep['request_id']}: {len(sweep['hits'])} hits")
        for hit in sweep["hits"]:
            print(f"  {hit}")


if __name__ == "__main__":
    main()
