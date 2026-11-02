# Copyright 2026 Pigs Can Fly Labs LLC
# SPDX-License-Identifier: Apache-2.0
"""Holds the Yummly Smart Thermometer spec to its own stated algorithms.

`device-specs/devices/yummly-smart-thermometer.yaml` says the XW2 dock packs
every number as a 4-bit rotation selector over a W-bit field holding the
reading rotated right by that many bits, and that the challenge reply is the
brand id packed the same way at W = 4. This module transcribes both rules
with nothing but the standard library, imports none of our code, and checks:

* every vector under `protocol_details.xw2_rotation_packing.vectors` decodes
  to its stated value, from both its little-endian bytes and its integer;
* a second, independent statement of the decode (the mask form the vendor
  app uses, as the spec's `algorithm` restates it) agrees with the rotation
  form for every selector and field width;
* the challenge codes are exactly {02, 11, 28};
* the published frames parse under the TLV size rule and decode to the
  documented firmware string, battery bars, name and status;
* the fixed request frames follow the `01 <request>` shape and the
  request/reply table, and the probe-targeted templates render to the
  published wrapper with a documentation address.
"""

from __future__ import annotations

from pathlib import Path

import pytest
import yaml

REPO_ROOT = Path(__file__).resolve().parent.parent
SPEC_PATH = REPO_ROOT / "device-specs" / "devices" / "yummly-smart-thermometer.yaml"
REQUEST_UUID = "6e40aa02-b5a3-f393-e0a9-e50e4159414d"
NOTIFY_UUID = "6e40aa03-b5a3-f393-e0a9-e50e4159414d"

# RFC 7042 documentation address, as the spec writes it on the wire (reversed).
DOC_MAC_WIRE = bytes.fromhex("0153005e0000")

WIDTHS = {"core_temperature": 20, "body_temperature": 12, "battery": 4}
BYTES = {"core_temperature": 3, "body_temperature": 2, "battery": 1}


# ---------------------------------------------------------------------------
# The algorithm, transcribed from the spec's prose
# ---------------------------------------------------------------------------
def unpack_rotation(packed: int, width: int) -> int:
    """Rotation form: rotate the W-bit field left by the selector."""
    s = packed >> width
    field = packed & ((1 << width) - 1)
    if s == 0:
        return field
    return ((field << s) | (field >> (width - s))) & ((1 << width) - 1)


def unpack_mask_form(packed: int, width: int) -> int:
    """The vendor app's spelling, as the spec restates it."""
    s = packed >> width
    field = packed & ((1 << width) - 1)
    m = ((1 << s) - 1) << (width - s)
    return (((field & ~m) << s) | ((field & m) >> (width - s))) & ((1 << width) - 1)


def pack_rotation(value: int, s: int, width: int) -> int:
    """Encoder, for round-trips: rotate right by s, put s in the top nibble."""
    value &= (1 << width) - 1
    if s:
        value = ((value >> s) | (value << (width - s))) & ((1 << width) - 1)
    return value | (s << width)


def battery_bars(gauge: int) -> int:
    if 1 <= gauge <= 3:
        return 1
    if 4 <= gauge <= 5:
        return 2
    if 6 <= gauge <= 8:
        return 3
    if gauge == 9:
        return 4
    return 0


def challenge_code(brand_id: int, s: int) -> int:
    return pack_rotation(brand_id, s, 4)


def parse_tlv(frame: bytes) -> tuple[int, bytes]:
    """Return (type, value) under the 'size is the last value index' rule."""
    size, typ = frame[0], frame[1]
    assert len(frame) >= size + 1, "frame shorter than its size byte claims"
    return typ, frame[2 : size + 1]


def parse_wrapped(frame: bytes) -> tuple[bytes, int, bytes]:
    """Return (probe address on the wire, inner type, inner value)."""
    typ, outer_value = parse_tlv(frame)
    assert typ == 0x07 and frame[0] == 0x07
    mac = outer_value
    inner = frame[frame[0] + 1 :]
    inner_type, inner_value = parse_tlv(inner)
    return mac, inner_type, inner_value


def hexbytes(text: str) -> bytes:
    return bytes.fromhex(text.replace(" ", ""))


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------
@pytest.fixture(scope="module")
def spec() -> dict:
    return yaml.safe_load(SPEC_PATH.read_text(encoding="utf-8"))


@pytest.fixture(scope="module")
def details(spec) -> dict:
    return spec["protocol_details"]


def _characteristic(spec: dict, uuid: str) -> dict:
    for service in spec["services"]:
        for char in service["characteristics"]:
            if char["uuid"] == uuid:
                return char
    raise AssertionError(f"{uuid} not found")


@pytest.fixture(scope="module")
def commands(spec) -> dict:
    return _characteristic(spec, REQUEST_UUID)["commands"]


# ---------------------------------------------------------------------------
# Rotation packing
# ---------------------------------------------------------------------------
def test_both_statements_of_the_decode_agree_everywhere():
    for width in WIDTHS.values():
        for s in range(min(width, 16)):
            for value in range(0, 1 << width, 1009 if width == 20 else 1):
                packed = pack_rotation(value, s, width)
                assert unpack_rotation(packed, width) == value, (width, s, value)
                assert unpack_mask_form(packed, width) == value, (width, s, value)


