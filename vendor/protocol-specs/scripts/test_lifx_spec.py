# Copyright 2026 Pigs Can Fly Labs LLC
# SPDX-License-Identifier: Apache-2.0
"""Proves the LIFX Z spec's LAN control surface can be driven from the spec alone.

`device-specs/devices/lifx-z.yaml` documents the LIFX binary LAN protocol as a
36-byte header plus typed payloads under `payload_formats`, and lists the
message-type numbers under `lifx_lan_protocol`. This module transcribes a
consumer's side of that contract — build the exact datagram for a message from
the documented field offsets, message types and header constants — and holds the
spec to it by diffing against the `example` each message publishes, the same way
`test_wemo_spec.py` holds the Wemo SOAP surface honest.

Everything here reads the YAML and the standard library, nothing else. If a
message cannot be transcribed into the exact datagram the spec publishes, the
layout is underspecified or wrong, and this fails.
"""

from __future__ import annotations

from pathlib import Path

import pytest
import yaml

REPO_ROOT = Path(__file__).resolve().parent.parent
SPEC_PATH = REPO_ROOT / "device-specs" / "devices" / "lifx-z.yaml"

# The consumer-side constants the header description states in prose. Named here
# as the test's own transcription of the spec, so a description that stops
# matching the wire fails here rather than on a strip.
SOURCE = 0x4C425247  # "LBRG"
PROTOCOL_ADDRESSED = 0x1400
PROTOCOL_TAGGED = 0x3400
HEADER_LEN = 36
TARGET = bytes.fromhex("d073d50004a3")  # the example datagrams' device MAC


@pytest.fixture(scope="module")
def spec() -> dict:
    return yaml.safe_load(SPEC_PATH.read_text())


def _formats(spec: dict) -> dict:
    formats = spec.get("payload_formats")
    assert formats, "the spec documents its control-plane payload_formats"
    return formats


def _fields(fmt: dict) -> dict:
    """A format's fields as {name: (offset, bytes)}."""
    return {f["name"]: (f["offset"], f["bytes"]) for f in fmt.get("fields", [])}


def _place(buf: bytearray, fields: dict, name: str, value) -> None:
    """Write `value` at the field's documented offset and width."""
    offset, width = fields[name]
    raw = value if isinstance(value, (bytes, bytearray)) else int(value).to_bytes(width, "little")
    assert len(raw) <= width, f"{name} value overruns its {width}-byte field"
    buf[offset : offset + len(raw)] = raw


def _header(spec: dict, *, msg_type: int, tagged: bool, target: bytes,
            res_required: bool, sequence: int, payload_len: int) -> bytearray:
    """Build the 36-byte header purely from the spec's lan_header field table."""
    fields = _fields(_formats(spec)["lan_header"])
    h = bytearray(HEADER_LEN)
    _place(h, fields, "size", HEADER_LEN + payload_len)
    _place(h, fields, "protocol", PROTOCOL_TAGGED if tagged else PROTOCOL_ADDRESSED)
    _place(h, fields, "source", SOURCE)
    _place(h, fields, "target", target)
    _place(h, fields, "response", 0x01 if res_required else 0x00)
    _place(h, fields, "sequence", sequence)
    _place(h, fields, "type", msg_type)
    return h


def _hsbk(spec: dict, hue: int, saturation: int, brightness: int, kelvin: int) -> bytes:
    fields = _fields(_formats(spec)["hsbk"])
    b = bytearray(8)
    _place(b, fields, "hue", hue)
    _place(b, fields, "saturation", saturation)
    _place(b, fields, "brightness", brightness)
    _place(b, fields, "kelvin", kelvin)
    return bytes(b)


def _message_types(spec: dict) -> dict:
    return spec["lifx_lan_protocol"]["message_types"]


def _multizone_types(spec: dict) -> dict:
    return spec["lifx_lan_protocol"]["multizone_messages"]


def _example(spec: dict, name: str) -> bytes:
    return bytes.fromhex(_formats(spec)[name]["example"])


# ── the header table is internally consistent ────────────────────────────────

def test_header_fields_tile_the_36_bytes_without_gaps_or_overlap(spec):
    fields = _formats(spec)["lan_header"]["fields"]
    covered = bytearray(HEADER_LEN)
    for f in fields:
        for i in range(f["offset"], f["offset"] + f["bytes"]):
            assert i < HEADER_LEN, f"{f['name']} runs past the 36-byte header"
            assert covered[i] == 0, f"{f['name']} overlaps another field at {i}"
            covered[i] = 1
    assert all(covered), "every header byte is accounted for by exactly one field"


# ── each message transcribes to its published example ────────────────────────

def test_get_service_probe(spec):
    built = _header(
        spec,
        msg_type=_message_types(spec)["get_service"],
        tagged=True,
        target=bytes(6),
        res_required=True,
        sequence=0,
        payload_len=0,
    )
    assert bytes(built) == _example(spec, "get_service")


def test_set_power_on(spec):
    fields = _fields(_formats(spec)["set_power"])
    payload = bytearray(6)
    _place(payload, fields, "level", 65535)  # on
    _place(payload, fields, "duration", 0)
    built = _header(
        spec,
        msg_type=_message_types(spec)["set_power"],
        tagged=False,
        target=TARGET,
        res_required=False,
        sequence=3,
        payload_len=len(payload),
    ) + payload
    assert bytes(built) == _example(spec, "set_power")


def test_set_color_full_red(spec):
    fields = _fields(_formats(spec)["set_color"])
    payload = bytearray(13)
    _place(payload, fields, "reserved", 0)
    _place(payload, fields, "color", _hsbk(spec, 0, 65535, 65535, 3500))  # full red
    _place(payload, fields, "duration", 0)
    built = _header(
        spec,
        msg_type=_message_types(spec)["set_color"],
        tagged=False,
        target=TARGET,
        res_required=False,
        sequence=7,
        payload_len=len(payload),
    ) + payload
    assert bytes(built) == _example(spec, "set_color")


def test_set_color_zones_green_zone(spec):
    fields = _fields(_formats(spec)["set_color_zones"])
    payload = bytearray(15)
    _place(payload, fields, "start_index", 3)
    _place(payload, fields, "end_index", 3)
    _place(payload, fields, "color", _hsbk(spec, 21845, 65535, 65535, 3500))  # green
    _place(payload, fields, "duration", 0)
    _place(payload, fields, "apply", 1)
    built = _header(
        spec,
        msg_type=_multizone_types(spec)["set_color_zones"],
        tagged=False,
        target=TARGET,
        res_required=False,
        sequence=4,
        payload_len=len(payload),
    ) + payload
    assert bytes(built) == _example(spec, "set_color_zones")


def test_examples_carry_the_message_type_the_spec_numbers(spec):
    """The type field of each example equals the number the spec lists for it."""
    type_field = _fields(_formats(spec)["lan_header"])["type"]
    offset, width = type_field

    def type_of(name: str) -> int:
        payload = _example(spec, name)
        return int.from_bytes(payload[offset : offset + width], "little")

    assert type_of("get_service") == _message_types(spec)["get_service"]
    assert type_of("set_power") == _message_types(spec)["set_power"]
    assert type_of("set_color") == _message_types(spec)["set_color"]
    assert type_of("set_color_zones") == _multizone_types(spec)["set_color_zones"]
