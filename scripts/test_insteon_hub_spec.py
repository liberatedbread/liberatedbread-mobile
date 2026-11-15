# Copyright 2026 Pigs Can Fly Labs LLC
# SPDX-License-Identifier: Apache-2.0
"""Proves the Insteon Hub spec's frames follow its own stated rules.

`device-specs/devices/insteon-hub.yaml` says:

- a standard send is `02 62 <addr:3> <flags> <cmd1> <cmd2>` (8 bytes, flags
  bit 4 clear) and the modem echoes it with 06 or 15 appended;
- an extended send is the same with flags bit 4 set and 14 data bytes, where
  D14 = (-(cmd1 + cmd2 + D1..D13)) & 0xFF;
- a received standard message is `02 50 <from:3> <to:3> <flags> <cmd1> <cmd2>`;
- Hub v2's buffstatus.xml BS element is 200 hex characters of ring plus a
  2-hex-digit write position, read from a stored cursor with wrap-around.

This module transcribes those rules with nothing but the standard library,
builds its own vectors from invented addresses (1A.2B.3C for a device,
4D.5E.6F for the hub modem), and holds every command path, payload example
and the buffer parser to them — the same contract `test_wemo_spec.py` keeps.
"""

from __future__ import annotations

import re
from pathlib import Path

import pytest
import yaml

REPO_ROOT = Path(__file__).resolve().parent.parent
SPEC_PATH = REPO_ROOT / "device-specs" / "devices" / "insteon-hub.yaml"

DEVICE = bytes.fromhex("1A2B3C")
HUB = bytes.fromhex("4D5E6F")
RING = 200
SEND_PATH = re.compile(r"^/3\?([0-9A-F{}a-z_]+)=I=3$")


def checksum(cmd1: int, cmd2: int, data13: bytes) -> int:
    assert len(data13) == 13
    return (-(cmd1 + cmd2 + sum(data13))) & 0xFF


def standard(addr: bytes, cmd1: int, cmd2: int, flags: int = 0x0F) -> bytes:
    assert not flags & 0x10, "standard messages have flags bit 4 clear"
    return bytes([0x02, 0x62]) + addr + bytes([flags, cmd1, cmd2])


def extended(addr: bytes, cmd1: int, cmd2: int, data13: bytes, flags: int = 0x1F) -> bytes:
    assert flags & 0x10, "extended messages have flags bit 4 set"
    return (
        bytes([0x02, 0x62]) + addr + bytes([flags, cmd1, cmd2])
        + data13 + bytes([checksum(cmd1, cmd2, data13)])
    )


def received(frm: bytes, to: bytes, flags: int, cmd1: int, cmd2: int) -> bytes:
    return bytes([0x02, 0x50]) + frm + to + bytes([flags, cmd1, cmd2])


def new_data(bs: str, cursor: int) -> tuple[str, int]:
    """The spec's HubBuffer parse rules: returns (new hex chars, new cursor)."""
    bs = bs.strip()
    assert len(bs) % 2 == 0
    ring, position = bs[:RING], int(bs[RING:RING + 2], 16)
    if set(ring) == {"0"}:
        return "", 0
    if position > cursor:
        return ring[cursor:position], position
    if position < cursor:
        tail = ring[cursor:RING]
        if set(tail) == {"0"}:
            tail = ""
        return tail + ring[:position], position
    return "", position


def fill(path: str, **params) -> str:
    out = path
    for key, value in params.items():
        out = out.replace("{" + key + "}", value)
    assert "{" not in out, out
    return out


@pytest.fixture(scope="module")
def spec() -> dict:
    return yaml.safe_load(SPEC_PATH.read_text(encoding="utf-8"))


# -- checksum ---------------------------------------------------------------


def test_checksum_helper_matches_the_stated_rule():
    """The helper itself, not the spec: the spec-facing checks are below."""
    for cmd1, cmd2, data in [
        (0x2E, 0x00, bytes([0x01]) + bytes(12)),
        (0x2E, 0x00, bytes(range(1, 14))),
        (0xFF, 0xFF, bytes([0xFF]) * 13),
        (0x00, 0x00, bytes(13)),
    ]:
        d14 = checksum(cmd1, cmd2, data)
        assert (cmd1 + cmd2 + sum(data) + d14) & 0xFF == 0


def test_checksum_known_values():
    # Extended get-settings for button 1: 2E 00, D1 = 01 -> -(0x2F) = 0xD1.
    assert checksum(0x2E, 0x00, bytes([0x01]) + bytes(12)) == 0xD1
    assert checksum(0x00, 0x00, bytes(13)) == 0x00


def test_extended_example_carries_a_valid_checksum(spec):
    frame = bytes.fromhex(spec["payload_formats"]["SendExtended"]["example"])
    assert len(frame) == 22
    assert frame[:2] == b"\x02\x62"
    assert frame[5] & 0x10
    cmd1, cmd2, data13, d14 = frame[6], frame[7], frame[8:21], frame[21]
    assert d14 == checksum(cmd1, cmd2, data13)
    assert frame == extended(DEVICE, 0x2E, 0x00, bytes([0x01]) + bytes(12))


