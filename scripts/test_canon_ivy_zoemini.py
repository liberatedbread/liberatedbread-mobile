"""Independent implementation checks for the Canon PV-223 specification.

The encoders, decoders, stream reassembler and completion tracker below are
transcribed from ``device-specs/devices/canon-ivy-zoemini.yaml``. They import
no Canon code and none of the pinned public client's code. Only Python's
standard library implements the protocol; pytest and PyYAML load and run the
checks against the spec's own full-frame vectors.

The upstream project's hardware results remain ``reported`` evidence. These
tests prove that the document is internally implementable, not that this
project has driven a printer.
"""

from __future__ import annotations

import struct
from pathlib import Path

import pytest
import yaml

REPO_ROOT = Path(__file__).resolve().parent.parent
SPEC_PATH = REPO_ROOT / "device-specs" / "devices" / "canon-ivy-zoemini.yaml"

FRAME_LEN = 34
PAYLOAD_LEN = 26
COMMAND_START = b"\x43\x0f"
RESPONSE_START = b"\x43\xf0"


@pytest.fixture(scope="module")
def spec() -> dict:
    return yaml.safe_load(SPEC_PATH.read_text(encoding="utf-8"))


@pytest.fixture(scope="module")
def vectors(spec: dict) -> dict:
    return spec["protocol_details"]["test_vectors"]


def wire_bytes(vector: dict) -> bytes:
    return bytes.fromhex(vector["hex"])


def build_request(
    command: int,
    payload: bytes = b"",
    *,
    session: bool = False,
    write: bool = False,
) -> bytes:
    """Per protocol_details.frame_layout and commands[] request headers."""
    if len(payload) > PAYLOAD_LEN:
        raise ValueError("payload exceeds 26 bytes")
    device_type, device_code = (0xFFFF, 0xFF) if session else (0x0001, 0x20)
    header = COMMAND_START + struct.pack(
        ">HBHB", device_type, device_code, command, int(write)
    )
    return (header + payload).ljust(FRAME_LEN, b"\x00")


def build_response(command: int, payload: bytes = b"", *, status: int = 0) -> bytes:
    """Independent response constructor used for negative status cases."""
    if len(payload) > PAYLOAD_LEN:
        raise ValueError("payload exceeds 26 bytes")
    header = RESPONSE_START + struct.pack(">HBHB", 0x0001, 0x21, command, status)
    return (header + payload).ljust(FRAME_LEN, b"\x00")


def decode_header(frame: bytes) -> dict[str, int]:
    """Per protocol_details.frame_layout; reject truncation and bad start bytes."""
    if len(frame) != FRAME_LEN:
        raise ValueError(f"expected 34 bytes, got {len(frame)}")
    if frame[:2] not in (COMMAND_START, RESPONSE_START):
        raise ValueError("unknown frame start")
    device_type, device_code, command, status = struct.unpack(">HBHB", frame[2:8])
    return {
        "device_type": device_type,
        "device_code": device_code,
        "command": command,
        "status": status,
    }


def decode_declared_fields(frame: bytes, fields: list[dict]) -> dict[str, object]:
    """Decode a command's response.format offsets, widths, endianness and masks."""
    if len(frame) != FRAME_LEN:
        raise ValueError("expected a complete frame")
    decoded: dict[str, object] = {}
    for field in fields:
        start = field["offset"]
        end = start + field["length"]
        raw_bytes = frame[start:end]
        kind = field["type"]
        if kind == "bytes":
            decoded[field["name"]] = raw_bytes
            continue
        if kind == "string":
            decoded[field["name"]] = raw_bytes.decode("utf-8")
            continue
        raw = int.from_bytes(
            raw_bytes,
            field.get("endianness", "little"),
            signed=kind.startswith("int"),
        )
        if "mask" in field:
            mask = field["mask"]
            raw = (raw & mask) >> ((mask & -mask).bit_length() - 1)
        decoded[field["name"]] = raw * field.get("scale", 1) + field.get("value_offset", 0)
    return decoded


def decode_status(frame: bytes, spec: dict) -> dict[str, object]:
    fields = spec["commands"]["get_status"]["response"]["format"]
    return decode_declared_fields(frame, fields)


def decode_session(frame: bytes, spec: dict) -> dict[str, object]:
    fields = spec["commands"]["start_session"]["response"]["format"]
    return decode_declared_fields(frame, fields)


def decode_settings(frame: bytes, spec: dict) -> dict[str, object]:
    fields = spec["commands"]["get_settings"]["response"]["format"]
    return decode_declared_fields(frame, fields)


