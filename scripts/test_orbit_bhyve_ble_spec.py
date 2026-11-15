# Copyright 2026 Pigs Can Fly Labs LLC
# SPDX-License-Identifier: Apache-2.0
"""Proves the Orbit B-hyve BLE spec's envelope reproduces its own vectors.

`device-specs/devices/orbit-bhyve-ble.yaml` states, in
`protocol_details.envelope`, how a session nonce and two counters come out of
the 20-byte handshake, how the AES-128 keystream is built from them, how the
outer frame and its additive trailer are laid out, and how the protobuf
family's inner message is wrapped in a CRC-16/XMODEM. This module transcribes
those rules -- AES-128-ECB from `cryptography` (already a dev dependency for
the Rabbit Air proof), everything else from the standard library -- imports
none of our code and none of the upstream project's, and asserts that the
transcription reproduces every vector the spec carries.

It also renders the command templates (protobuf start bodies, HT25 mesh
start) and checks them against the plaintexts in those vectors, so a template
that drifts from the envelope fails here.
"""

from __future__ import annotations

import struct
from pathlib import Path

import pytest
import yaml

from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes

REPO_ROOT = Path(__file__).resolve().parent.parent
SPEC_PATH = REPO_ROOT / "device-specs" / "devices" / "orbit-bhyve-ble.yaml"
CMD_CHAR = "00006c72-fe32-4f58-8b78-98e42b2c047f"
INNER_HEADER = bytes.fromhex("aa775a0f")


# --- transcription of protocol_details.envelope ----------------------------

def crc16_xmodem(data: bytes) -> int:
    crc = 0
    for byte in data:
        crc ^= byte << 8
        for _ in range(8):
            crc = ((crc << 1) ^ 0x1021) if crc & 0x8000 else crc << 1
            crc &= 0xFFFF
    return crc


def inner_message(protobuf: bytes) -> bytes:
    head = INNER_HEADER + struct.pack("<H", len(protobuf) + 2) + protobuf
    return head + struct.pack("<H", crc16_xmodem(head))


def session(handshake_write: bytes, handshake_read: bytes) -> tuple[bytes, int, int]:
    composed = handshake_read[:4] + handshake_write[4:20]
    nonce = composed[:12]
    ctr_tx = struct.unpack("<I", composed[12:16])[0]
    ctr_rx = struct.unpack("<I", composed[16:20])[0]
    return nonce, ctr_tx, ctr_rx


def keystream_xor(key: bytes, nonce: bytes, counter: int, data: bytes) -> tuple[bytes, int]:
    blocks = (len(data) + 15) // 16
    aes = Cipher(algorithms.AES(key), modes.ECB()).encryptor()
    stream = b"".join(
        aes.update(nonce + struct.pack("<I", (counter + i) & 0xFFFFFFFF))
        for i in range(blocks)
    )
    out = bytes(a ^ b for a, b in zip(data, stream[: len(data)], strict=True))
    return out, (counter + blocks) & 0xFFFFFFFF


def trailer(magic: int, plaintext: bytes) -> bytes:
    return struct.pack("<H", (magic + len(plaintext) + sum(plaintext)) & 0xFFFF)


def encode_frame(key, nonce, counter, magic, plaintext) -> tuple[bytes, int]:
    ciphertext, nxt = keystream_xor(key, nonce, counter, plaintext)
    frame = bytes([magic, len(ciphertext)]) + ciphertext + trailer(magic, plaintext)
    return frame, nxt


def decode_frame(key, nonce, counter, frame: bytes) -> tuple[bytes, int]:
    magic, length = frame[0], frame[1]
    plaintext, nxt = keystream_xor(key, nonce, counter, frame[2:2 + length])
    assert frame[2 + length:] == trailer(magic, plaintext), "trailer mismatch"
    return plaintext, nxt


def varint(value: int) -> bytes:
    out = bytearray()
    while value > 0x7F:
        out.append((value & 0x7F) | 0x80)
        value >>= 7
    out.append(value)
    return bytes(out)


def render(command: dict, values: dict) -> bytes:
    """Render a template with the spec's parameter types (uint8/uint16/varint)."""
    out = bytearray()
    for item in command["template"]:
        if isinstance(item, int):
            out.append(item)
            continue
        name = item.strip("{}")
        param = command["parameters"][name]
        value = values.get(name, param.get("default"))
        if param["type"] == "varint":
            out += varint(value)
        elif param["type"] == "uint16":
            order = "<" if param.get("endianness") == "little" else ">"
            out += struct.pack(order + "H", value)
        elif param["type"] == "uint8":
            out.append(value)
        else:  # pragma: no cover - a new type needs a new branch here
            raise AssertionError(f"unhandled parameter type {param['type']}")
    return bytes(out)


# --- fixtures --------------------------------------------------------------

@pytest.fixture(scope="module")
def spec() -> dict:
    return yaml.safe_load(SPEC_PATH.read_text(encoding="utf-8"))


@pytest.fixture(scope="module")
def vectors(spec) -> dict:
    return spec["protocol_details"]["envelope"]["test_vectors"]


@pytest.fixture(scope="module")
def commands(spec) -> dict:
    for service in spec["services"]:
        for char in service["characteristics"]:
            if char["uuid"] == CMD_CHAR:
                return char["commands"]
    raise AssertionError("command characteristic not found")


# --- tests -----------------------------------------------------------------

