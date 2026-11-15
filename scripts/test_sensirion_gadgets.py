"""Independent fixture checks for the two Sensirion protocol generations.

Protocol decoders and arithmetic below use only Python's standard library and
are transcribed from the two YAML specs. Pytest and PyYAML run the checks and
load the published vectors; no Sensirion or third-party parser code is imported.
Passing these tests proves internal implementability, not hardware compatibility.
"""

from __future__ import annotations

import math
import struct
from fractions import Fraction
from pathlib import Path

import pytest
import yaml

REPO_ROOT = Path(__file__).resolve().parent.parent
NEWER_SPEC_PATH = REPO_ROOT / "device-specs/devices/sensirion-ble-gadgets.yaml"
LEGACY_SPEC_PATH = (
    REPO_ROOT / "device-specs/devices/sensirion-sht31-smart-gadget.yaml"
)
TICK_DENOMINATOR = 65535
LEGACY_HISTORY_LENGTHS = frozenset((8, 12, 16, 20))


@pytest.fixture(scope="module")
def newer_spec() -> dict:
    return yaml.safe_load(NEWER_SPEC_PATH.read_text(encoding="utf-8"))


@pytest.fixture(scope="module")
def legacy_spec() -> dict:
    return yaml.safe_load(LEGACY_SPEC_PATH.read_text(encoding="utf-8"))


def parse_passive_advertisement(payload: bytes) -> dict[str, object]:
    """Decode protocol_details.advertisement_formats, excluding company ID."""
    if len(payload) < 2 or payload[0] != 0:
        raise ValueError("advertisement type must be zero")
    sample_type = payload[1]
    accepted_lengths = {4: (8,), 6: (8,), 8: (10, 12)}
    if sample_type not in accepted_lengths:
        raise ValueError(f"unsupported sample type {sample_type}")
    if len(payload) not in accepted_lengths[sample_type]:
        raise ValueError(
            f"type {sample_type} needs {accepted_lengths[sample_type]} bytes, "
            f"got {len(payload)}"
        )

    temperature_ticks, humidity_ticks = struct.unpack_from("<HH", payload, 4)
    result: dict[str, object] = {
        "sample_type": sample_type,
        "device_id_hex": payload[2:4].hex(),
        "temperature_ticks": temperature_ticks,
        "humidity_ticks": humidity_ticks,
        "temperature_c": Fraction(175 * temperature_ticks, TICK_DENOMINATOR) - 45,
    }
    if sample_type == 6:
        result["humidity_percent"] = (
            Fraction(125 * humidity_ticks, TICK_DENOMINATOR) - 6
        )
    else:
        result["humidity_percent"] = Fraction(
            100 * humidity_ticks, TICK_DENOMINATOR
        )
    if sample_type == 8:
        result["co2_ppm"] = struct.unpack_from("<H", payload, 8)[0]
    return result


def parse_legacy_measurement_packet(packet: bytes) -> dict[str, object]:
    """Distinguish LegacyLiveMeasurement from LegacyHistoryPacket by length."""
    if len(packet) == 4:
        return {"kind": "live", "value": struct.unpack("<f", packet)[0]}
    if len(packet) not in LEGACY_HISTORY_LENGTHS:
        raise ValueError(f"invalid legacy live/history length {len(packet)}")
    sequence = struct.unpack_from("<I", packet)[0]
    values = struct.unpack_from(f"<{(len(packet) - 4) // 4}f", packet, 4)
    return {"kind": "history", "sequence": sequence, "values": values}


def legacy_history_timestamp_ms(
    selected_newest_epoch_ms: int,
    sequence: int,
    zero_based_value_slot: int,
    logger_interval_ms: int,
) -> int:
    """Apply protocol_details.measurement_channels.history.timestamp_rule."""
    if sequence < 1 or zero_based_value_slot < 0 or logger_interval_ms < 1:
        raise ValueError("invalid history timestamp coordinates")
    return selected_newest_epoch_ms - (
        sequence - 1 + zero_based_value_slot
    ) * logger_interval_ms


