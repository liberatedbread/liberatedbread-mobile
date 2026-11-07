# Copyright 2026 Pigs Can Fly Labs LLC
# SPDX-License-Identifier: Apache-2.0
"""Proves the SolarEdge Modbus TCP spec's frames follow its own stated rule.

`device-specs/devices/solaredge-modbus-tcp.yaml` says every request is an
MBAP header (transaction id, protocol id 0, length of what follows, unit id)
then a Modbus PDU, all big-endian, and that SunSpec readings are
`raw x 10^SF`. This module transcribes that rule with the standard library
alone, rebuilds every example frame in the spec from it, renders each
command's `body` template, and decodes the example replies with their scale
factors, so a frame or reading that drifts from the rule fails here rather
than at an inverter.
"""

from __future__ import annotations

import re
import struct
from pathlib import Path

import pytest
import yaml

REPO_ROOT = Path(__file__).resolve().parent.parent
SPEC_PATH = REPO_ROOT / "device-specs" / "devices" / "solaredge-modbus-tcp.yaml"
UNIT = 1


def mbap(tid: int, unit: int, pdu: bytes) -> str:
    return (struct.pack(">HHHB", tid, 0, len(pdu) + 1, unit) + pdu).hex().upper()


def read(start: int, qty: int) -> bytes:
    return struct.pack(">BHH", 0x03, start, qty)


def write_single(address: int, value: int) -> bytes:
    return struct.pack(">BHH", 0x06, address, value & 0xFFFF)


def write_multiple(address: int, registers: list[int]) -> bytes:
    head = struct.pack(">BHHB", 0x10, address, len(registers), 2 * len(registers))
    return head + b"".join(struct.pack(">H", r) for r in registers)


def le_words_int32(value: int) -> list[int]:
    raw = value & 0xFFFFFFFF
    return [raw & 0xFFFF, raw >> 16]  # SolarEdge control block: low word first


def le_words_float32(value: float) -> list[int]:
    high, low = struct.unpack(">HH", struct.pack(">f", value))
    return [low, high]


def parse(frame: str) -> tuple[int, int, bytes]:
    """Check the MBAP header and return (transaction id, unit id, PDU)."""
    raw = bytes.fromhex(frame)
    tid, protocol, length, unit = struct.unpack(">HHHB", raw[:7])
    assert protocol == 0, "protocol id is always 0"
    assert length == len(raw) - 6, "length counts the unit id and PDU"
    return tid, unit, raw[7:]


def registers(pdu: bytes) -> list[int]:
    assert pdu[0] == 0x03
    assert pdu[1] == len(pdu) - 2, "byte count"
    return [int.from_bytes(pdu[i : i + 2], "big") for i in range(2, len(pdu), 2)]


def s16(word: int) -> int:
    return word - 0x10000 if word & 0x8000 else word


def scaled(raw: int, sf_word: int) -> float:
    sf = s16(sf_word)
    assert -10 <= sf <= 10, "SunSpec scale factors lie in -10..10"
    return raw * 10**sf


def text(words: list[int]) -> str:
    return b"".join(w.to_bytes(2, "big") for w in words).rstrip(b"\0").decode("ascii")


@pytest.fixture(scope="module")
def spec() -> dict:
    return yaml.safe_load(SPEC_PATH.read_text())


EXPECTED = {
    "read_common_block": (1, read(40000, 69)),
    "read_inverter_block": (2, read(40069, 40)),
    "read_meter_1_common": (3, read(40121, 67)),
    "read_meter_1_block": (4, read(40188, 107)),
    "read_meter_1_power": (6, read(40206, 5)),
    "set_active_power_limit": (0x10, write_single(0xF001, 50)),
    "commit_power_control": (0x11, write_single(0xF100, 1)),
    "enable_advanced_power_control": (0x12, write_multiple(0xF142, le_words_int32(1))),
    "set_reactive_power_rrcr": (0x13, write_multiple(0xF104, le_words_int32(4))),
    "set_export_site_limit": (0x14, write_multiple(0xE002, le_words_float32(5000.0))),
    "restore_power_control_defaults": (0x16, write_single(0xF101, 1)),
}


def test_every_command_has_a_rebuilt_example(spec):
    assert set(spec["commands"]) == set(EXPECTED)


@pytest.mark.parametrize("name", sorted(EXPECTED))
def test_example_frames_match_the_mbap_rule(spec, name):
    tid, pdu = EXPECTED[name]
    example = spec["commands"][name]["example_body"]
    assert example == mbap(tid, UNIT, pdu)
    parsed_tid, unit, parsed_pdu = parse(example)
    assert (parsed_tid, unit, parsed_pdu) == (tid, UNIT, pdu)


_FIELD = re.compile(r"\{([a-z_]+)\}")


def render(body: str, values: dict[str, str]) -> str:
    return _FIELD.sub(lambda m: values[m.group(1)], body)


