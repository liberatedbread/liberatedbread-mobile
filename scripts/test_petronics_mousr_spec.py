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


ONE_DIGIT = {"stop": 0, "spin": 1, "move": 2, "reset_heading": 3, "turn_off": 9}


def _code_bytes(command):
    if "value" in command:
        return bytes(command["value"][-2:])
    return bytes(command["template"][-2:])


def test_one_digit_codes_are_hypothesis_and_one_of_the_two_forms():
    """The second code byte is unresolved; the spec must not claim more."""
    for name, code in ONE_DIGIT.items():
        command = COMMANDS[name]
        assert command["verification"] == "hypothesis", name
        form_a = bytes([0x30, 0x30 + code])
        form_b = bytes([0x30 + code, 0x00])
        assert _code_bytes(command) in (form_a, form_b), name
        other = form_b if _code_bytes(command) == form_a else form_a
        assert other.hex(" ") in command["description"], name


def test_two_digit_codes_are_two_ascii_digits():
    for name, code in (("chirp", 18), ("sleep", 10)):
        assert _code_bytes(COMMANDS[name]) == str(code).encode(), name


def test_both_forms_are_vectored():
    vectors = SPEC["protocol_details"]["test_vectors"]
    stop_a = octets(vectors["stop_form_a_hex"])
    assert stop_a[:13] == octets(vectors["stop_hex"])[:13]
    assert stop_a[13:] == b"00"
    move_b = octets(vectors["move"]["form_b_hex"])
    assert move_b[:13] == octets(vectors["move"]["expected_hex"])[:13]
    assert move_b[13:] == b"2\x00"


def test_identification_needs_exact_name_and_excludes_bootloader():
    ident = SPEC["device"]["identification"]
    assert ident["local_names"] == ["Mousr"]
    assert "local_name_prefix" not in ident
    ble = SPEC["device"]["discovery"]["methods"][0]["ble"]
    assert ble["local_name"] == {"match": "exact", "value": "Mousr"}
    # Within a ble_scan method name and service are OR'd; the shared Nordic
    # UART service must not be a standalone matcher.
    assert "service_uuids" not in ble
    dfu = SPEC["features"][0]["dfu"]
    assert dfu["dfu_mode"]["local_names"] == ["MousrDfu"]
    assert "MousrDfu" not in ident["local_names"]


def test_ordinary_controls_are_not_advanced():
    for name in ("sleep", "turn_off", "reset_heading", "chirp", "stop"):
        assert not COMMANDS[name].get("advanced"), name
