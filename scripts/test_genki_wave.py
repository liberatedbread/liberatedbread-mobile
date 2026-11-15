#!/usr/bin/env python3
"""Independent Wave framing and structure checks from the YAML alone.

COBS, stream reassembly and payload decoding use only the standard library.
Every byte string is synthetic; none is an owner capture. PyYAML loads the spec
and pytest runs the checks, but neither supplies protocol logic.
"""

from pathlib import Path
import struct

import yaml

SPEC = yaml.safe_load(
    (Path(__file__).parents[1] / "device-specs/devices/genki-wave.yaml").read_text()
)
FORMATS = SPEC["payload_formats"]
VECTORS = SPEC["protocol_details"]["fixed_write_vectors"]
API_CHARACTERISTIC = SPEC["services"][0]["characteristics"][0]


def octets(text):
    return bytes.fromhex(text)


def cobs_encode(data):
    """Encode one body, without a delimiter, from protocol_details.api_framing."""
    output = bytearray([0])
    block_start = 0
    run_length = 0
    for byte in data:
        if byte == 0:
            output[block_start] = run_length + 1
            block_start = len(output)
            output.append(0)
            run_length = 0
            continue
        output.append(byte)
        run_length += 1
        if run_length == 254:
            output[block_start] = 0xFF
            block_start = len(output)
            output.append(0)
            run_length = 0
    output[block_start] = run_length + 1
    return bytes(output)


def cobs_decode(data):
    if not data:
        raise ValueError("empty COBS body")
    output = bytearray()
    cursor = 0
    while cursor < len(data):
        code = data[cursor]
        cursor += 1
        if code == 0:
            raise ValueError("zero inside a COBS body")
        count = code - 1
        if cursor + count > len(data):
            raise ValueError("truncated COBS block")
        output += data[cursor : cursor + count]
        cursor += count
        if code != 0xFF and cursor < len(data):
            output.append(0)
    return bytes(output)


class CobsStream:
    """Notification-independent reassembly from receive_reassembly."""

    def __init__(self):
        self.buffer = bytearray()

    def feed(self, data):
        self.buffer += data
        decoded = []
        while 0 in self.buffer:
            body, _, remainder = self.buffer.partition(b"\x00")
            self.buffer = bytearray(remainder)
            if not body:
                continue
            try:
                decoded.append(cobs_decode(body))
            except ValueError:
                # The delimiter supplies recovery: discard only this bad frame.
                continue
        return decoded


def decode_field(payload, field):
    offset = field["offset"]
    length = field["length"]
    kind = field["type"]
    endian = field.get("endianness", "little")
    if kind == "float32":
        prefix = "<" if endian == "little" else ">"
        count = field.get("count", 1)
        assert length == 4 * count
        values = struct.unpack_from(f"{prefix}{count}f", payload, offset)
        return values if count > 1 else values[0]
    if kind in {"uint8", "uint16", "uint64"}:
        expected_length = {"uint8": 1, "uint16": 2, "uint64": 8}[kind]
        assert length == expected_length
        return int.from_bytes(payload[offset : offset + length], endian)
    if kind == "bool":
        assert length == 1
        return payload[offset] != 0
    if kind == "bytes":
        return payload[offset : offset + length]
    raise AssertionError(f"unhandled synthetic-check type: {kind}")


def fields(format_name):
    return FORMATS[format_name]["fields"]


def test_cobs_primitive_vectors_and_long_runs():
    vectors = [
        (b"", "01"),
        (b"\x00", "01 01"),
        (b"\x00\x00", "01 01 01"),
        (b"\x11\x00\x22", "02 11 02 22"),
        (b"\x11\x22\x33", "04 11 22 33"),
        (octets(VECTORS["enter_api_mode"]["raw_hex"]), VECTORS["enter_api_mode"]["write_hex"][:-3]),
    ]
    for raw, encoded_hex in vectors:
        encoded = octets(encoded_hex)
        assert cobs_encode(raw) == encoded
        assert cobs_decode(encoded) == raw
        assert 0 not in encoded

    for raw in (
        bytes(range(1, 255)),
        bytes(range(1, 256)),
        b"\x00" + bytes(range(1, 255)) + b"\x00\x00" + bytes(range(1, 40)),
    ):
        encoded = cobs_encode(raw)
        assert cobs_decode(encoded) == raw
        assert 0 not in encoded


