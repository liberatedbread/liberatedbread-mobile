#!/usr/bin/env python3
"""Independent Mousr packet and float32 checks, using only YAML and stdlib."""

import struct
from pathlib import Path

import yaml

SPEC = yaml.safe_load(
    (Path(__file__).parents[1] / "device-specs/devices/petronics-mousr.yaml").read_text()
)
COMMANDS = SPEC["services"][0]["characteristics"][0]["commands"]


def octets(text):
    return bytes.fromhex(text)


def encode_move(speed, hold, angle):
    return b"0" + struct.pack("<fff", speed, hold, angle) + b"02"


def test_stop_and_chirp_match_declared_vectors():
    vectors = SPEC["protocol_details"]["test_vectors"]
    assert bytes(COMMANDS["stop"]["value"]) == octets(vectors["stop_hex"])
    assert bytes(COMMANDS["chirp"]["value"]) == octets(vectors["chirp_hex"])


def test_move_float32_vector():
    vector = SPEC["protocol_details"]["test_vectors"]["move"]
    assert encode_move(vector["speed"], vector["hold"], vector["angle"]) == octets(
        vector["expected_hex"]
    )


def test_fractional_and_negative_values_are_not_rounded():
    vector = SPEC["protocol_details"]["test_vectors"]["move_fractional"]
    assert encode_move(vector["speed"], vector["hold"], vector["angle"]) == octets(
        vector["expected_hex"]
    )


def test_move_declares_three_float32_parameters_in_wire_order():
    command = COMMANDS["move"]
    assert command["template"] == [0x30, "{speed}", "{hold}", "{angle}", 0x30, 0x32]
    for name in ("speed", "hold", "angle"):
        assert command["parameters"][name]["type"] == "float32"
        assert command["parameters"][name]["endianness"] == "little"


def test_every_declared_command_is_exactly_15_bytes():
    for name, command in COMMANDS.items():
        if "value" in command:
            assert len(command["value"]) == 15, name
        else:
            assert command["template"][0] == 0x30, name
            assert command["template"][-2:] == [0x30, 0x32], name
            assert sum(
                1 if isinstance(item, int) else 4 for item in command["template"]
            ) == 15, name


def test_stop_is_the_only_unadvanced_motion_command():
    assert "advanced" not in COMMANDS["stop"]
    for name in ("move", "spin"):
        assert COMMANDS[name]["advanced"] is True
        assert COMMANDS[name]["advanced_reason"]
