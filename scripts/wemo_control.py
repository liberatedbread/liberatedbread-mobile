#!/usr/bin/env python3
# Copyright 2026 Pigs Can Fly Labs LLC
# SPDX-License-Identifier: Apache-2.0
"""Send SOAP 1.1 control commands to Belkin Wemo devices.

Generates valid SOAP envelopes and dispatches them over HTTP to Wemo
UPnP control URLs. Supports the basicevent and insight services.

By default runs in dry-run mode (prints the SOAP envelope without sending).
Use --execute to actually send commands to a device.

Usage:
    # Dry-run: show what would be sent
    python scripts/wemo_control.py on --device 192.168.1.42:49153
    python scripts/wemo_control.py off --device 192.168.1.42:49153
    python scripts/wemo_control.py state --device 192.168.1.42:49153
    python scripts/wemo_control.py insight --device 192.168.1.42:49153

    # Actually send the command
    python scripts/wemo_control.py on --device 192.168.1.42:49153 --execute

Environment:
    Uses only Python 3 stdlib (xml.etree, urllib, argparse, socket).

VERIFICATION SCAFFOLDING — NOT A SUPPORTED CLIENT.

This exists to check `device-specs/devices/wemo-devices.yaml` against real
hardware, because every `methods[].verified` in that spec is still false. Once
the spec is confirmed it should be deleted; see issue #16.

For actually using a Wemo device, use pywemo (https://github.com/pywemo/pywemo).
It is maintained and tested against far more hardware than this is, and it is
what our documentation points people at. The spec is this project's
contribution; `scripts/test_wemo_spec.py` is what proves the spec stands on its
own without any client.
"""

from __future__ import annotations

import argparse
import sys
import urllib.request
import xml.etree.ElementTree as ET
from datetime import datetime, timezone
from typing import Optional
from xml.sax.saxutils import escape
from urllib.error import URLError

# ── UPnP SOAP constants ──────────────────────────────────────────────────────
SOAP_ENVELOPE_NS = "http://schemas.xmlsoap.org/soap/envelope/"
SOAP_ENCODING_NS = "http://schemas.xmlsoap.org/soap/encoding/"

# Wemo UPnP service URNs.
SERVICE_BASICEVENT = "urn:Belkin:service:basicevent:1"
SERVICE_INSIGHT = "urn:Belkin:service:insight:1"
SERVICE_METAINFO = "urn:Belkin:service:metainfo:1"
SERVICE_TIMESYNC = "urn:Belkin:service:timesync:1"
SERVICE_DEVICEINF = "urn:Belkin:service:deviceinf:1"
SERVICE_WIFI = "urn:Belkin:service:WiFiSetup:1"

# Default control URLs.
CONTROL_BASICEVENT = "/upnp/control/basicevent1"
CONTROL_INSIGHT = "/upnp/control/insight1"


#: Request body template, matching the wire format pywemo and ouimeaux send.
#: The service namespace is declared on the action element rather than the
#: envelope. ElementTree hoists such declarations to the root, which is
#: equivalent XML but not byte-identical to what Wemo firmware normally
#: receives — and these devices run famously crude XML parsers, so this stays
#: as a literal template.
REQUEST_TEMPLATE = (
    '<?xml version="1.0" encoding="utf-8"?>\n'
    '<s:Envelope xmlns:s="{envelope_ns}" s:encodingStyle="{encoding_ns}">\n'
    "<s:Body>\n"
    '<u:{action} xmlns:u="{service}">\n'
    "{args}\n"
    "</u:{action}>\n"
    "</s:Body>\n"
    "</s:Envelope>\n"
)


def build_soap_body(
    service_type: str,
    action: str,
    arguments: Optional[dict[str, str]] = None,
) -> bytes:
    """Build the SOAP 1.1 request body for a UPnP action.

    Action arguments are *unqualified* — ``<BinaryState>1</BinaryState>``, not
    ``<u:BinaryState>``. pywemo, ouimeaux and the Wemo app all send them that
    way; putting them in the service namespace is a plausible-looking way to
    be silently ignored by the device.

    Values are XML-escaped. pywemo does not escape, which means an SSID
    containing ``&`` produces a malformed document; escaping is both correct
    and what any XML parser will decode back to the original string.

    Args:
        service_type: UPnP service URN, e.g. ``urn:Belkin:service:basicevent:1``.
        action: SOAP action name, e.g. ``SetBinaryState``.
        arguments: Ordered action arguments.

    Returns:
        UTF-8 encoded request body.
    """
    args = "\n".join(
        f"<{name}>{escape(value)}</{name}>"
        for name, value in (arguments or {}).items()
    )
    return REQUEST_TEMPLATE.format(
        envelope_ns=SOAP_ENVELOPE_NS,
        encoding_ns=SOAP_ENCODING_NS,
        action=action,
        service=service_type,
        args=args,
    ).encode("utf-8")


