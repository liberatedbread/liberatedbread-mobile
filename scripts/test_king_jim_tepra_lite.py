"""Independent vectors for the LR30 depth, raster and print sequencing rules.

The algorithms below use only the Python standard library. PyYAML is used to
check that the machine-readable spec carries the same vectors and command
references; no LR30 or reference-client code is imported.
"""

from __future__ import annotations

from pathlib import Path

import pytest
import yaml

SPEC_PATH = Path(__file__).resolve().parent.parent / "device-specs/devices/king-jim-tepra-lite.yaml"
PAIR_ORDER = (6, 7, 4, 5, 2, 3, 0, 1, 14, 15, 12, 13, 10, 11, 8, 9)
DEPTH_VECTORS = {
    -3: "F0 5B 13 06",
    -2: "F0 5B 12 06",
    -1: "F0 5B 11 06",
    0: "F0 5B 00 06",
    1: "F0 5B 01 06",
    2: "F0 5B 02 06",
    3: "F0 5B 03 06",
}
WIDTH_VECTORS = (
    {
        "source_width_pixels": 1,
        "padded_width_pixels": 84,
        "left_padding_pixels": 42,
        "encoded_bytes": 672,
        "data_writes": 42,
        "batch_acks": 7,
        "trailing_writes_without_batch_ack": 0,
    },
    {
        "source_width_pixels": 83,
        "padded_width_pixels": 84,
        "left_padding_pixels": 1,
        "encoded_bytes": 672,
        "data_writes": 42,
        "batch_acks": 7,
        "trailing_writes_without_batch_ack": 0,
    },
    {
        "source_width_pixels": 85,
        "padded_width_pixels": 86,
        "left_padding_pixels": 1,
        "encoded_bytes": 688,
        "data_writes": 43,
        "batch_acks": 7,
        "trailing_writes_without_batch_ack": 1,
    },
    {
        "source_width_pixels": 96,
        "padded_width_pixels": 96,
        "left_padding_pixels": 0,
        "encoded_bytes": 768,
        "data_writes": 48,
        "batch_acks": 8,
        "trailing_writes_without_batch_ack": 0,
    },
)
COLUMN_0_Y = (56, 49, 42, 35, 28, 21, 14, 7)
COLUMN_1_Y = (63, 54, 45, 36, 27, 18, 9, 0)
EXPECTED_ROW_0 = bytes.fromhex("01 02 04 08 10 20 40 80")
EXPECTED_ROW_1 = bytes.fromhex("80 40 20 10 08 04 02 01")
EXPECTED_WIRE_WRITE = bytes.fromhex("F0 5C 40 80 10 20 04 08 01 02 02 01 08 04 20 10 80 40")


@pytest.fixture(scope="module")
def spec() -> dict:
    return yaml.safe_load(SPEC_PATH.read_text())


@pytest.fixture(scope="module")
def commands(spec: dict) -> dict:
    print_service = next(service for service in spec["services"] if service["uuid"].endswith("fff0-0000-1000-8000-00805f9b34fb"))
    tx = next(
        characteristic
        for characteristic in print_service["characteristics"]
        if characteristic["uuid"] == "0000fff2-0000-1000-8000-00805f9b34fb"
    )
    return tx["commands"]


def from_hex(value: str) -> bytes:
    return bytes(int(byte, 16) for byte in value.split())


def depth_code(depth: int) -> int:
    if not -3 <= depth <= 3:
        raise ValueError("LR30 depth must be in -3..3")
    return 0x10 - depth if depth < 0 else depth


def depth_frame(depth: int) -> bytes:
    return bytes((0xF0, 0x5B, depth_code(depth), 0x06))


def padded_width(source_width: int) -> int:
    if source_width < 1:
        raise ValueError("source width must be positive")
    width = max(84, source_width)
    return width + (width % 2)


def left_padding(source_width: int) -> int:
    return padded_width(source_width) // 2 - source_width // 2