def decode_info(frame: bytes) -> dict[str, object]:
    """Per protocol_details.get_info_payload's length-prefixed dynamic layout."""
    header = decode_header(frame)
    if header["command"] != 0x0102:
        raise ValueError("not a GET_INFO response")
    payload = frame[8:]
    n = payload[6]
    model_length_offset = 7 + n
    if model_length_offset >= len(payload):
        raise ValueError("serial length exceeds payload")
    m = payload[model_length_offset]
    model_start = 8 + n
    model_end = model_start + m
    if model_end > len(payload):
        raise ValueError("model length exceeds payload")
    return {
        "product_code": header["device_code"],
        "address": ":".join(f"{octet:02x}" for octet in payload[:6]),
        "serial": payload[7 : 7 + n].decode("utf-8"),
        "model": payload[model_start:model_end].decode("utf-8"),
        "padding": payload[model_end:],
    }


def render_command(command: dict, arguments: dict[str, int]) -> bytes:
    """Render commands[].value/template with the declared parameter widths."""
    if "value" in command:
        if arguments:
            raise ValueError("a fixed command takes no arguments")
        return bytes(command["value"])
    rendered = bytearray()
    for element in command["template"]:
        if isinstance(element, int):
            rendered.append(element)
            continue
        name = element.strip("{}")
        parameter = command["parameters"][name]
        value = arguments[name]
        kind = parameter["type"]
        if kind == "bytes":
            rendered.extend(value)
            continue
        width = {"uint8": 1, "int8": 1, "uint16": 2, "uint32": 4}[kind]
        rendered.extend(
            int(value).to_bytes(
                width,
                parameter.get("endianness", "little"),
                signed=kind.startswith("int"),
            )
        )
    return bytes(rendered)


def status_payload(
    *,
    power: int = 0x81E4,
    error: int = 0,
    queue: int = 0,
    flags: int = 0,
    progress: int = 0,
) -> bytes:
    """Per get_status response offsets p[0] through p[6]."""
    return struct.pack(">HBBHb", power, error, queue, flags, progress)


def ready_for_print(status: dict[str, object]) -> bool:
    """Per get_status.notes: both errors zero, READY, and flags 0-4 clear."""
    return (
        status["response_status"] == 0
        and status["error_code"] == 0
        and status["queue_status"] == 0
        and status["queue_flags"] & 0x1F == 0
    )


class ResponseReader:
    """RFCOMM reassembly per protocol_details.frame_layout.receive_rule."""

    def __init__(self) -> None:
        self.buffer = bytearray()
        self.discarded = 0

    def feed(self, data: bytes) -> list[bytes]:
        self.buffer.extend(data)
        frames = []
        while True:
            start = self.buffer.find(RESPONSE_START)
            if start < 0:
                keep = 1 if self.buffer.endswith(RESPONSE_START[:1]) else 0
                self.discarded += len(self.buffer) - keep
                del self.buffer[: len(self.buffer) - keep]
                return frames
            if start:
                self.discarded += start
                del self.buffer[:start]
            if len(self.buffer) < FRAME_LEN:
                return frames
            frames.append(bytes(self.buffer[:FRAME_LEN]))
            del self.buffer[:FRAME_LEN]


class PrintCompletion:
    """Per protocol_details.print_session.completion; ACK is not completion."""

    def __init__(self, spec: dict) -> None:
        self.spec = spec
        self.started = False

    def feed(self, frame: bytes) -> str:
        header = decode_header(frame)
        if header["command"] == 0x0302:
            if header["status"]:
                return "failed"
            return "received"
        if header["command"] != 0x0101:
            raise ValueError("unexpected frame during completion polling")
        status = decode_status(frame, self.spec)
        queue = status["queue_status"]
        error = status["error_code"]
        if queue == 0x10 or 0x21 <= error <= 0x24:
            return "failed"
        if queue in (0x01, 0x04):
            self.started = True
            return "printing"
        if queue == 0 and (self.started or status["print_progress"] >= 100):
            return "complete"
        return "waiting"


def test_every_published_frame_is_exactly_34_bytes(vectors: dict) -> None:
    for group, start in (("requests", COMMAND_START), ("responses", RESPONSE_START)):
        for name, vector in vectors[group].items():
            frame = wire_bytes(vector)
            assert len(frame) == FRAME_LEN, f"{group}.{name}: {len(frame)} bytes"
            assert frame.startswith(start), f"{group}.{name}: wrong direction"