def soapaction_header(service_type: str, action: str) -> str:
    """Build the SOAPACTION HTTP header value.

    Example: ``"urn:Belkin:service:basicevent:1#SetBinaryState"``
    """
    return f'"{service_type}#{action}"'


# ── Wemo command builders ────────────────────────────────────────────────────


def build_set_binary_state(binary_state: int) -> tuple[bytes, str, str]:
    """Build a SetBinaryState request.

    Args:
        binary_state: 1 for on, 0 for off.

    Returns:
        Tuple of (request body, service_type, action_name).
    """
    body = build_soap_body(
        SERVICE_BASICEVENT, "SetBinaryState", {"BinaryState": str(binary_state)}
    )
    return body, SERVICE_BASICEVENT, "SetBinaryState"


def build_get_binary_state() -> tuple[bytes, str, str]:
    """Build a GetBinaryState request."""
    return (
        build_soap_body(SERVICE_BASICEVENT, "GetBinaryState"),
        SERVICE_BASICEVENT,
        "GetBinaryState",
    )


def build_get_insight_params() -> tuple[bytes, str, str]:
    """Build a GetInsightParams request."""
    return (
        build_soap_body(SERVICE_INSIGHT, "GetInsightParams"),
        SERVICE_INSIGHT,
        "GetInsightParams",
    )


def build_get_meta_info() -> tuple[bytes, str, str]:
    """Build a GetMetaInfo request."""
    return (
        build_soap_body(SERVICE_METAINFO, "GetMetaInfo"),
        SERVICE_METAINFO,
        "GetMetaInfo",
    )


