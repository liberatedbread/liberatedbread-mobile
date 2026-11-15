#!/usr/bin/env python3
# Copyright 2026 Pigs Can Fly Labs LLC
# SPDX-License-Identifier: Apache-2.0
"""Tests for the APK-on-disk cross-reference in generate_verification_ref.

apkeep filenames vary by source and version (a bare ``<pkg>.apk``, a split
``<pkg>.apks``/``<pkg>.xapk``, or a version-bearing ``<pkg>@1.2.3.apk``). If the
matcher only tried the two exact paths, a populated workspace was reported as NO
and that error propagated into the APK index and maturity-tier counts — so the
matching is worth a test.
"""
from __future__ import annotations

import generate_verification_ref as gvr


def test_matches_bare_split_and_version_bearing(tmp_path, monkeypatch):
    apkeep = tmp_path / "apkeep"
    apkeep.mkdir()
    (apkeep / "com.example.bare.apk").touch()
    (apkeep / "com.example.split.apks").touch()
    (apkeep / "com.example.bundle.xapk").touch()
    (apkeep / "com.example.at@1.2.3.apk").touch()
    (apkeep / "com.example.under_9.apks").touch()
    monkeypatch.setattr(gvr, "APKEEP_DIR", apkeep)
    for pid in (
        "com.example.bare",
        "com.example.split",
        "com.example.bundle",
        "com.example.at",
        "com.example.under",
    ):
        assert gvr.check_apk_on_disk([pid]) == "YES", pid


def test_no_false_positive_on_a_longer_package(tmp_path, monkeypatch):
    apkeep = tmp_path / "apkeep"
    apkeep.mkdir()
    (apkeep / "com.example.foobar.apk").touch()
    monkeypatch.setattr(gvr, "APKEEP_DIR", apkeep)
    # com.example.foo must not be satisfied by com.example.foobar's artifact.
    assert gvr.check_apk_on_disk(["com.example.foo"]) == "NO"


def test_populated_dir_with_no_match_is_no(tmp_path, monkeypatch):
    apkeep = tmp_path / "apkeep"
    apkeep.mkdir()
    (apkeep / "com.other.app.apk").touch()
    monkeypatch.setattr(gvr, "APKEEP_DIR", apkeep)
    assert gvr.check_apk_on_disk(["com.example.missing"]) == "NO"
    assert gvr.check_apk_on_disk(["TBD", "N/A"]) == "NO"


def test_none_when_workspace_absent(tmp_path, monkeypatch):
    monkeypatch.setattr(gvr, "APKEEP_DIR", tmp_path / "does-not-exist")
    assert gvr.check_apk_on_disk(["com.example.x"]) is None


def test_singular_package_id_is_parsed():
    # Targets such as astral-hoops declare a singular ``app package_id:`` (no
    # plural ``(s)``); it must be extracted, not reported as ``?``.
    text = (
        "## Target metadata\n"
        "- target_id: astral-hoops\n"
        '- app package_id: com.astral.astral ("Astral"), v2.0.16 analyzed\n'
        "- device class: LED flow props\n"
        "- transport(s): Bluetooth (BLE) only\n"
        "\n"
        "## Known facts\n"
    )
    meta = gvr.parse_metadata_section(text)
    assert meta["package_ids"] == ["com.astral.astral"]


def test_cctld_package_id_is_valid():
    # de.wgsoft.motoscan (bmw-motorcycle-motoscan) was silently dropped by a
    # fixed prefix allowlist that had no "de." — any short TLD-style first
    # segment must pass, not just the handful someone thought of.
    for pid in ("de.wgsoft.motoscan", "com.example.app", "io.flutter.app", "re.notifica.go"):
        assert gvr.is_valid_reverse_domain_pkg(pid), pid
    assert gvr.extract_valid_package_ids(
        "de.wgsoft.motoscan (MotoScan for BMW Motorcycles)"
    ) == ["de.wgsoft.motoscan"]


def test_non_package_text_is_still_rejected():
    assert not gvr.is_valid_reverse_domain_pkg("motoscan.de")  # forwards, not reversed
    assert not gvr.is_valid_reverse_domain_pkg("WGSoft.de")  # capitalised prose
    assert not gvr.is_valid_reverse_domain_pkg("e.g.")  # abbreviation
    assert not gvr.is_valid_reverse_domain_pkg("nodots")


def test_hyphenated_domain_fragment_is_not_a_package():
    # fardriver-controller's metadata mentions the vendor download domain
    # "far-driver.com" in prose; the extractor must not carve "driver.com"
    # out of the middle of it.
    text = "UNKNOWN — the app is a direct APK download from far-driver.com, not Play."
    assert gvr.extract_valid_package_ids(text) == []


def test_bare_can_transport_buckets_with_obd():
    # "CAN, 500 kbit/s" (bosch-ebike-cx-gen4) has neither "obd" nor "can bus"
    # in it; a substring check also must not fire on the "can" inside "scan".
    counts = gvr.compute_transport_counts([
        {"transport": "CAN, 500 kbit/s"},
        {"transport": "OBD-II connector; ISO 15765-4 (CAN)"},
        {"transport": "BLE (advertisement scan only)"},
    ])
    assert counts == {"OBD-II / CAN": 2, "BLE / Bluetooth": 1}


def test_uncategorised_transport_label_is_not_truncated():
    counts = gvr.compute_transport_counts([
        {"transport": "UART (9600 baud TTL, 6-pin connector under the seat)"},
    ])
    assert counts == {"UART": 1}


def test_previous_apk_collected_carried_forward(tmp_path, monkeypatch):
    # Without workspace/ the disk probe cannot re-verify a committed YES; the
    # committed value must be readable back so a regen does not downgrade it.
    ref = tmp_path / "VERIFICATION_REFERENCE.md"
    ref.write_text(
        "# VERIFICATION REFERENCE\n"
        "\n"
        "## 1. APK Source Index\n"
        "\n"
        "| target_id | package_id(s) | APK method | APK collected? | CSV notes |\n"
        "|---|---|---|---|---|\n"
        "| some-target | com.example.app | apkeep | YES | note, with commas |\n"
        "| other-target | ? | ? | NO | — |\n"
        "\n"
        "## 2. Reference URL Catalog\n",
        encoding="utf-8",
    )
    monkeypatch.setattr(gvr, "OUTPUT_PATH", ref)
    assert gvr.read_previous_apk_collected() == {
        "some-target": "YES",
        "other-target": "NO",
    }


def test_previous_apk_collected_missing_file_is_empty(tmp_path, monkeypatch):
    monkeypatch.setattr(gvr, "OUTPUT_PATH", tmp_path / "does-not-exist.md")
    assert gvr.read_previous_apk_collected() == {}


def test_plural_package_ids_still_parsed():
    # The existing plural spelling with indented sub-bullets must keep working.
    text = (
        "## Target metadata\n"
        "- target_id: gerbing-thermogauge\n"
        "- app package_id(s):\n"
        "  - Android: `com.gyde.thermogauge` (unpublished)\n"
        "  - iOS: companion app of the same name\n"
        "- device class: BLE heated apparel controller\n"
        "\n"
        "## Why this target matters\n"
    )
    meta = gvr.parse_metadata_section(text)
    assert meta["package_ids"] == ["com.gyde.thermogauge"]
