# Copyright 2026 Pigs Can Fly Labs LLC
# SPDX-License-Identifier: Apache-2.0
"""Holds the QardioArm spec's measurement records to the SFLOAT rule it states.

`device-specs/devices/qardio-arm.yaml` says a 0x2a35 record is the Bluetooth
SIG Blood Pressure Measurement layout: a flags byte, three IEEE-11073 16-bit
SFLOATs (12-bit two's-complement mantissa, 4-bit two's-complement exponent,
five reserved mantissas that carry no value), then optional fields in flag
order. This module transcribes that rule with nothing but the standard
library — importing none of this repository's code — and checks that the
spec's own worked examples decode to the numbers the spec says they do, that
its flag masks and fixed offsets agree with the walk, and that the two
control-command byte pairs are what the spec's prose says.

The examples are constructed from the SIG layout rather than captured from a
cuff, so what this proves is that the spec is internally consistent and
implementable, not that a QardioArm emits exactly these bytes.
"""

from __future__ import annotations

import re
from pathlib import Path

import pytest
import yaml

REPO_ROOT = Path(__file__).resolve().parent.parent
SPEC_PATH = REPO_ROOT / "device-specs" / "devices" / "qardio-arm.yaml"
MEASUREMENT_UUID = "00002a35-0000-1000-8000-00805f9b34fb"
CONTROL_UUID = "583cb5b3-875d-40ed-9098-c39eb0c1983d"
KPA_TO_MMHG = 7.500617

SPECIAL_MANTISSAS = {0x07FF: "NaN", 0x0800: "NRes", 0x07FE: "+INF", 0x0802: "-INF", 0x0801: "reserved"}


def sfloat(raw: int) -> float | None:
    """Decode a 16-bit IEEE-11073 SFLOAT; None for the reserved values."""
    mantissa = raw & 0x0FFF
    if mantissa in SPECIAL_MANTISSAS:
        return None
    if mantissa >= 0x800:
        mantissa -= 0x1000
    exponent = raw >> 12
    if exponent >= 8:
        exponent -= 16
    return mantissa * 10.0**exponent


def parse(record: bytes) -> dict:
    """Walk one Blood Pressure Measurement record as the spec describes it."""
    if len(record) < 7:
        raise ValueError("too short")
    flags = record[0]
    if flags & 0xE0:
        raise ValueError("reserved flag bits set")
    out = {"kpa": bool(flags & 0x01)}
    for name, offset in (("systolic", 1), ("diastolic", 3), ("map", 5)):
        out[name] = sfloat(int.from_bytes(record[offset : offset + 2], "little"))
    i = 7
    if flags & 0x02:
        year = int.from_bytes(record[i : i + 2], "little")
        out["timestamp"] = (year, *record[i + 2 : i + 7])
        i += 7
    if flags & 0x04:
        out["pulse"] = sfloat(int.from_bytes(record[i : i + 2], "little"))
        i += 2
    if flags & 0x08:
        out["user_id"] = record[i]
        i += 1
    if flags & 0x10:
        out["status"] = int.from_bytes(record[i : i + 2], "little")
        i += 2
    if i != len(record):
        raise ValueError("record length disagrees with its flags")
    return out


def is_result(decoded: dict) -> bool:
    systolic, diastolic = decoded["systolic"], decoded["diastolic"]
    return (
        systolic is not None
        and diastolic is not None
        and systolic > 0
        and diastolic > 0
        and systolic > diastolic
    )


@pytest.fixture(scope="module")
def spec() -> dict:
    return yaml.safe_load(SPEC_PATH.read_text())


def characteristic(spec: dict, uuid: str) -> dict:
    for service in spec["services"]:
        for char in service.get("characteristics") or []:
            if char["uuid"] == uuid:
                return char
    raise AssertionError(f"{uuid} not found")


def test_sfloat_special_values_carry_no_value():
    for mantissa in SPECIAL_MANTISSAS:
        assert sfloat(mantissa) is None
        # The special values are matched on the mantissa whatever the exponent.
        assert sfloat(mantissa | 0xF000) is None


def test_sfloat_exponent_and_mantissa_are_twos_complement():
    assert sfloat(0x0078) == 120
    assert sfloat(0xF0A0) == pytest.approx(16.0)  # 160 x 10^-1
    assert sfloat(0x0FFF) == -1  # mantissa -1, exponent 0
    assert sfloat(0x1001) == 10  # mantissa 1, exponent +1


