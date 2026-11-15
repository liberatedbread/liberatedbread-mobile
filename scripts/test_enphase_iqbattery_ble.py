"""Check Enphase XBee unlock variants and provisioning frame layouts."""

import re
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
SPEC = yaml.safe_load(
    (ROOT / "device-specs" / "devices" / "enphase-iqbattery-ble.yaml").read_text(
        encoding="utf-8"
    )
)


def test_unlock_passwords_are_flow_specific():
    passwords = SPEC["protocol_details"]["unlock_passwords"]
    assert passwords["generic_library_default"] == "password"
    assert passwords["provisioning_manager_pan_and_link_key_checks"] == "030609"

    setup_text = str(SPEC["device"]["setup"])
    assert "flow-specific" in setup_text
    assert "protocol_details.unlock_passwords" in setup_text


def test_envoy_serial_write_layout():
    provisioning = SPEC["protocol_details"]["enphase_relay_protocol"][
        "provisioning_frames"
    ]
    assert provisioning["write_envoy_sn"]["frame"] == (
        "[0x07][serial_length:u8][serial_ascii]"
    )
    assert provisioning["read_requests"] == {
        "zb_read_link_key": [0x06, 0x00],
        "zb_read_envoy_sn": [0x08, 0x00],
        "read_enpower_telem": [0x09, 0x00],
    }

    # Encode a serial by following the spec's declared layout field by field,
    # so a change to the spec's frame, length rule or type byte fails here.
    serial = b"TESTGATEWAY"
    fields = re.findall(r"\[([^\]]+)\]", provisioning["write_envoy_sn"]["frame"])
    frame = b""
    for field in fields:
        if field.startswith("0x"):
            frame += bytes([int(field, 16)])
        elif field == "serial_length:u8":
            frame += bytes([len(serial)])
        elif field == "serial_ascii":
            frame += serial
        else:
            raise AssertionError(f"unexpected field {field!r} in the spec's frame")
    assert frame == bytes.fromhex("07 0b 54 45 53 54 47 41 54 45 57 41 59")
    length_rule = provisioning["write_envoy_sn"]["length"]
    extra = int(re.fullmatch(r"serial_length \+ (\d+) bytes total", length_rule)[1])
    assert len(frame) == len(serial) + extra
    frame_types = provisioning["frame_types"]
    assert "serial" in frame_types[str(frame[0])].lower()


def test_supported_scope_does_not_claim_a_live_unlock():
    device = SPEC["device"]
    assert device["integration"] == "supported"
    assert "No GATT connection was attempted" in device["testing"]["notes"]
    assert "XBee Series 2" in device["notes"]
    assert "Communications Kit 2" in device["notes"]
    assert "types 4, 5 and 8" in device["notes"]
