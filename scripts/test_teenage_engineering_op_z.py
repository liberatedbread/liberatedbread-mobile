#!/usr/bin/env python3
"""Independent OP-Z BLE-MIDI and source-fact checks.

The reassembler is transcribed from the YAML's standard BLE-MIDI rules and uses
only the standard library. Vectors are synthetic, not OP-Z captures. PyYAML
loads the document and pytest runs the checks; neither provides protocol logic.
"""

from pathlib import Path

import pytest
import yaml

SPEC = yaml.safe_load(
    (Path(__file__).parents[1] / "device-specs/devices/teenage-engineering-op-z.yaml").read_text()
)
DETAILS = SPEC["protocol_details"]
MIDI_SERVICE = "03b80e5a-ede8-4b33-a751-6ce34ec4c700"
MIDI_CHARACTERISTIC = "7772e5db-3868-4112-a1a9-f2669d106bf3"


def octets(text):
    return bytes.fromhex(text)


class BleMidiReassembler:
    """Stateful standard BLE-MIDI packet-to-message reassembly."""

    CHANNEL_DATA_LENGTHS = {
        0x8: 2,  # note off
        0x9: 2,  # note on
        0xA: 2,  # polyphonic pressure
        0xB: 2,  # control change
        0xC: 1,  # program change
        0xD: 1,  # channel pressure
        0xE: 2,  # pitch bend
    }
    SYSTEM_DATA_LENGTHS = {0xF1: 1, 0xF2: 2, 0xF3: 1, 0xF6: 0}

    def __init__(self):
        self.reset()

    def reset(self):
        self.current = None
        self.expected_data = None
        self.running_status = None
        self.previous_timestamp_low = None
        self.timestamp_high = 0
        self.timestamps = []

    @property
    def in_sysex(self):
        return self.current is not None and self.current[0] == 0xF0

    def feed(self, packet):
        if not packet:
            raise ValueError("empty BLE-MIDI packet")
        header = packet[0]
        if header & 0xC0 != 0x80:
            raise ValueError("missing BLE-MIDI header bits")
        self.timestamp_high = header & 0x3F
        self.previous_timestamp_low = None
        after_timestamp = False
        messages = []
        for byte in packet[1:]:
            if not after_timestamp and byte & 0x80:
                low = byte & 0x7F
                if self.previous_timestamp_low is not None and low < self.previous_timestamp_low:
                    self.timestamp_high = (self.timestamp_high + 1) & 0x3F
                self.timestamps.append((self.timestamp_high << 7) | low)
                self.previous_timestamp_low = low
                after_timestamp = True
                continue
            message = self._consume_midi_byte(byte)
            if message is not None:
                messages.append(message)
            after_timestamp = False
        return messages

    def _consume_midi_byte(self, byte):
        if byte < 0x80:
            return self._consume_data(byte)
        if byte >= 0xF8:
            # Real-time statuses complete immediately and preserve running status.
            return bytes([byte])
        if byte == 0xF7:
            if not self.in_sysex:
                raise ValueError("end of SysEx without a start")
            self.current.append(byte)
            self.running_status = None
            return self._finish_current()
        if byte == 0xF0:
            self._require_no_partial_message()
            self.running_status = None
            self.current = bytearray([byte])
            self.expected_data = None
            return None
        if byte in self.SYSTEM_DATA_LENGTHS:
            self._require_no_partial_message()
            self.running_status = None
            self.current = bytearray([byte])
            self.expected_data = self.SYSTEM_DATA_LENGTHS[byte]
            if self.expected_data == 0:
                return self._finish_current()
            return None
        if 0x80 <= byte <= 0xEF:
            self._require_no_partial_message()
            self.running_status = byte
            self.current = bytearray([byte])
            self.expected_data = self.CHANNEL_DATA_LENGTHS[byte >> 4]
            return None
        raise ValueError(f"undefined or unexpected MIDI status {byte:#x}")

    def _consume_data(self, byte):
        if self.current is None:
            if self.running_status is None:
                raise ValueError("data without a pending message or running status")
            self.current = bytearray([self.running_status])
            self.expected_data = self.CHANNEL_DATA_LENGTHS[self.running_status >> 4]
        self.current.append(byte)
        if not self.in_sysex and len(self.current) == self.expected_data + 1:
            return self._finish_current()
        return None

    def _finish_current(self):
        message = bytes(self.current)
        self.current = None
        self.expected_data = None
        return message

    def _require_no_partial_message(self):
        if self.current is not None:
            raise ValueError("new status interrupted an incomplete MIDI message")