def test_header_is_type_u8_id_u8_size_u16le():
    raw = octets(VECTORS["enter_api_mode"]["raw_hex"])
    assert raw == struct.pack("<BBH", 1, 5, 1) + b"\x67"
    package_type, package_id, payload_size = struct.unpack_from("<BBH", raw)
    assert (package_type, package_id, payload_size) == (1, 5, 1)
    assert raw[1] == 5
    assert raw[2:4] == b"\x01\x00"
    assert struct.calcsize("<BBH") == 4


def test_every_fixed_write_matches_its_pre_cobs_vector_and_command():
    expected_ids = {
        "enter_api_mode": 5,
        "configure_motion_8_byte": 11,
        "configure_spectrogram_8_byte": 11,
        "configure_motion_extended_12_byte": 11,
        "request_battery_status": 2,
        "request_device_info": 3,
    }
    assert VECTORS["synthetic"] is True
    for name, package_id in expected_ids.items():
        vector = VECTORS[name]
        raw = octets(vector["raw_hex"])
        write = octets(vector["write_hex"])
        assert bytes(API_CHARACTERISTIC["commands"][name]["value"]) == write
        assert API_CHARACTERISTIC["commands"][name]["verification"] == "reported"
        assert write[-1] == 0
        assert 0 not in write[:-1]
        assert cobs_encode(raw) + b"\x00" == write
        assert cobs_decode(write[:-1]) == raw
        package_type, actual_id, payload_size = struct.unpack_from("<BBH", raw)
        assert package_type == 1
        assert actual_id == package_id
        assert payload_size == len(raw) - 4


def test_original_and_extended_configurations_stay_distinct():
    original = octets(VECTORS["configure_motion_8_byte"]["raw_hex"])
    extended = octets(VECTORS["configure_motion_extended_12_byte"]["raw_hex"])
    assert len(original) == 12  # four-byte header + eight-byte payload
    assert len(extended) == 16  # four-byte header + twelve-byte payload
    assert struct.unpack_from("<H", original, 2)[0] == 8
    assert struct.unpack_from("<H", extended, 2)[0] == 12

    original_values = {
        field["name"]: decode_field(original[4:], field) for field in fields("ApiConfig8")
    }
    extended_values = {
        field["name"]: decode_field(extended[4:], field) for field in fields("ApiConfig12")
    }
    assert original_values["datastream_type"] == 1
    assert original_values["spectrogram_enabled"] is False
    assert original_values["sample_rate"] == 400.0
    assert "tap_sensitivity" not in original_values
    assert extended_values["sample_rate"] == 400.0
    assert extended_values["tap_sensitivity"] == struct.unpack("<f", struct.pack("<f", 0.7))[0]

    spectrogram = octets(VECTORS["configure_spectrogram_8_byte"]["raw_hex"])
    spectrogram_values = {
        field["name"]: decode_field(spectrogram[4:], field) for field in fields("ApiConfig8")
    }
    assert spectrogram_values["datastream_type"] == 0
    assert spectrogram_values["spectrogram_enabled"] is True
    assert spectrogram_values["sample_rate"] == 2000.0


def test_stream_reassembly_handles_fragmentation_coalescing_and_recovery():
    names = [
        "enter_api_mode",
        "configure_motion_8_byte",
        "configure_spectrogram_8_byte",
        "configure_motion_extended_12_byte",
    ]
    raws = [octets(VECTORS[name]["raw_hex"]) for name in names]
    writes = [octets(VECTORS[name]["write_hex"]) for name in names]

    stream = CobsStream()
    assert stream.feed(writes[0][:2]) == []
    chunk = writes[0][2:] + writes[1] + writes[2][:5]
    assert stream.feed(chunk) == raws[:2]
    assert stream.feed(writes[2][5:] + b"\x00" + writes[3]) == raws[2:]

    bytewise = CobsStream()
    received = []
    for byte in b"".join(writes):
        received += bytewise.feed(bytes([byte]))
    assert received == raws

    recovered = CobsStream()
    assert recovered.feed(b"\x00\x00" + writes[0]) == [raws[0]]