def build_time_sync() -> tuple[bytes, str, str]:
    """Build a TimeSync request carrying the current UTC timestamp."""
    body = build_soap_body(
        SERVICE_TIMESYNC,
        "TimeSync",
        {"UTC": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S")},
    )
    return body, SERVICE_TIMESYNC, "TimeSync"


def build_get_device_information() -> tuple[bytes, str, str]:
    """Build a GetDeviceInformation request."""
    return (
        build_soap_body(SERVICE_DEVICEINF, "GetDeviceInformation"),
        SERVICE_DEVICEINF,
        "GetDeviceInformation",
    )


# ── SOAP response parsing ────────────────────────────────────────────────────


def parse_soap_response(xml_bytes: bytes) -> Optional[str]:
    """Extract the first text value from a SOAP response body.

    Handles the common Wemo response pattern where the response element
    contains a single text value (e.g. BinaryState, InsightParams).
    """
    try:
        root = ET.fromstring(xml_bytes)
    except ET.ParseError:
        return None

    # Navigate: Envelope → Body → <action>Response → value.
    body = root.find(f"{{{SOAP_ENVELOPE_NS}}}Body")
    if body is None:
        return None

    # The response element is the first child of Body.
    children = list(body)
    if not children:
        return None

    response_el = children[0]
    # Check for direct text, or first child's text.
    if response_el.text and response_el.text.strip():
        return response_el.text.strip()

    # Check first sub-element's text.
    sub_children = list(response_el)
    if sub_children and sub_children[0].text:
        return sub_children[0].text.strip()

    return None


def parse_soap_values(xml_bytes: bytes) -> dict[str, str]:
    """Extract every named value from a SOAP response body.

    Wemo actions such as ``GetMetaInfo`` and ``GetApList`` return one or more
    named children inside the response element; :func:`parse_soap_response`
    only yields the first. Returns an empty dict if the document cannot be
    parsed or carries no values.
    """
    try:
        root = ET.fromstring(xml_bytes)
    except ET.ParseError:
        return {}

    body = root.find(f"{{{SOAP_ENVELOPE_NS}}}Body")
    if body is None:
        return {}

    children = list(body)
    if not children:
        return {}

    values: dict[str, str] = {}
    for el in children[0]:
        tag = el.tag.split("}")[-1] if "}" in el.tag else el.tag
        values[tag] = (el.text or "").strip()
    return values


def post_soap(
    device_addr: str,
    body: bytes,
    service_type: str,
    action: str,
    control_path: str,
    timeout: int = 10,
) -> bytes:
    """POST a SOAP request to a Wemo device and return the raw response body.

    Raises ``URLError`` (or ``HTTPError``, its subclass) on transport failure.
    """
    req = urllib.request.Request(
        f"http://{device_addr}{control_path}",
        data=body,
        headers={
            "Content-Type": 'text/xml; charset="utf-8"',
            "SOAPACTION": soapaction_header(service_type, action),
        },
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return resp.read()


#: Field order of the pipe-delimited InsightParams string, per pywemo.
INSIGHT_PARAM_FIELDS = [
    "state",
    "lastchange",
    "onfor_seconds",
    "ontoday_seconds",
    "ontotal_seconds",
    "timeperiod",
    "wifipower",
    "currentpower_mw",
    "todaymw",
    "totalmw",
    "powerthreshold",
]


def parse_insight_params(raw: str) -> dict[str, str]:
    """Parse the pipe-delimited InsightParams string.

    Format (from pywemo)::

        state|lastchange|onfor|ontoday|ontotal|timeperiod|wifipower|
        currentpower_mw|todaymw|totalmw|powerthreshold

    Fields past the known list are returned as ``field_<n>`` so a firmware that
    appends values is reported rather than silently dropped.
    """
    parts = raw.split("|")

    result: dict[str, str] = {}
    for i, part in enumerate(parts):
        key = (
            INSIGHT_PARAM_FIELDS[i]
            if i < len(INSIGHT_PARAM_FIELDS)
            else f"field_{i}"
        )
        result[key] = part.strip()
    return result


# ── Command dispatch ─────────────────────────────────────────────────────────


def send_soap(
    device_addr: str,
    body_bytes: bytes,
    service_type: str,
    action: str,
    control_path: str,
    dry_run: bool = True,
    timeout: int = 10,
) -> None:
    """Send a SOAP command to a Wemo device (or dry-run print it).

    Args:
        device_addr: IP:port of the device, e.g. ``192.168.1.42:49153``.
        body_bytes: Serialized SOAP request body.
        service_type: UPnP service URN.
        action: SOAP action name.
        control_path: Control URL path on the device.
        dry_run: If True, print the request instead of sending.
        timeout: HTTP timeout in seconds.
    """
    soapaction = soapaction_header(service_type, action)

    url = f"http://{device_addr}{control_path}"

    print(f"── SOAP ACTION: {action} ──")
    print(f"URL:      {url}")
    print(f"SOAPACTION: {soapaction}")
    print()
    print(body_bytes.decode("utf-8"))

    if dry_run:
        print()
        print("[DRY RUN — not sent. Use --execute to send.]")
        return

    print()
    print("[SENDING...]")

    try:
        resp_body = post_soap(
            device_addr=device_addr,
            body=body_bytes,
            service_type=service_type,
            action=action,
            control_path=control_path,
            timeout=timeout,
        )
    except URLError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        raise SystemExit(2) from exc

    print(resp_body.decode("utf-8", errors="replace"))
    print()

    # Try to parse the result.
    result = parse_soap_response(resp_body)
    if result:
        print(f"RESULT: {result}")

        if action == "GetInsightParams":
            insight = parse_insight_params(result)
            print("── InsightParams parsed ──")
            for k, v in insight.items():
                print(f"  {k}: {v}")


# ── CLI ──────────────────────────────────────────────────────────────────────


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Send SOAP 1.1 control commands to Belkin Wemo devices.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  %(prog)s on --device 192.168.1.42:49153       # Dry-run: show SetBinaryState(1)
  %(prog)s off --device 192.168.1.42:49153      # Dry-run: show SetBinaryState(0)
  %(prog)s state --device 192.168.1.42:49153    # Dry-run: show GetBinaryState
  %(prog)s insight --device 192.168.1.42:49153  # Dry-run: show GetInsightParams
  %(prog)s info --device 192.168.1.42:49153     # Dry-run: show GetDeviceInformation
  %(prog)s on --device 192.168.1.42:49153 --execute  # Actually send
        """,
    )
    parser.add_argument(
        "command",
        choices=["on", "off", "state", "insight", "metainfo", "info", "timesync"],
        help="Command to send.",
    )
    parser.add_argument(
        "--device",
        required=True,
        help="Device address as IP:port (e.g. 192.168.1.42:49153).",
    )
    parser.add_argument(
        "--execute",
        action="store_true",
        help="Actually send the command (default: dry-run only).",
    )
    parser.add_argument(
        "--timeout",
        type=int,
        default=10,
        help="HTTP timeout in seconds (default: 10).",
    )

    args = parser.parse_args()

    # Determine control path.
    if args.command == "insight":
        control_path = CONTROL_INSIGHT
    elif args.command in ("metainfo",):
        control_path = "/upnp/control/metainfo1"
    elif args.command in ("timesync",):
        control_path = "/upnp/control/timesync1"
    elif args.command in ("info",):
        control_path = "/upnp/control/deviceinf1"
    else:
        control_path = CONTROL_BASICEVENT

    # Build the SOAP envelope.
    if args.command == "on":
        body, svc_type, action = build_set_binary_state(1)
    elif args.command == "off":
        body, svc_type, action = build_set_binary_state(0)
    elif args.command == "state":
        body, svc_type, action = build_get_binary_state()
    elif args.command == "insight":
        body, svc_type, action = build_get_insight_params()
    elif args.command == "metainfo":
        body, svc_type, action = build_get_meta_info()
    elif args.command == "timesync":
        body, svc_type, action = build_time_sync()
    elif args.command == "info":
        body, svc_type, action = build_get_device_information()
    else:
        print(f"Unknown command: {args.command}", file=sys.stderr)
        return 1

    send_soap(
        device_addr=args.device,
        body_bytes=body,
        service_type=svc_type,
        action=action,
        control_path=control_path,
        dry_run=not args.execute,
        timeout=args.timeout,
    )

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
