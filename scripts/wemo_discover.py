#!/usr/bin/env python3
# Copyright 2026 Pigs Can Fly Labs LLC
# SPDX-License-Identifier: Apache-2.0
"""Discover Belkin Wemo devices on the local LAN via SSDP (UPnP).

Sends an M-SEARCH multicast probe to 239.255.255.250:1900 and collects
responses from Wemo devices. For each discovered device, fetches and
parses the UPnP device description XML at the LOCATION URL to extract
device metadata (deviceType, friendlyName, UDN, serial, MAC, services).

Usage:
    python scripts/wemo_discover.py [--timeout SECONDS] [--json]

Environment:
    No external dependencies. Uses only Python 3 stdlib (socket, xml.etree,
    urllib, argparse, json).

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
import json
import re
import socket
import sys
import time
import urllib.request
import xml.etree.ElementTree as ET
from dataclasses import dataclass, field
from typing import Optional

# ── Constants ────────────────────────────────────────────────────────────────
SSDP_MULTICAST = "239.255.255.250"
SSDP_PORT = 1900
SSDP_MX = 2  # seconds to wait for responses

# Wemo-specific search targets for M-SEARCH ST header.
SEARCH_TARGETS = [
    "urn:Belkin:service:basicevent:1",
    "urn:Belkin:device:controllee:1",
    "urn:Belkin:device:socket:1",
    "ssdp:all",
]

# Port fallback order used by pywemo when the advertised LOCATION is stale.
PROBE_PORTS = [49153, 49152, 49154, 49151, 49155, 49156, 49157, 49158, 49159]

# Timeout for fetching setup.xml after discovery.
HTTP_TIMEOUT = 5  # seconds

# SSDP response patterns.
LOCATION_RE = re.compile(r"(?i)^location:\s*(.+)$", re.MULTILINE)
USN_RE = re.compile(r"(?i)^usn:\s*(.+)$", re.MULTILINE)
ST_RE = re.compile(r"(?i)^st:\s*(.+)$", re.MULTILINE)

# UPnP XML namespaces.
NS = {
    "dn": "urn:schemas-upnp-org:device-1-0",
}


@dataclass
class WemoService:
    """A UPnP service exposed by a Wemo device."""

    service_type: str
    service_id: str
    control_url: str
    event_sub_url: str
    scpd_url: str = ""


@dataclass
class WemoDevice:
    """Parsed Wemo device description from /setup.xml."""

    location_url: str
    ip: str
    port: int
    device_type: str = ""
    friendly_name: str = ""
    manufacturer: str = ""
    model_name: str = ""
    model_number: str = ""
    serial_number: str = ""
    mac_address: str = ""
    udn: str = ""
    usn: str = ""
    services: list[WemoService] = field(default_factory=list)
    #: Belkin's non-standard extension elements inside <device>, e.g.
    #: firmwareVersion, rtos, iot, binaryOption, new_algo. These select the
    #: WiFi-setup password encryption variant — see scripts/wemo_setup.py.
    config_extras: dict[str, str] = field(default_factory=dict)
    raw_ssdp_response: str = ""
    fetch_error: Optional[str] = None

    def service_by_type(self, service_type: str) -> Optional[WemoService]:
        """Return the advertised service with *service_type*, if present."""
        for service in self.services:
            if service.service_type == service_type:
                return service
        return None


def build_msearch_packet(st: str, mx: int = SSDP_MX) -> bytes:
    """Build an SSDP M-SEARCH request packet for the given search target.

    Args:
        st: Search Target (ST header), e.g. ``urn:Belkin:service:basicevent:1``.
        mx: Maximum wait time in seconds for responses.

    Returns:
        Encoded M-SEARCH request as bytes.
    """
    request = (
        "M-SEARCH * HTTP/1.1\r\n"
        f"HOST: {SSDP_MULTICAST}:{SSDP_PORT}\r\n"
        'MAN: "ssdp:discover"\r\n'
        f"MX: {mx}\r\n"
        f"ST: {st}\r\n"
        "\r\n"
    )
    return request.encode("utf-8")


def send_msearch(st: str, timeout: float = 3.0) -> list[str]:
    """Send one M-SEARCH and collect all unicast responses.

    Args:
        st: Search Target to probe for.
        timeout: How long to wait for responses (in seconds).

    Returns:
        List of raw SSDP response strings (headers only, no body).
    """
    responses: list[str] = []

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
    sock.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_TTL, 2)
    sock.settimeout(timeout)

    try:
        packet = build_msearch_packet(st)
        sock.sendto(packet, (SSDP_MULTICAST, SSDP_PORT))

        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                break
            try:
                sock.settimeout(remaining)
                data, addr = sock.recvfrom(4096)
                responses.append(data.decode("utf-8", errors="replace"))
            except socket.timeout:
                break
    finally:
        sock.close()

    return responses


def parse_ssdp_response(raw: str) -> tuple[Optional[str], Optional[str], Optional[str]]:
    """Extract LOCATION, USN, and ST headers from an SSDP response.

    Returns:
        Tuple of (location_url, usn, st) — any may be None if missing.
    """
    location = None
    usn = None
    st = None

    m = LOCATION_RE.search(raw)
    if m:
        location = m.group(1).strip()

    m = USN_RE.search(raw)
    if m:
        usn = m.group(1).strip()

    m = ST_RE.search(raw)
    if m:
        st = m.group(1).strip()

    return location, usn, st


def parse_ip_port(url: str) -> tuple[str, int]:
    """Extract IP and port from a URL like http://192.168.1.42:49153/setup.xml."""
    # Strip scheme
    host_port = url
    for prefix in ("http://", "https://"):
        if host_port.startswith(prefix):
            host_port = host_port[len(prefix) :]
            break

    host, _, path = host_port.partition("/")
    if ":" in host:
        ip, port_str = host.rsplit(":", 1)
        return ip, int(port_str)
    return host, 80


