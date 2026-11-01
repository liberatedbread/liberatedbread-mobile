# Copyright 2026 Pigs Can Fly Labs LLC
# SPDX-License-Identifier: Apache-2.0
"""Proves the Hot Wheels id Race Portal spec's encodings against its own vectors.

`device-specs/devices/hot-wheels-id-race-portal.yaml` says the speed
indication is a little-endian IEEE 754 binary32, and that the car's NDEF URI
record carries `https://www.pid.mattel/<token>` where the token is 28 URL-safe
base64 characters encoding a 21-byte car identifier whose last 6 bytes are the
NFC UID the car-detect event also reports. This module transcribes those
rules with nothing but the standard library and holds the spec's examples to
them — the same contract `test_am43_spec.py` keeps for the AM43 checksum.

The speed vectors are measurements the source published (they identify no
unit); the car-ID vector is invented, with the placeholder UID
aa:bb:cc:dd:ee:ff, so it names no real car.
"""

from __future__ import annotations

import base64
import struct
from pathlib import Path

import pytest
import yaml

REPO_ROOT = Path(__file__).resolve().parent.parent
SPEC_PATH = REPO_ROOT / "device-specs" / "devices" / "hot-wheels-id-race-portal.yaml"

UUID_PREFIX = "af0a6ec7-"
UUID_SUFFIX = "-84a0-91559fc6f0de"
SPEED_CHAR = "af0a6ec7-0006-000c-84a0-91559fc6f0de"
NDEF_CHAR = "af0a6ec7-0004-000c-84a0-91559fc6f0de"
DETECT_CHAR = "af0a6ec7-0005-000c-84a0-91559fc6f0de"
URI_HOST_PATH = b"pid.mattel/"


def unhex(text: str) -> bytes:
    return bytes.fromhex(text.replace(" ", ""))


def decode_speed(payload: bytes) -> float:
    """The rule the spec states: exactly 4 bytes, little-endian binary32."""
    assert len(payload) == 4
    return struct.unpack("<f", payload)[0]


def decode_token(token: str) -> bytes:
    """28 URL-safe base64 characters, no padding, -> 21 bytes."""
    assert len(token) == 28
    return base64.urlsafe_b64decode(token)


def uri_record(token: str) -> bytes:
    """Build the NDEF URI record the spec lays out field by field."""
    uri = URI_HOST_PATH + token.encode("ascii")
    payload = bytes([0x02]) + uri  # prefix code 0x02 = "https://www."
    header = 0x91  # MB=1, ME=0, CF=0, SR=1, IL=0, TNF=1
    return bytes([header, 1, len(payload), ord("U")]) + payload


@pytest.fixture(scope="module")
def spec() -> dict:
    return yaml.safe_load(SPEC_PATH.read_text(encoding="utf-8"))


@pytest.fixture(scope="module")
def vectors(spec) -> dict:
    return spec["protocol_details"]["test_vectors"]


def characteristic(spec: dict, uuid: str) -> dict:
    for service in spec["services"]:
        for char in service.get("characteristics") or []:
            if char["uuid"] == uuid:
                return char
    raise AssertionError(f"{uuid} not found")


def test_every_uuid_follows_the_declared_scheme(spec):
    """af0a6ec7-XXXX-YYYY-84a0-91559fc6f0de, lower-case, service YYYY in a/b/c."""
    for service in spec["services"]:
        suuid = service["uuid"]
        assert suuid.startswith(UUID_PREFIX + "0001-") and suuid.endswith(UUID_SUFFIX)
        service_field = suuid[14:18]
        assert service_field in {"000a", "000b", "000c"}, suuid
        for char in service.get("characteristics") or []:
            cuuid = char["uuid"]
            assert cuuid == cuuid.lower()
            assert cuuid.startswith(UUID_PREFIX) and cuuid.endswith(UUID_SUFFIX)
            assert cuuid[14:18] == service_field, f"{cuuid} is filed under {suuid}"
            assert cuuid[9:13] != "0001", f"{cuuid} reuses the service's own index"


def test_published_speed_examples_decode_as_little_endian_float32(vectors):
    for vector in vectors["speed_float32_le"]:
        value = decode_speed(unhex(vector["hex"]))
        assert value == pytest.approx(vector["value"], abs=5e-5), vector


