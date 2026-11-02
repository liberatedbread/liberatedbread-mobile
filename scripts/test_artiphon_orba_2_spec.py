#!/usr/bin/env python3
"""Independent Orba 2 framing checks, using only the YAML and stdlib."""

from pathlib import Path

import pytest
import yaml

SPEC = yaml.safe_load(
    (Path(__file__).parents[1] / "device-specs/devices/artiphon-orba-2.yaml").read_text()
)
MIDI_CHAR = SPEC["services"][0]["characteristics"][0]


def octets(text):
    return bytes.fromhex(text)


def crc16_orba(data):
    crc = 0
    for byte in data:
        crc ^= byte
        for _ in range(8):
            crc = (crc >> 1) ^ (0xA001 if crc & 1 else 0)
    return crc


def encode7(packet):
    bits = [(byte >> bit) & 1 for byte in packet for bit in range(8)]
    output = bytearray()
    for start in range(0, len(bits), 7):
        value = 0
        for offset, bit in enumerate(bits[start : start + 7]):
            value |= bit << offset
        output.append(value)
    return bytes(output)


def sysex(payload, message_id=0):
    packet = bytearray([0x82, 0x01, message_id])
    packet += len(payload).to_bytes(2, "big")
    packet += payload
    packet += crc16_orba(packet).to_bytes(2, "big")
    return bytes([0xF0, 0x00]) + encode7(packet) + bytes([0xF7])


def ble_writes(midi, write_size=20):
    body = midi[:-1]
    packets = [bytes([0x80, 0x80]) + body[: write_size - 2]]
    body = body[write_size - 2 :]
    while body:
        packets.append(bytes([0x80]) + body[: write_size - 1])
        body = body[write_size - 1 :]
    packets.append(bytes([0x80, 0x80, 0xF7]))
    return packets


def encode_template(command, values):
    output = bytearray()
    for item in command.get("template", command.get("value", [])):
        if isinstance(item, int):
            output.append(item)
            continue
        name = item.strip("{}")
        parameter = command["parameters"][name]
        value = values[name]
        if parameter["type"] == "uint8":
            output.append(value)
        elif parameter["type"] == "uint16":
            output += value.to_bytes(2, parameter.get("endianness", "little"))
        else:
            raise AssertionError(f"unexpected test type {parameter['type']}")
    return bytes(output)


@pytest.mark.parametrize("vector_name", ["play", "active_part_bass", "bass_volume_50_percent"])
def test_reference_sysex_and_ble_vectors(vector_name):
    vector = SPEC["protocol_details"]["test_vectors"][vector_name]
    payload = octets(vector["payload_hex"])
    midi = sysex(payload)
    assert midi == octets(vector["midi_hex"])
    assert ble_writes(midi) == [octets(w) for w in vector["writes_hex"]]


def test_declared_play_payload_matches_reference():
    command = MIDI_CHAR["commands"]["transport_play"]
    assert encode_template(command, {}) == octets(
        SPEC["protocol_details"]["test_vectors"]["play"]["payload_hex"]
    )


def test_declared_bass_volume_matches_reference_and_keeps_required_trailer():
    command = MIDI_CHAR["commands"]["set_bass_volume"]
    encoded = encode_template(command, {"level": 128})
    assert encoded == octets(
        SPEC["protocol_details"]["test_vectors"]["bass_volume_50_percent"]["payload_hex"]
    )
    assert encoded[-3:] == bytes([0, 1, 4])


def test_every_fx_write_has_the_required_trailer():
    for name, command in MIDI_CHAR["commands"].items():
        if name.startswith("set_") and any(
            word in name for word in ("volume", "pan", "reverb", "delay")
        ):
            assert command["template"][-3:] == [0, 1, 4], name


def test_ble_fragment_boundaries():
    midi = sysex(bytes(range(64)))
    packets = ble_writes(midi)
    assert all(len(packet) <= 20 for packet in packets)
    assert packets[0][:3] == bytes([0x80, 0x80, 0xF0])
    assert packets[-1] == bytes([0x80, 0x80, 0xF7])
    assert all(packet[0] == 0x80 for packet in packets)