def normalize_legacy_interval_ms(requested_ms: int) -> int:
    """Apply protocol_details.interval_write.normalization to one uint32."""
    if not 0 <= requested_ms <= 0xFFFFFFFF:
        raise ValueError("interval does not fit uint32")
    return max(1000, requested_ms - requested_ms % 1000)


def arduino_sample_timestamp_ms(
    header_received_epoch_ms: int,
    age_of_latest_sample_ms: int,
    download_sample_count: int,
    sample_index: int,
    interval_ms: int,
) -> int:
    """Apply the current Arduino oldest-to-newest header timestamp rule."""
    if not 0 <= sample_index < download_sample_count or interval_ms < 1:
        raise ValueError("invalid Arduino sample coordinates")
    return (
        header_received_epoch_ms
        - age_of_latest_sample_ms
        - (download_sample_count - 1 - sample_index) * interval_ms
    )


def characteristic(spec: dict, uuid: str) -> dict:
    return next(
        item
        for service in spec["services"]
        for item in service.get("characteristics", [])
        if item["uuid"] == uuid
    )


@pytest.mark.parametrize("vector_name", ("type_4_invented", "type_6_invented", "type_8_invented"))
def test_passive_vectors_exactly(newer_spec: dict, vector_name: str) -> None:
    vector = next(
        item
        for item in newer_spec["protocol_details"]["test_vectors"]["passive"]
        if item["name"] == vector_name
    )
    decoded = parse_passive_advertisement(bytes.fromhex(vector["payload_hex"]))

    assert decoded["device_id_hex"] == vector["device_id_hex"]
    assert decoded["temperature_ticks"] == vector["temperature_ticks"]
    assert decoded["humidity_ticks"] == vector["humidity_ticks"]
    assert decoded["temperature_c"] == Fraction(vector["temperature_c"])
    assert decoded["humidity_percent"] == Fraction(vector["humidity_percent"])
    assert math.isclose(
        float(decoded["temperature_c"]),
        vector["temperature_c_approx"],
        rel_tol=0,
        abs_tol=1e-12,
    )
    assert math.isclose(
        float(decoded["humidity_percent"]),
        vector["humidity_percent_approx"],
        rel_tol=0,
        abs_tol=1e-12,
    )
    if "co2_ppm" in vector:
        assert decoded["co2_ppm"] == vector["co2_ppm"]


def test_company_matchers_and_generation_separation(
    newer_spec: dict, legacy_spec: dict
) -> None:
    identification = newer_spec["device"]["identification"]["manufacturer_data"]
    assert identification["company_id"] == 0x06D5 == 1749
    assert identification["company_id_hex"] == "0x06D5"
    methods = newer_spec["device"]["discovery"]["methods"]
    assert {
        method["ble"]["manufacturer_data"]["pattern"] for method in methods
    } == {"0004", "0006", "0008"}
    assert all(
        method["ble"]["manufacturer_data"]["company_id"] == 0x06D5
        for method in methods
    )
    connection = newer_spec["protocol_details"]["connection_behavior"]
    assert connection["advertising_during_gatt_connection"] is False
    assert connection["visible_to_other_clients_while_connected"] is False
    exclusion = newer_spec["protocol_details"]["generation_exclusions"][
        "smart_humigadget"
    ]
    assert exclusion["newer_logger_service_supported"] is False
    assert exclusion["separate_spec"] == "sensirion-sht31-smart-gadget"

    assert "manufacturer_data" not in legacy_spec["device"]["identification"]
    assert legacy_spec["device"]["identification"]["local_names"] == [
        "Smart Humigadget"
    ]
    assert "0000f234-b38d-4985-720e-0f993a68ee41" in {
        service["uuid"] for service in legacy_spec["services"]
    }
    assert "00008000-b38d-4985-720e-0f993a68ee41" not in {
        service["uuid"] for service in legacy_spec["services"]
    }


