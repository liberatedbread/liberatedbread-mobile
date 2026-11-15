"""Independent LOY AA55/TLV transcription using only the standard library."""

from hashlib import md5, sha256
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
SPEC = yaml.safe_load(
    (ROOT / "device-specs" / "devices" / "loypro-led-display.yaml").read_text(
        encoding="utf-8"
    )
)
DETAILS = SPEC["protocol_details"]


def tlv(tag: int, value: bytes) -> bytes:
    length = len(value)
    if length < 0x80:
        encoded_length = bytes([length])
    elif length < 0x100:
        encoded_length = bytes([0x81, length])
    else:
        encoded_length = b"\x82" + length.to_bytes(2, "little")
    return bytes([tag]) + encoded_length + value


def aa55(sequence: int, command_type: int, payload: bytes, flags: int = 0xC1) -> bytes:
    declared_length = 2 + 1 + 1 + len(payload) + 2
    packet_without_checksum = (
        b"\xaa\x55\xff\xff"
        + declared_length.to_bytes(2, "little")
        + sequence.to_bytes(2, "little")
        + bytes([flags, command_type])
        + payload
    )
    checksum = sum(packet_without_checksum) & 0xFFFF
    return packet_without_checksum + checksum.to_bytes(2, "little")


def program_header() -> bytes:
    return b"".join(
        [
            tlv(0x08, (0).to_bytes(2, "little")),
            tlv(0x09, b"\x01"),
            tlv(0x0C, b"\x00"),
            tlv(0x1C, bytes.fromhex("00 00 03 00 03 00")),
            tlv(0x0D, b"\x00"),
            tlv(0x1D, bytes.fromhex("00 00 00 00 30 00 10 00 00")),
        ]
    )


def graphic_item() -> bytes:
    return b"".join(
        [
            tlv(0x09, b"\x01"),
            tlv(0x0C, b"\x00"),
            tlv(0x0D, b"\x00"),
            tlv(0x0E, b"\x00"),
            tlv(0x14, bytes.fromhex("01 0d 03")),
            tlv(0x11, bytes.fromhex("00 01 00 0a")),
        ]
    )


def test_program_header_matches_sanitized_spec_vector():
    encoded = aa55(1, 0x02, program_header())
    expected = bytes.fromhex(DETAILS["program_upload"]["example_program_header_hex"])

    assert encoded == expected
    assert len(encoded) == int.from_bytes(encoded[4:6], "little") + 6
    assert int.from_bytes(encoded[-2:], "little") == sum(encoded[:-2]) & 0xFFFF
    assert encoded[10:14] == bytes.fromhex("08 02 00 00")


def test_graphic_item_matches_sanitized_spec_vector():
    encoded = aa55(2, 0x02, graphic_item())
    expected = bytes.fromhex(DETAILS["program_upload"]["example_graphic_item_hex"])

    assert encoded == expected
    assert len(encoded) == int.from_bytes(encoded[4:6], "little") + 6
    assert int.from_bytes(encoded[-2:], "little") == sum(encoded[:-2]) & 0xFFFF


def test_tlv_lengths_cover_short_extended_and_capture_chunk_sizes():
    assert tlv(0x13, b"abc") == bytes.fromhex("13 03 61 62 63")
    assert tlv(0x13, bytes(196))[:3] == bytes.fromhex("13 81 c4")
    assert tlv(0x13, bytes(960))[:4] == bytes.fromhex("13 82 c0 03")
    assert tlv(0x13, bytes(4551))[:4] == bytes.fromhex("13 82 c7 11")


def test_capture_chunk_accounting_and_delete_only_packet_is_not_upload():
    example = DETAILS["program_upload"]["geometry_examples"]
    whole, remainder = divmod(example["gif_bytes"], example["maximum_chunk_bytes"])

    assert (whole, remainder) == (4, 711)
    assert example["logical_chunks"] == whole + bool(remainder) == 5
    assert DETAILS["program_upload"]["sequence"] != [
        "08 02 00 00"
    ]
    assert "replaces" in DETAILS["program_upload"]["storage_effect"]


def test_query_vector_checksum_and_declared_length():
    raw = bytes.fromhex(DETAILS["read_only_identification"]["source_derived_query_hex"])

    assert len(raw) == 20
    assert len(raw) == int.from_bytes(raw[4:6], "little") + 6
    assert int.from_bytes(raw[-2:], "little") == sum(raw[:-2]) & 0xFFFF



