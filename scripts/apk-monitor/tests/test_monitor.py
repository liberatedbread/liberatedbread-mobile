"""Tests for monitor.py — target_id generation, CSV operations."""

import csv
import inspect


from monitor import _generate_target_id, _append_to_targets_csv, _load_existing_target_ids, run_vote_only


class TestGenerateTargetId:
    def test_three_segment_package(self):
        assert _generate_target_id("com.example.myapp") == "example-myapp"

    def test_four_segment_package(self):
        assert _generate_target_id("com.company.sub.app") == "sub-app"

    def test_two_segment_package(self):
        assert _generate_target_id("org.project") == "org-project"

    def test_single_segment(self):
        assert _generate_target_id("myapp") == "myapp"

    def test_underscores_become_hyphens(self):
        assert _generate_target_id("com.my_company.my_app") == "my-company-my-app"

    def test_collision_avoidance(self):
        existing = {"example-myapp"}
        result = _generate_target_id("com.example.myapp", existing)
        assert result == "example-myapp-2"

    def test_multiple_collisions(self):
        existing = {"example-myapp", "example-myapp-2", "example-myapp-3"}
        result = _generate_target_id("com.example.myapp", existing)
        assert result == "example-myapp-4"

    def test_no_collision_without_existing(self):
        existing = {"other-target"}
        result = _generate_target_id("com.example.myapp", existing)
        assert result == "example-myapp"


class TestAppendToTargetsCsv:
    def test_appends_row(self, tmp_root):
        csv_path = tmp_root / "targets" / "targets.csv"
        _append_to_targets_csv(csv_path, "com.new.app", "new-app", "widget", "BLE")

        with open(csv_path, newline="") as f:
            rows = list(csv.DictReader(f))
        last = rows[-1]
        assert last["package_id"] == "com.new.app"
        assert last["target_id"] == "new-app"
        assert "auto-discovered" in last["notes"]

    def test_preserves_existing_rows(self, tmp_root):
        csv_path = tmp_root / "targets" / "targets.csv"
        _append_to_targets_csv(csv_path, "com.new.app", "new-app", "widget", "BLE")

        with open(csv_path, newline="") as f:
            rows = list(csv.DictReader(f))
        assert len(rows) == 3  # 2 original + 1 new


class TestLoadExistingTargetIds:
    def test_loads_ids(self, tmp_root):
        csv_path = tmp_root / "targets" / "targets.csv"
        ids = _load_existing_target_ids(csv_path)
        assert ids == {"example-led", "test-thermo"}

    def test_missing_file(self, tmp_path):
        ids = _load_existing_target_ids(tmp_path / "nope.csv")
        assert ids == set()


class TestRunVoteOnly:
    def test_accepts_cfg_param(self):
        """run_vote_only should use cfg dict, not os.environ directly."""
        sig = inspect.signature(run_vote_only)
        assert "cfg" in sig.parameters

    def test_no_os_environ_for_min_votes(self):
        """run_vote_only source should not reference os.environ for MIN_VOTES."""
        source = inspect.getsource(run_vote_only)
        assert "os.environ" not in source
