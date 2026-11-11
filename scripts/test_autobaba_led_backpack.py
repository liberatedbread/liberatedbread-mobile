"""Reproduce the source-derived AUTOBABA information query independently."""

from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
SPEC = yaml.safe_load(
    (ROOT / "device-specs" / "devices" / "autobaba-led-backpack.yaml").read_text(
        encoding="utf-8"
    )
)


def test_information_query_checksum_and_length():
    expected = bytes.fromhex(
        SPEC["protocol_details"]["panel_discovery"]["source_derived_query_hex"]
    )
    tlv = bytes.fromhex("0a 00 1b 00 04 00 06 00")
    frame = bytearray.fromhex("aa 55 ff ff")
    frame += (len(tlv) + 6).to_bytes(2, "little")
    frame += (1).to_bytes(2, "little")
    frame += bytes.fromhex("c1 03")
    frame += tlv
    frame += (sum(frame) & 0xFFFF).to_bytes(2, "little")

    assert bytes(frame) == expected
    assert len(frame) == 20
    assert int.from_bytes(frame[4:6], "little") == len(tlv) + 6
    assert int.from_bytes(frame[-2:], "little") == 0x03FF


def _tlv_header(data: bytes) -> tuple[int, int, int]:
    """Decode [type][length] per tlv_length_encoding: (type, length, header size)."""
    tlv_type, first = data[0], data[1]
    if first < 0x80:
        return tlv_type, first, 2
    if first == 0x81:
        return tlv_type, data[2], 3
    if first == 0x82:
        return tlv_type, int.from_bytes(data[2:4], "little"), 4
    raise AssertionError(f"unknown length prefix {first:#04x}")


def test_extended_tlv_length_81_c4_means_196_bytes():
    encoding = SPEC["protocol_details"]["panel_discovery"]["tlv_length_encoding"]
    assert encoding["extended_8"].startswith("81 LL")
    example_hex, claim = encoding["example"].split("=", 1)
    tlv_type, length, header = _tlv_header(bytes.fromhex(example_hex))
    assert (tlv_type, length, header) == (0x13, 196, 3)
    assert f"type {tlv_type:#04x}" in claim
    assert f"{length}-byte value" in claim

    # The worked GIF chunk carries the same TLV: its value runs to the checksum.
    upload = SPEC["protocol_details"]["raw_gif_upload"]
    packet = bytes.fromhex(upload["worked_chunk_hex"])
    tlv_type, length, header = _tlv_header(packet[42:])
    assert tlv_type == 0x13
    assert length == upload["value_chunk_bytes"] == 196
    assert len(packet) - 2 - (42 + header) == length


def test_panel_dimensions_are_little_endian_after_type_byte():
    observed = SPEC["protocol_details"]["panel_discovery"]["observed_reply"]
    panel = bytes.fromhex("00 40 00 40")

    assert panel[0] == 0
    assert int.from_bytes(panel[1:3], "little") == observed["width"] == 64
    assert int.from_bytes(panel[3:5], "little") == observed["height"] == 64
    assert observed["width_height_endian"] == "little"


def test_raw_gif_write_fits_the_observed_mtu():
    upload = SPEC["protocol_details"]["raw_gif_upload"]
    assert upload["value_chunk_bytes"] == 196
    assert upload["gatt_write_bytes"] == 243
    assert upload["gatt_write_bytes"] <= upload["mtu"] - 3


def test_raw_gif_worked_chunk_has_exact_layout_and_checksum():
    upload = SPEC["protocol_details"]["raw_gif_upload"]
    packet = bytes.fromhex(upload["worked_chunk_hex"])
    assert len(packet) == upload["gatt_write_bytes"] == 243
    assert packet[:4] == bytes.fromhex("aa 55 ff ff")
    assert packet[4] == 0xED
    assert packet[5:8] == bytes(3)
    assert packet[8:35] == bytes.fromhex(upload["chunk_prefix"]["sequence_hex"])
    assert packet[35] == upload["worked_chunk_fields"]["total_chunks"] == 3
    assert packet[36:39] == bytes(3)
    assert packet[39:43].hex() == upload["chunk_prefix"]["constant_2_hex"]
    assert packet[43:45] == bytes.fromhex("81 c4")
    assert packet[45:51] == b"GIF89a"
    assert packet[51:-2] == bytes(190)
    assert packet[-2:] == (sum(packet[:-2]) & 0xFFFF).to_bytes(2, "little")
    assert packet[-2:] == bytes.fromhex("0d09")
    assert len(packet) - upload["value_chunk_bytes"] == upload["packet_overhead_bytes"]
