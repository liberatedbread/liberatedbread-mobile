# Copyright 2026 Pigs Can Fly Labs LLC
# SPDX-License-Identifier: Apache-2.0
"""Holds the Bose Sleepbuds II spec's frames to its own stated layouts.

`device-specs/devices/bose-sleepbuds-ii.yaml` has no checksum anywhere on
its control surface; what it has instead are three encodings a client must
get byte-exact — the 12-byte little-endian playback frame, the Sounds list
(4-byte header, uint16 LE ids, 0xffa0 terminator) and the synchronised-start
frame whose timing bytes are the bud's clock plus an offset with carry. This
module transcribes those rules with the standard library alone, renders the
spec's templates with the worked values its descriptions quote, and checks
the result against the spec's own examples and against the two frames the
community client (chillee151/SleepBuds2Revival) logged as accepted on
hardware.
"""

from __future__ import annotations

import struct
from pathlib import Path

import pytest
import yaml

REPO_ROOT = Path(__file__).resolve().parent.parent
SPEC_PATH = REPO_ROOT / "device-specs" / "devices" / "bose-sleepbuds-ii.yaml"
AUDIO_UUID = "1cbd5f8f-6c18-4309-9354-703e7d42a74e"
CONTROL_UUID = "e81359e0-9f35-483a-a46f-7c6d686daa06"
SETTINGS_UUID = "5e500c28-33db-4d0a-afc8-c9b6df4269bf"

# Frames the community client logged as accepted by a Sleepbuds II bud
# (firmware 11.9.0): the play frame from its test log, the stop frame it
# sends. Facts about the wire, restated here as bytes.
PUBLISHED = {
    "play_warm_static_50": "01324f7b0000000000000000",
    "stop": "0000a0ff0000000000000000",
}

WIDTH = {"uint8": "B", "int8": "b", "uint16": "H", "int16": "h", "uint32": "I", "int32": "i"}


@pytest.fixture(scope="module")
def spec() -> dict:
    return yaml.safe_load(SPEC_PATH.read_text())


def commands_of(spec: dict, uuid: str) -> dict:
    for service in spec["services"]:
        for char in service.get("characteristics") or []:
            if char["uuid"] == uuid:
                return char["commands"]
    raise AssertionError(f"characteristic {uuid} not found")


def render(command: dict, values: dict) -> bytes:
    """Render a template exactly as the spec declares it: each placeholder is
    one parameter, emitted at the parameter's declared width, little-endian
    unless it says otherwise, with `default` filling anything the caller left
    out."""
    out = bytearray()
    params = command["parameters"]
    for item in command["template"]:
        if isinstance(item, int):
            out.append(item)
            continue
        name = item.strip("{}")
        param = params[name]
        value = values.get(name, param.get("default"))
        assert value is not None, f"no value for {name}"
        order = "<" if param.get("endianness", "little") == "little" else ">"
        out += struct.pack(order + WIDTH[param["type"]], value)
    return bytes(out)


def test_play_sound_renders_the_logged_frame(spec):
    cmd = commands_of(spec, AUDIO_UUID)["play_sound"]
    frame = render(cmd, {"volume": 50, "file_id": 31567})
    assert len(frame) == 12
    assert frame.hex() == PUBLISHED["play_warm_static_50"]


def test_stop_is_the_logged_frame(spec):
    cmd = commands_of(spec, AUDIO_UUID)["stop"]
    assert bytes(cmd["value"]).hex() == PUBLISHED["stop"]
    assert len(cmd["value"]) == 12
    assert struct.unpack_from("<H", bytes(cmd["value"]), 2)[0] == 0xFFA0


def test_timed_play_sets_timeout_and_remaining_alike(spec):
    cmd = commands_of(spec, AUDIO_UUID)["play_sound_timed"]
    frame = render(cmd, {"volume": 30, "file_id": 13198, "duration": 1800})
    assert len(frame) == 12
    state, volume, file_id, timeout, remaining, fade_in, fade_out = struct.unpack("<BBHHHHH", frame)
    assert (state, volume, file_id) == (1, 30, 13198)
    assert timeout == remaining == 1800
    assert fade_in == fade_out == 0


def test_set_volume_only_differs_from_play_in_byte_one(spec):
    cmds = commands_of(spec, AUDIO_UUID)
    play = render(cmds["play_sound"], {"volume": 50, "file_id": 31567})
    quieter = render(cmds["set_volume"], {"volume": 20, "file_id": 31567})
    assert quieter[1] == 20
    assert quieter[:1] + play[1:2] + quieter[2:] == play


