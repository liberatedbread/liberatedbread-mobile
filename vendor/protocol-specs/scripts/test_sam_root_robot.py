# Copyright 2026 Pigs Can Fly Labs LLC
# SPDX-License-Identifier: Apache-2.0
"""Independently verifies the Root RT0/RT1 packet and CRC vectors.

The packet builder and bitwise CRC below use only the Python standard library
and import no project implementation. They rebuild every constructed frame in
``device-specs/devices/sam-root-robot.yaml``, render each safe request template,
and decode every response layout. The CRC also has the standard CRC-8/SMBUS
check value as an external anchor. No vector came from, or identifies, hardware.
"""

from __future__ import annotations

from pathlib import Path

import pytest
import yaml

REPO_ROOT = Path(__file__).resolve().parent.parent
SPEC_PATH = REPO_ROOT / "device-specs" / "devices" / "sam-root-robot.yaml"
ROOT_IDENTIFIER = "48c5d828-ac2a-442d-97a3-0c9822b04979"
UART_SERVICE = "6e400001-b5a3-f393-e0a9-e50e24dcca9e"
ROBOT_RX = "6e400002-b5a3-f393-e0a9-e50e24dcca9e"
ROBOT_TX = "6e400003-b5a3-f393-e0a9-e50e24dcca9e"


@pytest.fixture(scope="module")
def spec() -> dict:
    return yaml.safe_load(SPEC_PATH.read_text(encoding="utf-8"))


@pytest.fixture(scope="module")
def root_protocol(spec) -> dict:
    return spec["protocol_details"]["root_ble"]


@pytest.fixture(scope="module")
def vectors(root_protocol) -> dict[str, dict]:
    entries = root_protocol["test_vectors"]["vectors"]
    return {entry["name"]: entry for entry in entries}


def crc8(data: bytes) -> int:
    """CRC-8/SMBUS: poly 0x07, init/xorout zero, MSB-first, no reflection."""
    crc = 0
    for octet in data:
        crc ^= octet
        for _ in range(8):
            if crc & 0x80:
                crc = ((crc << 1) ^ 0x07) & 0xFF
            else:
                crc = (crc << 1) & 0xFF
    return crc


def build_packet(device: int, opcode: int, packet_id: int, payload: bytes = b"") -> bytes:
    if len(payload) > 16:
        raise ValueError("Root payload exceeds 16 bytes")
    body = bytes([device, opcode, packet_id]) + payload.ljust(16, b"\0")
    assert len(body) == 19
    return body + bytes([crc8(body)])


def valid_packet(frame: bytes) -> bool:
    return len(frame) == 20 and frame[-1] == crc8(frame[:19])


def render_request(command: dict, packet_id: int) -> bytes:
    output = []
    for item in command["template"]:
        if isinstance(item, int):
            output.append(item)
            continue
        name = item.strip("{}")
        parameter = command["parameters"][name]
        if parameter.get("auto") == "sequence":
            output.append(packet_id)
        elif parameter.get("auto") == "crc8":
            output.append(crc8(bytes(output[parameter["checksum_start"] :])))
        else:
            raise AssertionError(f"test supplies no value for {name}")
    return bytes(output)


def decode_layout(frame: bytes, layout: dict) -> dict:
    decoded = {}
    for field in layout["fields"]:
        start = field["offset"]
        raw = frame[start : start + field["length"]]
        if field["type"] == "string":
            value = raw.split(b"\0", 1)[0].decode(field["encoding"])
        else:
            value = int.from_bytes(
                raw,
                field.get("endianness", "big"),
                signed=field["type"].startswith("int"),
            )
        decoded[field["name"]] = value
    return decoded


def characteristic(spec: dict, uuid: str) -> dict:
    for service in spec["services"]:
        for char in service.get("characteristics") or []:
            if char["uuid"] == uuid:
                return char
    raise AssertionError(f"characteristic {uuid} not found")


def test_crc8_matches_standard_check_value():
    assert crc8(b"123456789") == 0xF4


def test_every_vector_is_an_independently_rebuilt_20_byte_packet(vectors):
    assert len(vectors) == 10
    for name, vector in vectors.items():
        payload = bytes.fromhex(vector["payload_hex"])
        expected = bytes.fromhex(vector["frame"])
        rebuilt = build_packet(
            vector["device"], vector["opcode"], vector["packet_id"], payload
        )
        assert rebuilt == expected, name
        assert valid_packet(expected), name
        assert expected[:3] == bytes(
            [vector["device"], vector["opcode"], vector["packet_id"]]
        ), name
        assert expected[3 + len(payload) : 19] == bytes(16 - len(payload)), name


def test_request_templates_render_their_independent_vectors(spec, vectors):
    commands = characteristic(spec, ROBOT_RX)["commands"]
    for vector in vectors.values():
        if vector["direction"] != "request":
            continue
        command = commands[vector["command"]]
        assert command["fixed_length"] == 20
        assert render_request(command, vector["packet_id"]) == bytes.fromhex(
            vector["frame"]
        ), vector["name"]


