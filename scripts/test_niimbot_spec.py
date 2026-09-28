"""Proves the NIIMBOT D110 print task can be built from the spec alone.

`device-specs/devices/niimbot-d110.yaml` claims its commands block plus
`protocol_details.niimbot_print_task` are enough to print a label. Everything
below is a transcription of what the YAML says, with nothing but the standard
library and PyYAML: the packet envelope, the XOR checksum, the control
packets, and the row encoding. If a transcription cannot reproduce the spec's
own fixed values and its documented example row, the spec is underspecified
and this fails.
"""

from __future__ import annotations

from functools import reduce
from pathlib import Path

import pytest
import yaml

SPEC = Path(__file__).resolve().parent.parent / "device-specs/devices/niimbot-d110.yaml"


@pytest.fixture(scope="module")
def spec() -> dict:
    return yaml.safe_load(SPEC.read_text())


@pytest.fixture(scope="module")
def commands(spec: dict) -> dict:
    # services[0].characteristics[0].commands
    return spec["services"][0]["characteristics"][0]["commands"]


def xor(data: list[int]) -> int:
    return reduce(lambda a, b: a ^ b, data, 0)


def envelope(cmd: int, data: list[int]) -> list[int]:
    """services[0].notes: 55 55 <cmd> <len> <data...> <xor> AA AA, the xor
    over cmd through the last data byte."""
    body = [cmd, len(data), *data]
    return [0x55, 0x55, *body, xor(body), 0xAA, 0xAA]


def render(command: dict, **values: int) -> list[int]:
    """Fill a command template the way a generic encoder does: literal bytes
    pass through, a named parameter becomes its declared width (big-endian
    where the spec says so), and an `auto: xor_checksum` parameter is the XOR
    of the bytes emitted from `checksum_start` on."""
    out: list[int] = []
    for item in command["template"]:
        if isinstance(item, int):
            out.append(item)
            continue
        name = item.strip("{}")
        param = command["parameters"][name]
        if param.get("auto") == "xor_checksum":
            out.append(xor(out[param.get("checksum_start", 1) :]))
            continue
        value = values.get(name, param.get("default"))
        assert value is not None, f"{name} has no value and no default"
        width = {"uint8": 1, "uint16": 2}[param["type"]]
        raw = value.to_bytes(width, "big" if param.get("endianness") == "big" else "little")
        out.extend(raw)
    return out


def test_every_fixed_packet_carries_its_own_checksum(commands: dict) -> None:
    for name, command in commands.items():
        if "value" not in command:
            continue
        packet = command["value"]
        if name == "connect":
            assert packet[0] == 0x03, "connect alone carries the 0x03 prefix"
            packet = packet[1:]
        assert packet[:2] == [0x55, 0x55] and packet[-2:] == [0xAA, 0xAA], name
        cmd, length, *rest = packet[2:-2]
        data, checksum = rest[:-1], rest[-1]
        assert length == len(data), name
        assert packet == envelope(cmd, data), name
        assert checksum == xor([cmd, length, *data]), name


def test_templates_render_to_the_envelope(commands: dict) -> None:
    assert render(commands["set_density"], density=3) == envelope(0x21, [3])
    assert render(commands["set_label_type"]) == envelope(0x23, [1])
    # A 30 mm label on the 96-dot head: 240 rows by 96 columns.
    assert render(commands["set_page_size"], rows=240, cols=96) == envelope(
        0x13, [0x00, 0xF0, 0x00, 0x60]
    )
    assert render(commands["set_print_quantity"], quantity=2) == envelope(0x15, [0x00, 0x02])
    assert render(commands["heartbeat"], type=4) == envelope(0xDC, [4])


def test_the_d110_print_start_is_the_one_byte_variant(commands: dict) -> None:
    assert commands["print_start"]["value"] == [0x55, 0x55, 0x01, 0x01, 0x01, 0x01, 0xAA, 0xAA]


def test_the_sequence_names_only_declared_commands(spec: dict, commands: dict) -> None:
    task = spec["protocol_details"]["niimbot_print_task"]
    named = [step for step in task["sequence"] if not step.startswith("rows")]
    for step in named:
        assert step.split(" ")[0] in commands, step


def test_the_feature_choices_match_their_commands(spec: dict, commands: dict) -> None:
    upload = next(f for f in spec["features"] if f["type"] == "image_upload")
    for key, command in (("print_density", "set_density"), ("paper_type", "set_label_type")):
        choice = upload[key]
        assert choice["command"] == command
        param = next(p for p in commands[command]["parameters"].values() if "auto" not in p)
        # A contiguous set is a min..max range on the command, a gapped one a list.
        offered = param.get("allowed") or list(range(param["min"], param["max"] + 1))
        assert offered == choice["allowed"], key
        assert param["default"] == choice["default"], key


def split_counts(row: bytes, head_dots: int) -> list[int]:
    """protocol_details.niimbot_print_task.black_dot_counts, split mode."""
    chunk = head_dots // 8 // 3
    assert len(row) <= chunk * 3, "the D110's rows always fit split mode"
    counts = [0, 0, 0]
    for i, byte in enumerate(row):
        counts[i // chunk] += bin(byte).count("1")
    return counts


def row_packet(index: int, row: bytes, repeat: int, head_dots: int) -> list[int]:
    """protocol_details.niimbot_print_task.rows: pick the packet by the row's
    black dots, the dot MSB-first from byte 0."""
    pos = [index >> 8, index & 0xFF]
    dots = [i * 8 + bit for i, b in enumerate(row) for bit in range(8) if b & (0x80 >> bit)]
    if not dots:
        return envelope(0x84, [*pos, repeat])
    counts = split_counts(row, head_dots)
    if len(dots) <= 6:
        indexes = [b for d in dots for b in (d >> 8, d & 0xFF)]
        return envelope(0x83, [*pos, *counts, repeat, *indexes])
    return envelope(0x85, [*pos, *counts, repeat, *row])


def test_the_documented_indexed_row_is_reproduced(spec: dict) -> None:
    head = next(f for f in spec["features"] if f["type"] == "image_upload")["print_geometry"][
        "head_dots"
    ]
    # Black dots 39-42 on row 126: dot 39 is the LSB of byte 4, dots 40-42
    # the top three bits of byte 5 (MSB of byte 0 is dot 0).
    row = bytearray(head // 8)
    for dot in (39, 40, 41, 42):
        row[dot // 8] |= 0x80 >> (dot % 8)
    example = spec["protocol_details"]["niimbot_print_task"]["example"]
    expected = [int(b, 16) for b in example.split("—")[0].split(":")[1].split()]
    assert row_packet(126, bytes(row), 1, head) == expected


def test_row_packet_shapes(spec: dict) -> None:
    head = 96
    blank = bytes(12)
    assert row_packet(0, blank, 5, head) == envelope(0x84, [0, 0, 5])
    full = bytes([0xFF] * 12)
    packet = row_packet(1, full, 1, head)
    assert packet[2] == 0x85 and packet[3] == 18
    assert packet[6:9] == [32, 32, 32]