def test_audio_format_decodes_the_example(spec):
    fmt = next(
        c for s in spec["services"] for c in s.get("characteristics") or []
        if c["uuid"] == AUDIO_UUID
    )["format"]
    frame = bytes.fromhex(spec["payload_formats"]["AudioFrame"]["example"])
    decoded = {}
    for field in fmt:
        raw = int.from_bytes(frame[field["offset"]: field["offset"] + field["length"]], "little")
        if "mask" in field:
            mask = field["mask"]
            raw = (raw & mask) >> ((mask & -mask).bit_length() - 1)
        decoded[field["name"]] = raw
    assert decoded["playing"] == 1
    assert decoded["volume"] == 50
    assert decoded["file_id"] == 31567
    assert fmt[2]["values"][31567] == "Warm Static"
    assert decoded["masking_timeout"] == decoded["time_remaining"] == 0


def parse_sounds(value: bytes) -> list[int]:
    ids = []
    for offset in range(4, len(value) - 1, 2):
        (file_id,) = struct.unpack_from("<H", value, offset)
        if file_id == 0xFFA0:
            break
        ids.append(file_id)
    return ids


def test_sounds_example_parses_to_file_ids(spec):
    example = bytes.fromhex(spec["payload_formats"]["SoundsList"]["example"])
    assert example[:4] == bytes.fromhex("01000200")
    assert example[-2:] == bytes.fromhex("a0ff"), "0xffa0 terminator, little-endian on the wire"
    assert parse_sounds(example) == [31567, 13198]


def test_generation_catalogues_do_not_overlap(spec):
    audio_fields = next(
        c for s in spec["services"] for c in s.get("characteristics") or []
        if c["uuid"] == AUDIO_UUID
    )["format"]
    kingsley = {k for k in audio_fields[2]["values"] if k != 65440}
    drowsy = set(spec["protocol_details"]["sound_catalogue_first_generation"]["file_ids"])
    assert kingsley and drowsy
    assert not (kingsley & drowsy), "a file id must identify exactly one generation"


def parse_clock(value: bytes) -> tuple[int, int, int, int, int]:
    record_type, hours, minutes, seconds, ms, us = struct.unpack("<BBBBHH", value)
    assert record_type == 0
    return hours, minutes, seconds, ms, us


def test_sync_example_decodes_as_documented(spec):
    example = bytes.fromhex(spec["payload_formats"]["SyncClock"]["example"])
    assert parse_clock(example) == (13, 1, 0, 357, 0)


def offset_clock(minutes: int, seconds: int, ms: int, add_ms: int = 750) -> tuple[int, int, int]:
    """The spec's timing rule: add the offset, carry ms -> s -> min."""
    ms += add_ms
    seconds += ms // 1000
    ms %= 1000
    minutes += seconds // 60
    seconds %= 60
    minutes %= 60
    return minutes, seconds, ms


def test_play_in_future_renders_the_worked_example(spec):
    cmd = commands_of(spec, CONTROL_UUID)["play_in_future"]
    _, minutes, seconds, ms, us = parse_clock(
        bytes.fromhex(spec["payload_formats"]["SyncClock"]["example"])
    )
    minutes, seconds, ms = offset_clock(minutes, seconds, ms)
    assert (minutes, seconds, ms) == (1, 1, 107)
    frame = render(cmd, {
        "minutes": minutes, "seconds": seconds, "milliseconds": ms, "microseconds": us,
        "file_id": 31567, "volume": 50,
    })
    assert len(frame) == 18
    assert frame[:2] == bytes([0x01, 0xBB])
    assert frame[8] == 0, "zero pad before the file id"
    assert frame.hex() == spec["payload_formats"]["PlayInFuture"]["example"]


def test_timing_carry_rolls_over_seconds_and_minutes():
    assert offset_clock(59, 59, 300) == (0, 0, 50)
    assert offset_clock(10, 59, 250) == (11, 0, 0)


def test_control_point_fixed_frames_are_opcode_then_submodule(spec):
    cmds = commands_of(spec, CONTROL_UUID)
    for name, cmd in cmds.items():
        if "value" in cmd:
            assert len(cmd["value"]) == 2, name
    assert cmds["cancel_play_in_future"]["value"] == [0x02, 0xBB]
    assert cmds["alarm_cancel"]["value"] == [0x02, 0x02]
    response = bytes.fromhex(spec["payload_formats"]["ControlPointResponse"]["example"])
    assert response == bytes([0x03, 0x01, 0xBB])


def test_connection_parameter_request_matches_the_client_defaults(spec):
    cmd = commands_of(spec, CONTROL_UUID)["request_connection_parameters"]
    frame = render(cmd, {})
    assert frame.hex() == "d000" + struct.pack("<HHHH", 16, 16, 0, 200).hex()


def test_phone_free_frames_toggle_bit_zero_only(spec):
    cmds = commands_of(spec, SETTINGS_UUID)
    on, off = bytes(cmds["phone_free_on"]["value"]), bytes(cmds["phone_free_off"]["value"])
    assert len(on) == len(off) == 4
    assert on[0] & 0x01 and not off[0] & 0x01
    assert on[1:] == off[1:] == b"\x00\x00\x00"