def encode_ystp01(
    width: int,
    height: int,
    delay: int,
    bits_per_pixel: int,
    palette: list[tuple[int, int, int]],
    pages: list,
) -> bytes:
    palette_bytes = b"".join(bytes(entry) for entry in palette)
    if bits_per_pixel == 24:
        assert palette == []
    else:
        assert len(palette) == 1 << bits_per_pixel

    packed_pages = []
    stride = (width * bits_per_pixel + 7) // 8
    for page in pages:
        assert len(page) == height
        for row in page:
            assert len(row) == width
            if bits_per_pixel == 24:
                packed_pages.append(b"".join(bytes(pixel) for pixel in row))
                continue

            packed = bytearray()
            accumulator = 0
            bit_count = 0
            for index in row:
                assert 0 <= index < len(palette)
                accumulator |= index << bit_count
                bit_count += bits_per_pixel
                while bit_count >= 8:
                    packed.append(accumulator & 0xFF)
                    accumulator >>= 8
                    bit_count -= 8
            if bit_count:
                packed.append(accumulator & 0xFF)
            assert len(packed) == stride
            packed_pages.append(bytes(packed))

    encoded = (
        b"YSTP01"
        + width.to_bytes(2, "little")
        + height.to_bytes(2, "little")
        + len(pages).to_bytes(2, "little")
        + delay.to_bytes(2, "little")
        + bytes([bits_per_pixel])
        + palette_bytes
        + b"".join(packed_pages)
    )
    assert len(encoded) == 15 + len(palette_bytes) + len(pages) * height * stride
    return encoded


