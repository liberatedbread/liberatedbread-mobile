# Copyright 2026 Pigs Can Fly Labs LLC
# SPDX-License-Identifier: Apache-2.0
"""Proves the AM43 blind-motor spec's frames follow its own stated rule.

`device-specs/devices/am43-blind-motor.yaml` says a request is
`00 ff 00 00 9a cmd len data chk`, with `chk` the XOR of every byte from
`9a` on, and that a reply's bytes XOR to zero. This module transcribes that
rule with nothing but the standard library and holds every fixed frame,
every template and every published reply example to it — the same contract
`test_wemo_spec.py` keeps for the Wemo crypto.

Six of the frames are also pinned to their literal spelling in am43-ctrl
(the open-source client they were checked against) -- four fixed frames and
the two position frames its "open" and "close" send -- so a spec that
drifts from the wire fails here rather than at a window.
"""

from __future__ import annotations

from functools import reduce
from pathlib import Path

import pytest
import yaml

REPO_ROOT = Path(__file__).resolve().parent.parent
SPEC_PATH = REPO_ROOT / "device-specs" / "devices" / "am43-blind-motor.yaml"
CHAR_UUID = "0000fe51-0000-1000-8000-00805f9b34fb"
PREFIX = [0x00, 0xFF, 0x00, 0x00]

# Frames as they appear literally in binsentsu/am43-ctrl (src/am43.js).
PUBLISHED = {
    "stop": "00ff00009a0a01cc5d",
    "get_battery": "00ff00009aa2010138",
    "get_light": "00ff00009aaa010130",
    "get_status": "00ff00009aa701013d",
}
# am43-ctrl's "open" and "close" are set_position 0 and 100, not 0x0a dd/ee.
PUBLISHED_POSITIONS = {0: "00ff00009a0d010096", 100: "00ff00009a0d0164f2"}


def xor(data: list[int]) -> int:
    return reduce(lambda a, b: a ^ b, data, 0)


def request(cmd: int, data: list[int]) -> list[int]:
    body = [0x9A, cmd, len(data), *data]
    return PREFIX + body + [xor(body)]


@pytest.fixture(scope="module")
def commands() -> dict:
    spec = yaml.safe_load(SPEC_PATH.read_text())
    for service in spec["services"]:
        for char in service["characteristics"]:
            if char["uuid"] == CHAR_UUID:
                return char["commands"]
    raise AssertionError("0xfe51 characteristic not found")


def test_every_fixed_frame_carries_a_valid_checksum(commands):
    for name, command in commands.items():
        if "value" not in command:
            continue
        frame = command["value"]
        assert frame[:4] == PREFIX, name
        assert frame[4] == 0x9A, name
        assert frame[6] == len(frame) - 8, f"{name}: length byte disagrees with the frame"
        assert request(frame[5], frame[7:-1]) == frame, f"{name}: checksum is wrong"


def test_published_frames_match_the_spec(commands):
    for name, wire in PUBLISHED.items():
        assert bytes(commands[name]["value"]).hex() == wire, name


def render(template: list, params: dict, checksum_start: int) -> list[int]:
    out = []
    for item in template:
        if isinstance(item, int):
            out.append(item)
        elif item == "{checksum}":
            out.append(xor(out[checksum_start:]))
        else:
            out.append(params[item.strip("{}")])
    return out


def test_templates_render_to_the_documented_examples(commands):
    position = commands["set_position"]
    start = position["parameters"]["checksum"]["checksum_start"]
    assert render(position["template"], {"position": 50}, start) == request(0x0D, [50])
    assert bytes(render(position["template"], {"position": 50}, start)).hex() == "00ff00009a0d0132a4"
    for pos, wire in PUBLISHED_POSITIONS.items():
        assert bytes(render(position["template"], {"position": pos}, start)).hex() == wire

    login = commands["login"]
    start = login["parameters"]["checksum"]["checksum_start"]
    frame = render(login["template"], {"pin_high": 8888 >> 8, "pin_low": 8888 & 0xFF}, start)
    assert bytes(frame).hex() == "00ff00009a170222b815"


def test_reply_examples_xor_to_zero():
    spec = yaml.safe_load(SPEC_PATH.read_text())
    examples = {n: f["example"] for n, f in spec["payload_formats"].items() if "example" in f}
    assert examples, "no reply examples to check"
    for name, example in examples.items():
        frame = bytes.fromhex(example)
        assert frame[0] == 0x9A, name
        assert frame[2] == len(frame) - 4, f"{name}: length byte disagrees"
        assert xor(list(frame)) == 0, f"{name}: reply checksum is wrong"


def test_status_example_decodes_as_documented():
    spec = yaml.safe_load(SPEC_PATH.read_text())
    frame = bytes.fromhex(spec["payload_formats"]["StatusReply"]["example"])
    assert frame[1] == 0xA7
    assert frame[3] & 0x0C == 0x0C  # both travel limits set
    assert frame[4] == 50  # rpm
    assert frame[5] == 78  # percent closed
