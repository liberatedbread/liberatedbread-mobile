# Copyright 2026 Pigs Can Fly Labs LLC
# SPDX-License-Identifier: Apache-2.0
"""Proves the Hörmann BiSecur Gateway spec's frames follow its own stated rule.

`device-specs/devices/hormann-bisecur-gateway.yaml` says a frame is hex ASCII
of `src(6) dst(6) len(2) tag token(4) cmd payload chk`, where the packet
checksum is the length value plus the byte sum of tag through payload, and a final
transport checksum is the sum of the ASCII codes of the hex text before it.
This module transcribes that rule with the standard library alone and holds
every example frame in the spec to it, so a frame that drifts from the rule
fails here rather than at a gateway.
"""

from __future__ import annotations

from pathlib import Path

import pytest
import yaml

REPO_ROOT = Path(__file__).resolve().parent.parent
SPEC_PATH = REPO_ROOT / "device-specs" / "devices" / "hormann-bisecur-gateway.yaml"
GATEWAY = bytes.fromhex("5410EC000001")  # placeholder; OUI kept
CLIENT = bytes.fromhex("000000000006")
TOKEN = 0x1A2B3C4D  # invented


def build(src: bytes, dst: bytes, tag: int, token: int, cmd: int, payload: bytes = b"") -> str:
    body = bytes([tag]) + token.to_bytes(4, "big") + bytes([cmd]) + payload
    length = 2 + len(body) + 1
    packet_chk = (length + sum(body)) & 0xFF
    text = (src + dst).hex().upper() + f"{length:04X}" + (body + bytes([packet_chk])).hex().upper()
    return text + f"{sum(text.encode()) & 0xFF:02X}"


def check(frame: str) -> tuple[bytes, int, bytes]:
    """Return (packet bytes without checksum, command id, payload) after verifying both checksums."""
    assert frame == frame.upper(), "frames are upper-case hex"
    assert sum(frame[:-2].encode()) & 0xFF == int(frame[-2:], 16), "transport checksum"
    raw = bytes.fromhex(frame[:-2])
    length = int.from_bytes(raw[12:14], "big")
    packet = raw[12:]
    assert length == len(packet), "length field counts the packet"
    assert (length + sum(packet[2:-1])) & 0xFF == packet[-1], "packet checksum"
    return packet[:-1], packet[7], packet[8:-1]


@pytest.fixture(scope="module")
def spec() -> dict:
    return yaml.safe_load(SPEC_PATH.read_text())


def test_every_example_frame_carries_valid_checksums(spec):
    frames = [c["example_body"] for c in spec["commands"].values()]
    frames.append(spec["payload_formats"]["Frame"]["example"])
    for frame in frames:
        check(frame)


def test_examples_match_their_stated_contents(spec):
    cmds = spec["commands"]
    assert cmds["login"]["example_body"] == build(
        CLIENT, GATEWAY, 3, 0, 0x10, bytes([8]) + b"username" + b"password"
    )
    assert cmds["get_groups"]["example_body"] == build(
        CLIENT, GATEWAY, 4, TOKEN, 0x06, b'{"CMD":"GET_GROUPS"}'
    )
    assert cmds["get_transition"]["example_body"] == build(CLIENT, GATEWAY, 5, TOKEN, 0x70, b"\x00")
    assert cmds["send_impulse"]["example_body"] == build(CLIENT, GATEWAY, 6, TOKEN, 0x33, b"\x00\xff")
    assert cmds["logout"]["example_body"] == build(CLIENT, GATEWAY, 8, TOKEN, 0x11)
    assert spec["payload_formats"]["Frame"]["example"] == build(CLIENT, GATEWAY, 2, 0, 0x26)


def test_impulse_is_advanced(spec):
    assert spec["commands"]["send_impulse"]["advanced"] is True


def test_discovery_probe_is_the_documented_text(spec):
    probe = spec["device"]["discovery"]["methods"][0]["udp_broadcast"]["probe_hex"]
    assert bytes.fromhex(probe) == b'<Discover target="Gateway" />'


def test_safety_facts_are_pinned(spec):
    """PORT_ERROR after an impulse does not mean the door stayed put; never resend on it."""
    impulse = " ".join(spec["commands"]["send_impulse"]["description"].split())
    assert "PORT_ERROR" in impulse
    assert "Do not retry on PORT_ERROR" in impulse
    detail = " ".join(spec["device"]["safety_advisory"]["detail"].split())
    assert "PORT_ERROR reply does not mean the door did not move" in detail
    assert "never resend automatically" in detail
    udp = spec["device"]["discovery"]["methods"][0]["udp_broadcast"]
    assert udp["port"] == 4001
    assert udp["listen_port"] == 4002


def test_packet_checksum_adds_the_length_value_not_its_bytes():
    """With a payload of 247+ bytes the length passes 255 and the two readings diverge."""
    payload = b'{"CMD":"GET_GROUPS","PAD":"' + b"x" * 230 + b'"}'
    assert len(payload) >= 247
    frame = build(CLIENT, GATEWAY, 9, TOKEN, 0x06, payload)
    check(frame)
    packet = bytes.fromhex(frame[:-2])[12:]
    length = int.from_bytes(packet[:2], "big")
    assert length == 9 + len(payload) > 0xFF
    body_sum = sum(packet[2:-1])  # tag through payload
    assert packet[-1] == (length + body_sum) & 0xFF
    assert packet[-1] != (packet[0] + packet[1] + body_sum) & 0xFF


def test_transition_example_decodes_as_documented(spec):
    data = bytes.fromhex(spec["payload_formats"]["Transition"]["example"])
    assert len(data) == 16
    assert data[0] / 2 == 92  # percent open
    assert data[1] == 0
    assert data[3] == 24
    status = int.from_bytes(data[6:8], "little")
    assert status == 0x026C
    bits = {i for i in range(16) if status >> i & 1}
    assert bits == {2, 3, 5, 6, 9}  # option relay, light barrier, to-closed, driving, learned
