"""Proves the FOREO Peach 2 spec's activation algorithm is implementable.

`device-specs/devices/foreo-peach-2.yaml` claims the ship-lock unlock is
computable offline: the chipId written to characteristic 0A20 is a keyless
permutation of the device's own BLE MAC, published as pseudocode under
`protocol_details.activation.chip_id_algorithm` with test vectors beside it.

This module transcribes that pseudocode using nothing but the standard
library, importing none of our code, and asserts the transcription reproduces
the spec's own vectors. If the transcription cannot be written, or the vectors
do not reproduce, the spec is underspecified and this fails.

The vectors use the documentation MAC AA:BB:CC:DD:EE:FF, which identifies no
real unit.
"""

from __future__ import annotations

from pathlib import Path

import yaml

REPO_ROOT = Path(__file__).resolve().parent.parent
SPEC_PATH = REPO_ROOT / "device-specs" / "devices" / "foreo-peach-2.yaml"


def chip_id(mac: list[int]) -> list[int]:
    """Transcription of protocol_details.activation.chip_id_algorithm.

    mac is m0..m5 in the usual printed order. All arithmetic mod 256.
    """
    assert len(mac) == 6
    b = [mac[5], mac[4], mac[3], 0x00, 0x00, mac[2], mac[1], mac[0]]
    return [
        (b[2] & 0x0F) | (b[7] & 0xF0),
        (b[5] & 0x0F) | (b[1] & 0xF0),
        ((b[7] & 0x0F) + (0xF0 - (b[6] & 0xF0))) % 256,
        (0xFF - b[6]) % 256,
        (b[5] + 1) % 256,
        ((b[1] & 0x0F) + (0xF0 - (b[2] & 0xF0))) % 256,
        (b[0] & 0x0F) | (b[5] & 0xF0),
        (b[6] & 0x0F) | (b[0] & 0xF0),
    ]


def security_access(mac: list[int]) -> list[int]:
    """01 A1 <MAC[3]> <MAC[4]> <MAC[5]> — the per-connect handshake."""
    return [0x01, 0xA1, mac[3], mac[4], mac[5]]


def _parse(hex_bytes: str) -> list[int]:
    return [int(tok, 16) for tok in hex_bytes.split()]


def test_activation_test_vectors_reproduce() -> None:
    spec = yaml.safe_load(SPEC_PATH.read_text(encoding="utf-8"))
    vectors = spec["protocol_details"]["activation"]["test_vectors"]
    mac = _parse(vectors["input"]["ble_mac"].replace(":", " "))

    expected = {
        v["step"]: _parse(v["bytes"]) for v in vectors["vectors"]
    }

    assert security_access(mac) == expected["security_access write to 0A10"]

    derived = chip_id(mac)
    assert derived == expected[
        "chipId (payload of the 01 02 … activation write to 0A20)"
    ]

    assert [0x01, 0x02, *derived] == expected["full activation write to 0A20"]