def test_extended_command_path_carries_a_valid_checksum(spec):
    path = spec["commands"]["extended_get_settings"]["path"]
    frame = bytes.fromhex(SEND_PATH.match(fill(path, address="1A2B3C")).group(1))
    assert frame == extended(DEVICE, 0x2E, 0x00, bytes([0x01]) + bytes(12))


# Modem commands that address no device: each path is a fixed frame, and the
# reset among them erases the modem's link database, so a typo must fail here.
@pytest.mark.parametrize(
    "name,frame_hex",
    [
        ("get_im_info", "0260"),
        ("get_first_link", "0269"),
        ("get_next_link", "026A"),
        ("start_all_linking", "02640100"),
        ("cancel_all_linking", "0265"),
        ("reset_im", "0267"),
    ],
)
def test_fixed_modem_command_paths(spec, name, frame_hex):
    assert SEND_PATH.match(spec["commands"][name]["path"]).group(1) == frame_hex


# -- standard frame layout --------------------------------------------------


def test_standard_example_layout(spec):
    frame = bytes.fromhex(spec["payload_formats"]["SendStandard"]["example"])
    assert frame == standard(DEVICE, 0x11, 0xFF)
    fields = {f["name"]: f for f in spec["payload_formats"]["SendStandard"]["fields"]}
    assert frame[fields["to_address"]["offset"]:][:3] == DEVICE
    assert frame[fields["cmd1"]["offset"]] == 0x11
    assert sum(f["length"] for f in fields.values()) == len(frame) == 8


@pytest.mark.parametrize(
    "name,cmd1,cmd2",
    [
        ("light_on_full", 0x11, 0xFF),
        ("light_fast_on", 0x12, 0xFF),
        ("light_off", 0x13, 0x00),
        ("light_fast_off", 0x14, 0x00),
        ("status_request", 0x19, 0x00),
    ],
)
def test_fixed_standard_command_paths(spec, name, cmd1, cmd2):
    path = spec["commands"][name]["path"]
    frame = bytes.fromhex(SEND_PATH.match(fill(path, address="1A2B3C")).group(1))
    assert frame == standard(DEVICE, cmd1, cmd2)


def test_level_command_path_renders_two_hex_digits(spec):
    path = spec["commands"]["light_on"]["path"]
    for level in (0, 128, 255):
        url = fill(path, address="1A2B3C", level=f"{level:02X}")
        frame = bytes.fromhex(SEND_PATH.match(url).group(1))
        assert frame == standard(DEVICE, 0x11, level)
    assert fill(path, address="1A2B3C", level="FF") == "/3?02621A2B3C0F11FF=I=3"


def test_received_example_layout(spec):
    frame = bytes.fromhex(spec["payload_formats"]["ReceiveStandard"]["example"])
    assert frame == received(DEVICE, HUB, 0x2B, 0x11, 0xFF)
    assert len(frame) == 11
    assert frame[8] >> 5 == 0b001, "ACK of direct message"


def test_im_info_example_layout(spec):
    frame = bytes.fromhex(spec["payload_formats"]["ImInfo"]["example"])
    assert len(frame) == 9 and frame[:2] == b"\x02\x60" and frame[-1] == 0x06
    assert frame[2:5] == HUB


# -- hub v2 buffer ----------------------------------------------------------


def test_buffer_example_decodes_to_echo_ack_and_device_reply(spec):
    bs = spec["payload_formats"]["HubBuffer"]["example"]
    assert len(bs) == RING + 2
    data, cursor = new_data(bs, 0)
    echo = standard(DEVICE, 0x11, 0xFF) + b"\x06"
    reply = received(DEVICE, HUB, 0x2B, 0x11, 0xFF)
    assert bytes.fromhex(data) == echo + reply
    assert cursor == len(data) == 0x28


def test_buffer_wraparound_and_clear():
    # 180 characters of older traffic, then a 22-character 0x50 frame that
    # runs 2 characters past the end of the ring and wraps to the start.
    start = 180
    new = "0250" + "1A2B3C4D5E6F2B1300"
    ring = list("AA" * (start // 2) + "0" * (RING - start))
    for i, ch in enumerate(new):
        ring[(start + i) % RING] = ch
    bs = "".join(ring) + f"{(start + len(new)) % RING:02X}"
    data, cursor = new_data(bs, start)
    assert data == new and cursor == 2
    assert new_data("0" * RING + "00", 120) == ("", 0)
    # A tail of zeros past the cursor is a ring the hub cleared, not a wrap:
    # only what was written from the start counts.
    head = "0262" + "1A2B3C0F1100" + "06"
    cleared = head + "0" * (RING - len(head))
    assert new_data(cleared + f"{len(head):02X}", 150) == (head, len(head))
    assert new_data(bs, cursor) == ("", cursor)