def test_speed_example_in_payload_formats_matches_the_first_vector(spec, vectors):
    example = spec["payload_formats"]["SpeedEvent"]["example"]
    first = vectors["speed_float32_le"][0]
    assert unhex(example) == unhex(first["hex"])
    assert decode_speed(unhex(example)) == pytest.approx(first["value"], abs=5e-5)


def test_speed_field_is_four_raw_bytes(spec):
    """The schema has no float type, so the field must be declared as bytes[4]."""
    fields = characteristic(spec, SPEED_CHAR)["format"]
    assert len(fields) == 1
    field = fields[0]
    assert (field["offset"], field["length"], field["type"]) == (0, 4, "bytes")
    assert "unit" not in field, "the unit is unconfirmed; the spec must not claim one"


def test_car_id_token_decodes_to_the_declared_layout(vectors):
    car_id = vectors["car_id"]
    decoded = decode_token(car_id["token"])
    assert len(decoded) == 21
    assert decoded.hex() == car_id["decoded_hex"]
    assert decoded[:2] == bytes([0x01, 0x00]), "version prefix"
    assert decoded[-6:].hex() == car_id["nfc_uid_hex"], "NFC UID is the last 6 bytes"


def test_car_detect_event_carries_the_same_uid(vectors):
    car_id = vectors["car_id"]
    event = unhex(car_id["car_detect_event_hex"])
    assert len(event) == 7
    assert event[0] == 0x04
    assert event[1:].hex() == car_id["nfc_uid_hex"]


def test_ndef_uri_record_rebuilds_from_the_token(spec, vectors):
    car_id = vectors["car_id"]
    record = uri_record(car_id["token"])
    assert record.hex() == car_id["ndef_uri_record_hex"]
    # The field-by-field layout the characteristic declares.
    fields = {f["name"]: f for f in characteristic(spec, NDEF_CHAR)["format"]}
    assert record[fields["ndef_header"]["offset"]] == 0x91
    assert record[fields["type_length"]["offset"]] == 1
    assert record[fields["payload_length"]["offset"]] == 0x28 == 1 + len(URI_HOST_PATH) + 28
    assert record[fields["record_type"]["offset"]] == 0x55
    assert record[fields["uri_prefix_code"]["offset"]] == 0x02
    host = fields["uri_host_path"]
    assert record[host["offset"]: host["offset"] + host["length"]] == URI_HOST_PATH
    token = fields["car_id_token"]
    assert record[token["offset"]: token["offset"] + token["length"]].decode() == car_id["token"]
    assert len(record) == token["offset"] + token["length"] == 44


def test_ndef_header_bits_say_more_records_follow():
    header = 0x91
    assert header & 0x80, "MB: first record"
    assert not header & 0x40, "ME clear: another record follows (the source's signature)"
    assert header & 0x10, "SR: one-byte payload length"
    assert not header & 0x08, "IL clear: no ID field"
    assert header & 0x07 == 1, "TNF 1: NFC Forum well-known type"


def test_payload_format_examples_agree_with_the_vectors(spec, vectors):
    formats = spec["payload_formats"]
    car_id = vectors["car_id"]
    assert formats["CarIdToken"]["example"] == car_id["token"]
    assert unhex(formats["NdefRecord"]["example"]).hex() == car_id["ndef_uri_record_hex"]
    assert unhex(formats["CarDetectEvent"]["example"]).hex() == car_id["car_detect_event_hex"]


def test_control_register_patterns_are_five_bytes_and_byte_4_means_present(spec):
    patterns = spec["payload_formats"]["ControlRegister"]["values"]
    present = {unhex(k)[4] for k, meaning in patterns.items() if "car present" in meaning}
    absent = {unhex(k)[4] for k, meaning in patterns.items() if "car present" not in meaning}
    assert all(len(unhex(k)) == 5 for k in patterns)
    assert present == {0x02}
    assert absent == {0x00}
    field = next(
        f for f in characteristic(spec, "af0a6ec7-0007-000c-84a0-91559fc6f0de")["format"]
        if f["name"] == "car_present"
    )
    assert field["offset"] == 4 and set(field["values"]) == {0, 2}


def test_detect_format_match_is_the_event_type_byte(spec):
    char = characteristic(spec, DETECT_CHAR)
    assert char["format_match"] == {
        "offset": 0,
        "value": 0x04,
        "notes": char["format_match"]["notes"],
    }
