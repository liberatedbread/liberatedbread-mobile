# Copyright 2026 Pigs Can Fly Labs LLC
# SPDX-License-Identifier: Apache-2.0
"""Proves the Apple AirPort ACP spec's example messages follow its own stated rules.

`device-specs/devices/apple-airport-acp.yaml` says an ACP message is a 128-byte
big-endian header (magic "acpp", version, Adler-32 header checksum computed
with that field zeroed, Adler-32 body checksum, signed body size, flags,
unused, command, error code, 12 zero bytes, a 32-byte key field, 48 zero
bytes) followed by a body of property elements (name, flags, size, value) or
a CFB0 plist. The legacy key field is the password XORed with a keystream
derived from a 16-byte static key, and SRP session keys come from PBKDF2.
This module transcribes those rules with the standard library alone and
rebuilds every example in the spec from them, using the invented password
"example-owner-pw", so an example that drifts from the rule fails here.
"""

from __future__ import annotations

import hashlib
import struct
import zlib
from pathlib import Path

import pytest
import yaml

REPO_ROOT = Path(__file__).resolve().parent.parent
SPEC_PATH = REPO_ROOT / "device-specs" / "devices" / "apple-airport-acp.yaml"
PASSWORD = "example-owner-pw"  # invented

GET_PROPERTY, SET_PROPERTY, AUTHENTICATE, GET_FEATURES = 0x14, 0x15, 0x1A, 0x1B


def keystream(static_key: bytes, length: int) -> bytes:
    return bytes(((i + 0x55) & 0xFF) ^ static_key[i % len(static_key)] for i in range(length))


@pytest.fixture(scope="module")
def spec() -> dict:
    return yaml.safe_load(SPEC_PATH.read_text())


@pytest.fixture(scope="module")
def acp(spec) -> dict:
    return spec["protocol_details"]["acp"]


@pytest.fixture(scope="module")
def stream32(acp) -> bytes:
    text = " ".join(acp["key_field"]["keystream"].split())
    static_hex = text.split("static_key = ")[1].split(".")[0]
    return keystream(bytes.fromhex(static_hex), 32)


def password_key(stream: bytes, password: str) -> bytes:
    padded = password.encode()[:32].ljust(32, b"\x00")
    return bytes(a ^ b for a, b in zip(stream, padded, strict=True))


def header(command: int, flags: int, key: bytes, body: bytes | None) -> bytes:
    size, body_sum = (-1, 1) if body is None else (len(body), zlib.adler32(body))

    def pack(checksum: int) -> bytes:
        fields = struct.pack(">iIIiiiii", 0x00030001, checksum, body_sum, size, flags, 0, command, 0)
        return b"acpp" + fields + bytes(12) + key + bytes(48)

    return pack(zlib.adler32(pack(0)))


def message(command: int, flags: int, key: bytes, body: bytes | None = None) -> str:
    return (header(command, flags, key, body) + (body or b"")).hex()


def element(name: str, value: bytes = b"\x00\x00\x00\x00", flags: int = 0) -> bytes:
    return name.encode() + struct.pack(">II", flags, len(value)) + value


def cfb_object(obj) -> bytes:
    if isinstance(obj, bool):
        return bytes([0x09 if obj else 0x08])
    if isinstance(obj, int):
        for size in (1, 2, 4, 8):
            if obj < 1 << (8 * size):
                return bytes([0x10 + size.bit_length() - 1]) + obj.to_bytes(size, "big")
    if isinstance(obj, str):
        return b"\x70" + obj.encode() + b"\x00"
    if isinstance(obj, bytes):
        prefix = bytes([0x40 + len(obj)]) if len(obj) < 15 else b"\x4f" + cfb_object(len(obj))
        return prefix + obj
    if isinstance(obj, dict):
        return b"\xd0" + b"".join(cfb_object(k) + cfb_object(v) for k, v in obj.items()) + b"\x00"
    raise TypeError(obj)


def cfb(obj) -> bytes:
    return b"CFB0" + cfb_object(obj) + b"END!"


def parse(hex_message: str, header_only: bool = False) -> tuple[dict, bytes]:
    """Split a message and verify magic, version, both checksums and the size."""
    raw = bytes.fromhex(hex_message)
    head, body = raw[:128], raw[128:]
    assert head[:4] == b"acpp"
    version, h_sum, b_sum, size, flags, unused, command, error = struct.unpack(">iIIiiiii", head[4:36])
    assert version == 0x00030001
    assert head[36:48] == bytes(12) and head[80:] == bytes(48)
    assert zlib.adler32(head[:8] + bytes(4) + head[12:]) == h_sum, "header checksum"
    if header_only:
        assert body == b""
    elif size == -1:
        assert body == b"" and b_sum == 1
    else:
        assert len(body) == size and zlib.adler32(body) == b_sum, "body checksum"
    return {"flags": flags, "command": command, "error": error, "unused": unused, "key": head[48:80]}, body


def test_keystream_matches_the_stated_prefix(acp, stream32):
    text = " ".join(acp["key_field"]["keystream"].split())
    assert stream32.hex() in text