def test_every_spec_vector_decodes_to_its_stated_value(details):
    vectors = details["xw2_rotation_packing"]["vectors"]
    assert len(vectors) >= 10, "the spec should carry a real set of vectors"
    seen_fields = set()
    for vector in vectors:
        field = vector["field"]
        width = WIDTHS[field]
        seen_fields.add(field)
        if "packed_le_hex" in vector:
            packed = int.from_bytes(bytes.fromhex(vector["packed_le_hex"]), "little")
            assert len(bytes.fromhex(vector["packed_le_hex"])) == BYTES[field], vector
            assert packed == vector["packed_int"], f"{vector}: bytes and integer disagree"
        else:
            packed = int(vector["packed_hex"], 16)
        assert packed >> width == vector["selector"], f"{vector}: selector"
        assert unpack_rotation(packed, width) == vector["decoded"], f"{vector}: decode"
        assert unpack_mask_form(packed, width) == vector["decoded"], f"{vector}: mask form"
        if field == "battery":
            assert battery_bars(vector["decoded"]) == vector["bars"], vector
        if field == "core_temperature":
            assert 320 <= vector["decoded"] <= 2120
            assert vector["value"] == f"{vector['decoded'] / 10:.1f} F"
        if field == "body_temperature":
            assert 32 <= vector["decoded"] <= 572
            assert vector["value"] == f"{vector['decoded']} F"
    assert seen_fields == set(WIDTHS), "every packed field needs a vector"


def test_published_battery_bytes_are_the_reported_vectors(details):
    reported = {
        v["packed_hex"]: (v["decoded"], v["bars"])
        for v in details["xw2_rotation_packing"]["vectors"]
        if v["field"] == "battery" and v["verification"] == "reported"
    }
    assert reported == {"2d": (7, 3), "33": (9, 4)}


def test_field_table_matches_the_transcription(details):
    fields = details["xw2_rotation_packing"]["fields"]
    for name, width in WIDTHS.items():
        assert fields[name]["field_bits"] == width
        assert fields[name]["selector_bits"] == 4
        assert fields[name]["bytes"] == BYTES[name]
    assert fields["core_temperature"]["clamp"] == [320, 2120]
    assert fields["body_temperature"]["clamp"] == [32, 572]


# ---------------------------------------------------------------------------
# Challenge
# ---------------------------------------------------------------------------
def test_challenge_codes_are_the_three_the_dock_accepts(details, commands):
    auth = details["xw2_auth_challenge"]
    brand = auth["brand_id"]
    assert brand == 2
    codes = {v["selector"]: v["code"] for v in auth["vectors"]}
    assert codes == {s: challenge_code(brand, s) for s in range(3)}
    assert sorted(codes.values()) == [0x02, 0x11, 0x28]
    # The command's allowed list is the same set, and the example frame renders.
    allowed = commands["auth_reply"]["parameters"]["code"]["allowed"]
    assert sorted(allowed) == sorted(codes.values())
    rendered = render(commands["auth_reply"]["template"], {"code": codes[0]})
    assert rendered.hex(" ") == auth["reply_frame_example"]
    assert rendered[0] == len(rendered) - 1, "size byte is the last value index"


# ---------------------------------------------------------------------------
# Frames
# ---------------------------------------------------------------------------
def test_published_frames_parse_under_the_size_rule(details):
    frames = details["xw2_published_frames"]
    assert hexbytes(frames["challenge_ping"]) == b"\x01\xab"

    typ, value = parse_tlv(hexbytes(frames["dock_firmware_reply"]))
    assert (typ, value) == (0x04, b"1.53")

    typ, value = parse_tlv(hexbytes(frames["dock_battery_reply"]))
    assert typ == 0x15
    assert battery_bars(unpack_rotation(value[0], 4)) == 3

    mac, inner_type, inner_value = parse_wrapped(hexbytes(frames["probe_name_reply"]))
    assert mac == DOC_MAC_WIRE
    assert inner_type == 0x22
    assert inner_value.rstrip(b"\x00") == b"Yummly P1"

    mac, inner_type, inner_value = parse_wrapped(hexbytes(frames["probe_battery_reply"]))
    assert (mac, inner_type) == (DOC_MAC_WIRE, 0x03)
    assert battery_bars(unpack_rotation(inner_value[0], 4)) == 4

    mac, inner_type, inner_value = parse_wrapped(hexbytes(frames["probe_status_reply_observed"]))
    assert mac == bytes(6)
    assert (inner_type, inner_value) == (0x1E, b"\x05")

    mac, inner_type, inner_value = parse_wrapped(hexbytes(frames["probe_name_request"]))
    assert (mac, inner_type, inner_value) == (DOC_MAC_WIRE, 0x23, b"")


