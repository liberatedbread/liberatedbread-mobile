#!/usr/bin/env python3
"""Independent SmartRow V3.10 checks using YAML and stdlib only."""

from pathlib import Path

import pytest
import yaml

SPEC = yaml.safe_load(
    (Path(__file__).parents[1] / "device-specs/devices/waterrower-smartrow.yaml").read_text()
)
VECTORS = SPEC["protocol_details"]["test_vectors"]


def decode_record(record):
    if len(record) != 17 or record[-1] != 0x0D:
        raise ValueError("bad record envelope")
    if sum(record[:14]) & 0xFF != int(record[14:16], 16):
        raise ValueError("bad checksum")
    prefix = chr(record[0])
    if prefix not in "abcdefxyz":
        raise ValueError("unknown record")
    output = {
        "distance": int("".join(chr((byte & 0x0F) | 0x30) for byte in record[1:6])),
    }
    text = record[:14].decode("ascii")
    if prefix == "a":
        output["elapsed"] = int(text[6:9]) * 60 + int(text[9:11])
    elif prefix == "b":
        output["work_raw"] = int(text[6:11]) / 10
        output["stroke_length_raw"] = int(text[11:14])
    elif prefix == "c":
        output["instant_power"] = int(text[6:9])
        output["average_power"] = int(text[9:14]) / 10
    elif prefix == "d":
        output["stroke_rate"] = int(text[6:9]) / 10
        output["stroke_count"] = int(text[9:13])
    elif prefix == "e":
        output["instant_pace"] = int(text[6]) * 60 + int(text[7:9])
        output["average_pace"] = int(text[9]) * 60 + int(text[10:12])
    elif prefix == "f":
        output["stopped"] = text[11] == "!"
    else:
        output["points"] = [(ord(char) - 33) * 16 for char in text[6:14]]
    return output


def record(name):
    text = VECTORS[name]["record_text"]
    assert len(text) == 16
    return text.encode("ascii") + b"\r"


def keylock_response(challenge):
    text = challenge.decode("ascii").strip("\r\n")
    if len(text) != 16 or sum(text.encode()[:14]) & 0xFF != int(text[14:16], 16):
        return b"#"
    value = int(text[10:14], 16) * 17923 // 256
    return ("\r" + f"{value:06X}"[2:].lower() + "\r").encode()


def test_capture_power_vectors():
    first = decode_record(record("power_349"))
    assert first["distance"] == 28
    assert first["instant_power"] == 0
    assert first["average_power"] == pytest.approx(34.9)
    second = decode_record(record("power_45"))
    assert second["distance"] == 72
    assert second["instant_power"] == 45
    assert second["average_power"] == pytest.approx(35.8)


def test_capture_stroke_pace_and_elapsed_vectors():
    stroke = decode_record(record("stroke_266"))
    assert stroke["stroke_rate"] == pytest.approx(26.6)
    assert stroke["stroke_count"] == 3
    pace = decode_record(record("pace_337"))
    assert pace["instant_pace"] == 0
    assert pace["average_pace"] == 217
    assert decode_record(record("elapsed_12"))["elapsed"] == 12


def test_capture_force_and_distance_vector():
    decoded = decode_record(record("force_x"))
    assert decoded["distance"] == 25
    assert decoded["points"] == VECTORS["force_x"]["points"]
    assert len(decoded["points"]) == 8


def test_checksum_envelope_and_unknown_records_are_rejected():
    corrupted = bytearray(record("power_349"))
    corrupted[11] = ord("9")
    with pytest.raises(ValueError):
        decode_record(bytes(corrupted))
    with pytest.raises(ValueError):
        decode_record(b"c0123")
    with pytest.raises(ValueError):
        decode_record(b"Q" * 16 + b"\r")


def test_keylock_vectors_and_bad_checksum():
    declarations = SPEC["protocol_details"]["keylock"]["test_vectors"]
    for name in ("synthetic", "capture_backed"):
        vector = declarations[name]
        assert keylock_response(bytes.fromhex(vector["challenge_hex"])) == bytes.fromhex(vector["response_hex"])
    assert keylock_response(b"KEYLOCK=001A2B00") == b"#"


def test_stop_marker_and_ftms_rules():
    body = b"f@@@@@---00!--"
    packet = body + f"{sum(body) & 0xFF:02X}".encode() + b"\r"
    assert decode_record(packet)["stopped"] is True
    ftms = SPEC["protocol_details"]["ftms"]
    assert ftms["all_fields_flags"] == 0x1FFE
    assert ftms["all_fields_bytes"] == 29
    assert ftms["more_data_bit"] == 0
    assert ftms["energy_unavailable"]["total_energy"] == 0xFFFF
