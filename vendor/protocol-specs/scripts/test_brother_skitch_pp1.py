# Copyright 2026 Pigs Can Fly Labs LLC
# SPDX-License-Identifier: Apache-2.0
"""Independently rebuild the Brother Skitch PP1's synthetic protocol vectors.

Command serialization, transfer envelopes and additive checksums below use only
the Python standard library and import no project implementation. PyYAML is used
only to read the specification and its expected vectors. No vector is a capture
or identifies a real machine.
"""

from __future__ import annotations

import re
import struct
from pathlib import Path

import pytest
import yaml

REPO_ROOT = Path(__file__).resolve().parent.parent
SPEC_PATH = REPO_ROOT / "device-specs" / "devices" / "brother-skitch-pp1.yaml"
SERVICE = "a76eb9e0-f3ac-4990-84cf-3a94d2426b2b"
READ = "a76eb9e1-f3ac-4990-84cf-3a94d2426b2b"
WRITE = "a76eb9e2-f3ac-4990-84cf-3a94d2426b2b"


@pytest.fixture(scope="module")
def spec() -> dict:
    return yaml.safe_load(SPEC_PATH.read_text(encoding="utf-8"))


@pytest.fixture(scope="module")
def vectors(spec) -> dict:
    return spec["protocol_details"]["test_vectors"]


def command_frame(opcode: int, payload: bytes = b"") -> bytes:
    """The command opcode is big-endian regardless of payload encoding."""
    return struct.pack(">H", opcode) + payload


def data_info(data: bytes, data_type: int = 3) -> bytes:
    payload = (
        bytes([data_type])
        + struct.pack("<I", len(data))
        + struct.pack("<H", sum(data) & 0xFFFF)
    )
    return command_frame(0x1200, payload)


def data_chunk(chunk: bytes, offset: int) -> bytes:
    payload = struct.pack("<I", offset) + chunk + bytes([sum(chunk) & 0xFF])
    return command_frame(0x1201, payload)


def design_chunks(data: bytes, chunk_size: int) -> list[bytes]:
    return [
        data_chunk(data[offset : offset + chunk_size], offset)
        for offset in range(0, len(data), chunk_size)
    ]


def write_commands(spec: dict) -> dict:
    for service in spec["services"]:
        for characteristic in service.get("characteristics", []):
            if characteristic["uuid"] == WRITE:
                return characteristic["commands"]
    raise AssertionError("PP1 write characteristic not found")


def decode_fields(frame: bytes, layout: dict) -> dict:
    decoded = {}
    for field in layout["fields"]:
        start = field["offset"]
        end = start + field["length"]
        if end > len(frame):
            if field["name"] == "error_code":
                continue
            raise AssertionError(f"short response for {field['name']}")
        raw = frame[start:end]
        if field["type"] == "string":
            value = raw.rstrip(b"\0").decode("ascii")
        else:
            value = int.from_bytes(
                raw,
                field.get("endianness", "little"),
                signed=field["type"].startswith("int"),
            )
        decoded[field["name"]] = value
    return decoded


def walk_values(value, key: str):
    if isinstance(value, dict):
        for child_key, child in value.items():
            if child_key == key:
                yield child
            yield from walk_values(child, key)
    elif isinstance(value, list):
        for child in value:
            yield from walk_values(child, key)


def test_command_opcodes_are_big_endian(vectors):
    for vector in vectors["command_frames"]:
        expected = bytes.fromhex(vector["frame_hex"])
        rebuilt = command_frame(vector["opcode"])
        assert rebuilt == expected, vector["name"]
        high, low = divmod(vector["opcode"], 0x100)
        if high != low:
            assert rebuilt != struct.pack("<H", vector["opcode"]), vector["name"]


def test_declared_commands_use_the_corrected_framing(spec, vectors):
    commands = write_commands(spec)
    by_name = {entry["name"]: entry for entry in vectors["command_frames"]}
    for command_name, vector_name in (
        ("get_information", "information"),
        ("get_status", "status"),
        ("get_service_count", "service_count"),
        ("reset_to_defaults", "reset"),
    ):
        command = commands[command_name]
        assert bytes(command["value"]) == bytes.fromhex(
            by_name[vector_name]["frame_hex"]
        )
        assert command["verification"] == "reported"

    firmware = commands["begin_firmware_update"]
    assert bytes(firmware["template"][:2]) == bytes.fromhex(
        by_name["firmware_begin"]["frame_hex"]
    )
    assert firmware["advanced"] is True
    assert firmware["verification"] == "reported"
    assert commands["reset_to_defaults"]["advanced"] is True
    assert "design_data_info" not in commands
    assert "design_chunk" not in commands
    assert "delete_before_upload" not in commands


