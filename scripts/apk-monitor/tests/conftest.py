"""Shared test fixtures for apk-monitor tests."""

import csv
import sys
from pathlib import Path

import pytest

# Ensure the apk-monitor package is importable
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from config import ModelConfig, ResolvedPaths


@pytest.fixture
def tmp_root(tmp_path):
    """Create a minimal repo-like directory structure for tests."""
    targets_dir = tmp_path / "targets"
    targets_dir.mkdir()

    # Write a minimal targets.csv
    csv_path = targets_dir / "targets.csv"
    with open(csv_path, "w", newline="") as f:
        writer = csv.writer(f)
        writer.writerow(["package_id", "target_id", "device_class", "transport", "rating", "notes"])
        writer.writerow(["com.example.led", "example-led", "LED controller", "BLE", "3.0", "test device"])
        writer.writerow(["com.test.thermo", "test-thermo", "thermometer", "BLE", "4.0", "test thermo"])

    # Create workspace
    workspace = tmp_path / "workspace"
    workspace.mkdir()

    # Create prompts dir
    prompts = tmp_path / "prompts"
    prompts.mkdir()
    (prompts / "AGENT_META_PROMPT.md").write_text("You are a test RE agent.")

    # Create device-specs dirs
    (tmp_path / "device-specs" / "candidates").mkdir(parents=True)
    (tmp_path / "device-specs" / "devices").mkdir(parents=True)

    # Create docs dirs
    (tmp_path / "docs" / "devices" / "candidates").mkdir(parents=True)

    return tmp_path


@pytest.fixture
def sample_model_config():
    """A ModelConfig with dummy values for testing."""
    return ModelConfig(
        claude_model="test-claude",
        openai_model="test-openai",
        local_model="test-qwen",
        local_base_url="http://localhost:9999/v1",
        local_api_key="test-key",
        anthropic_api_key="sk-ant-test",
        openai_api_key="sk-test",
    )


@pytest.fixture
def sample_paths(tmp_root):
    """A ResolvedPaths pointing at the tmp_root fixture."""
    return ResolvedPaths(
        root_dir=tmp_root,
        workspace_dir=tmp_root / "workspace",
        transcripts_dir=tmp_root / "workspace" / "re-transcripts",
        targets_csv=tmp_root / "targets" / "targets.csv",
    )