@pytest.mark.parametrize("name", sorted(EXPECTED))
def test_body_templates_render_to_their_examples(spec, name):
    """Fill each `{placeholder}` from the example's own bytes; the template's
    literal bytes must then reproduce the example exactly."""
    command = spec["commands"][name]
    body = command["body"]
    assert set(_FIELD.findall(body)) <= set(command["parameters"])
    raw = bytes.fromhex(command["example_body"])
    values = {
        "transaction_id": raw[0:2].hex().upper(),
        "length": raw[4:6].hex().upper(),
        "unit_id": raw[6:7].hex().upper(),
    }
    pdu = raw[7:]
    value_hex = {
        "set_active_power_limit": pdu[3:5],
        "set_export_site_limit": pdu[6:10],
        "enable_advanced_power_control": pdu[6:10],
        "set_reactive_power_rrcr": pdu[6:10],
    }
    for param in set(_FIELD.findall(body)) - set(values):
        values[param] = value_hex[name].hex().upper()
    assert render(body, values) == command["example_body"]


def test_writes_are_advanced_and_reads_are_not(spec):
    for name, command in spec["commands"].items():
        is_write = bytes.fromhex(command["example_body"])[7] in (0x06, 0x10)
        assert bool(command.get("advanced")) == is_write, name
        if is_write:
            assert command["advanced_reason"].strip()


def test_common_block_reply_decodes(spec):
    example = spec["payload_formats"]["CommonBlockReply"]["example"]
    tid, unit, pdu = parse(example)
    assert (tid, unit) == (1, UNIT)
    regs = registers(pdu)
    assert len(regs) == 69
    assert regs[0] << 16 | regs[1] == 0x53756E53  # "SunS"
    assert text(regs[0:2]) == "SunS"
    assert regs[2:4] == [1, 65]
    assert text(regs[4:20]) == "SolarEdge"
    assert text(regs[20:36]) == "SE8K"
    assert regs[36:44] == [0] * 8  # C_Options not implemented
    assert text(regs[44:52]) == "0004.0020.0000"
    assert text(regs[52:68]) == "00000000-00"
    assert regs[68] == UNIT


def test_inverter_block_reply_decodes_with_scale_factors(spec):
    example = spec["payload_formats"]["InverterBlockReply"]["example"]
    tid, unit, pdu = parse(example)
    assert (tid, unit) == (2, UNIT)
    r = registers(pdu)
    assert len(r) == 40
    assert r[0] == 103 and r[1] == 50
    assert scaled(r[2], r[6]) == pytest.approx(12.50)
    assert [scaled(x, r[6]) for x in r[3:6]] == pytest.approx([4.17, 4.17, 4.16])
    assert [scaled(x, r[13]) for x in r[7:10]] == pytest.approx([400.2, 400.5, 399.8])
    assert [scaled(x, r[13]) for x in r[10:13]] == pytest.approx([231.0, 231.2, 230.9])
    assert scaled(s16(r[14]), r[15]) == 8650
    assert scaled(r[16], r[17]) == pytest.approx(50.01)
    assert scaled(s16(r[18]), r[19]) == 8700
    assert scaled(s16(r[20]), r[21]) == -150
    assert scaled(s16(r[22]), r[23]) == pytest.approx(99.50)
    energy = r[24] << 16 | r[25]  # SunSpec acc32: high word first
    assert scaled(energy, r[26]) == 12345678
    assert scaled(r[27], r[28]) == pytest.approx(11.75)
    assert scaled(r[29], r[30]) == pytest.approx(750.0)
    assert scaled(s16(r[31]), r[32]) == 8812
    assert r[33] == r[35] == r[36] == 0x8000  # unimplemented temperatures
    assert scaled(s16(r[34]), r[37]) == pytest.approx(45.12)
    assert r[38] == 4
    assert spec["payload_formats"]["InverterStatus"]["values"]["4"].startswith("Producing")


def test_inverter_block_field_offsets_match_the_register_map(spec):
    fields = {f["name"]: f["offset"] for f in spec["payload_formats"]["InverterBlockReply"]["fields"]}
    base = 40069
    assert base + fields["I_AC_Power"] == 40083
    assert base + fields["I_AC_Energy_WH"] == 40093
    assert base + fields["I_DC_Power"] == 40100
    assert base + fields["I_Temp_Sink"] == 40103
    assert base + fields["I_Temp_SF"] == 40106
    assert base + fields["I_Status"] == 40107


def test_meter_power_reply_decodes(spec):
    tid, unit, pdu = parse(spec["payload_formats"]["MeterPowerReply"]["example"])
    assert (tid, unit) == (6, UNIT)
    r = registers(pdu)
    assert scaled(s16(r[0]), r[4]) == pytest.approx(-1520.0)
    assert r[2] == r[3] == 0x8000


def test_exception_reply(spec):
    _, _, pdu = parse(spec["payload_formats"]["ExceptionReply"]["example"])
    assert pdu == bytes([0x83, 0x02])


def test_site_limit_float_is_low_word_first():
    assert le_words_float32(5000.0) == [0x4000, 0x459C]


def test_placeholder_addresses_only(spec):
    blob = SPEC_PATH.read_text()
    for address in re.findall(r"\b\d{1,3}(?:\.\d{1,3}){3}\b", blob):
        assert address.startswith("192.168.1.5"), address


def test_documented_defaults_are_pinned(spec):
    device = spec["device"]
    assert device["identification"]["default_port"] == 1502
    assert device["identification"]["mdns_service_type"] == "_solaredge-modbus._tcp.local."
    for command in spec["commands"].values():
        assert command["parameters"]["unit_id"]["default"] == 1