def test_response_layouts_decode_their_independent_vectors(root_protocol, vectors):
    layouts = root_protocol["response_layouts"]
    for vector in vectors.values():
        if "expected" not in vector:
            continue
        frame = bytes.fromhex(vector["frame"])
        decoded = decode_layout(frame, layouts[vector["layout"]])
        assert decoded == vector["expected"], vector["name"]


def test_battery_fields_are_big_endian_and_left_justified(vectors):
    frame = bytes.fromhex(vectors["battery_level_7"]["frame"])
    assert frame[3:10].hex() == "010203040fa04b"
    assert int.from_bytes(frame[3:7], "big") == 16909060
    assert int.from_bytes(frame[7:9], "big") == 4000
    assert frame[9] == 75
    assert frame[10:19] == bytes(9)
    assert int.from_bytes(frame[3:7], "little") != 16909060


def test_response_ids_match_requests_but_event_ids_are_independent(vectors):
    request = bytes.fromhex(vectors["get_battery_level_7"]["frame"])
    response = bytes.fromhex(vectors["battery_level_7"]["frame"])
    event = bytes.fromhex(vectors["battery_event_231"]["frame"])
    assert response[:3] == request[:3]
    assert response[1] == 1
    assert event[:2] == bytes([14, 0])
    assert event[2] == 231 != request[2]
    assert event[:3] != request[:3]


def test_version_example_confirms_root_protocol_1_3(root_protocol, vectors):
    response = bytes.fromhex(vectors["main_board_versions_42"]["frame"])
    request = bytes.fromhex(vectors["get_main_board_versions_42"]["frame"])
    assert response[:3] == request[:3]
    decoded = decode_layout(
        response, root_protocol["response_layouts"]["get_versions_response"]
    )
    assert (decoded["firmware_major"], decoded["firmware_minor"]) == (2, 7)
    assert (decoded["protocol_major"], decoded["protocol_minor"]) == (1, 3)
    assert root_protocol["scope"]["latest_root_version_in_source"] == "1.3"
    assert root_protocol["scope"]["protocol_versions"] == ["1.0", "1.1", "1.2", "1.3"]


def test_crc_validation_rejects_damage_and_bad_lengths(vectors):
    frame = bytearray.fromhex(vectors["name_zero"]["frame"])
    assert valid_packet(bytes(frame))
    frame[3] ^= 0x01
    assert not valid_packet(bytes(frame))
    assert not valid_packet(bytes(frame[:-1]))
    with pytest.raises(ValueError, match="exceeds 16 bytes"):
        build_packet(0, 2, 0, bytes(17))


def test_only_scoped_safe_commands_are_declared(spec):
    commands = characteristic(spec, ROBOT_RX)["commands"]
    expected = {
        "get_main_board_versions": (0, 0),
        "get_name": (0, 2),
        "stop_and_reset": (0, 3),
        "get_battery_level": (14, 1),
    }
    assert set(commands) == set(expected)
    for name, command in commands.items():
        assert tuple(command["template"][:2]) == expected[name]
        assert len(command["template"]) == 20
        assert command["verification"] == "reported"
        assert not command.get("advanced"), name
        assert all(
            parameter.get("auto") in {"sequence", "crc8"}
            for parameter in command["parameters"].values()
        ), name


def test_subscribe_first_and_uart_directions(spec):
    initialization = spec["initialization"]
    assert initialization[0]["characteristic"] == ROBOT_TX
    assert initialization[0]["subscribe"] is True
    rx = characteristic(spec, ROBOT_RX)
    tx = characteristic(spec, ROBOT_TX)
    assert rx["role"] == "command"
    assert set(rx["properties"]) == {"write", "write_without_response"}
    assert tx["role"] == "notify"
    assert set(tx["properties"]) == {"notify", "indicate"}
    identifier = next(
        service for service in spec["services"] if service["uuid"] == ROOT_IDENTIFIER
    )
    assert "characteristics" not in identifier
    uart = next(service for service in spec["services"] if service["uuid"] == UART_SERVICE)
    assert {char["uuid"] for char in uart["characteristics"]} == {ROBOT_RX, ROBOT_TX}


def test_discovery_and_protocol_scope_exclude_other_robots(spec):
    methods = spec["device"]["discovery"]["methods"]
    patterns = {
        method["ble"]["manufacturer_data"]["pattern"] for method in methods
    }
    assert patterns == {"525430", "525431"}
    for method in methods:
        assert method["ble"]["service_uuids"] == [ROOT_IDENTIFIER]
        assert method["ble"]["manufacturer_data"]["company_id"] == 0x0600
    assert spec["device"]["testing"]["status"] == "untested"