def test_design_info_and_chunk_vectors(vectors):
    for vector in vectors["design_envelopes"]:
        data = bytes.fromhex(vector["data_hex"])
        expected_info = bytes.fromhex(vector["info_hex"])
        assert sum(data) & 0xFFFF == vector["expected_sum16"], vector["name"]
        assert data_info(data, vector["data_type"]) == expected_info, vector["name"]

        expected_chunks = [bytes.fromhex(hex) for hex in vector["chunks_hex"]]
        rebuilt_chunks = design_chunks(data, vector["chunk_size"])
        assert rebuilt_chunks == expected_chunks, vector["name"]

        reconstructed = bytearray()
        for offset, chunk in enumerate(rebuilt_chunks):
            expected_offset = offset * vector["chunk_size"]
            assert struct.unpack("<I", chunk[2:6])[0] == expected_offset
            payload = chunk[6:-1]
            assert chunk[-1] == sum(payload) & 0xFF
            reconstructed.extend(payload)
        assert bytes(reconstructed) == data

        if "firmware_info_hex" in vector:
            assert data_info(data, 4) == bytes.fromhex(vector["firmware_info_hex"])


def test_checksum_wraparound_is_explicit(vectors):
    vector = next(
        entry
        for entry in vectors["design_envelopes"]
        if entry["name"] == "wrapping_additive_checksums"
    )
    data = bytes.fromhex(vector["data_hex"])
    assert sum(data) == 0x01FF
    assert data_info(data)[-2:] == b"\xff\x01"
    chunks = design_chunks(data, 2)
    assert chunks[0][-1] == 0
    assert chunks[1][-1] == 0xFF
    assert data_info(data)[0:2] == b"\x12\x00"
    assert chunks[0][0:2] == b"\x12\x01"


def test_response_vectors_decode_against_reported_layouts(spec, vectors):
    layouts = spec["protocol_details"]["response_layouts"]
    for vector in vectors["responses"]:
        frame = bytes.fromhex(vector["frame_hex"])
        layout = layouts[vector["layout"]]
        assert len(frame) >= layout["minimum_length_bytes"]
        assert decode_fields(frame, layout) == vector["expected"], vector["name"]


def test_status_and_error_offsets(vectors):
    vector = next(
        entry for entry in vectors["responses"] if entry["name"] == "synthetic_status"
    )
    frame = bytes.fromhex(vector["frame_hex"])
    assert frame[:2] == b"\x00\x01"
    assert frame[2] == 17
    assert frame[4] == 221
    assert frame[3] != frame[4]


def test_identity_requires_pp1_name_and_shared_service(spec):
    device = spec["device"]
    matcher = device["discovery"]["methods"][0]["ble"]
    pattern = matcher["local_name"]["value"]
    assert matcher["local_name"]["match"] == "regex"
    assert re.fullmatch(pattern, "Brother PP1-0000")
    for other in (
        "Brother PP1E-0000",
        "Brother PP1-123A",
        "Brother PP1-0000-extra",
        "Brother CT-0000",
    ):
        assert not re.fullmatch(pattern, other), other

    assert "service_uuids" not in matcher
    assert SERVICE not in device["identification"].get("service_uuids", [])
    setup_ble = device["setup"]["methods"][0]["ble"]
    assert setup_ble["service_uuid"] == SERVICE
    assert setup_ble["read_characteristic"] == READ
    assert setup_ble["write_characteristic"] == WRITE
    assert spec["services"][0]["uuid"] == SERVICE


def test_scope_stays_narrow_and_all_facts_remain_unverified(spec):
    assert spec["device"]["testing"]["status"] == "untested"
    assert set(walk_values(spec, "verification")) == {"reported"}
    assert all(value is False for value in walk_values(spec, "verified"))

    commands = write_commands(spec)
    assert set(commands) == {
        "get_information",
        "get_service_count",
        "get_status",
        "reset_to_defaults",
        "begin_firmware_update",
    }
    assert [feature["type"] for feature in spec["features"]] == ["firmware_update"]
    assert spec["protocol_details"]["design_transfer"]["implementable_feature"] is False
    assert spec["protocol_details"]["firmware_transfer"]["advanced"] is True

    dfu = spec["features"][0]["dfu"]
    assert dfu["verification"] == "reported"
    assert dfu["image"]["signing"] == "unknown"
    assert dfu["recovery"]["interrupted"] == "unknown"
    assert commands[dfu["enter"]["command"]]["advanced"] is True
    assert spec["device"]["model"] == "PP1"
    assert "variants" not in spec["device"]
