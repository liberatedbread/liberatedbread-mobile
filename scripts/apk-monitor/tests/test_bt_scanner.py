"""Tests for bt_scanner.py — pattern matching, UUID extraction, confidence scoring."""

import re

import pytest

from bt_scanner import (
    BT_PATTERNS,
    ScanResult,
    _CONFIDENCE_WEIGHTS,
    _UUID_RE,
    _compute_confidence,
    _detect_flutter,
    _extract_uuids,
    _grep_dir,
    is_interesting,
)


class TestExtractUuids:
    def test_filters_sig_uuids(self):
        lines = [
            'path:uuid = "00001800-0000-1000-8000-00805f9b34fb"',
            'path:uuid = "0000180a-0000-1000-8000-00805f9b34fb"',
        ]
        result = _extract_uuids(lines)
        assert result == []

    def test_keeps_custom_uuids(self):
        lines = [
            'path:service_uuid = "12345678-1234-5678-9abc-def012345678"',
            'path:char_uuid = "abcdef01-2345-6789-abcd-ef0123456789"',
        ]
        result = _extract_uuids(lines)
        assert len(result) == 2
        assert "12345678-1234-5678-9abc-def012345678" in result

    def test_deduplicates(self):
        lines = [
            'a.java:uuid = "12345678-1234-5678-9abc-def012345678"',
            'b.java:uuid = "12345678-1234-5678-9abc-def012345678"',
        ]
        result = _extract_uuids(lines)
        assert len(result) == 1

    def test_lowercases(self):
        lines = ['path:UUID = "ABCDEF01-2345-6789-ABCD-EF0123456789"']
        result = _extract_uuids(lines)
        assert result == ["abcdef01-2345-6789-abcd-ef0123456789"]

    def test_empty_input(self):
        assert _extract_uuids([]) == []


class TestGrepDir:
    def test_finds_matching_lines(self, tmp_path):
        (tmp_path / "test.java").write_text("import BluetoothGatt;\nother line\n")
        pattern = re.compile(r"BluetoothGatt")
        matches = _grep_dir(tmp_path, pattern)
        assert len(matches) == 1
        assert "BluetoothGatt" in matches[0]

    def test_skips_binary_extensions(self, tmp_path):
        (tmp_path / "image.png").write_text("BluetoothGatt fake match")
        pattern = re.compile(r"BluetoothGatt")
        matches = _grep_dir(tmp_path, pattern)
        assert len(matches) == 0

    def test_respects_max_matches(self, tmp_path):
        content = "\n".join(f"BluetoothGatt line {i}" for i in range(100))
        (tmp_path / "big.java").write_text(content)
        pattern = re.compile(r"BluetoothGatt")
        matches = _grep_dir(tmp_path, pattern, max_matches=5)
        assert len(matches) == 5

    def test_handles_nested_dirs(self, tmp_path):
        nested = tmp_path / "com" / "example"
        nested.mkdir(parents=True)
        (nested / "Ble.java").write_text("connectGatt(device)")
        pattern = re.compile(r"connectGatt")
        matches = _grep_dir(tmp_path, pattern)
        assert len(matches) == 1

    def test_handles_empty_dir(self, tmp_path):
        pattern = re.compile(r"anything")
        matches = _grep_dir(tmp_path, pattern)
        assert matches == []


class TestConfidenceScoring:
    def _make_result(self, **pattern_hits) -> ScanResult:
        """Helper to build a ScanResult with specific pattern hits."""
        r = ScanResult(package_id="test", apk_path="/test.apk")
        r.pattern_hits = pattern_hits
        _compute_confidence(r)
        return r

    def test_no_hits_zero_confidence(self):
        r = self._make_result()
        assert r.confidence == 0.0
        assert not r.has_bluetooth

    def test_permission_only(self):
        r = self._make_result(bluetooth_permission=3)
        assert r.confidence == pytest.approx(0.15)
        assert r.has_bluetooth

    def test_full_ble_stack(self):
        r = self._make_result(
            bluetooth_permission=1,
            ble_gatt=5,
            ble_scan=2,
            bluetooth_adapter=1,
            ble_advertising_name=1,
        )
        assert r.confidence == pytest.approx(0.80)

    def test_confidence_caps_at_1(self):
        r = ScanResult(package_id="test", apk_path="/test.apk")
        r.pattern_hits = {
            "bluetooth_permission": 1,
            "ble_gatt": 5,
            "ble_scan": 2,
            "bluetooth_adapter": 1,
            "ble_advertising_name": 1,
        }
        r.uuids_found = ["fake-uuid"]
        _compute_confidence(r)
        assert r.confidence == 1.0
        assert r.has_custom_uuids


class TestIsInteresting:
    def test_high_confidence_with_bt(self):
        r = ScanResult(package_id="x", apk_path="/x.apk", confidence=0.5, has_bluetooth=True)
        assert is_interesting(r)

    def test_low_confidence_rejected(self):
        r = ScanResult(package_id="x", apk_path="/x.apk", confidence=0.1, has_bluetooth=True)
        assert not is_interesting(r)

    def test_no_bluetooth_rejected(self):
        r = ScanResult(package_id="x", apk_path="/x.apk", confidence=0.8, has_bluetooth=False)
        assert not is_interesting(r)

    def test_custom_threshold(self):
        r = ScanResult(package_id="x", apk_path="/x.apk", confidence=0.2, has_bluetooth=True)
        assert is_interesting(r, threshold=0.1)
        assert not is_interesting(r, threshold=0.3)


class TestUuidConstant:
    def test_uuid_re_is_valid_regex(self):
        compiled = re.compile(_UUID_RE)
        assert compiled.match("12345678-1234-5678-9abc-def012345678")

    def test_uuid_re_rejects_garbage(self):
        compiled = re.compile(_UUID_RE)
        assert not compiled.match("not-a-uuid")

    def test_custom_service_uuid_not_in_patterns(self):
        assert "custom_service_uuid" not in BT_PATTERNS

    def test_flutter_ble_pattern_in_bt_patterns(self):
        assert "flutter_ble" in BT_PATTERNS

    def test_confidence_weights_cover_all_non_uuid_patterns(self):
        """Every non-uuid pattern that should contribute to scoring has a weight."""
        for key in _CONFIDENCE_WEIGHTS:
            assert key in BT_PATTERNS, f"{key} in weights but not in BT_PATTERNS"

    def test_flutter_ble_boosts_confidence(self):
        r = ScanResult(package_id="test", apk_path="/test.apk")
        r.pattern_hits = {"flutter_ble": 5}
        _compute_confidence(r)
        assert r.confidence == pytest.approx(0.25)
        assert r.has_bluetooth


class TestFlutterDetection:
    def test_detects_libflutter(self, tmp_path):
        lib_dir = tmp_path / "lib" / "arm64-v8a"
        lib_dir.mkdir(parents=True)
        (lib_dir / "libflutter.so").write_text("fake")
        (lib_dir / "libapp.so").write_text("fake")
        assert _detect_flutter(tmp_path)

    def test_detects_flutter_assets(self, tmp_path):
        (tmp_path / "assets" / "flutter_assets").mkdir(parents=True)
        assert _detect_flutter(tmp_path)

    def test_non_flutter_app(self, tmp_path):
        (tmp_path / "classes.dex").write_text("fake")
        assert not _detect_flutter(tmp_path)

    def test_empty_dir(self, tmp_path):
        assert not _detect_flutter(tmp_path)
