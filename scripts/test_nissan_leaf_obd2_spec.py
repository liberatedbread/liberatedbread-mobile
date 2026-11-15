#!/usr/bin/env python3
"""Independent checks of the Nissan Leaf OBD-II battery spec's worked examples.

Transcribes the spec's ISO-TP reassembly rules and per-generation decode tables
using only the standard library, then asserts that the invented example frames
in ``protocol_details.test_vectors`` decode to the documented values. Nothing
here imports repository code, and no vector comes from a real car.
"""

from pathlib import Path

import pytest
import yaml

SPEC = yaml.safe_load(
    (Path(__file__).parents[1] / "device-specs/devices/nissan-leaf-obd2.yaml").read_text(
        encoding="utf-8"
    )
)
DETAILS = SPEC["protocol_details"]
GROUPS = DETAILS["lbc_groups"]
VECTORS = DETAILS["test_vectors"]
LBC_RESPONSE_ID = int(SPEC["obd"]["transport"]["response_id"], 16)
DIDS = {entry["did"]: entry for entry in SPEC["obd"]["data_identifiers"]}

# Read-only scope: service bytes this spec must never carry as a request.
WRITE_OR_CONTROL_SERVICES = {"04", "10", "11", "14", "27", "28", "2E", "2F", "31", "34", "36", "3B", "85"}


def parse_frame(line):
    """'7BB 10 29 61 ...' -> (0x7BB, bytes)."""
    can_id, *data = line.split()
    return int(can_id, 16), bytes(int(b, 16) for b in data)


def reassemble(lines, expected_id=LBC_RESPONSE_ID):
    """ISO 15765-2 reassembly as protocol_details.iso_tp_reassembly states it."""
    frames = [parse_frame(line) for line in lines]
    assert all(can_id == expected_id for can_id, _ in frames)
    first = frames[0][1]
    kind = first[0] >> 4
    if kind == 0:
        return first[1 : 1 + (first[0] & 0x0F)]
    assert kind == 1, "a multi-frame reply starts with a first frame"
    total = ((first[0] & 0x0F) << 8) | first[1]
    payload = bytearray(first[2:8])
    expected_sn = 1
    for _, data in frames[1:]:
        assert data[0] >> 4 == 2, "consecutive frame expected"
        assert data[0] & 0x0F == expected_sn & 0x0F, "sequence number out of order"
        payload += data[1:8]
        expected_sn += 1
    assert len(payload) >= total, "reply ended before the announced length"
    return bytes(payload[:total])


def decode_field(payload, field):
    start = field["byte_offset"]
    raw = int.from_bytes(
        payload[start : start + field["length"]], "big", signed=field.get("signed", False)
    )
    return raw * field.get("scale", 1) / field.get("divisor", 1) + field.get("value_offset", 0)


def generation_for_length(length):
    return DETAILS["generation_by_group_01_length"][f"0x{length:02X}"].split()[0]


@pytest.mark.parametrize("vector", VECTORS["lbc_group_01"], ids=lambda v: v["variant"])
def test_group_01_decodes_per_generation(vector):
    payload = reassemble(vector["frames"])
    assert payload[:2] == b"\x61\x01"
    layout = GROUPS["group_01"][vector["variant"]]
    assert len(payload) == layout["response_length"]
    assert generation_for_length(len(payload)) == vector["variant"]
    decoded = {f["name"]: decode_field(payload, f) for f in layout["fields"]}
    assert set(decoded) == set(vector["expected"])
    for name, value in vector["expected"].items():
        assert decoded[name] == pytest.approx(value, abs=1e-6), name


def test_group_01_layouts_cover_each_declared_variant():
    variants = {v["model"] for v in SPEC["device"]["variants"]}
    assert set(GROUPS["group_01"]) == variants
    assert {v["variant"] for v in VECTORS["lbc_group_01"]} == variants


def test_group_02_cell_voltages():
    vector = VECTORS["lbc_group_02"]
    payload = reassemble(vector["frames"])
    group = GROUPS["group_02"]
    assert payload[:2] == b"\x61\x02"
    assert len(payload) == group["response_length"]
    cells_spec = group["cells"]
    cells = []
    for i in range(cells_spec["count"]):
        off = cells_spec["first_offset"] + i * cells_spec["stride"]
        raw = int.from_bytes(payload[off : off + cells_spec["length"]], "big")
        assert raw != 0xFFFF
        cells.append(raw / cells_spec["divisor"])
    expected = vector["expected"]
    assert len(cells) == expected["cell_count"]
    assert cells[0] == pytest.approx(expected["cell_first"])
    assert cells[-1] == pytest.approx(expected["cell_last"])
    for field in group["fields"]:
        assert decode_field(payload, field) == pytest.approx(expected[field["name"]])


