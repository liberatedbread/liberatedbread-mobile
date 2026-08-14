#!/usr/bin/env python3
# Copyright 2026 Pigs Can Fly Labs LLC
# SPDX-License-Identifier: Apache-2.0
"""Tests for scripts/obd_discover.py response parsing and addressing helpers."""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import obd_discover  # noqa: E402


def test_parse_spaced_response():
    """The spaced form, with and without a CAN header token."""
    assert obd_discover.parse_response("62 F1 90 01") == [[0x62, 0xF1, 0x90, 0x01]]
    # ATH1 prepends a three-character header, which is not payload.
    assert obd_discover.parse_response("7E8 06 62 F1 90 01") == [
        [0x06, 0x62, 0xF1, 0x90, 0x01]
    ]


def test_parse_compact_response():
    """Adapters with spaces off return one unbroken hex run."""
    assert obd_discover.parse_response("4100BE3FA813") == [
        [0x41, 0x00, 0xBE, 0x3F, 0xA8, 0x13]
    ]
    # Compact with a leading 11-bit CAN header: odd length, header dropped.
    assert obd_discover.parse_response("7E80662F19001") == [
        [0x06, 0x62, 0xF1, 0x90, 0x01]
    ]


def test_parse_multiframe_lines():
    """ISO-TP continuation lines carry a frame-index prefix; the length line is not payload."""
    reply = "014\n0: 49 02 01 31 32 33\n1: 34 35 36 37 38 39 41"
    frames = obd_discover.parse_response(reply)
    assert frames[0] == [0x49, 0x02, 0x01, 0x31, 0x32, 0x33]
    assert frames[1] == [0x34, 0x35, 0x36, 0x37, 0x38, 0x39, 0x41]


def test_parse_skips_status_words():
    for noise in ("NO DATA", "SEARCHING...", "OK", "CAN ERROR", "UNABLE TO CONNECT", ""):
        assert obd_discover.parse_response(noise) == []


def test_classify_positive_and_negative():
    """Compact and spaced, with and without the ISO-TP PCI byte."""
    assert obd_discover.classify(obd_discover.parse_response("62 F1 90 01"), 0x22) == {
        "result": "positive",
        "data": "62 F1 90 01",
    }
    assert obd_discover.classify(obd_discover.parse_response("4100BE3F"), 0x01) == {
        "result": "positive",
        "data": "41 00 BE 3F",
    }
    verdict = obd_discover.classify(obd_discover.parse_response("7F 22 31"), 0x22)
    assert verdict["result"] == "negative"
    assert verdict["nrc_name"] == "requestOutOfRange"
    verdict = obd_discover.classify(obd_discover.parse_response("03 7F 22 33"), 0x22)
    assert verdict["nrc_name"] == "securityAccessDenied"
    assert obd_discover.classify(obd_discover.parse_response("NO DATA"), 0x22) == {
        "result": "no_response"
    }


def test_default_ecus_are_request_ids():
    """ATSH takes a transmit header, so a response ID here would probe a dead address."""
    for request_id in obd_discover.DEFAULT_ECUS:
        assert 0x7E0 <= int(request_id, 16) <= 0x7E7


def test_response_id_pairing():
    assert obd_discover.response_id_for("0x7E0") == "0x7E8"
    assert obd_discover.response_id_for("0x7E7") == "0x7EF"
    # Outside the standard range the pairing is manufacturer-defined: do not guess.
    assert obd_discover.response_id_for("0x700") is None


def test_parse_range():
    assert obd_discover.parse_range("0xF180-0xF1FF") == (0xF180, 0xF1FF)
    assert obd_discover.parse_range("0xF190") == (0xF190, 0xF190)


class FakeElm:
    """Minimal stand-in for Elm327 so the vehicle helpers can be tested offline."""

    def __init__(self, replies):
        self.replies = replies
        self.sent = []

    def command(self, cmd, delay=0.1):
        self.sent.append(cmd)
        return self.replies.get(cmd, "")


def test_triumph_read_sia_decodes_odometer():
    """0D 01 -> 704 8D 01 <b1><b2><b3>, a 24-bit big-endian odometer in km."""
    elm = FakeElm({"0D01": "704 8D 01 01 5F 90", "5E01": "704 DE"})
    out = obd_discover.triumph_read_sia(elm)
    assert out["odometer_km"] == 0x015F90  # 89998
    assert out["odometer_miles"] == round(0x015F90 / 1.60934, 1)
    assert out["tft_dash"] is True


def test_triumph_read_sia_without_tft():
    elm = FakeElm({"0D01": "704 8D 01 00 00 64", "5E01": "NO DATA"})
    out = obd_discover.triumph_read_sia(elm)
    assert out["odometer_km"] == 100
    assert out["tft_dash"] is False


def test_triumph_service_reset_builds_scaled_opcode():
    """33 = km, 34 = miles, value is distance/100 in one byte."""
    elm = FakeElm({"3364": "704 B3"})
    out = obd_discover.triumph_service_reset(elm, 10000, "km")
    assert elm.sent == ["3364"]
    assert out["request"] == "33 64"
    assert out["ok"] is True

    elm = FakeElm({"343C": "704 B4"})
    out = obd_discover.triumph_service_reset(elm, 6000, "miles")
    assert elm.sent == ["343C"]
    assert out["ok"] is True


def test_triumph_service_reset_rejects_unrepresentable_values():
    import pytest

    with pytest.raises(SystemExit):
        obd_discover.triumph_service_reset(FakeElm({}), 6050, "km")  # not a multiple of 100
    with pytest.raises(SystemExit):
        obd_discover.triumph_service_reset(FakeElm({}), 30000, "km")  # > 0xFF after /100


def test_bmw_module_init_uses_6f1_scheme():
    elm = FakeElm({})
    obd_discover.bmw_module_init(elm, 0x60)
    assert "ATSH6F1" in elm.sent
    assert "ATCEA60" in elm.sent
    assert "ATCF660" in elm.sent
    assert "ATFCSD60300008" in elm.sent


def test_bmw_read_service_decodes_fields():
    elm = FakeElm({
        "22E119": "6F1 62 E1 19 00 01 5F 90",
        "22E12B": "6F1 62 E1 2B 0C 1E 05 14 03 07 E9",
        "22E12C": "6F1 62 E1 2C 14 03 07 EA",
        "22E12D": "6F1 62 E1 2D 27 10",
    })
    out = obd_discover.bmw_read_service(elm)
    assert out["odometer_km"] == 0x00015F90
    assert out["service_distance_km"] == 10000
    assert out["service_date"] == "20.03.2026"
    assert out["clock"].startswith("20.03.2025") or out["clock"].endswith("12:30:05")