def test_mmhg_example_decodes_as_documented(spec):
    example = spec["payload_formats"]["BloodPressureMeasurement"]["example"]
    decoded = parse(bytes.fromhex(example))
    assert decoded["kpa"] is False
    assert decoded["systolic"] == 120
    assert decoded["diastolic"] == 80
    assert decoded["map"] == 95
    assert decoded["pulse"] == 72
    assert "timestamp" not in decoded
    assert is_result(decoded)


def test_kpa_example_converts_to_the_documented_mmhg():
    decoded = parse(bytes.fromhex("05 a0 f0 6a f0 7f f0 48 00"))
    assert decoded["kpa"] is True
    assert decoded["systolic"] == pytest.approx(16.0)
    assert decoded["diastolic"] == pytest.approx(10.6)
    assert decoded["map"] == pytest.approx(12.7)
    assert decoded["systolic"] * KPA_TO_MMHG == pytest.approx(120.0, abs=0.05)
    assert decoded["diastolic"] * KPA_TO_MMHG == pytest.approx(79.5, abs=0.05)
    assert decoded["map"] * KPA_TO_MMHG == pytest.approx(95.3, abs=0.05)
    assert decoded["pulse"] == 72


def test_full_record_walks_every_optional_field():
    decoded = parse(bytes.fromhex("1e 78 00 50 00 5f 00 e9 07 0a 0b 08 1e 00 48 00 ff 04 00"))
    assert decoded["timestamp"] == (2025, 10, 11, 8, 30, 0)
    assert decoded["pulse"] == 72
    assert decoded["user_id"] == 255
    assert decoded["status"] == 0x0004  # irregular pulse
    assert is_result(decoded)


def test_in_progress_records_are_not_results():
    zeros = parse(bytes.fromhex("00 00 00 00 00 00 00"))
    assert zeros["systolic"] == 0 and not is_result(zeros)
    nans = parse(bytes.fromhex("04 ff 07 ff 07 ff 07 48 00"))
    assert nans["systolic"] is None and not is_result(nans)
    # Systolic must exceed diastolic.
    inverted = parse(bytes.fromhex("00 50 00 78 00 5f 00"))
    assert not is_result(inverted)


def test_malformed_records_are_rejected():
    with pytest.raises(ValueError):
        parse(bytes.fromhex("04 78 00 50 00 5f"))  # too short
    with pytest.raises(ValueError):
        parse(bytes.fromhex("24 78 00 50 00 5f 00 48 00"))  # reserved bit 5
    with pytest.raises(ValueError):
        parse(bytes.fromhex("04 78 00 50 00 5f 00 48"))  # pulse truncated
    with pytest.raises(ValueError):
        parse(bytes.fromhex("00 78 00 50 00 5f 00 48 00"))  # trailing bytes


def test_every_worked_example_in_the_parse_rules_decodes(spec):
    """Every hex record quoted in the worked parse rules must parse."""
    rules = spec["payload_formats"]["BloodPressureMeasurement"]["parse_rules"]
    worked = [rule for rule in rules if rule.startswith("Worked")]
    assert len(worked) >= 4
    records = [
        match.group(0).strip()
        for rule in worked
        for match in re.finditer(r"(?:\b[0-9a-f]{2}\b ?){7,}", rule)
    ]
    assert len(records) >= 5, "expected the worked examples to be quoted as hex records"
    for record in records:
        parse(bytes.fromhex(record))


def test_format_block_agrees_with_the_walk(spec):
    fields = {f["name"]: f for f in characteristic(spec, MEASUREMENT_UUID)["format"]}
    assert fields["flags_unit_kpa"]["mask"] == 0x01
    assert fields["flags_timestamp_present"]["mask"] == 0x02
    assert fields["flags_pulse_present"]["mask"] == 0x04
    assert fields["flags_user_id_present"]["mask"] == 0x08
    assert fields["flags_status_present"]["mask"] == 0x10
    for name, offset in (("systolic_sfloat", 1), ("diastolic_sfloat", 3), ("map_sfloat", 5)):
        assert fields[name]["offset"] == offset
        assert fields[name]["length"] == 2
        assert fields[name].get("endianness", "little") == "little"
        assert fields[name]["unit_values"] == {0: "mmHg", 1: "kPa"}
        assert fields[name]["unit_reference"].endswith(".flags_unit_kpa")


def test_control_commands_are_the_two_byte_f1_pairs(spec):
    commands = characteristic(spec, CONTROL_UUID)["commands"]
    assert commands["start_measurement"]["value"] == [0xF1, 0x01]
    assert commands["cancel_measurement"]["value"] == [0xF1, 0x02]
    for command in commands.values():
        assert command["verification"] == "reported"
        assert not command.get("advanced")