def fetch_setup_xml(url: str, timeout: int = HTTP_TIMEOUT) -> Optional[bytes]:
    """Fetch the UPnP device description XML from a LOCATION URL.

    Returns:
        Raw XML bytes, or None on failure.
    """
    try:
        req = urllib.request.Request(url, method="GET")
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.read()
    except OSError:
        # URLError is an OSError subclass; this also covers socket timeouts.
        return None


def _local_tag(tag: str) -> str:
    """Return an XML tag without its ``{namespace}`` prefix."""
    return tag.split("}")[-1] if "}" in tag else tag


def _find_child(parent: ET.Element, name: str) -> Optional[ET.Element]:
    """Return the first child element with local tag *name*, ignoring namespace."""
    for child in parent:
        if _local_tag(child.tag) == name:
            return child
    return None


def _child_text(parent: ET.Element, name: str) -> str:
    """Return the stripped text of the first child named *name*, or ""."""
    child = _find_child(parent, name)
    return (child.text or "").strip() if child is not None else ""


def parse_setup_xml(xml_bytes: bytes) -> Optional[WemoDevice]:
    """Parse a UPnP device description XML document.

    Returns:
        Parsed WemoDevice, or None if parsing fails.
    """
    try:
        root = ET.fromstring(xml_bytes)
    except ET.ParseError:
        return None

    device_el = root.find(".//dn:device", NS)
    if device_el is None:
        # Some firmware serves the description without the UPnP namespace.
        device_el = next(
            (el for el in root.iter() if _local_tag(el.tag) == "device"), None
        )

    if device_el is None:
        return None

    device = WemoDevice(
        location_url="",
        ip="",
        port=0,
        device_type=_child_text(device_el, "deviceType"),
        friendly_name=_child_text(device_el, "friendlyName"),
        manufacturer=_child_text(device_el, "manufacturer"),
        model_name=_child_text(device_el, "modelName"),
        model_number=_child_text(device_el, "modelNumber"),
        serial_number=_child_text(device_el, "serialNumber"),
        mac_address=_child_text(device_el, "macAddress"),
        udn=_child_text(device_el, "UDN"),
    )

    # Belkin adds non-standard elements alongside the UPnP ones. They are not
    # decoration: rtos/iot/binaryOption/new_algo select which password
    # encryption variant the device expects during WiFi setup.
    standard_tags = {
        "deviceType",
        "friendlyName",
        "manufacturer",
        "manufacturerURL",
        "modelDescription",
        "modelName",
        "modelNumber",
        "modelURL",
        "serialNumber",
        "UDN",
        "UPC",
        "macAddress",
        "iconList",
        "serviceList",
        "deviceList",
        "presentationURL",
    }
    for child in device_el:
        tag = _local_tag(child.tag)
        if tag in standard_tags:
            continue
        text = (child.text or "").strip()
        if text:
            device.config_extras[tag] = text

    # Parse service list. Devices vary in whether they namespace child
    # elements, so match on the local tag name rather than on a namespace.
    service_list_el = _find_child(device_el, "serviceList")

    if service_list_el is not None:
        for svc_el in service_list_el:
            if _local_tag(svc_el.tag) != "service":
                continue
            device.services.append(
                WemoService(
                    service_type=_child_text(svc_el, "serviceType"),
                    service_id=_child_text(svc_el, "serviceId"),
                    control_url=_child_text(svc_el, "controlURL"),
                    event_sub_url=_child_text(svc_el, "eventSubURL"),
                    scpd_url=_child_text(svc_el, "SCPDURL"),
                )
            )

    return device