def test_handshake_derives_the_stated_nonce_and_counters(vectors):
    write = bytes.fromhex(vectors["handshake_write"])
    read = bytes.fromhex(vectors["handshake_read"])
    assert len(write) == 20 and len(read) == 20
    assert write[11] == 0x00, "the spec says byte 11 of the handshake write is forced to 0"
    assert any(read[:4]) and not any(read[4:]), "a valid handshake read is seed + 16 zeros"
    nonce, ctr_tx, ctr_rx = session(write, read)
    assert nonce.hex() == vectors["nonce"]
    assert ctr_tx == vectors["ctr_tx"]
    assert ctr_rx == vectors["ctr_rx"]


def test_every_frame_vector_encrypts_and_decrypts(vectors):
    key = bytes.fromhex(vectors["network_key"])
    nonce, _, _ = session(
        bytes.fromhex(vectors["handshake_write"]), bytes.fromhex(vectors["handshake_read"])
    )
    for vec in vectors["frames"]:
        plaintext = bytes.fromhex(vec["plaintext"])
        frame, nxt = encode_frame(key, nonce, vec["counter"], vec["magic"], plaintext)
        assert frame.hex() == vec["frame"], vec["name"]
        assert nxt == vec["next_counter"], vec["name"]
        assert len(frame) == len(plaintext) + 4
        decoded, _ = decode_frame(key, nonce, vec["counter"], bytes.fromhex(vec["frame"]))
        assert decoded == plaintext, vec["name"]


def test_host_frames_chain_their_counter(vectors):
    """The second host frame starts where the first one's blocks ended."""
    frames = [f for f in vectors["frames"] if f["magic"] == 0x11 and "host" in f["name"]]
    assert frames[0]["counter"] == vectors["ctr_tx"]
    assert frames[1]["counter"] == frames[0]["next_counter"]


def test_protobuf_plaintexts_carry_a_valid_inner_crc(vectors):
    for vec in vectors["frames"]:
        pt = bytes.fromhex(vec["plaintext"])
        if vec["magic"] != 0x11:
            continue
        assert pt[:4] == INNER_HEADER
        length = struct.unpack("<H", pt[4:6])[0]
        assert length == len(pt) - 6, "inner length = protobuf + 2"
        assert inner_message(pt[6:-2]) == pt, vec["name"]


def test_published_inner_messages_match_the_crc_rule(vectors):
    published = vectors["published_inner_messages"]
    for name, hexstr in published.items():
        if name == "notes":
            continue
        msg = bytes.fromhex(hexstr)
        assert inner_message(msg[6:-2]) == msg, name


def test_stop_trailer_matches_the_independent_client(vectors):
    """wxfield's client sends 80 03 after its stop frame; the rule agrees."""
    stop = next(f for f in vectors["frames"] if "stop_watering" in f["name"])
    assert bytes.fromhex(stop["frame"])[-2:] == bytes.fromhex("8003")


def test_fixed_protobuf_commands_wrap_to_the_vector_plaintexts(commands, vectors):
    stop_pt = next(f for f in vectors["frames"] if "stop_watering" in f["name"])["plaintext"]
    assert inner_message(bytes(commands["stop_watering"]["value"])).hex() == stop_pt
    published = vectors["published_inner_messages"]
    assert inner_message(bytes(commands["get_status"]["value"])).hex() == published["get_status"]
    assert inner_message(bytes(commands["get_battery"]["value"])).hex() == published["get_battery"]


def test_start_templates_render_protobuf_with_consistent_lengths(commands, vectors):
    start2 = next(f for f in vectors["frames"] if "start_zone_2" in f["name"])["plaintext"]
    assert inner_message(render(commands["start_zone_2"], {"duration": 600})).hex() == start2
    for zone in range(1, 5):
        cmd = commands[f"start_zone_{zone}"]
        param = cmd["parameters"]["duration"]
        for seconds in (param["min"], param["default"], param["max"]):
            body = render(cmd, {"duration": seconds})
            # Re-encode generically and compare: the template's fixed
            # nested lengths must equal what a protobuf encoder writes.
            station = b"\x08" + varint(zone - 1) + b"\x10" + varint(seconds)
            manual = b"\x1a" + varint(len(station)) + station
            mode = b"\x08\x02\x12" + varint(len(manual)) + manual
            assert body == b"\x72" + varint(len(mode)) + mode, (zone, seconds)
        # Just outside the bound the varint changes width and the template breaks.
        assert len(varint(param["min"] - 1)) == 1
        assert len(varint(param["max"] + 1)) == 3


def test_ht25_start_template_renders_the_vector(commands, vectors):
    mesh = next(f for f in vectors["frames"] if f["magic"] == 0x10)
    body = render(commands["ht25_start"], {"mesh_id": 0x1234, "duration": 600})
    assert body.hex() == mesh["plaintext"]
    assert commands["ht25_start"]["parameters"]["mesh_id"]["source"] == "credential:mesh_device_id"


def test_battery_reply_vector_decodes_to_its_millivolts(vectors):
    reply = next(f for f in vectors["frames"] if "battery reply" in f["name"])
    pt = bytes.fromhex(reply["plaintext"])
    pb = pt[6:-2]
    # field 46 (tag 0xf2 0x02), length 3, field 3 varint (tag 0x18) = 2838
    assert pb[:2] == b"\xf2\x02" and pb[3] == 0x18
    value = (pb[4] & 0x7F) | (pb[5] << 7)
    assert value == 2838