def test_type_8_reserved_word_is_optional_and_ignored(newer_spec: dict) -> None:
    vector = next(
        item
        for item in newer_spec["protocol_details"]["test_vectors"]["passive"]
        if item["name"] == "type_8_invented"
    )
    packet = bytes.fromhex(vector["payload_hex"])
    without_reserved = parse_passive_advertisement(packet[:10])
    arbitrary_reserved = parse_passive_advertisement(packet[:10] + b"\xde\xad")
    assert without_reserved == arbitrary_reserved
    assert len(packet) == 12


@pytest.mark.parametrize(
    "payload",
    (
        b"",
        b"\x01\x04\x00\x00\x00\x00\x00\x00",
        b"\x00\x05\x00\x00\x00\x00\x00\x00",
        b"\x00\x04\x00\x00\x00\x00\x00",
        b"\x00\x04\x00\x00\x00\x00\x00\x00\x00",
        b"\x00\x06\x00\x00\x00\x00\x00",
        b"\x00\x08\x00\x00\x00\x00\x00\x00\x00",
        b"\x00\x08\x00\x00\x00\x00\x00\x00\x00\x00\x00",
        b"\x00\x08\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00",
    ),
)
def test_passive_rejects_bad_type_or_length(payload: bytes) -> None:
    with pytest.raises(ValueError):
        parse_passive_advertisement(payload)


def test_arduino_header_and_timestamp_vector(newer_spec: dict) -> None:
    example = bytes.fromhex(newer_spec["payload_formats"]["ArduinoLoggerHeader"]["example"])
    assert len(example) == 20
    assert example[:4] == bytes(4)
    assert struct.unpack_from("<H", example, 4)[0] == 9
    assert struct.unpack_from("<I", example, 6)[0] == 60000
    assert struct.unpack_from("<I", example, 10)[0] == 30000
    assert struct.unpack_from("<H", example, 14)[0] == 3
    assert example[16:] == bytes(4)

    vector = newer_spec["protocol_details"]["test_vectors"]["arduino_timestamp"]
    assert arduino_sample_timestamp_ms(
        vector["header_received_epoch_ms"],
        vector["age_of_latest_sample_ms"],
        vector["download_sample_count"],
        vector["sample_index"],
        vector["interval_ms"],
    ) == vector["expected_timestamp_ms"]


def test_legacy_live_vector(legacy_spec: dict) -> None:
    vector = legacy_spec["protocol_details"]["test_vectors"]["live_humidity"]
    decoded = parse_legacy_measurement_packet(bytes.fromhex(vector["packet_hex"]))
    assert decoded == {"kind": "live", "value": vector["expected_percent"]}


def test_legacy_history_vector_and_length(legacy_spec: dict) -> None:
    vector = legacy_spec["protocol_details"]["test_vectors"]["history_humidity"]
    packet = bytes.fromhex(vector["packet_hex"])
    assert len(packet) == vector["expected_length"] == 12
    decoded = parse_legacy_measurement_packet(packet)
    assert decoded["kind"] == "history"
    assert decoded["sequence"] == vector["expected_sequence"]
    assert list(decoded["values"]) == vector["expected_percent"]


@pytest.mark.parametrize("value_count", (1, 2, 3, 4))
def test_legacy_history_widths(value_count: int) -> None:
    values = tuple(20.0 + index for index in range(value_count))
    packet = struct.pack("<I", 1) + struct.pack(f"<{value_count}f", *values)
    assert len(packet) == 4 + value_count * 4
    decoded = parse_legacy_measurement_packet(packet)
    assert decoded == {"kind": "history", "sequence": 1, "values": values}


