"""Check iLEDColor packet checksums and advertised-geometry offsets."""

from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
SPEC = yaml.safe_load(
    (ROOT / "device-specs" / "devices" / "iledcolor-led-panel.yaml").read_text(
        encoding="utf-8"
    )
)


def _commands():
    service = SPEC["services"][0]
    characteristic = service["characteristics"][0]
    return characteristic["commands"]


def _assert_big_endian_sum(packet: list[int]) -> None:
    assert sum(packet[:-2]) & 0xFFFF == (packet[-2] << 8) | packet[-1]


def test_fixed_command_checksums():
    commands = _commands()
    for name in ("connect", "test_pass_default", "end_stream"):
        command = commands[name]
        assert command["verification"] == "confirmed"
        _assert_big_endian_sum(command["value"])

    assert commands["connect"]["value"] == list(
        bytes.fromhex("54 0d 00 03 00 00 64")
    )
    assert commands["end_stream"]["value"] == list(
        bytes.fromhex("54 01 00 03 01 00 59")
    )


def test_advertised_geometry_offsets():
    feature = SPEC["features"][0]
    advertisement = feature["resolution_advertisement"]
    manufacturer_value = bytes.fromhex(
        "42 44 02 00 40 00 20 03 00 00 0d 00 3d 00 44 00 00 00"
    )

    # schema.json: each offset is ONE byte of the manufacturer-data value,
    # which is how the mobile client reads it. The u16 fields are big-endian,
    # so the declared offsets must be their low bytes.
    width = manufacturer_value[advertisement["width_offset"]]
    height = manufacturer_value[advertisement["height_offset"]]
    assert (width, height) == (32, 64)
    assert advertisement["company_id"] == 0x5401
    assert feature["resolution_source"] == "device_reported"
    assert feature["animation"] is True


def test_vendor_native_animation_uses_raw_rgb_frames():
    upload = SPEC["protocol_details"]["live_upload"]
    native = upload["native_animation_example"]
    assert native["item_type"] == 2
    assert native["frames"] == 3
    assert native["pixel_format"] == "RGB row-major, 3 bytes per pixel"
    assert native["duration_bytes_per_frame"] == 2
    assert native["duration_endian"] == "big"
    assert native["duration_unit"] == "frames_per_second"
    assert native["duration_example_hex"] == "000100010001"
    assert native["item_header_bytes"] == 22
    assert native["item_bytes"] == 18460
    assert native["stream_body_bytes"] == 18484
    assert native["logical_transfer_bytes"] == 18508
    assert native["item_bytes"] == (
        native["item_header_bytes"] + 3 * 32 * 64 * 3 + 3 * 2
    )
    assert native["stream_body_bytes"] == 4 + 4 + 16 + native["item_bytes"]
    assert native["logical_transfer_bytes"] == (
        native["start_packet_bytes"]
        + native["stream_body_bytes"]
        + native["end_packet_bytes"]
    )
    assert native["transport_bytes_with_chunk_headers"] == (
        native["logical_transfer_bytes"]
        + native["chunks"] * native["chunk_packet_overhead_bytes"]
    )
    assert native["chunks"] == 38
    assert native["chunk_payload_bytes"] == 492
    assert "restored the old program" in upload["legacy_acknowledged_gif_example"][
        "caveat"
    ]


def test_start_request_vector_matches_documented_transfer():
    native = SPEC["protocol_details"]["live_upload"]["native_animation_example"]
    request = native["start_request"]
    packet = bytes.fromhex(request["packet_hex"])
    assert len(packet) == native["start_packet_bytes"] == 17
    assert packet[:4] == bytes.fromhex("54 06 00 0d")
    assert packet[4:8].hex() == native["item_data_crc32c"]
    assert int.from_bytes(packet[8:12], "big") == native["logical_transfer_bytes"]
    assert packet[12:15] == bytes(3)
    assert request["payload_hex"] == packet[4:-2].hex()
    assert sum(packet[:-2]) & 0xFFFF == int.from_bytes(packet[-2:], "big")


def test_guide_default_password_checksum_matches_spec():
    packet = _commands()["test_pass_default"]["value"]
    _assert_big_endian_sum(packet)
    guide = (ROOT / "docs" / "devices" / "iledcolor-led-panel.md").read_text(
        encoding="utf-8"
    )
    expected = " ".join(f"{byte:02x}" for byte in packet)
    assert expected in guide
    assert "54 0f 00 08 00 00 00 00 00 00 00 6f" not in guide