def probe_port(host: str, ports: Optional[list[int]] = None) -> Optional[int]:
    """Find the port a Wemo device is currently serving /setup.xml on.

    Wemo ports move across 49151-49159 after a power cycle, so the port is
    never identity — probe for it. Returns None if nothing answers.
    """
    for port in ports or PROBE_PORTS:
        xml_data = fetch_setup_xml(f"http://{host}:{port}/setup.xml", timeout=2)
        if xml_data is not None and parse_setup_xml(xml_data) is not None:
            return port
    return None


def device_at(host: str, port: Optional[int] = None) -> Optional[WemoDevice]:
    """Fetch and parse the description of the Wemo device at *host*.

    Probes the known port list when *port* is not given. Returns None when no
    Wemo device answers.
    """
    if port is None:
        port = probe_port(host)
        if port is None:
            return None

    url = f"http://{host}:{port}/setup.xml"
    xml_data = fetch_setup_xml(url)
    if xml_data is None:
        return None

    device = parse_setup_xml(xml_data)
    if device is None:
        return None

    device.location_url = url
    device.ip = host
    device.port = port
    return device


def _merge_parsed(device: WemoDevice, parsed: WemoDevice) -> None:
    """Copy description fields from a parsed setup.xml onto a discovered device."""
    device.device_type = parsed.device_type
    device.friendly_name = parsed.friendly_name
    device.manufacturer = parsed.manufacturer
    device.model_name = parsed.model_name
    device.model_number = parsed.model_number
    device.serial_number = parsed.serial_number
    device.mac_address = parsed.mac_address
    device.udn = parsed.udn
    device.services = parsed.services
    device.config_extras = parsed.config_extras


def _fetch_description(device: WemoDevice, probe_ports: bool) -> None:
    """Fetch and parse the device description, updating *device* in place.

    Tries the SSDP ``LOCATION`` URL first. Wemo ports move across 49152-49159
    after a power cycle, so when the advertised location is stale and
    *probe_ports* is set, the known port list is probed for ``/setup.xml``.
    """
    xml_data = fetch_setup_xml(device.location_url)
    if xml_data is not None:
        parsed = parse_setup_xml(xml_data)
        if parsed is not None:
            _merge_parsed(device, parsed)
            return
        device.fetch_error = f"Failed to parse {device.location_url}"
        return

    if not probe_ports:
        device.fetch_error = f"Failed to fetch {device.location_url}"
        return

    for port in PROBE_PORTS:
        if port == device.port:
            continue
        url = f"http://{device.ip}:{port}/setup.xml"
        xml_data = fetch_setup_xml(url, timeout=1)
        if xml_data is None:
            continue
        parsed = parse_setup_xml(xml_data)
        if parsed is not None:
            _merge_parsed(device, parsed)
            device.location_url = url
            device.port = port
            return

    device.fetch_error = (
        f"Failed to fetch {device.location_url} (also probed ports "
        f"{PROBE_PORTS[0]}-{PROBE_PORTS[-1]})"
    )


def is_wemo(device: WemoDevice) -> bool:
    """Whether a discovered SSDP responder looks like a Belkin Wemo device.

    ``ssdp:all`` is one of the search targets, so every UPnP responder on the
    LAN answers. Belkin identifies itself in the USN/ST of its own search
    targets and in the manufacturer and deviceType of its description.
    """
    haystack = " ".join(
        (
            device.usn,
            device.device_type,
            device.manufacturer,
            device.raw_ssdp_response,
        )
    ).lower()
    return "belkin" in haystack or "wemo" in haystack


def discover(
    timeout: float = 3.0,
    fetch_details: bool = True,
    probe_ports: bool = True,
    wemo_only: bool = True,
) -> list[WemoDevice]:
    """Discover Wemo devices on the local LAN.

    Args:
        timeout: Seconds to wait for M-SEARCH responses, per search target.
        fetch_details: If True, fetch and parse the device description.
        probe_ports: If True, fall back to probing PROBE_PORTS when the
            advertised LOCATION does not answer.
        wemo_only: If True, drop responders that do not identify as Belkin/Wemo.

    Returns:
        List of discovered WemoDevice objects, ordered by IP then port.
    """
    # Collect all SSDP responses (deduplicate by LOCATION).
    seen_locations: dict[str, tuple[str, str, str]] = {}

    for st in SEARCH_TARGETS:
        for resp in send_msearch(st, timeout=timeout):
            loc, usn, search_st = parse_ssdp_response(resp)
            if loc and loc not in seen_locations:
                seen_locations[loc] = (resp, usn or "", search_st or "")

    devices: list[WemoDevice] = []
    for loc, (raw_resp, usn, _search_st) in seen_locations.items():
        ip, port = parse_ip_port(loc)
        device = WemoDevice(
            location_url=loc,
            ip=ip,
            port=port,
            usn=usn,
            raw_ssdp_response=raw_resp,
        )

        if fetch_details:
            _fetch_description(device, probe_ports=probe_ports)

        if wemo_only and not is_wemo(device):
            continue

        devices.append(device)

    devices.sort(key=lambda d: (d.ip, d.port))
    return devices