def test_all_synthetic_ble_midi_vectors():
    vectors = DETAILS["ble_midi"]["test_vectors"]
    assert vectors["synthetic"] is True
    for name, vector in vectors.items():
        if name in {"synthetic", "description"}:
            continue
        parser = BleMidiReassembler()
        messages = []
        for notification in vector["notifications_hex"]:
            messages += parser.feed(octets(notification))
        assert messages == [octets(message) for message in vector["messages_hex"]], name
        if "expected_timestamps" in vector:
            assert parser.timestamps == vector["expected_timestamps"], name


def test_reassembly_retains_partial_sysex_and_running_status_across_calls():
    parser = BleMidiReassembler()
    assert parser.feed(octets("80 80 f0 01")) == []
    assert parser.in_sysex
    assert parser.feed(octets("80 02")) == []
    assert parser.feed(octets("80 80 f7")) == [octets("f0 01 02 f7")]

    parser = BleMidiReassembler()
    assert parser.feed(octets("80 80 c0 05 81 06")) == [
        octets("c0 05"),
        octets("c0 06"),
    ]


def test_realtime_does_not_interrupt_sysex_or_channel_running_status():
    parser = BleMidiReassembler()
    assert parser.feed(octets("80 80 b0 01 81 f8 40")) == [
        octets("f8"),
        octets("b0 01 40"),
    ]
    assert parser.running_status == 0xB0

    parser = BleMidiReassembler()
    assert parser.feed(octets("80 80 f0 01 81 f8")) == [octets("f8")]
    assert parser.in_sysex
    assert parser.feed(octets("80 02 80 f7")) == [octets("f0 01 02 f7")]


def test_reset_discards_partial_state():
    parser = BleMidiReassembler()
    parser.feed(octets("80 80 f0 01"))
    parser.reset()
    with pytest.raises(ValueError, match="without a pending message"):
        parser.feed(octets("80 02"))


def test_invalid_header_and_unexpected_data_are_rejected():
    parser = BleMidiReassembler()
    with pytest.raises(ValueError, match="header"):
        parser.feed(b"\x00")
    with pytest.raises(ValueError, match="without a pending message"):
        parser.feed(octets("80 01"))


def test_manual_selection_does_not_claim_the_generic_midi_service():
    device = SPEC["device"]
    assert device["identification"] == {}
    assert "Manual selection only" in device["discovery"]["none"]
    assert "methods" not in device["discovery"]
    assert MIDI_SERVICE not in device["identification"].get("service_uuids", [])
    service = SPEC["services"][0]
    assert service["uuid"] == MIDI_SERVICE
    assert service["characteristics"][0]["uuid"] == MIDI_CHARACTERISTIC


def test_radio_surface_is_standard_midi_without_proprietary_commands():
    assert len(SPEC["services"]) == 1
    characteristic = SPEC["services"][0]["characteristics"][0]
    assert "commands" not in characteristic
    assert "commands" not in SPEC
    assert characteristic["properties"] == ["read", "write", "notify"]
    assert [step.get("read", False) for step in SPEC["initialization"]] == [True, False]
    assert [step.get("subscribe", False) for step in SPEC["initialization"]] == [False, True]


def test_official_absolute_and_relative_incoming_map():
    rows = DETAILS["incoming_midi"]["absolute_and_relative_parameters"]
    assert len(rows) == 18
    assert [row["absolute_cc"] for row in rows] == list(range(1, 19))
    assert [row["relative_cc"] for row in rows] == list(range(32, 50))
    assert [row["name"] for row in rows[:4]] == [
        "parameter 1",
        "parameter 2",
        "filter cutoff",
        "filter resonance",
    ]
    assert rows[-1]["name"] == "note style"
    for row in rows:
        assert row["channels"] == "1-16"
        assert row["absolute_values"] == "0-127"
        assert row["relative_values"] == [1, 127]