def test_legacy_key_example_is_the_xor_rule(acp, stream32):
    key_field = acp["key_field"]
    assert key_field["example_password"] == PASSWORD
    assert key_field["example_key"] == password_key(stream32, PASSWORD).hex()
    # The tail beyond the password is the bare keystream (password NUL-padded).
    assert key_field["example_key"][2 * len(PASSWORD):] == stream32[len(PASSWORD):].hex()
    # The empty password's key is the keystream itself.
    assert password_key(stream32, "") == stream32


def test_every_example_message_has_valid_checksums(spec):
    for command in spec["commands"].values():
        parse(command["example_body"])
    head = spec["protocol_details"]["acp"]["header"]["example_hex"]
    parse(head, header_only=True)


def test_examples_match_their_stated_contents(spec, stream32):
    legacy = password_key(stream32, PASSWORD)
    cmds = spec["commands"]
    expected = {
        "authenticate_start": message(AUTHENTICATE, 4, stream32, cfb({"state": 1, "username": "admin"})),
        "get_features": message(GET_FEATURES, 0, stream32),
        "get_name": message(GET_PROPERTY, 4, legacy, element("syNm")),
        "get_status": message(
            GET_PROPERTY, 4, legacy, b"".join(element(n) for n in ("syNm", "syVs", "syAP", "syUT", "raNm"))
        ),
        "get_wan_ip": message(GET_PROPERTY, 4, legacy, element("waIP")),
        "get_log": message(GET_PROPERTY, 4, legacy, element("logm")),
        "set_name": message(SET_PROPERTY, 0, legacy, element("syNm", b"Example Base")),
        "reboot": message(SET_PROPERTY, 0, legacy, element("acRB")),
    }
    assert set(expected) == set(cmds)
    for name, frame in expected.items():
        assert cmds[name]["example_body"] == frame, name


def test_header_example_is_the_get_name_header(spec):
    acp = spec["protocol_details"]["acp"]
    assert acp["header"]["size"] == 128
    assert spec["commands"]["get_name"]["example_body"].startswith(acp["header"]["example_hex"])
    fields, _ = parse(spec["commands"]["get_name"]["example_body"])
    assert fields["command"] == GET_PROPERTY and fields["flags"] == 4
    head = bytes.fromhex(acp["header"]["example_hex"])
    note = acp["header"]["example_notes"]
    assert f"0x{head[8:12].hex().upper()}" in note
    assert f"0x{head[12:16].hex().upper()}" in note


def test_property_element_examples(spec):
    acp = spec["protocol_details"]["acp"]
    assert acp["property_element"]["example_hex"] == element("syNm").hex()
    end = " ".join(acp["property_element"]["end_marker"].split())
    assert "00000000 00000000 00000004 00000000" in end
    assert spec["payload_formats"]["EndMarker"]["example"] == element("\x00\x00\x00\x00").hex()
    assert spec["payload_formats"]["PropertyElement"]["example"] == element("syNm", b"Example Base").hex()
    assert spec["commands"]["set_name"]["example_body"].endswith(
        spec["payload_formats"]["PropertyElement"]["example"]
    )


def test_cfb0_example_is_the_authenticate_body(spec):
    acp = spec["protocol_details"]["acp"]
    body = cfb({"state": 1, "username": "admin"})
    assert acp["cfb0_plist"]["example_hex"] == body.hex()
    assert spec["commands"]["authenticate_start"]["example_body"].endswith(body.hex())


def test_session_key_example_is_pbkdf2(acp):
    enc = acp["session_encryption"]
    ex = enc["example"]
    k = bytes.fromhex(ex["K"])
    salt0 = bytes.fromhex("F072FA3F66B410A135FAE8E6D1D43D5F")
    salt1 = bytes.fromhex("BD0682C9FE79325BC73655F4174B996C")
    assert "F072FA3F66B410A135FAE8E6D1D43D5F, 5 iterations" in enc["client_to_server"]
    assert "BD0682C9FE79325BC73655F4174B996C, 7 iterations" in enc["server_to_client"]
    assert ex["client_key"] == hashlib.pbkdf2_hmac("sha1", k, salt0, 5, 16).hex()
    assert ex["server_key"] == hashlib.pbkdf2_hmac("sha1", k, salt1, 7, 16).hex()


def test_writes_and_reboot_are_advanced(spec):
    cmds = spec["commands"]
    for name in ("set_name", "reboot"):
        assert cmds[name]["advanced"] is True
        assert cmds[name]["advanced_reason"].strip()
    for name in ("get_name", "get_status", "get_wan_ip", "get_log", "get_features", "authenticate_start"):
        assert not cmds[name].get("advanced")


def test_password_comes_from_the_stored_credential(spec):
    issued = spec["device"]["setup"]["methods"][0]["issues_credentials"]
    assert issued["admin_password"]["user_entered"] is True
    for name, command in spec["commands"].items():
        params = command.get("parameters") or {}
        if "admin_password" in params:
            assert params["admin_password"]["source"] == "credential:admin_password", name
            assert params["admin_password"]["max_length"] == 32


def test_discovery_and_port(spec):
    device = spec["device"]
    assert device["identification"]["default_port"] == 5009
    assert device["discovery"]["methods"][0]["mdns"]["service_type"] == "_airport._tcp.local."