def test_independent_request_encoder_reproduces_vectors(vectors: dict) -> None:
    requests = vectors["requests"]
    jpeg_size = requests["print_ready"]["arguments"]["jpeg_size"]
    built = {
        "start_session": build_request(0x0000, session=True),
        "get_status": build_request(0x0101),
        "get_info": build_request(0x0102),
        "get_settings": build_request(0x0103),
        "set_auto_power_off": build_request(
            0x0103,
            bytes([requests["set_auto_power_off"]["arguments"]["minutes"]]),
            write=True,
        ),
        "print_ready": build_request(0x0301, struct.pack(">IBB", jpeg_size, 1, 1)),
        "reboot": build_request(0xFFFF, b"\x01", write=True),
    }
    assert set(built) == set(requests)
    for name, frame in built.items():
        assert frame == wire_bytes(requests[name]), name


def test_spec_command_templates_reproduce_the_same_vectors(spec: dict, vectors: dict) -> None:
    for name, vector in vectors["requests"].items():
        arguments = vector.get("arguments", {})
        command = spec["commands"][name]
        rendered = render_command(command, arguments)
        assert rendered == wire_bytes(vector), name
        if "example_body" in command:
            assert bytes.fromhex(command["example_body"]) == rendered, name


def test_start_session_vector_decodes_power_and_mtu(spec: dict, vectors: dict) -> None:
    frame = wire_bytes(vectors["responses"]["start_session"])
    header = decode_header(frame)
    session = decode_session(frame, spec)
    assert header == {
        "device_type": 1,
        "device_code": 0x21,
        "command": 0,
        "status": 0,
    }
    assert session["session_unknown"] == 1
    assert session["battery_voltage_raw"] == 0x82
    assert session["battery_percent"] == 100
    assert session["on_mains"] == 0
    assert session["image_chunk_size"] == 0xFFFF


def test_status_ready_vector_decodes_every_declared_field(spec: dict, vectors: dict) -> None:
    status = decode_status(wire_bytes(vectors["responses"]["status_ready"]), spec)
    assert status["product_code"] == 0x21
    assert status["response_status"] == 0
    assert status["battery_voltage_raw"] == 0x81
    assert status["battery_percent"] == 100
    assert status["on_mains"] == 1
    assert status["error_code"] == 0
    assert status["queue_status"] == 0
    assert status["queue_flags"] == 0
    assert status["cover_open"] == 0
    assert status["out_of_paper"] == 0
    assert status["wrong_paper"] == 0
    assert status["calibrating"] == 0
    assert status["calibration_error"] == 0
    assert status["print_progress"] == 0
    assert ready_for_print(status)


def test_idle_media_flags_block_print_even_with_zero_error(spec: dict) -> None:
    frame = build_response(
        0x0101,
        status_payload(flags=0x0001 | 0x0002 | 0x0008),
    )
    status = decode_status(frame, spec)
    assert status["error_code"] == 0
    assert status["queue_status"] == 0
    assert status["cover_open"] == 1
    assert status["out_of_paper"] == 1
    assert status["calibrating"] == 1
    assert status["wrong_paper"] == 0
    assert status["calibration_error"] == 0
    assert not ready_for_print(status)


def test_print_ready_length_is_big_endian_and_has_observed_constants(vectors: dict) -> None:
    vector = vectors["requests"]["print_ready"]
    frame = wire_bytes(vector)
    assert int.from_bytes(frame[8:12], "big") == vector["arguments"]["jpeg_size"] == 1_157_644
    assert frame[12:14] == b"\x01\x01"
    assert frame[14:] == bytes(20)


def test_info_vector_uses_bounded_length_prefixed_strings(vectors: dict) -> None:
    info = decode_info(wire_bytes(vectors["responses"]["get_info"]))
    assert info == {
        "product_code": 0x21,
        "address": "02:00:00:00:00:01",
        "serial": "XXFTEST00001",
        "model": "PV223",
        "padding": b"\x00",
    }


def test_info_decoder_rejects_a_length_past_the_payload(vectors: dict) -> None:
    frame = bytearray(wire_bytes(vectors["responses"]["get_info"]))
    frame[14] = 19  # Leaves no room for even the model-length byte in 26 bytes.
    with pytest.raises(ValueError, match="serial length exceeds payload"):
        decode_info(bytes(frame))


def test_settings_vector_decodes_versions_counter_and_unknowns(spec: dict, vectors: dict) -> None:
    settings = decode_settings(wire_bytes(vectors["responses"]["get_settings"]), spec)
    assert settings["auto_power_off_minutes"] == 3
    assert settings["firmware_version"] == b"\x01\x04\x0d"
    assert ".".join(str(part) for part in settings["firmware_version"]) == "1.4.13"
    assert settings["settings_unknown_4"] == 5
    assert settings["tmd_version"] == 24
    assert settings["photos_printed"] == 11
    assert settings["colour_id"] == 0
    assert settings["settings_unknown_9_10"] == 2