def decode_ystp01(data: bytes) -> dict:
    assert data.startswith(b"YSTP01")
    width = int.from_bytes(data[6:8], "little")
    height = int.from_bytes(data[8:10], "little")
    page_count = int.from_bytes(data[10:12], "little")
    delay = int.from_bytes(data[12:14], "little")
    bits_per_pixel = data[14]
    palette_size = 1 << bits_per_pixel if bits_per_pixel <= 8 else 0
    palette = []
    for index in range(palette_size):
        offset = 15 + index * 3
        palette.append(tuple(data[offset : offset + 3]))

    stride = (width * bits_per_pixel + 7) // 8
    offset = 15 + 3 * palette_size
    pages = []
    for _ in range(page_count):
        page = []
        for y in range(height):
            row = []
            for x in range(width):
                if bits_per_pixel == 24:
                    row.append(tuple(data[offset : offset + 3]))
                    offset += 3
                else:
                    bit_offset = y * stride * 8 + x * bits_per_pixel
                    shift = bit_offset & 7
                    mask = (1 << bits_per_pixel) - 1
                    row.append((data[offset + bit_offset // 8] >> shift) & mask)
            page.append(row)
        pages.append(page)
        if bits_per_pixel != 24:
            offset += stride * height

    assert offset == len(data)
    return {
        "width": width,
        "height": height,
        "delay": delay,
        "bits_per_pixel": bits_per_pixel,
        "palette": palette,
        "pages": pages,
    }


def test_ystp01_rgb888_vector_round_trip():
    vector = DETAILS["program_upload"]["ystp01"]["synthetic_vectors"]["rgb888_2x2"]
    pages = [
        [[tuple(pixel) for pixel in row] for row in page]
        for page in vector["expected_pages"]
    ]

    encoded = encode_ystp01(
        vector["width"],
        vector["height"],
        vector["delay_raw"],
        vector["bits_per_pixel"],
        [],
        pages,
    )
    assert encoded == bytes.fromhex(vector["media_hex"])
    assert len(encoded) == vector["expected_total_bytes"]
    assert sha256(encoded).hexdigest() == vector["expected_sha256"]

    decoded = decode_ystp01(encoded)
    assert decoded["width"] == vector["width"]
    assert decoded["height"] == vector["height"]
    assert decoded["delay"] == vector["delay_raw"]
    assert decoded["bits_per_pixel"] == 24
    assert decoded["palette"] == []
    assert decoded["pages"] == pages


def test_ystp01_palettized_two_page_vector_round_trip():
    vector = DETAILS["program_upload"]["ystp01"]["synthetic_vectors"][
        "palettized8_2x1_two_pages"
    ]
    palette = [(index, index, index) for index in range(256)]

    encoded = encode_ystp01(
        vector["width"],
        vector["height"],
        vector["delay_raw"],
        vector["bits_per_pixel"],
        palette,
        vector["expected_pages"],
    )
    assert len(encoded) == vector["expected_total_bytes"] == 787
    assert sha256(encoded).hexdigest() == vector["expected_sha256"]

    decoded = decode_ystp01(encoded)
    assert decoded["width"] == vector["width"]
    assert decoded["height"] == vector["height"]
    assert decoded["delay"] == vector["delay_raw"]
    assert decoded["bits_per_pixel"] == 8
    assert decoded["palette"] == palette
    assert decoded["pages"] == vector["expected_pages"]


def test_ordinary_ack_status_layout_success_and_synthetic_rejection():
    acknowledgement = DETAILS["aa55_framing"]["ordinary_ack"]
    success = aa55(0x16, 0x82, b"\x00", flags=0x81)
    rejection = aa55(0x16, 0x82, b"\x01", flags=0x81)

    assert success == bytes.fromhex(acknowledgement["success_response_hex"])
    assert rejection == bytes.fromhex(
        acknowledgement["synthetic_nonzero_response_hex"]
    )
    status = acknowledgement["status"]
    for raw, expected_status in ((success, 0), (rejection, 1)):
        assert len(raw) == acknowledgement["full_frame_bytes"] == 13
        assert len(raw) == int.from_bytes(raw[4:6], "little") + 6
        assert int.from_bytes(raw[6:8], "little") == 0x16
        assert raw[8] == 0x81
        assert raw[9] == 0x82
        assert raw[status["offset"]] == expected_status
        assert int.from_bytes(raw[-2:], "little") == sum(raw[:-2]) & 0xFFFF
    assert success[status["offset"]] == status["success_value"]
    assert rejection[status["offset"]] != status["success_value"]



def test_media_chunk_repeats_item_prefix_and_metadata():
    vector = DETAILS["program_upload"]["media_chunks"]["synthetic_vector"]
    item_prefix = (
        tlv(0x09, b"\x01")
        + tlv(0x0C, bytes([vector["program_index"]]))
        + tlv(0x0D, bytes([vector["region_index"]]))
        + tlv(0x0E, bytes([vector["item_index"]]))
    )
    metadata = (
        vector["chunk_count"].to_bytes(2, "little")
        + vector["chunk_index"].to_bytes(2, "little")
        + vector["maximum_chunk_bytes"].to_bytes(2, "little")
        + b"\x00"
    )
    encoded = aa55(
        vector["sequence"],
        0x02,
        item_prefix
        + tlv(0x12, metadata)
        + tlv(0x13, bytes.fromhex(vector["media_hex"])),
    )

    assert encoded == bytes.fromhex(vector["packet_hex"])
    assert len(encoded) == vector["total_bytes"] == 38
    assert encoded[10:22] == item_prefix


def test_resource_id_uses_one_based_program_number_and_spaced_input_hex():
    vector = DETAILS["program_upload"]["resource_id"]["synthetic_vector"]
    data = bytes.fromhex(vector["input_hex"])
    prefix = (str(vector["app_program_number"]) + "0000000")[:8]
    spaced_hex = " ".join(f"{value:02x}" for value in data)
    resource = bytes.fromhex(prefix + md5(spaced_hex.encode()).hexdigest())

    assert vector["app_program_number"] == vector["wire_program_index"] + 1
    assert prefix == vector["expected_prefix_ascii"] == "10000000"
    assert spaced_hex == vector["input_description"]
    assert resource == bytes.fromhex(vector["expected_resource_id_hex"])
    assert len(resource) == 20


def test_playback_selection_layout_matches_capture():
    vector = DETAILS["playback"]["selection_vector"]
    value = bytes([vector["model"], vector["index"], *vector["ids_zero_based"]])
    encoded = aa55(vector["sequence"], 0x02, tlv(0x36, value))

    assert value.hex(" ") == vector["tlv_value_hex"]
    assert encoded == bytes.fromhex(vector["packet_hex"])
    assert [program + 1 for program in vector["ids_zero_based"]] == vector[
        "ids_one_based_decoded"
    ]


def test_upgrade_ack_status_layout_success_and_synthetic_rejection():
    acknowledgement = DETAILS["aa55_framing"]["upgrade_ack"]
    success = aa55(0, 0x84, b"\x00", flags=0x81)
    rejection = aa55(0, 0x84, b"\x01", flags=0x81)

    assert success == bytes.fromhex(acknowledgement["success_response_hex"])
    assert rejection == bytes.fromhex(
        acknowledgement["synthetic_nonzero_response_hex"]
    )
    status = acknowledgement["status"]
    for raw, expected_status in ((success, 0), (rejection, 1)):
        assert len(raw) == acknowledgement["full_frame_bytes"] == 13
        assert raw[8] == 0x81
        assert raw[9] == 0x84
        assert raw[status["offset"]] == expected_status
        assert int.from_bytes(raw[-2:], "little") == sum(raw[:-2]) & 0xFFFF
    assert success[status["offset"]] == status["success_value"]
    assert rejection[status["offset"]] != status["success_value"]