def test_group_02_wraps_the_sequence_number():
    # 198 bytes need 28 consecutive frames, so the 4-bit counter wraps.
    assert len(VECTORS["lbc_group_02"]["frames"]) == 29


def test_group_04_temperatures():
    vector = VECTORS["lbc_group_04"]
    payload = reassemble(vector["frames"])
    group = GROUPS["group_04"]
    assert len(payload) == group["response_length"][vector["variant"]]
    sensors = group["sensors"]
    conv = sensors["raw_to_celsius"]
    expected = vector["expected"]
    for i in range(sensors["count"]):
        roff = sensors["raw_offset"] + i * sensors["stride"]
        raw = int.from_bytes(payload[roff : roff + sensors["raw_length"]], "big")
        if raw == 0xFFFF:
            assert expected["raw"][i] is None
            continue
        assert raw == expected["raw"][i]
        assert payload[sensors["temp_offset"] + i * sensors["stride"]] == expected["temp_byte_c"][i]
        celsius = conv["scale"] * (raw + conv["raw_offset"])
        assert celsius == pytest.approx(expected["raw_to_celsius"][i], abs=0.005)
    (sensor5,) = group["fields"]
    assert decode_field(payload, sensor5) == expected["sensor_5_temp"]


def test_group_61_health_block_uses_a_12_bit_length():
    vector = VECTORS["lbc_group_61"]
    first = parse_frame(vector["frames"][0])[1]
    assert first[0] == 0x11, "331 bytes cannot be announced in the low byte alone"
    payload = reassemble(vector["frames"])
    assert payload[:2] == b"\x61\x61"
    assert len(payload) == GROUPS["group_61"]["response_length"]
    for field in GROUPS["group_61"]["fields"]:
        assert decode_field(payload, field) == pytest.approx(vector["expected"][field["name"]]), field["name"]


def _signed16(x):
    return x - 65536 if x >= 32768 else x


DID_DECODERS = {
    # Transcribed from each data_identifier's scale/formula in the spec.
    "0x1103": lambda x: x * DIDS["0x1103"]["scale"],
    "0x1183": lambda x: _signed16(x) / 256,
    "0x1203": lambda x: x,
    "0x115D": lambda x: x / 2 - 40,
    "0x121A": lambda x: _signed16(x) / 10,
    "0x0E01": lambda x: x,
    "0x0E25": lambda x: x * DIDS["0x0E25"]["scale"],
}

@pytest.mark.parametrize("vector", VECTORS["vcm_and_meter_single_frames"], ids=lambda v: v["did"])
def test_vcm_and_meter_single_frames(vector):
    req_id, req = parse_frame(vector["request"])
    resp_id, frame = parse_frame(vector["frame"])
    ecus = {int(e["request_id"], 16): int(e["response_id"], 16) for e in SPEC["obd"]["ecus"] if "request_id" in e}
    assert ecus[req_id] == resp_id
    assert req[0] == len(req) - 1 and req[1] == 0x22
    payload = frame[1 : 1 + (frame[0] & 0x0F)]
    assert payload[0] == 0x62 and payload[1:3] == req[2:4]
    did = vector["did"]
    assert int(did, 16) == int.from_bytes(payload[1:3], "big")
    assert did in DIDS
    # The single-frame length says how many data bytes follow the DID echo.
    raw = int.from_bytes(payload[3:], "big")
    if "expected_raw" in vector:
        assert raw == vector["expected_raw"]
    else:
        assert DID_DECODERS[did](raw) == pytest.approx(vector["expected"], abs=0.005)


def test_spec_is_read_only():
    for request in SPEC["obd"]["requests"]:
        assert request["writes"] is False, request["name"]
        assert request["service"].upper() not in WRITE_OR_CONTROL_SERVICES, request["name"]


def test_lbc_polls_name_their_group():
    for request in SPEC["obd"]["requests"]:
        if request["name"].startswith("lbc_group_"):
            group = request["name"].split("_")[2]
            assert request["request"] == f"21 {group.upper()}"
            assert request["expected_response"] == f"61 {group.upper()}"
