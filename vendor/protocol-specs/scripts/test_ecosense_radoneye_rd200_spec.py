#!/usr/bin/env python3
"""Independent RadonEye RD200 packet checks using YAML and stdlib."""

import math
from pathlib import Path
import struct

import pytest
import yaml

SPEC = yaml.safe_load(
    (Path(__file__).parents[1] / "device-specs/devices/ecosense-radoneye-rd200.yaml").read_text()
)


def v1_frame(command, payload):
    return bytes([command, len(payload)]) + payload


def parse_v1(frame):
    if len(frame) < 2 or len(frame) != frame[1] + 2:
        raise ValueError("bad V1 envelope")
    command, payload = frame[0], frame[2:]
    if command == 0x50:
        if len(payload) != 16:
            raise ValueError("short measurement")
        values = struct.unpack("<fffHH", payload)
        if not all(math.isfinite(value) for value in values[:3]):
            raise ValueError("non-finite measurement")
        return values
    if command == 0x51:
        if len(payload) != 14:
            raise ValueError("short status")
        return struct.unpack("<BBIIf", payload)
    raise ValueError("unknown response command")


def parse_v2_measurement(frame):
    if len(frame) != 12:
        raise ValueError("V2 measurement must be exactly 12 bytes")
    return struct.unpack("<2s5H", frame)


def test_constructed_v1_measurement_matches_spec_vector():
    vector = SPEC["protocol_details"]["test_vectors"]["v1_measurement"]
    frame = bytes.fromhex(vector["frame_hex"])
    assert frame == v1_frame(0x50, struct.pack("<fffHH", 2.5, 3.5, 4.5, 50, 60))
    assert parse_v1(frame) == (
        vector["current_pci_l"],
        vector["one_day_pci_l"],
        vector["one_month_pci_l"],
        vector["pulse_count"],
        vector["previous_pulse_count"],
    )


def test_constructed_v2_measurement_matches_spec_vector():
    vector = SPEC["protocol_details"]["test_vectors"]["v2_measurement"]
    frame = bytes.fromhex(vector["frame_hex"])
    assert parse_v2_measurement(frame) == (
        b"\x00\x00",
        vector["current_bq_m3"],
        vector["one_day_bq_m3"],
        vector["one_month_bq_m3"],
        vector["pulse_count"],
        vector["previous_pulse_count"],
    )


def test_native_units_remain_distinct_and_conversion_is_exact():
    v1 = SPEC["protocol_details"]["test_vectors"]["v1_measurement"]
    v2 = SPEC["protocol_details"]["test_vectors"]["v2_measurement"]
    assert parse_v1(bytes.fromhex(v1["frame_hex"]))[0] * 37 == pytest.approx(92.5)
    assert parse_v2_measurement(bytes.fromhex(v2["frame_hex"]))[1] / 37 == pytest.approx(100 / 37)
    assert SPEC["protocol_details"]["unit_conversion"]["v1_native"].startswith("pCi/L")
    assert SPEC["protocol_details"]["unit_conversion"]["v2_native"].startswith("Bq/m³")


def test_complete_v1_payload_is_required():
    with pytest.raises(ValueError):
        parse_v1(bytes.fromhex("50 10 00 00 20 40 00 00 60 40 00 00 90"))
    with pytest.raises(ValueError):
        parse_v1(v1_frame(0x50, struct.pack("<fffHH", math.nan, 3.5, 4.5, 50, 60)))
    with pytest.raises(ValueError):
        parse_v2_measurement(bytes(11))


def test_v1_status_layout_and_v2_lengths():
    status = v1_frame(0x51, struct.pack("<BBIIf", 1, 0, 120, 0, 5.5))
    assert parse_v1(status) == (1, 0, 120, 0, 5.5)
    queries = SPEC["protocol_details"]["v2_gatt"]["queries"]
    assert queries["measurement"]["response_bytes"] == 12
    assert queries["peak_identity"]["response_bytes"] == 68
    assert queries["uptime"]["response_bytes"] == 16


def test_history_erase_is_advanced_and_v2_does_not_inherit_v1_commands():
    control = SPEC["services"][0]["characteristics"][0]
    erase = control["commands"]["erase_history"]
    assert erase["value"] == [0xE0]
    assert erase["advanced"] is True
    assert "preserve history" in erase["advanced_reason"]
    assert SPEC["protocol_details"]["v2_gatt"]["parent_service_uuid"] is None
    assert set(SPEC["protocol_details"]["v2_gatt"]["queries"]) == {
        "measurement",
        "peak_identity",
        "uptime",
    }