@pytest.mark.parametrize("length", (0, 1, 3, 5, 6, 7, 9, 10, 11, 13, 21, 24))
def test_legacy_rejects_lengths_outside_both_formats(length: int) -> None:
    with pytest.raises(ValueError, match="invalid legacy"):
        parse_legacy_measurement_packet(bytes(length))


def test_legacy_epoch_and_interval_are_little_endian_milliseconds(
    legacy_spec: dict,
) -> None:
    vectors = legacy_spec["protocol_details"]["test_vectors"]
    epoch = vectors["epoch_milliseconds"]
    epoch_bytes = bytes.fromhex(epoch["packet_hex"])
    assert len(epoch_bytes) == 8
    assert struct.pack("<Q", epoch["value"]) == epoch_bytes
    assert struct.unpack("<Q", epoch_bytes)[0] == epoch["value"]
    assert struct.unpack("<I", epoch_bytes[:4])[0] != epoch["value"]

    interval = vectors["interval_milliseconds"]
    interval_bytes = bytes.fromhex(interval["packet_hex"])
    assert len(interval_bytes) == 4
    assert struct.pack("<I", interval["value"]) == interval_bytes
    assert struct.unpack("<I", interval_bytes)[0] == interval["value"]


def test_legacy_history_timestamp_vector(legacy_spec: dict) -> None:
    vector = legacy_spec["protocol_details"]["test_vectors"]["history_timestamp"]
    assert legacy_history_timestamp_ms(
        vector["selected_newest_epoch_ms"],
        vector["sequence"],
        vector["zero_based_value_slot"],
        vector["logger_interval_ms"],
    ) == vector["expected_timestamp_ms"]


def test_legacy_interval_normalization_vectors(legacy_spec: dict) -> None:
    vectors = legacy_spec["protocol_details"]["test_vectors"][
        "interval_normalization"
    ]
    for vector in vectors:
        assert (
            normalize_legacy_interval_ms(vector["requested_ms"])
            == vector["accepted_ms"]
        )


def test_destructive_and_generation_specific_commands_are_not_overclaimed(
    newer_spec: dict, legacy_spec: dict
) -> None:
    newer_interval = characteristic(
        newer_spec, "00008001-b38d-4985-720e-0f993a68ee41"
    )["commands"]["set_logging_interval_ms"]
    assert newer_interval["advanced"] is True
    assert newer_interval["verification"] == "reported"
    requested = characteristic(
        newer_spec, "00008003-b38d-4985-720e-0f993a68ee41"
    )
    assert "commands" not in requested

    legacy_service = next(
        service
        for service in legacy_spec["services"]
        if service["uuid"] == "0000f234-b38d-4985-720e-0f993a68ee41"
    )
    legacy_interval = characteristic(
        legacy_spec, "0000f239-b38d-4985-720e-0f993a68ee41"
    )["commands"]["set_logger_interval_ms"]
    assert legacy_interval["advanced"] is True
    assert legacy_interval["verification"] == "reported"
    start = characteristic(
        legacy_spec, "0000f238-b38d-4985-720e-0f993a68ee41"
    )["commands"]["start_history_download"]
    assert start["value"] == [1]
    assert "clear_history" not in {
        command
        for item in legacy_service["characteristics"]
        for command in item.get("commands", {})
    }

    for spec in (newer_spec, legacy_spec):
        assert spec["device"]["testing"]["status"] == "untested"
        assert not any(
            feature["type"] == "firmware_update"
            for feature in spec.get("features", [])
        )



def test_newer_transfer_declares_generation_specific_delivery(newer_spec: dict) -> None:
    transfer = characteristic(newer_spec, "00008004-b38d-4985-720e-0f993a68ee41")

    assert transfer["properties"] == ["notify", "indicate"]
    generations = newer_spec["protocol_details"]["logger_generations"]
    assert generations["arduino_1_5_0"]["data_transfer"]["delivery"] == "indicate"
    assert "CCCD 02 00" in transfer["notes"]
