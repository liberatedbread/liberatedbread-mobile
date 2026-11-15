# Copyright 2026 Pigs Can Fly Labs LLC
# SPDX-License-Identifier: Apache-2.0
"""Proves the Furby Connect spec's frames follow its own stated layouts.

`device-specs/devices/hasbro-furby-connect.yaml` says every command is one
opcode-first write of at most 20 bytes, gives the byte layout of each, and
gives the rule that builds the 129-entry name table. This module transcribes
those layouts with the standard library only, rebuilds every worked example
in `protocol_details.test_vectors`, checks the spec's own templates render
to the same bytes, and decodes the example notifications through the code
tables the spec declares.

The frames PyFluff's own unit tests pin (tests/test_protocol.py) are held
here too, so a spec that drifts from what the open clients send fails here.
"""

from __future__ import annotations

import re
from pathlib import Path

import pytest
import yaml

REPO_ROOT = Path(__file__).resolve().parent.parent
SPEC_PATH = REPO_ROOT / "device-specs" / "devices" / "hasbro-furby-connect.yaml"

SERVICE = "dab91435-b5a1-e29c-b041-bcd562613bde"
GP_WRITE = "dab91383-b5a1-e29c-b041-bcd562613bde"
GP_LISTEN = "dab91382-b5a1-e29c-b041-bcd562613bde"
NORDIC_WRITE = "dab90757-b5a1-e29c-b041-bcd562613bde"
NORDIC_LISTEN = "dab90756-b5a1-e29c-b041-bcd562613bde"
FILE_WRITE = "dab90758-b5a1-e29c-b041-bcd562613bde"
DFU_SERVICE = "00001530-1212-efde-1523-785feabcd123"
DFU_CONTROL = "00001531-1212-efde-1523-785feabcd123"

MAX_WRITE = 20

# Frames asserted by PyFluff tests/test_protocol.py.
PYFLUFF_PINNED = {
    "antenna_255_128_0": bytes([0x14, 255, 128, 0]),
    "action_55_2_14_0": bytes([0x13, 0x00, 55, 2, 14, 0]),
    "lcd_on": bytes([0xCD, 0x01]),
    "lcd_off": bytes([0xCD, 0x00]),
    "debug": bytes([0xDB]),
    "name_42": bytes([0x21, 42]),
    "mood_set_fullness_75": bytes([0x23, 1, 0x03, 75]),
}


# ── Transcription of the spec's layouts ──────────────────────────────────────


def antenna(red: int, green: int, blue: int) -> bytes:
    return bytes([0x14, red, green, blue])


def action(input_: int, index: int, subindex: int, specific: int) -> bytes:
    return bytes([0x13, 0x00, input_, index, subindex, specific])


def set_name(name_id: int) -> bytes:
    return bytes([0x21, name_id])


def say_name(name_id: int) -> bytes:
    return action(0x21, 0, 0, name_id)


def set_mood(mode: int, mood_type: int, value: int) -> bytes:
    return bytes([0x23, mode, mood_type, value])


def packet_ack(enabled: int) -> bytes:
    return bytes([0x09, enabled, 0x00])


def announce_dlc(size: int, slot: int, filename: str) -> bytes:
    name = filename.encode("ascii")
    assert len(name) <= 12
    return (
        bytes([0x50, 0x00])
        + size.to_bytes(3, "big")
        + bytes([slot])
        + name.ljust(12, b"\x00")
        + b"\x00\x00"
    )


def name_table(names: dict) -> list[str]:
    return [
        f"{a}-{b}"
        for a in names["first_syllables"]
        for b in names["second_syllables"]
        if f"{a}-{b}" != "Tay-Tah"
    ]


def hexbytes(text: str) -> bytes:
    return bytes.fromhex(text.replace(" ", ""))


# ── Spec access and a minimal template renderer ──────────────────────────────


@pytest.fixture(scope="module")
def spec() -> dict:
    return yaml.safe_load(SPEC_PATH.read_text())


def characteristic(spec: dict, uuid: str) -> dict:
    for service in spec["services"]:
        for char in service.get("characteristics") or []:
            if char["uuid"] == uuid:
                return char
    raise KeyError(uuid)


def command(spec: dict, name: str) -> dict:
    for service in spec["services"]:
        for char in service.get("characteristics") or []:
            if name in (char.get("commands") or {}):
                return char["commands"][name]
    raise KeyError(name)


WIDTHS = {"uint8": 1, "uint16": 2, "uint24": 3, "uint32": 4}
PLACEHOLDER = re.compile(r"^\{(\w+)\}$")


