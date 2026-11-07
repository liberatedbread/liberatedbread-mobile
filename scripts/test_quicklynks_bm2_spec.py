#!/usr/bin/env python3
"""Independent Quicklynks BM2 packet checks using YAML and public AES."""

from pathlib import Path

import pytest
import yaml
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes

SPEC = yaml.safe_load(
    (Path(__file__).parents[1] / "device-specs/devices/quicklynks-bm2.yaml").read_text()
)
VECTORS = SPEC["protocol_details"]["test_vectors"]


def decrypt(block):
    encryption = SPEC["protocol_details"]["encryption"]
    if len(block) != encryption["block_bytes"]:
        raise ValueError("expected one encrypted block")
    context = Cipher(
        algorithms.AES(bytes.fromhex(encryption["public_protocol_key_hex"])),
        modes.CBC(bytes.fromhex(encryption["iv_hex"])),
    ).decryptor()
    return context.update(block) + context.finalize()


def decode_active(block):
    plaintext = decrypt(block)
    if plaintext[0] != 0xF5:
        raise ValueError("not a voltage notification")
    word = int.from_bytes(plaintext[1:3], "big")
    percentage = plaintext[3]
    voltage = (word >> 4) / 100
    status = word & 0x0F
    known = SPEC["protocol_details"]["active_validation"]["known_status"]
    if not 5.0 <= voltage <= 20.0 or not 0 <= percentage <= 100 or status not in known:
        raise ValueError("implausible or unknown active telemetry")
    return voltage, percentage, status


def decode_enhanced(manufacturer_id, body):
    plaintext = decrypt(manufacturer_id.to_bytes(2, "little") + body)
    voltage = int.from_bytes(plaintext[6:8], "big") / 100
    percentage = plaintext[8]
    if not 5.0 <= voltage <= 20.0 or not 0 <= percentage <= 100:
        raise ValueError("implausible enhanced telemetry")
    return voltage, percentage


def decode_legacy(body):
    declaration = SPEC["protocol_details"]["legacy_advertisement"]
    if len(body) != declaration["manufacturer_body_bytes"]:
        raise ValueError("bad legacy length")
    if body[:18].hex() != declaration["fixed_prefix_hex"]:
        raise ValueError("bad legacy prefix")
    percentage = body[declaration["percentage_offset"]]
    if not 0 <= percentage <= 100:
        raise ValueError("bad percentage")
    return percentage


def test_active_ciphertext_and_packed_values():
    vector = VECTORS["active_gatt"]
    block = bytes.fromhex(vector["ciphertext_hex"])
    assert decrypt(block).hex() == vector["plaintext_hex"]
    assert decode_active(block) == (12.88, 80, 2)


def test_enhanced_reconstruction_and_values():
    vector = VECTORS["enhanced_advertisement"]
    body = bytes.fromhex(vector["manufacturer_body_hex"])
    assert len(body) == 14
    assert decode_enhanced(vector["manufacturer_id"], body) == (12.88, 80)


def test_legacy_percentage_and_coexistence_rules():
    vector = VECTORS["legacy_advertisement"]
    percentage = decode_legacy(bytes.fromhex(vector["manufacturer_body_hex"]))
    state = {"voltage": 12.88, "percentage": 80, "generation": "Enhanced", "status": 2}
    state.update(percentage=percentage, generation="Enhanced", status=None)
    assert state == {"voltage": 12.88, "percentage": 80, "generation": "Enhanced", "status": None}


def test_invalid_status_percentage_and_voltage_are_rejected():
    key = bytes.fromhex(SPEC["protocol_details"]["encryption"]["public_protocol_key_hex"])
    iv = bytes.fromhex(SPEC["protocol_details"]["encryption"]["iv_hex"])

    def encrypt(plaintext):
        context = Cipher(algorithms.AES(key), modes.CBC(iv)).encryptor()
        return context.update(plaintext) + context.finalize()

    with pytest.raises(ValueError):
        decode_active(encrypt(bytes.fromhex("f5508350000000000000000000000000")))
    with pytest.raises(ValueError):
        decode_active(encrypt(bytes.fromhex("f5508265000000000000000000000000")))
    with pytest.raises(ValueError):
        decode_active(encrypt(bytes.fromhex("f5000150000000000000000000000000")))
    with pytest.raises(ValueError):
        decode_active(bytes(16))


def test_malformed_legacy_data_is_rejected():
    body = bytes.fromhex(VECTORS["legacy_advertisement"]["manufacturer_body_hex"])
    with pytest.raises(ValueError):
        decode_legacy(body[:-1])
    with pytest.raises(ValueError):
        decode_legacy(bytes([body[0] ^ 1]) + body[1:])
    with pytest.raises(ValueError):
        decode_legacy(body[:-1] + bytes([101]))


def test_declared_voltage_field_and_entity_binding():
    fields = SPEC["services"][0]["characteristics"][0]["format"]
    voltage = next(field for field in fields if field["name"] == "voltage")
    raw = int.from_bytes(decrypt(bytes.fromhex(VECTORS["active_gatt"]["ciphertext_hex"]))[1:3], "big")
    mask = voltage["mask"]
    shift = (mask & -mask).bit_length() - 1
    assert (raw & mask) >> shift == 1288
    assert ((raw & mask) >> shift) * voltage["scale"] == pytest.approx(12.88)
    assert voltage["unit"] == "V"
    entity = next(entity for entity in SPEC["entities"] if entity["name"] == "Battery Voltage")
    assert entity["state_characteristic"] == SPEC["services"][0]["characteristics"][0]["uuid"]
    assert entity["state_mapping"]["value"] == "voltage"
