# Copyright 2026 Pigs Can Fly Labs LLC
# SPDX-License-Identifier: Apache-2.0
"""Proves the Keto-Mojo GK+ spec's frames and records follow its own rules.

`device-specs/devices/keto-mojo-gk-plus.yaml` says a frame is
`7b 01 src 01 dst cmd status len_hi len_lo data check 7d`, with the check a
CRC-16/MODBUS over bytes 1 through the last data byte, sent low byte first
as four nibble bytes; and that a stored result is nine bytes of date, time,
a base-100 value, a meal nibble and a type byte. This module transcribes
those rules with nothing but the standard library and holds every fixed
command, the end-of-records frame and every worked example to them.

The four frames that appear literally in the open-source integration the
spec is read from are pinned here too, so a spec that drifts from the wire
fails here rather than against a meter.
"""

from __future__ import annotations

import re
from datetime import datetime
from pathlib import Path

import pytest
import yaml

REPO_ROOT = Path(__file__).resolve().parent.parent
SPEC_PATH = REPO_ROOT / "device-specs" / "devices" / "keto-mojo-gk-plus.yaml"
SERVICE_UUID = "0003cdd0-0000-1000-8000-00805f9b0131"
NOTIFY_UUID = "0003cdd1-0000-1000-8000-00805f9b0131"
WRITE_UUID = "0003cdd2-0000-1000-8000-00805f9b0131"

# Frames as they appear literally in gjg4000-debug/ha-keto-mojo.
PUBLISHED = {
    "get_unit": "7b01100120aa55000002010d087d",
    "get_serial": "7b0110012077550000010b0b047d",
    "fetch_all_records": "7b01100120dd550000030a060c7d",
}
PUBLISHED_END = "7b01200110d16600000b0903047d"

GLUCOSE_TYPES = {0x11, 0x12, 0x22}
KETONE_TYPES = {0x55, 0x56, 0x66}
CONTROL_TYPES = {0x22, 0x66}


def crc16_modbus(data: bytes) -> int:
    crc = 0xFFFF
    for byte in data:
        crc ^= byte
        for _ in range(8):
            crc = (crc >> 1) ^ 0xA001 if crc & 1 else crc >> 1
    return crc


def check_bytes(body: bytes) -> bytes:
    crc = crc16_modbus(body)
    low, high = crc & 0xFF, crc >> 8
    return bytes([low >> 4, low & 0x0F, high >> 4, high & 0x0F])


def frame(src: int, dst: int, cmd: int, status: int, data: bytes = b"") -> bytes:
    body = bytes([0x01, src, 0x01, dst, cmd, status, len(data) >> 8, len(data) & 0xFF]) + data
    return b"\x7b" + body + check_bytes(body) + b"\x7d"


def split_frame(raw: bytes) -> dict:
    """Validate one frame and return its parts."""
    if raw[0] != 0x7B or raw[-1] != 0x7D:
        raise ValueError("bad delimiters")
    length = int.from_bytes(raw[7:9], "big")
    if len(raw) != 9 + length + 5:
        raise ValueError("length disagrees with frame size")
    data_end = 9 + length
    if raw[data_end : data_end + 4] != check_bytes(raw[1:data_end]):
        raise ValueError("check mismatch")
    return {
        "src": raw[2],
        "dst": raw[4],
        "cmd": raw[5],
        "status": raw[6],
        "data": raw[9:data_end],
    }


def decode_record(data: bytes, glucose_unit: str) -> dict:
    if len(data) != 9:
        raise ValueError("a record is nine bytes")
    year, month, day, hour, minute, hundreds, units, flags, rtype = data
    when = datetime(2000 + year, month, day, hour, minute)
    raw = hundreds * 100 + units
    if rtype in KETONE_TYPES:
        value, unit = raw / 100, "mmol/L"
    elif rtype in GLUCOSE_TYPES:
        value, unit = (raw / 10, "mmol/L") if glucose_unit == "mmol/L" else (float(raw), "mg/dL")
    else:
        raise ValueError(f"unknown record type {rtype:#04x}")
    meal = {1: "pre", 2: "post"}.get(flags >> 4, "general")
    return {
        "when": when,
        "value": value,
        "unit": unit,
        "meal": meal,
        "type": rtype,
        "control": rtype in CONTROL_TYPES,
    }


def gki(glucose: dict, ketone: dict) -> float:
    mmol = glucose["value"] if glucose["unit"] == "mmol/L" else glucose["value"] / 18
    return int(mmol / ketone["value"] * 10) / 10


def hexes(text: str) -> list[bytes]:
    return [
        bytes.fromhex(m.group(0))
        for m in re.finditer(r"7b(?: [0-9a-f]{2}){13,}", text)
    ]


@pytest.fixture(scope="module")
def spec() -> dict:
    return yaml.safe_load(SPEC_PATH.read_text())


@pytest.fixture(scope="module")
def commands(spec) -> dict:
    for service in spec["services"]:
        for char in service["characteristics"]:
            if char["uuid"] == WRITE_UUID:
                return char["commands"]
    raise AssertionError("write characteristic not found")


def test_uuids_are_on_the_vendor_base_not_the_sig_base(spec):
    service = spec["services"][0]
    assert service["uuid"] == SERVICE_UUID
    assert {c["uuid"] for c in service["characteristics"]} == {NOTIFY_UUID, WRITE_UUID}
    for uuid in (SERVICE_UUID, NOTIFY_UUID, WRITE_UUID):
        assert uuid.endswith("-0000-1000-8000-00805f9b0131")
        assert not uuid.endswith("00805f9b34fb")