def render(cmd: dict, **args) -> bytes:
    if "value" in cmd:
        assert not args
        return bytes(cmd["value"])
    out = bytearray()
    params = cmd.get("parameters") or {}
    for element in cmd["template"]:
        if isinstance(element, int):
            out.append(element)
            continue
        name = PLACEHOLDER.match(element).group(1)
        definition = params[name]
        value = args[name]
        if definition["type"] == "bytes":
            assert definition["min_length"] <= len(value) <= definition["max_length"]
            out += value
            continue
        assert definition.get("min", 0) <= value <= definition.get("max", 2**32), name
        width = WIDTHS[definition["type"]]
        order = definition.get("endianness", "big") if width > 1 else "big"
        out += value.to_bytes(width, order)
    if "fixed_length" in cmd:
        assert len(out) == cmd["fixed_length"]
    return bytes(out)


# ── Tests ────────────────────────────────────────────────────────────────────


def test_uuids_are_where_the_spec_says(spec):
    services = {s["uuid"]: s for s in spec["services"]}
    assert SERVICE in services and DFU_SERVICE in services
    fluff = {c["uuid"] for c in services[SERVICE]["characteristics"]}
    for uuid in (GP_WRITE, GP_LISTEN, NORDIC_WRITE, NORDIC_LISTEN, FILE_WRITE):
        assert uuid in fluff
        assert uuid.endswith("-b5a1-e29c-b041-bcd562613bde")
    assert characteristic(spec, FILE_WRITE)["role"] == "bulk"


def test_pyfluff_pinned_frames_match_the_transcription():
    assert antenna(255, 128, 0) == PYFLUFF_PINNED["antenna_255_128_0"]
    assert action(55, 2, 14, 0) == PYFLUFF_PINNED["action_55_2_14_0"]
    assert set_name(42) == PYFLUFF_PINNED["name_42"]
    assert set_mood(1, 3, 75) == PYFLUFF_PINNED["mood_set_fullness_75"]


def test_test_vectors_rebuild_from_the_layouts(spec):
    vectors = spec["protocol_details"]["test_vectors"]
    assert hexbytes(vectors["antenna_255_128_0"]) == antenna(255, 128, 0)
    assert hexbytes(vectors["giggle"]) == action(55, 2, 14, 0)
    assert hexbytes(vectors["set_name_42"]) == set_name(42)
    assert hexbytes(vectors["say_name_42"]) == say_name(42)
    assert hexbytes(vectors["set_fullness_75"]) == set_mood(1, 3, 75)
    assert hexbytes(vectors["lcd_on"]) == PYFLUFF_PINNED["lcd_on"]
    assert hexbytes(vectors["lcd_off"]) == PYFLUFF_PINNED["lcd_off"]
    assert hexbytes(vectors["packet_ack_on"]) == packet_ack(1)
    dlc = vectors["announce_dlc"]
    built = announce_dlc(dlc["size"], dlc["slot"], dlc["filename"])
    assert hexbytes(dlc["hex"]) == built
    assert len(built) == MAX_WRITE


def test_templates_render_to_the_test_vectors(spec):
    vectors = spec["protocol_details"]["test_vectors"]
    assert render(command(spec, "set_antenna_color"), red=255, green=128, blue=0) == hexbytes(
        vectors["antenna_255_128_0"]
    )
    assert render(command(spec, "giggle")) == hexbytes(vectors["giggle"])
    assert render(
        command(spec, "trigger_action"), input=55, index=2, subindex=14, specific=0
    ) == hexbytes(vectors["giggle"])
    assert render(command(spec, "set_name"), name_id=42) == hexbytes(vectors["set_name_42"])
    assert render(command(spec, "say_name"), name_id=42) == hexbytes(vectors["say_name_42"])
    assert render(command(spec, "set_mood"), mode=1, mood_type=3, value=75) == hexbytes(
        vectors["set_fullness_75"]
    )
    assert render(command(spec, "lcd_backlight_on")) == hexbytes(vectors["lcd_on"])
    assert render(command(spec, "lcd_backlight_off")) == hexbytes(vectors["lcd_off"])
    assert render(command(spec, "cycle_debug_screen")) == PYFLUFF_PINNED["debug"]
    assert render(command(spec, "set_packet_ack"), enabled=1) == hexbytes(vectors["packet_ack_on"])
    dlc = vectors["announce_dlc"]
    filename = dlc["filename"].encode("ascii").ljust(12, b"\x00")
    assert render(
        command(spec, "announce_dlc_upload"), size=dlc["size"], slot=dlc["slot"], filename=filename
    ) == hexbytes(dlc["hex"])


