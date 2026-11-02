# Copyright 2026 Pigs Can Fly Labs LLC
# SPDX-License-Identifier: Apache-2.0
"""Proves the Kano wand spec's LED and orientation vectors follow its own rules.

`device-specs/devices/kano-coding-wand.yaml` says the LED takes
`[on, rgb565 >> 8, rgb565 & 0xff]` with
`rgb565 = ((r & 0xf8) << 8) | ((g & 0xfc) << 3) | ((b & 0xf8) >> 3)`, and that
an orientation notification is four int16 little-endian words, w x y z, each
the quaternion component times 1000. This module transcribes both with
nothing but the standard library and holds every fixed LED frame, every
worked RGB565 vector and the published quaternion example to them — the same
contract `test_am43_spec.py` keeps for the AM43 checksum.
"""

from __future__ import annotations

import struct
from pathlib import Path

import pytest
import yaml

REPO_ROOT = Path(__file__).resolve().parent.parent
SPEC_PATH = REPO_ROOT / "device-specs" / "devices" / "kano-coding-wand.yaml"
LED_UUID = "64a70009-f691-4b93-a6f4-0968f5b648f8"
QUAT_UUID = "64a70002-f691-4b93-a6f4-0968f5b648f8"


def rgb565(rgb888: int) -> int:
    r = (rgb888 >> 16) & 0xFF
    g = (rgb888 >> 8) & 0xFF
    b = rgb888 & 0xFF
    return ((r & 0xF8) << 8) | ((g & 0xFC) << 3) | ((b & 0xF8) >> 3)


def led_frame(on: bool, rgb888: int) -> bytes:
    packed = rgb565(rgb888)
    return bytes([1 if on else 0, packed >> 8, packed & 0xFF])


def decode_quaternion(frame: bytes) -> tuple[float, float, float, float]:
    w, x, y, z = struct.unpack("<hhhh", frame)
    return (w / 1000, x / 1000, y / 1000, z / 1000)


@pytest.fixture(scope="module")
def spec() -> dict:
    return yaml.safe_load(SPEC_PATH.read_text())


def _characteristic(spec: dict, uuid: str) -> dict:
    for service in spec["services"]:
        for char in service["characteristics"]:
            if char["uuid"] == uuid:
                return char
    raise AssertionError(f"{uuid} not found")


def test_rgb565_examples_pack_as_the_spec_says(spec):
    examples = spec["protocol_details"]["rgb565"]["examples"]
    assert examples, "the spec carries no RGB565 vectors"
    for example in examples:
        frame = bytes.fromhex(example["frame"])
        on = frame[0] == 1
        assert led_frame(on, int(example["rgb888"], 16)) == frame, example["meaning"]


def test_fixed_led_frames_are_the_packing_of_their_colour(spec):
    commands = _characteristic(spec, LED_UUID)["commands"]
    assert bytes(commands["led_on_white"]["value"]) == led_frame(True, 0xFFFFFF)
    assert bytes(commands["led_off"]["value"]) == led_frame(False, 0x000000)


def test_set_led_template_is_state_then_big_endian_word(spec):
    command = _characteristic(spec, LED_UUID)["commands"]["set_led"]
    assert command["template"] == ["{state}", "{rgb565}"]
    word = command["parameters"]["rgb565"]
    assert word["type"] == "uint16" and word["endianness"] == "big"
    # Rendering the template for red must give the red vector above.
    rendered = bytes([1]) + rgb565(0xFF0000).to_bytes(2, "big")
    assert rendered == bytes.fromhex("01f800")


def test_rgb565_keeps_only_the_top_bits():
    # Low bits of every channel are discarded, so a colour one step short of
    # full packs identically to full.
    assert rgb565(0xF8FCF8) == rgb565(0xFFFFFF) == 0xFFFF
    assert rgb565(0x070307) == 0


def test_quaternion_example_decodes_to_the_identity_pose(spec):
    payload = spec["payload_formats"]["QuaternionNotification"]
    frame = bytes.fromhex(payload["example"])
    assert len(frame) == 8
    assert decode_quaternion(frame) == (1.0, 0.0, 0.0, 0.0)
    assert decode_quaternion(bytes.fromhex("18fc000000000000"))[0] == -1.0


def test_quaternion_format_fields_agree_with_the_decoder(spec):
    fields = _characteristic(spec, QUAT_UUID)["format"]
    names = [f["name"] for f in fields]
    assert names == ["quaternion_w", "quaternion_x", "quaternion_y", "quaternion_z"]
    for index, field in enumerate(fields):
        assert field["offset"] == 2 * index
        assert field["length"] == 2
        assert field["type"] == "int16"
        assert field["endianness"] == "little"
        assert field["scale"] == 0.001