def format_table(devices: list[WemoDevice]) -> str:
    """Format discovered devices as a human-readable table."""
    if not devices:
        return "No Wemo devices discovered."

    lines = []
    header = f"{'IP':<16} {'Port':<6} {'Name':<24} {'Device Type':<38} {'Serial':<18}"
    lines.append(header)
    lines.append("-" * len(header))

    for d in devices:
        # Shorten deviceType for display.
        dt = d.device_type
        if dt.startswith("urn:Belkin:device:"):
            dt = dt[len("urn:Belkin:device:") :]
        if dt.endswith(":1"):
            dt = dt[:-2]

        lines.append(
            f"{d.ip:<16} {d.port:<6} {d.friendly_name[:23]:<24} "
            f"{dt[:37]:<38} {d.serial_number[:17]:<18}"
        )

        if d.services:
            for svc in d.services:
                st_short = svc.service_type
                if st_short.startswith("urn:Belkin:service:"):
                    st_short = st_short[len("urn:Belkin:service:") :]
                if st_short.endswith(":1"):
                    st_short = st_short[:-2]
                lines.append(
                    f"        Service: {st_short:<20} CTRL={svc.control_url:<30} EVENT={svc.event_sub_url}"
                )

        # rtos/iot decide which passphrase encryption variant this device
        # wants at provisioning time, so surface them next to the firmware.
        notable = {
            k: v
            for k, v in d.config_extras.items()
            if k.lower() in {"firmwareversion", "rtos", "iot", "binaryoption", "new_algo"}
        }
        if notable:
            summary = "  ".join(f"{k}={v}" for k, v in sorted(notable.items()))
            lines.append(f"        Firmware: {summary}")

        if d.fetch_error:
            lines.append(f"        ⚠ {d.fetch_error}")

    return "\n".join(lines)


def format_json(devices: list[WemoDevice]) -> str:
    """Format discovered devices as JSON."""
    result = []
    for d in devices:
        entry = {
            "ip": d.ip,
            "port": d.port,
            "location_url": d.location_url,
            "device_type": d.device_type,
            "friendly_name": d.friendly_name,
            "manufacturer": d.manufacturer,
            "model_name": d.model_name,
            "model_number": d.model_number,
            "serial_number": d.serial_number,
            "mac_address": d.mac_address,
            "udn": d.udn,
            "usn": d.usn,
            "config_extras": d.config_extras,
            "services": [
                {
                    "service_type": svc.service_type,
                    "service_id": svc.service_id,
                    "control_url": svc.control_url,
                    "event_sub_url": svc.event_sub_url,
                }
                for svc in d.services
            ],
        }
        if d.fetch_error:
            entry["fetch_error"] = d.fetch_error
        result.append(entry)
    return json.dumps(result, indent=2, ensure_ascii=False)


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Discover Belkin Wemo devices via SSDP (UPnP).",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  %(prog)s                    # Discover Wemo devices, print table
  %(prog)s --timeout 5        # Wait 5s for responses
  %(prog)s --json             # Output as JSON
  %(prog)s --no-fetch         # Discover only (skip setup.xml fetch)
        """,
    )
    parser.add_argument(
        "--timeout",
        type=float,
        default=3.0,
        help="Seconds to wait for M-SEARCH responses (default: 3.0).",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="Output as JSON instead of a table.",
    )
    parser.add_argument(
        "--no-fetch",
        action="store_true",
        help="Skip fetching /setup.xml; report SSDP responses only.",
    )
    parser.add_argument(
        "--no-probe-ports",
        action="store_true",
        help=(
            "Do not fall back to probing ports "
            f"{PROBE_PORTS[0]}-{PROBE_PORTS[-1]} when the advertised LOCATION "
            "is stale."
        ),
    )
    parser.add_argument(
        "--all",
        action="store_true",
        help="Report every SSDP responder, not just Belkin/Wemo devices.",
    )

    args = parser.parse_args()

    print(f"Probing SSDP multicast on {SSDP_MULTICAST}:{SSDP_PORT}...", file=sys.stderr)
    print(f"Search targets: {', '.join(SEARCH_TARGETS)}", file=sys.stderr)
    print(f"Waiting up to {args.timeout}s per target...", file=sys.stderr)

    devices = discover(
        timeout=args.timeout,
        fetch_details=not args.no_fetch,
        probe_ports=not args.no_probe_ports,
        wemo_only=not args.all,
    )

    print(f"Found {len(devices)} device(s).\n", file=sys.stderr)

    if args.json:
        print(format_json(devices))
    else:
        print(format_table(devices))

    return 0 if devices else 1


if __name__ == "__main__":
    raise SystemExit(main())