def test_stream_reassembly_handles_noise_split_coalesced_and_trailing_header(
    vectors: dict,
) -> None:
    ready = wire_bytes(vectors["responses"]["status_ready"])
    preparing = wire_bytes(vectors["responses"]["status_preparing_25"])
    complete = wire_bytes(vectors["responses"]["status_ready_complete"])
    reader = ResponseReader()

    assert reader.feed(b"\x99" + ready[:11]) == []
    assert reader.feed(ready[11:] + preparing + b"\x43") == [ready, preparing]
    assert reader.feed(b"\xf0" + complete[2:17]) == []
    assert reader.feed(complete[17:]) == [complete]
    assert reader.discarded == 1
    assert reader.buffer == b""


def test_receive_ack_is_not_completion_then_status_timeline_completes(
    spec: dict,
    vectors: dict,
) -> None:
    tracker = PrintCompletion(spec)
    responses = vectors["responses"]
    sequence = [
        "print_receive_ack",
        "status_preparing_25",
        "status_printing_50",
        "status_ready_complete",
    ]
    assert [tracker.feed(wire_bytes(responses[name])) for name in sequence] == [
        "received",
        "printing",
        "printing",
        "complete",
    ]


def test_ready_without_print_activity_or_100_is_not_completion(spec: dict, vectors: dict) -> None:
    tracker = PrintCompletion(spec)
    frame = wire_bytes(vectors["responses"]["status_ready"])
    assert tracker.feed(frame) == "waiting"


def test_paper_jam_is_a_failure_even_when_error_code_is_zero(spec: dict) -> None:
    tracker = PrintCompletion(spec)
    frame = build_response(0x0101, status_payload(queue=0x10, progress=50))
    assert tracker.feed(frame) == "failed"


def test_session_chunking_respects_public_cap_and_unknown_mtu_fallback(spec: dict) -> None:
    notes = spec["commands"]["send_jpeg"]["notes"]
    assert "4096" in notes and "650" in notes

    def chunks(length: int, mtu: int) -> list[int]:
        size = min(mtu, 4096) if mtu else 650
        return [len(data) for data in (memoryview(bytes(length))[i : i + size] for i in range(0, length, size))]

    assert chunks(10_000, 0xFFFF) == [4096, 4096, 1808]
    assert chunks(1301, 0) == [650, 650, 1]


def test_scope_generation_boundary_and_firmware_negative_answer(spec: dict) -> None:
    models = [variant["model"] for variant in spec["device"]["variants"]]
    assert models == ["Ivy 2", "Zoemini 2", "iNSPiC PV-223"]
    scope = spec["protocol_details"]["scope"]
    assert scope["excluded_models"] == ["PV-123", "ZV-123", "ZV-223"]

    inquiry = spec["device"]["discovery"]["methods"][0]["bt_classic"]
    assert len(inquiry["service_uuids"]) == 4
    assert "00001101-0000-1000-8000-00805f9b34fb" in inquiry["service_uuids"]
    assert "00500056-0223-0000-0000-000000000000" in inquiry["service_uuids"]

    assert not [feature for feature in spec["features"] if feature["type"] == "firmware_update"]
    firmware = spec["protocol_details"]["firmware_update"]
    assert firmware["specified"] is False
    assert firmware["commands"] == []
    assert firmware["do_not_send"] == ["0x0201", "0x0202", "0x0203"]

    forbidden = {0x0201, 0x0202, 0x0203}
    for command in spec["commands"].values():
        envelope = command.get("value", command.get("template"))
        if len(envelope) >= 7 and envelope[:2] == [0x43, 0x0F]:
            assert int.from_bytes(bytes(envelope[5:7]), "big") not in forbidden


def test_no_hardware_or_completion_claim_is_overstated(spec: dict) -> None:
    assert spec["device"]["testing"]["status"] == "untested"
    completion = spec["protocol_details"]["print_session"]["completion"]
    assert completion["receive_ack_is_completion"] is False
    assert completion["poll_interval_seconds_min"] == 2
    assert completion["poll_interval_seconds_max"] == 5

    def verification_values(node: object) -> list[str]:
        if isinstance(node, dict):
            return [
                value
                for key, child in node.items()
                for value in (
                    [child]
                    if key == "verification" and isinstance(child, str)
                    else verification_values(child)
                )
            ]
        if isinstance(node, list):
            return [value for child in node for value in verification_values(child)]
        return []

    assert verification_values(spec)
    assert set(verification_values(spec)) <= {"reported", "hypothesis"}
