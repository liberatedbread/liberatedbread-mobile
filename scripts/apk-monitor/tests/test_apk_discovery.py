"""Tests for apk_discovery.py — package filtering, state management."""

import json


from apk_discovery import load_known_packages, load_seen_packages, save_seen_packages


class TestLoadKnownPackages:
    def test_reads_csv(self, tmp_root):
        csv_path = tmp_root / "targets" / "targets.csv"
        pkgs = load_known_packages(csv_path)
        assert "com.example.led" in pkgs
        assert "com.test.thermo" in pkgs
        assert len(pkgs) == 2

    def test_missing_file_returns_empty(self, tmp_path):
        pkgs = load_known_packages(tmp_path / "nonexistent.csv")
        assert pkgs == set()


class TestSeenPackages:
    def test_missing_file_returns_empty(self, tmp_path):
        seen = load_seen_packages(tmp_path / "no_such.json")
        assert seen == set()

    def test_corrupt_json_returns_empty(self, tmp_path):
        state_file = tmp_path / "corrupt.json"
        state_file.write_text("{{not valid json at all!!")
        seen = load_seen_packages(state_file)
        assert seen == set()

    def test_save_and_load_roundtrip(self, tmp_path):
        state_file = tmp_path / "state" / "seen.json"
        original = {"com.foo.bar", "com.baz.qux"}
        save_seen_packages(state_file, original)

        assert state_file.exists()
        loaded = load_seen_packages(state_file)
        assert loaded == original

    def test_save_creates_parent_dirs(self, tmp_path):
        state_file = tmp_path / "deep" / "nested" / "seen.json"
        save_seen_packages(state_file, {"com.test"})
        assert state_file.exists()

    def test_saved_json_structure(self, tmp_path):
        state_file = tmp_path / "seen.json"
        save_seen_packages(state_file, {"b.pkg", "a.pkg"})
        data = json.loads(state_file.read_text())
        assert data["seen"] == ["a.pkg", "b.pkg"]  # sorted
        assert "updated" in data