def test_crc_rule_reproduces_every_published_frame():
    for literal in [*PUBLISHED.values(), PUBLISHED_END]:
        raw = bytes.fromhex(literal)
        split_frame(raw)  # raises on a check mismatch


def test_commands_are_the_published_frames(commands):
    assert set(commands) == set(PUBLISHED)
    for key, literal in PUBLISHED.items():
        assert bytes(commands[key]["value"]) == bytes.fromhex(literal)
        assert commands[key]["verification"] == "reported"
        assert not commands[key].get("advanced")


def test_commands_rebuild_from_the_frame_rule(commands):
    for key, cmd in (("get_unit", 0xAA), ("get_serial", 0x77), ("fetch_all_records", 0xDD)):
        assert bytes(commands[key]["value"]) == frame(0x10, 0x20, cmd, 0x55)


def test_end_of_records_example_is_the_published_frame(spec):
    example = spec["payload_formats"]["EndOfRecords"]["example"]
    raw = bytes.fromhex(example)
    assert raw == bytes.fromhex(PUBLISHED_END)
    assert raw == frame(0x20, 0x10, 0xD1, 0x66)


def test_check_is_nibble_encoded_so_delimiters_cannot_appear():
    for literal in [*PUBLISHED.values(), PUBLISHED_END]:
        raw = bytes.fromhex(literal)
        assert all(b <= 0x0F for b in raw[-5:-1])


def test_unit_reply_examples(spec):
    rules = spec["payload_formats"]["UnitReply"]["parse_rules"]
    frames = [f for rule in rules for f in hexes(rule)]
    assert len(frames) == 2
    codes = {split_frame(f)["data"][0] for f in frames}
    assert codes == {0x11, 0x22}
    assert frames[0] == frame(0x20, 0x10, 0xAA, 0xAA, b"\x11")
    assert bytes.fromhex(spec["payload_formats"]["UnitReply"]["example"]) == frames[0]


def test_unit_reply_check_annotations_match_the_frames(spec):
    for rule in spec["payload_formats"]["UnitReply"]["parse_rules"]:
        stated = re.search(r"check 0x([0-9a-f]{4})", rule)
        if stated:
            (f,) = hexes(rule)
            assert crc16_modbus(f[1:10]) == int(stated.group(1), 16), rule


def test_serial_reply_example_is_an_invented_serial(spec):
    raw = bytes.fromhex(spec["payload_formats"]["SerialReply"]["example"])
    parts = split_frame(raw)
    assert parts["cmd"] == 0x77 and parts["status"] == 0xAA
    assert len(parts["data"]) == 16
    assert parts["data"].decode("ascii").strip("\x00 ") == "SN000TEST0001"


def test_record_examples_decode_as_documented(spec):
    rules = spec["payload_formats"]["RecordFrame"]["parse_rules"]
    worked = [rule for rule in rules if rule.startswith("Worked")]
    assert len(worked) >= 6
    decoded = {}
    for rule in worked:
        (raw,) = hexes(rule)
        parts = split_frame(raw)
        assert (parts["src"], parts["dst"]) == (0x20, 0x10)
        unit = "mmol/L" if "mmol/L meter" in rule else "mg/dL"
        decoded[rule.split(")")[0]] = decode_record(parts["data"], unit)

    pre = decoded["Worked (glucose, pre-meal"]
    assert pre["when"] == datetime(2026, 10, 17, 7, 30)
    assert (pre["value"], pre["unit"], pre["meal"]) == (95, "mg/dL", "pre")

    post = decoded["Worked (glucose, post-meal"]
    assert (post["value"], post["meal"]) == (142, "post")

    glucose = decoded["Worked (GKI pair, glucose half"]
    ketone = decoded["Worked (GKI pair, ketone half"]
    assert (glucose["type"], glucose["value"]) == (0x12, 108)
    assert (ketone["type"], ketone["value"], ketone["unit"]) == (0x56, 1.25, "mmol/L")
    assert gki(glucose, ketone) == 4.8

    control = decoded["Worked (control solution"]
    assert control["control"] and control["value"] == 112

    mmol = decoded["Worked (mmol/L meter"]
    assert (mmol["value"], mmol["unit"]) == (5.4, "mmol/L")


def test_record_example_matches_the_first_worked_record(spec):
    fmt = spec["payload_formats"]["RecordFrame"]
    raw = bytes.fromhex(fmt["example"])
    assert raw in hexes(" ".join(fmt["parse_rules"]))


def test_value_is_base_100_not_uint16():
    data = bytes([26, 10, 17, 7, 30, 0x01, 0x2A, 0x00, 0x11])
    assert decode_record(data, "mg/dL")["value"] == 142  # not 0x012a = 298


def test_corrupt_frames_are_rejected(spec):
    raw = bytearray(bytes.fromhex(spec["payload_formats"]["RecordFrame"]["example"]))
    raw[14] ^= 0x01
    with pytest.raises(ValueError):
        split_frame(bytes(raw))
    with pytest.raises(ValueError):
        decode_record(bytes([26, 10, 17, 7, 30, 0, 95, 0, 0x99]), "mg/dL")


def test_record_type_enum_matches_the_decoder(spec):
    fields = {f["name"]: f for f in spec["payload_formats"]["RecordFrame"]["fields"]}
    assert set(fields["record_type"]["values"]) == GLUCOSE_TYPES | KETONE_TYPES
    assert fields["ketone_mmol_l"]["scale"] == 0.01
    assert fields["glucose_mmol_l"]["scale"] == 0.1
    assert fields["year"]["value_offset"] == 2000


def test_medical_safety_advisory_present(spec):
    advisory = spec["device"]["safety_advisory"]
    assert advisory["acknowledge_required"] is True
    assert "dose" in advisory["summary"]
    assert "control" in advisory["detail"].lower()