def test_official_system_track_realtime_and_ui_map():
    system = {row["name"]: row for row in DETAILS["incoming_midi"]["system"]}
    assert system["track gain"]["cc"] == 50
    assert system["reset track gains"] == {
        "name": "reset track gains",
        "cc": 52,
        "channels": "any",
        "values": "any",
    }
    assert system["tempo"]["cc"] == 56
    assert system["select pattern"]["values"] == "0-15"
    assert system["next pattern"]["values"] == "16"
    assert system["previous pattern"]["values"] == "17"

    track = {row["name"]: row for row in DETAILS["incoming_midi"]["track"]}
    assert {name: row["cc"] for name, row in track.items()} == {
        "track step count": 60,
        "track step length": 61,
        "quantize": 62,
        "note length": 63,
    }

    realtime = {row["name"]: row for row in DETAILS["incoming_midi"]["other_and_realtime"]}
    assert realtime["start"]["status_hex"] == "fa"
    assert realtime["stop"]["status_hex"] == "fc"
    assert realtime["continue"]["status_hex"] == "fb"
    assert realtime["clock"]["status_hex"] == "f8"
    assert realtime["song pointer"]["supported"] is False
    assert realtime["active sense"]["supported"] is False

    ui = {row["name"]: row for row in DETAILS["incoming_midi"]["ui"]}
    assert ui["active track"] == {
        "name": "active track",
        "cc": 102,
        "channels": "0",
        "values": "0-15",
    }
    assert ui["parameter page"]["cc"] == 102
    assert ui["parameter page"]["channels"] == "1"
    assert ui["parameter page"]["values"] == "0-3"


def test_all_documented_midi_json_keys_and_ranges_are_present():
    settings = {row["key"]: row for row in DETAILS["midi_json"]["settings"]}
    assert set(settings) == {
        "channel_one_to_active",
        "incoming_midi",
        "outgoing_midi",
        "timing_clock_in",
        "timing_clock_out",
        "enable_program_change",
        "alt_program_change",
        "midi_echo",
        "track_enable",
        "track_channels",
        "parameter_cc_out",
    }
    assert settings["track_channels"]["range"] == "1-16"
    assert settings["parameter_cc_out"]["range"] == "0-255"
    assert settings["parameter_cc_out"]["scope"] == "per parameter per track"
    for key in (
        "channel_one_to_active",
        "incoming_midi",
        "outgoing_midi",
        "timing_clock_in",
        "timing_clock_out",
        "enable_program_change",
        "alt_program_change",
        "midi_echo",
        "track_enable",
    ):
        assert settings[key]["values"] == [True, False]
    assert "preserve" in DETAILS["midi_json"]["container_scope"].lower()


def test_all_setup_and_physical_procedures_are_unverified_and_sourced():
    for method in SPEC["device"]["setup"]["methods"]:
        assert method["verified"] is False, method["name"]
        assert method["basis"], method["name"]

    reset = SPEC["device"]["setup"]["factory_reset"]
    assert reset["applicable"] is True
    for procedure in reset["procedures"]:
        assert procedure["verified"] is False
        assert procedure["basis"]
    reset_text = " ".join(reset["procedures"][0]["steps"][index]["action"] for index in (1, 2))
    assert "screen" in reset_text
    assert "stop" in reset_text
    assert "one second" in reset_text
    assert "custom user content" in reset["effect"]

    for procedure in SPEC["device"]["pairing"]["enter_pairing_mode"]["procedures"]:
        assert procedure["verified"] is False
        assert procedure["basis"]
        assert "back of OP-Z" in procedure["steps"][1]["action"]

    for name in ("upgrade_mode", "firmware_update"):
        procedure = DETAILS["usb_procedures"][name]
        assert procedure["verified"] is False
        assert procedure["basis"]


def test_content_firmware_and_dfu_facts_stay_scoped():
    content = next(
        method
        for method in SPEC["device"]["setup"]["methods"]
        if method["name"] == "USB content-mode configuration and backup"
    )
    assert content["type"] == "device_ui"
    content_text = " ".join(step["action"] for step in content["steps"])
    assert "track" in content_text
    assert "Safely eject" in content_text
    assert "midi.json" in content_text
    assert content["steps"][0]["expect"] == "All track LEDs are green, indicating content mode."

    firmware = DETAILS["usb_procedures"]["firmware_update"]
    firmware_text = " ".join(step["action"] for step in firmware["steps"])
    assert "Copy the vendor-supplied OP-Z firmware file" in firmware_text
    assert "in full" in firmware_text
    assert "Safely eject" in firmware_text
    assert "do not power" in firmware["steps"][-1]["action"].lower()
    assert "No latest version" in firmware["version_scope"]

    feature = next(item for item in SPEC["features"] if item["type"] == "firmware_update")
    dfu = feature["dfu"]
    assert dfu["verification"] == "reported"
    assert dfu["transport"] == "usb"
    assert dfu["mechanisms"] == ["custom"]
    assert dfu["image"]["source"] == "user_supplied"
    assert dfu["enter"]["how"] == "button"
    assert dfu["recovery"]["interrupted"] == "unknown"
    assert SPEC["device"]["testing"]["status"] == "untested"
