# Copyright 2026 Pigs Can Fly Labs LLC
# SPDX-License-Identifier: Apache-2.0
"""Holds the Instant Pot Smart spec's frames to its own checksum rule.

`device-specs/devices/instant-pot-smart-bluetooth.yaml` says every frame is
20 bytes and its last byte makes the whole frame sum to 0 mod 256. This
transcribes that rule with the standard library alone and checks the fixed
frames, the templates rendered with the spec's own worked examples, and the
clock encoding the spec spells out.
"""

from __future__ import annotations

import struct
from datetime import datetime
from pathlib import Path

import pytest
import yaml

SPEC_PATH = (
    Path(__file__).resolve().parent.parent
    / "device-specs" / "devices" / "instant-pot-smart-bluetooth.yaml"
)
COMMAND_UUID = "0000dab1-0000-1000-8000-00805f9b34fb"


def check(body: list[int]) -> int:
    return (-sum(body)) & 0xFF


@pytest.fixture(scope="module")
def commands() -> dict:
    spec = yaml.safe_load(SPEC_PATH.read_text())
    for service in spec["services"]:
        for char in service["characteristics"]:
            if char["uuid"] == COMMAND_UUID:
                return char["commands"]
    raise AssertionError("command characteristic not found")


def render(template: list, params: dict) -> list[int]:
    out = []
    for item in template:
        if isinstance(item, int):
            out.append(item)
        elif item == "{check}":
            out.append(check(out))
        else:
            out.append(params[item.strip("{}")])
    return out


def test_fixed_frames_sum_to_zero(commands):
    for name, command in commands.items():
        if "value" in command:
            frame = command["value"]
            assert len(frame) == 20, name
            assert frame[:4] == [0xAA, 0x55, 0x5A, 0x01], name
            assert sum(frame) % 256 == 0, name


def test_templates_render_the_worked_examples(commands):
    manual = render(commands["pressure_cook"]["template"], {"pressure": 0x30, "hours": 0, "minutes": 30})
    assert bytes(manual).hex() == "aa555a010c20300000001e00000000000000002c"
    soup = render(
        commands["start_program"]["template"],
        {"program": 0x0A, "mode": 0x70, "hours": 0, "minutes": 30},
    )
    assert bytes(soup).hex() == "aa555a010a20700000001e0000000000000000ee"


def test_clock_example_is_little_endian_seconds_since_2001():
    seconds = int((datetime(2024, 10, 17, 12, 0, 0) - datetime(2001, 1, 1)).total_seconds())
    assert struct.pack("<I", seconds).hex() == "c033c12c"
    assert "c0 33 c1 2c" in SPEC_PATH.read_text()