def test_payload_format_examples_decode_as_documented(spec):
    formats = spec["payload_formats"]

    typ, value = parse_tlv(hexbytes(formats["Xw2Frame"]["example"]))
    assert (typ, value) == (0x04, b"1.53")

    mac, inner_type, inner_value = parse_wrapped(hexbytes(formats["Xw2AmbientTemperature"]["example"]))
    assert (mac, inner_type) == (DOC_MAC_WIRE, 0x02)
    raw = int.from_bytes(inner_value, "little")
    assert unpack_rotation(raw, 12) == 275

    typ, value = parse_tlv(hexbytes(formats["Xw2Battery"]["example"]))
    assert typ == 0x15 and battery_bars(unpack_rotation(value[0], 4)) == 3

    mac, inner_type, inner_value = parse_wrapped(hexbytes(formats["Xw2ProbeStatus"]["example"]))
    assert (inner_type, inner_value) == (0x1E, b"\x05")

    typ, value = parse_tlv(hexbytes(formats["Xw2ProbeMac"]["example"]))
    assert (typ, value) == (0x20, DOC_MAC_WIRE)


def test_core_frame_in_the_vector_notes_decodes_through_the_format_block(spec, details):
    """The frame quoted beside the selector-2 core vector is a real core frame."""
    char = _characteristic(spec, NOTIFY_UUID)
    match = char["format_match"]
    fields = {f["name"]: f for f in char["format"]}
    frame = hexbytes("07 07 01 53 00 5e 00 00 04 01 4b 01 20")
    assert frame[match["offset"]] == match["value"]
    packed_field = fields["core_temp_packed"]
    assert packed_field["type"] == "uint24" and packed_field["endianness"] == "little"
    start, length = packed_field["offset"], packed_field["length"]
    packed = int.from_bytes(frame[start : start + length], "little")
    vector = next(
        v
        for v in details["xw2_rotation_packing"]["vectors"]
        if v["field"] == "core_temperature" and v["selector"] == 2 and v["decoded"] == 1324
    )
    assert packed == vector["packed_int"]
    assert unpack_rotation(packed, 20) / 10 == 132.4
    # And the generic wrapped parser agrees on where the inner value sits.
    mac, inner_type, inner_value = parse_wrapped(frame)
    assert (mac, inner_type) == (DOC_MAC_WIRE, 0x01)
    assert inner_value == frame[start : start + length]


# ---------------------------------------------------------------------------
# Requests
# ---------------------------------------------------------------------------
def render(template: list, params: dict) -> bytes:
    out = bytearray()
    for item in template:
        if isinstance(item, int):
            out.append(item)
        else:
            value = params[item.strip("{}")]
            out.extend(value if isinstance(value, (bytes, bytearray)) else [value])
    return bytes(out)


def test_fixed_requests_follow_the_request_table(commands, details):
    table = details["xw2_request_reply_types"]["dock"]
    expected = {
        "get_base_firmware": table["firmware"]["request"],
        "get_base_model": table["model"]["request"],
        "get_base_battery": table["battery"]["request"],
        "get_base_production_date": table["production_date"]["request"],
        "get_base_rssi": table["rssi"]["request"],
        "get_probe_mac": table["probe_mac"]["request"],
        "get_probe_status": table["probe_status"]["request"],
        "enter_probe_dfu": table["enter_probe_dfu"]["request"],
    }
    for name, request in expected.items():
        frame = bytes(commands[name]["value"])
        assert frame == bytes([0x01, request]), name
        typ, value = parse_tlv(frame)
        assert (typ, value) == (request, b""), f"{name}: a request carries no value"
    # Request bytes and reply types really do differ (except RSSI, as stated).
    for reading, pair in table.items():
        reply = pair.get("reply", pair.get("reply_inner"))
        if reply is None:
            continue
        if reading == "rssi":
            assert pair["request"] == reply
        else:
            assert pair["request"] != reply, reading
    assert commands["enter_probe_dfu"]["advanced"] is True


def test_probe_requests_render_to_the_published_wrapper(commands, details):
    table = details["xw2_request_reply_types"]["probe"]
    expected = {
        "get_probe_firmware": table["firmware"]["request"],
        "get_probe_name": table["name"]["request"],
        "get_probe_model": table["model"]["request"],
        "get_probe_production_date": table["production_date"]["request"],
        "get_probe_battery": table["battery"]["request"],
        "get_probe_rssi": table["rssi"]["request"],
    }
    for name, request in expected.items():
        command = commands[name]
        param = command["parameters"]["probe_mac"]
        assert param["type"] == "bytes" and param["min_length"] == param["max_length"] == 6
        frame = render(command["template"], {"probe_mac": DOC_MAC_WIRE})
        mac, inner_type, inner_value = parse_wrapped(frame)
        assert (mac, inner_type, inner_value) == (DOC_MAC_WIRE, request, b""), name
    name_request = render(commands["get_probe_name"]["template"], {"probe_mac": DOC_MAC_WIRE})
    assert name_request.hex(" ") == details["xw2_published_frames"]["probe_name_request"]


def test_display_address_reverses_the_wire_bytes():
    """aa:bb:cc:dd:ee:ff travels as ff ee dd cc bb aa, as the spec says."""
    assert ":".join(f"{b:02x}" for b in reversed(DOC_MAC_WIRE)) == "00:00:5e:00:53:01"