def test_partial_action_opcodes_share_the_layout(spec):
    assert render(command(spec, "trigger_action_by_input"), input=7) == bytes([0x10, 0, 7])
    assert render(command(spec, "trigger_action_by_index"), input=7, index=1) == bytes(
        [0x11, 0, 7, 1]
    )
    assert render(
        command(spec, "trigger_action_by_subindex"), input=7, index=1, subindex=2
    ) == bytes([0x12, 0, 7, 1, 2])


def test_every_fixed_command_fits_one_write(spec):
    for service in spec["services"]:
        for char in service.get("characteristics") or []:
            for name, cmd in (char.get("commands") or {}).items():
                if "value" in cmd:
                    assert 1 <= len(cmd["value"]) <= MAX_WRITE, name


def test_upload_delete_and_dfu_commands_are_advanced(spec):
    for name in ("announce_dlc_upload", "delete_dlc_slot", "enter_dfu_bootloader"):
        cmd = command(spec, name)
        assert cmd.get("advanced") is True and cmd.get("advanced_reason"), name
    assert characteristic(spec, DFU_CONTROL)["commands"]["enter_dfu_bootloader"]["value"] == [1, 4]
    dfu = next(f["dfu"] for f in spec["features"] if f["type"] == "firmware_update")
    assert dfu["enter"]["command"] == "enter_dfu_bootloader"
    assert dfu["services"] == [DFU_SERVICE]


def test_name_table_rule(spec):
    names = spec["protocol_details"]["names"]
    table = name_table(names)
    assert len(table) == names["count"] == 129
    assert len(names["first_syllables"]) == 13 and len(names["second_syllables"]) == 10
    assert table[0] == "Ah-Bay"
    assert table[47] == "Dee-Koh"
    assert table[107] == "Tay-Koh"
    assert table[108] == "Tay-Toh"
    assert table[128] == "Way-Toh"
    assert "Tay-Tah" not in table
    assert command(spec, "set_name")["parameters"]["name_id"]["max"] == len(table) - 1


def test_example_notifications_decode(spec):
    gp = {f["name"]: f for f in characteristic(spec, GP_LISTEN)["format"]}
    opcodes = gp["gp_response"]["values"]
    formats = spec["payload_formats"]

    sequence_ended = hexbytes(formats["FurbyMessage"]["example"])
    assert sequence_ended[0] in opcodes and opcodes[sequence_ended[0]].startswith("FurbyMessage")
    assert formats["FurbyMessage"]["values"][sequence_ended[1]] == "sequence ended"

    ready = hexbytes(formats["FileTransferMode"]["example"])
    assert opcodes[ready[0]].startswith("FileTransferMode")
    assert formats["FileTransferMode"]["values"][ready[1]] == "ready to receive"

    firmware = hexbytes(formats["GplFirmwareVersion"]["example"])
    assert opcodes[firmware[0]].startswith("GPLFirmwareVersion") and firmware[1] == 4

    ack = hexbytes(formats["NordicReply"]["example"])
    nordic = characteristic(spec, NORDIC_LISTEN)["format"][0]["values"]
    assert nordic[ack[0]].startswith("GotPacketAck") and ack[1] == 2

    # The LCD backlight replies the spec names are FurbyMessage codes 17/18.
    assert formats["FurbyMessage"]["values"][0x17] == "LCD eyes on"
    assert formats["FurbyMessage"]["values"][0x18] == "LCD eyes off"


def test_sensor_report_is_recognised_but_left_opaque(spec):
    opcodes = characteristic(spec, GP_LISTEN)["format"][0]["values"]
    assert "undecoded" in opcodes[0x21]
    # An invented, all-zero report: classify by opcode and length only.
    report = bytes([0x21]) + bytes(7)
    assert report[0] == 0x21 and len(report) == 8


def test_dlc_upload_chunking_covers_the_file_exactly():
    data = bytes(range(256)) * 3 + b"\x01\x02\x03"  # invented payload
    chunks = [data[i : i + MAX_WRITE] for i in range(0, len(data), MAX_WRITE)]
    assert b"".join(chunks) == data
    assert all(len(c) == MAX_WRITE for c in chunks[:-1]) and 0 < len(chunks[-1]) <= MAX_WRITE
    header = announce_dlc(len(data), 2, "CUSTOM01.DLC")
    assert int.from_bytes(header[2:5], "big") == len(data)
