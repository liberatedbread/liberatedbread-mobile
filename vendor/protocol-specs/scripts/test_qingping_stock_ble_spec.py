#!/usr/bin/env python3
"""Independent stock Qingping advertisement checks using YAML and stdlib."""

from pathlib import Path

import pytest
import yaml

SPEC = yaml.safe_load(
    (Path(__file__).parents[1] / "device-specs/devices/qingping-stock-ble.yaml").read_text()
)


def decode(packet):
    if len(packet) < 8:
        raise ValueError("missing envelope")
    output = {"event": bool(packet[0] & 0x40), "device_type": packet[1]}
    offset = 8
    tlvs = SPEC["protocol_details"]["tlvs"]
    while offset < len(packet):
        if offset + 2 > len(packet):
            break
        kind, length = packet[offset], packet[offset + 1]
        offset += 2
        payload = packet[offset : offset + length]
        if len(payload) != length:
            break
        offset += length
        declaration = tlvs.get(f"0x{kind:02x}")
        if declaration is None or declaration["length"] != length:
            continue
        for field in declaration["fields"]:
            if not field.get("sensor_output", True):
                continue
            if field["name"].startswith("illuminance_") and output["event"]:
                continue
            start = field["offset"]
            size = {"uint8": 1, "int16": 2, "uint16": 2, "uint32": 4}[field["type"]]
            raw = int.from_bytes(
                payload[start : start + size],
                field.get("endianness", "little"),
                signed=field["type"] == "int16",
            )
            if "true_values" in field:
                output[field["name"]] = raw in field["true_values"]
            else:
                output[field["name"]] = raw * field.get("scale", 1)
        if kind == 0x08 and not output["event"]:
            output["illuminance"] = output["illuminance_low"] + (output["illuminance_high"] << 16)
    return output


def vector(name):
    return bytes.fromhex(SPEC["protocol_details"]["test_vectors"][name]["packet_hex"])


def test_cgdk2_example_decodes_temperature_humidity_and_battery():
    decoded = decode(vector("cgdk2_temperature_humidity_battery"))
    assert decoded["device_type"] == 0x10
    assert SPEC["protocol_details"]["device_types"]["0x10"].startswith("CGDK2")
    assert decoded["temperature"] == pytest.approx(28.4)
    assert decoded["relative_humidity"] == pytest.approx(68.7)
    assert decoded["battery"] == 100


def test_capability_bitmap_never_becomes_co2():
    decoded = decode(vector("capability_is_not_co2"))
    assert "co2" not in decoded
    assert "hardware_capabilities" not in decoded


def test_event_motion_preserves_previous_illuminance():
    previous = {"illuminance": 12345}
    decoded = decode(vector("event_motion_does_not_replace_illuminance"))
    assert decoded["event"] is True
    assert decoded["motion"] == 1
    assert "illuminance" not in decoded
    assert "illuminance_low" not in decoded
    previous.update(decoded)
    assert previous["illuminance"] == 12345


def test_non_event_24_bit_illuminance_and_signed_temperature():
    packet = bytes.fromhex("08 01 00 00 00 00 00 00 01 04 9c ff af 02 08 04 01 34 12 01")
    decoded = decode(packet)
    assert decoded["temperature"] == pytest.approx(-10.0)
    assert decoded["illuminance"] == 0x1234 + (0x01 << 16)


def test_truncated_tlv_is_not_partially_decoded():
    complete = vector("cgdk2_temperature_humidity_battery")
    decoded = decode(complete[:-1])
    assert decoded["temperature"] == pytest.approx(28.4)
    assert "battery" not in decoded