def test_declared_binary_layouts_are_contiguous_and_exact_sized():
    expected_sizes = {
        "ApiHeader": 4,
        "ApiConfig8": 8,
        "ApiConfig12": 12,
        "MotionData": 105,
        "RawMotionData": 32,
        "BatteryStatus": 9,
        "SpectrogramData": 392,
        "DeviceInfo": 35,
    }
    for name, expected_size in expected_sizes.items():
        cursor = 0
        for field in sorted(fields(name), key=lambda item: item["offset"]):
            assert field["offset"] == cursor, (name, field["name"])
            cursor += field["length"]
        assert cursor == expected_size, name


def test_motion_struct_decode_and_unaligned_tail():
    values = [index - 11 + 0.25 for index in range(23)]
    timestamp = 0x0102030405060708
    payload = struct.pack("<23f?fQ", *values, True, 42.5, timestamp)
    assert len(payload) == 105
    motion_fields = fields("MotionData")
    for index, value in enumerate(values):
        assert decode_field(payload, motion_fields[index]) == value
    assert decode_field(payload, motion_fields[23]) is True
    assert decode_field(payload, motion_fields[24]) == 42.5
    assert decode_field(payload, motion_fields[25]) == timestamp
    assert motion_fields[23]["offset"] == 92
    assert motion_fields[24]["offset"] == 93
    assert motion_fields[25]["offset"] == 97


def test_raw_battery_and_spectrogram_struct_decodes():
    raw_values = [-3.0, -2.0, -1.0, 0.25, 0.5, 0.75]
    raw_payload = struct.pack("<6fQ", *raw_values, 123456)
    assert len(raw_payload) == 32
    for index, value in enumerate(raw_values):
        assert decode_field(raw_payload, fields("RawMotionData")[index]) == value
    assert decode_field(raw_payload, fields("RawMotionData")[6]) == 123456

    battery_payload = octets(FORMATS["BatteryStatus"]["example"])
    assert battery_payload == struct.pack("<ff?", 4.0, 87.5, True)
    battery_fields = fields("BatteryStatus")
    for payload in (battery_payload, battery_payload + b"\x00\x00\x00"):
        assert decode_field(payload, battery_fields[0]) == 4.0
        assert decode_field(payload, battery_fields[1]) == 87.5
        assert decode_field(payload, battery_fields[2]) is True
    native_candidate = FORMATS["BatteryStatus"]["native_layout_candidate"]
    assert native_candidate["total_bytes"] == 12
    assert native_candidate["trailing_padding_bytes"] == 3
    assert native_candidate["wire_size_verified"] is False

    bins = [float(index - 48) for index in range(96)]
    spectrogram_payload = struct.pack("<96fQ", *bins, 789012)
    assert len(spectrogram_payload) == 392
    for channel_index, field in enumerate(fields("SpectrogramData")[:-1]):
        expected = tuple(bins[channel_index * 16 : (channel_index + 1) * 16])
        assert decode_field(spectrogram_payload, field) == expected
        assert field["count"] == 16
    assert decode_field(spectrogram_payload, fields("SpectrogramData")[-1]) == 789012


def test_device_info_struct_contains_only_synthetic_identifiers():
    address = bytes.fromhex("00 00 5e 00 53 00")
    serial = b"SYNTHETIC"
    payload = struct.pack("<3B9s6s17s", 1, 7, 4, b"BOARD", address, serial)
    assert len(payload) == 35
    info_fields = fields("DeviceInfo")
    assert [decode_field(payload, field) for field in info_fields[:3]] == [1, 7, 4]
    assert decode_field(payload, info_fields[3]).rstrip(b"\x00") == b"BOARD"
    assert decode_field(payload, info_fields[4]) == address
    assert decode_field(payload, info_fields[5]).rstrip(b"\x00") == serial


def test_unresolved_physical_units_are_not_invented():
    for format_name in ("MotionData", "RawMotionData"):
        for field in fields(format_name):
            if field["name"] != "timestamp_us":
                assert "unit" not in field, (format_name, field["name"])
    for field in fields("SpectrogramData")[:-1]:
        assert "unit" not in field, field["name"]
