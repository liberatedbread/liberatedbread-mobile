#!/usr/bin/env python3
"""Independent Oral-B iO charger/battery/session checks using YAML and stdlib."""

from pathlib import Path

import pytest
import yaml

SPEC = yaml.safe_load(
    (Path(__file__).parents[1] / "device-specs/devices/oral-b-io-smartbrush.yaml").read_text()
)
BRUSH_SERVICE = "a0f0ff00-5047-4d53-8208-4f72616c2d42"
CHARGER_SERVICE = "a0f03e00-5047-4d53-8208-4f72616c2d42"


def characteristic(service_uuid, characteristic_uuid):
    service = next(service for service in SPEC["services"] if service["uuid"] == service_uuid)
    return next(char for char in service["characteristics"] if char["uuid"] == characteristic_uuid)


def parse_battery(payload):
    if not payload:
        raise ValueError("missing battery")
    output = {"battery_percent": payload[0]}
    if len(payload) >= 3:
        runtime = int.from_bytes(payload[1:3], "little")
        output["remaining_brushing_seconds"] = None if runtime == 0xFFFF else runtime
    if len(payload) >= 5:
        output["battery_millivolts"] = int.from_bytes(payload[3:5], "little")
    if len(payload) >= 7:
        current = int.from_bytes(payload[5:7], "little", signed=True)
        output["battery_current"] = None if current == -1 else current
    if len(payload) >= 8:
        output["battery_temperature"] = int.from_bytes(payload[7:8], "little", signed=True)
    return output


def parse_session(payload):
    if len(payload) != 21:
        raise ValueError("protocol 7/8 session requires 21 bytes")
    identity = int.from_bytes(payload[4:6], "little")
    configuration = int.from_bytes(payload[6:8], "little")
    return {
        "start": int.from_bytes(payload[0:4], "little"),
        "session_id": identity & 0x1FFF,
        "user_id": (identity & 0xE000) >> 13,
        "target_duration": configuration & 0x1FFF,
        "sectors": (configuration & 0xE000) >> 13,
        "duration": int.from_bytes(payload[8:10], "little"),
        "high_pressure_time": int.from_bytes(payload[10:12], "little") / 10,
        "low_pressure_time": int.from_bytes(payload[12:14], "little") / 10,
        "average_pressure": payload[14] * 100,
        "maximum_pressure": payload[15] * 100,
        "high_events": payload[16],
        "low_events": payload[17],
        "power_on_count": payload[18],
        "mode": payload[19],
        "battery_end": payload[20] if payload[20] <= 100 else None,
    }


def test_charger_has_its_own_service_and_all_four_roles():
    charger = next(service for service in SPEC["services"] if service["uuid"] == CHARGER_SERVICE)
    brush = next(service for service in SPEC["services"] if service["uuid"] == BRUSH_SERVICE)
    assert len(charger["characteristics"]) == 4
    assert not any(char["uuid"].startswith("a0f03c") for char in brush["characteristics"])
    assert characteristic(CHARGER_SERVICE, "a0f03c01-5047-4d53-8208-4f72616c2d42")["properties"] == ["read", "notify"]
    assert characteristic(CHARGER_SERVICE, "a0f03c03-5047-4d53-8208-4f72616c2d42")["properties"] == ["read", "notify"]


def test_extended_battery_layout_and_short_records():
    payload = bytes.fromhex("50 e8 03 20 4e 20 00 14")
    assert parse_battery(payload) == {
        "battery_percent": 80,
        "remaining_brushing_seconds": 1000,
        "battery_millivolts": 20000,
        "battery_current": 32,
        "battery_temperature": 20,
    }
    assert parse_battery(bytes([80])) == {"battery_percent": 80}
    unavailable = parse_battery(bytes.fromhex("50 ff ff 20 4e ff ff 14"))
    assert unavailable["remaining_brushing_seconds"] is None
    assert unavailable["battery_current"] is None


def test_protocol_7_8_session_record():
    payload = bytearray(21)
    payload[0:4] = (1700000000).to_bytes(4, "little")
    payload[4:6] = ((2 << 13) | 123).to_bytes(2, "little")
    payload[6:8] = ((4 << 13) | 120).to_bytes(2, "little")
    payload[8:10] = (128).to_bytes(2, "little")
    payload[10:12] = (100).to_bytes(2, "little")
    payload[12:14] = (10).to_bytes(2, "little")
    payload[14:21] = bytes([19, 33, 40, 2, 5, 4, 94])
    decoded = parse_session(payload)
    assert decoded["start"] == 1700000000
    assert decoded["session_id"] == 123
    assert decoded["user_id"] == 2
    assert decoded["target_duration"] == 120
    assert decoded["sectors"] == 4
    assert decoded["duration"] == 128
    assert decoded["high_pressure_time"] == pytest.approx(10.0)
    assert decoded["low_pressure_time"] == pytest.approx(1.0)
    assert decoded["average_pressure"] == 1900
    assert decoded["maximum_pressure"] == 3300
    assert decoded["high_events"] == 40
    assert decoded["low_events"] == 2
    assert decoded["power_on_count"] == 5
    assert decoded["mode"] == 4
    assert decoded["battery_end"] == 94
    with pytest.raises(ValueError):
        parse_session(payload[:-1])


def test_charger_status_bits_and_passthrough_sequence():
    bits = SPEC["protocol_details"]["charger_advertisement"]["connection_status_bits"]
    status = 0xAD
    assert {bit for bit in bits if status & (1 << bit)} == {0, 2, 3, 5, 7}
    passthrough = SPEC["protocol_details"]["charger_bridge"]["brush_passthrough_read"]
    assert passthrough["header_hex"] == "c1 37"
    assert passthrough["payload"] == "uuid_lsb uuid_msb 01 00 on 3C02"
    assert passthrough["success_status_hex"] == "37 c1 01"
    assert "08 ff 01 00" in passthrough["example"]
    assert len(SPEC["protocol_details"]["charger_bridge"]["native_read_only_commands"]) == 24


def test_diagnostic_widths_and_metadata_versions():
    diagnostics = SPEC["protocol_details"]["service_data_diagnostics"]
    for name in ("service_data_a", "service_data_b"):
        declaration = diagnostics[name]
        assert sum(field["length"] for field in declaration["fields"]) == declaration["length_bytes"] == 16
        assert declaration["endianness"] == "little"
    metadata = SPEC["protocol_details"]["sonos_metadata"]
    assert metadata["protocol_7_length_bytes"] == 14
    assert metadata["protocol_8_plus_length_bytes"] == 30
    assert metadata["statistics_markers"] == {"default_available_separator": 0xFE, "end": 0xFF}
    assert metadata["fields"][-1]["length"] == 16