def encode_columns(width: int, black_pixels: set[tuple[int, int]]) -> bytes:
    """Pack source columns directly using byte 7-y//8, bit y%8."""
    encoded = bytearray()
    for x in range(width):
        row = bytearray(8)
        for y in range(64):
            if (x, y) in black_pixels:
                row[7 - y // 8] |= 1 << (y % 8)
        encoded.extend(row)
    return bytes(encoded)


def render(source_width: int, source_black_pixels: set[tuple[int, int]]) -> bytes:
    width = padded_width(source_width)
    offset = left_padding(source_width)
    for x, y in source_black_pixels:
        assert 0 <= x < source_width and 0 <= y < 64
    padded_black_pixels = {(x + offset, y) for x, y in source_black_pixels}
    return encode_columns(width, padded_black_pixels)


def permute_pair(source_block: bytes) -> bytes:
    if len(source_block) != 16:
        raise ValueError("one wire pair needs exactly 16 source bytes")
    return bytes(source_block[index] for index in PAIR_ORDER)


def raster_frame(source_block: bytes) -> bytes:
    return bytes((0xF0, 0x5C)) + permute_pair(source_block)


def raster_writes(encoded: bytes) -> list[tuple[bytes, bool]]:
    """Return (18-byte write, wait for F1 5C after this write)."""
    if len(encoded) % 16:
        raise ValueError("encoded raster must be 16-byte aligned")
    writes = []
    for offset in range(0, len(encoded), 16):
        write_number = offset // 16 + 1
        writes.append((raster_frame(encoded[offset : offset + 16]), write_number % 6 == 0))
    return writes


def job_events(encoded: bytes, depth: int = 0) -> list[tuple[str, bytes | str]]:
    events: list[tuple[str, bytes | str]] = [
        ("write", bytes((0xF0, 0x5A))),
        ("wait", "F1 5A"),
        ("write", depth_frame(depth)),
        ("wait", "F1 5B"),
    ]
    for frame, batch_complete in raster_writes(encoded):
        events.append(("write", frame))
        if batch_complete:
            events.append(("wait", "F1 5C"))
    events.extend(
        [
            ("write", bytes((0xF0, 0x5D, 0x00))),
            ("wait", "F1 5D 00"),
            ("write", bytes((0xF0, 0x5E))),
            ("wait", "F1 5E"),
        ]
    )
    return events


def poll_state(reply: bytes) -> str:
    if len(reply) != 4 or reply[:2] != bytes((0xF1, 0x5E)):
        raise ValueError("not a four-byte F1 5E poll reply")
    if reply[2] == 0x01:
        return "busy"
    if reply[2] == 0x00:
        return "complete"
    raise ValueError("unmapped poll state")


@pytest.mark.parametrize(("depth", "expected"), DEPTH_VECTORS.items())
def test_depth_sign_magnitude_vectors(depth: int, expected: str) -> None:
    assert depth_frame(depth) == from_hex(expected)


@pytest.mark.parametrize("depth", (-4, 4))
def test_depth_rejects_values_outside_the_established_range(depth: int) -> None:
    with pytest.raises(ValueError, match="-3..3"):
        depth_frame(depth)


def test_spec_carries_the_independent_depth_vectors(spec: dict, commands: dict) -> None:
    vectors = spec["protocol_details"]["test_vectors"]["depth"]
    assert [from_hex(vector["write_hex"]) for vector in vectors] == [
        depth_frame(depth) for depth in range(-3, 4)
    ]
    parameter = commands["set_print_depth"]["parameters"]["depth"]
    labels = dict(zip(parameter["allowed"], parameter["labels"], strict=True))
    for depth in range(-3, 4):
        expected_label = str(depth) if depth == 0 else f"{depth:+d}"
        assert labels[depth_code(depth)] == expected_label
    upload = next(feature for feature in spec["features"] if feature["type"] == "image_upload")
    assert upload["print_density"]["allowed"] == parameter["allowed"]
    assert upload["print_density"]["labels"] == parameter["labels"]
    assert upload["print_density"]["command"] == "set_print_depth"


def test_rotation_row_packing_and_pair_permutation(spec: dict) -> None:
    black_pixels = {(0, y) for y in COLUMN_0_Y} | {(1, y) for y in COLUMN_1_Y}
    encoded = encode_columns(2, black_pixels)
    assert encoded[:8] == EXPECTED_ROW_0
    assert encoded[8:] == EXPECTED_ROW_1
    assert len(encoded) == 16
    assert raster_frame(encoded) == EXPECTED_WIRE_WRITE
    assert len(EXPECTED_WIRE_WRITE) == 18

    vector = spec["protocol_details"]["test_vectors"]["raster_pair"]
    assert vector["black_pixels"]["column_0_y"] == list(COLUMN_0_Y)
    assert vector["black_pixels"]["column_1_y"] == list(COLUMN_1_Y)
    assert from_hex(vector["encoded_row_0_hex"]) == EXPECTED_ROW_0
    assert from_hex(vector["encoded_row_1_hex"]) == EXPECTED_ROW_1
    assert from_hex(vector["wire_write_hex"]) == EXPECTED_WIRE_WRITE


def test_sixteen_byte_alignment_is_enforced() -> None:
    with pytest.raises(ValueError, match="16-byte aligned"):
        raster_writes(bytes(15))
    with pytest.raises(ValueError, match="exactly 16"):
        permute_pair(bytes(17))


@pytest.mark.parametrize("vector", WIDTH_VECTORS, ids=lambda item: f"source-{item['source_width_pixels']}")
def test_width_padding_and_batch_sequence(vector: dict) -> None:
    source_width = vector["source_width_pixels"]
    assert padded_width(source_width) == vector["padded_width_pixels"]
    assert left_padding(source_width) == vector["left_padding_pixels"]

    encoded = render(source_width, {(source_width - 1, 0)})
    assert len(encoded) == vector["encoded_bytes"]
    content_row = left_padding(source_width) + source_width - 1
    for row in range(padded_width(source_width)):
        row_bytes = encoded[row * 8 : (row + 1) * 8]
        if row == content_row:
            assert row_bytes == bytes.fromhex("00 00 00 00 00 00 00 01")
        else:
            assert row_bytes == bytes(8)

    writes = raster_writes(encoded)
    assert len(writes) == vector["data_writes"]
    assert all(len(frame) == 18 for frame, _ in writes)
    acknowledged = [index for index, (_, wait) in enumerate(writes, start=1) if wait]
    assert acknowledged == list(range(6, len(writes) + 1, 6))
    assert len(acknowledged) == vector["batch_acks"]
    assert len(writes) - 6 * len(acknowledged) == vector["trailing_writes_without_batch_ack"]


def test_spec_carries_the_independent_width_vectors(spec: dict) -> None:
    assert spec["protocol_details"]["test_vectors"]["width_and_sequence"] == list(WIDTH_VECTORS)


def test_minimum_width_job_order() -> None:
    events = job_events(render(1, set()), depth=-3)
    assert events[:4] == [
        ("write", bytes((0xF0, 0x5A))),
        ("wait", "F1 5A"),
        ("write", from_hex(DEPTH_VECTORS[-3])),
        ("wait", "F1 5B"),
    ]
    data_writes = [payload for kind, payload in events if kind == "write" and isinstance(payload, bytes) and payload[:2] == b"\xf0\x5c"]
    assert len(data_writes) == 42
    assert [payload for kind, payload in events if kind == "wait"].count("F1 5C") == 7
    assert events[-4:] == [
        ("write", bytes((0xF0, 0x5D, 0x00))),
        ("wait", "F1 5D 00"),
        ("write", bytes((0xF0, 0x5E))),
        ("wait", "F1 5E"),
    ]


def test_trailing_partial_group_goes_straight_to_end() -> None:
    events = job_events(render(85, set()))
    last_data = max(
        index
        for index, (kind, payload) in enumerate(events)
        if kind == "write" and isinstance(payload, bytes) and payload[:2] == b"\xf0\x5c"
    )
    assert events[last_data + 1] == ("write", bytes((0xF0, 0x5D, 0x00)))
    assert [payload for kind, payload in events if kind == "wait"].count("F1 5C") == 7


def test_capture_derived_busy_and_complete_replies() -> None:
    assert poll_state(bytes.fromhex("F1 5E 01 00")) == "busy"
    assert poll_state(bytes.fromhex("F1 5E 00 00")) == "complete"
    with pytest.raises(ValueError, match="F1 5E"):
        poll_state(bytes.fromhex("F1 5D 01 00"))
    with pytest.raises(ValueError, match="four-byte"):
        poll_state(bytes.fromhex("F1 5E 01"))
    with pytest.raises(ValueError, match="unmapped"):
        poll_state(bytes.fromhex("F1 5E 02 00"))


def test_job_steps_and_subscription_reference_declared_targets(spec: dict, commands: dict) -> None:
    for step in spec["protocol_details"]["job_sequence"]["steps"]:
        if "command" in step:
            assert step["command"] in commands
    upload = next(feature for feature in spec["features"] if feature["type"] == "image_upload")
    assert upload["session_open"] == ["prepare", "set_print_depth"]
    assert spec["initialization"] == [
        {
            "characteristic": "0000fff1-0000-1000-8000-00805f9b34fb",
            "subscribe": True,
            "when": "connect",
            "description": "Enable printer-to-client notifications before any command or raster write.",
            "notes": "Required for prepare/depth replies, six-write flow control, end acknowledgement and busy polling.",
        }
    ]


def test_scope_and_verification_stay_within_the_evidence(spec: dict, commands: dict) -> None:
    assert spec["device"]["model"] == "LR30"
    assert "variants" not in spec["device"]
    assert spec["device"]["testing"]["status"] == "untested"
    assert all(command["verification"] == "reported" for command in commands.values())
    assert commands["write_raster_pair"]["fixed_length"] == 18
    parameter = commands["write_raster_pair"]["parameters"]["raster_pair"]
    assert (parameter["min_length"], parameter["max_length"]) == (16, 16)
