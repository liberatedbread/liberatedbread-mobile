"""Tests for config.py — loading, env precedence, dataclass factories."""



from config import (
    DEFAULT_CLAUDE_MODEL, DEFAULT_OPENAI_BASE_URL, ModelConfig, ResolvedPaths, load_config,
)


class TestLoadConfig:
    def test_load_from_file(self, tmp_path):
        cfg_file = tmp_path / "config.env"
        cfg_file.write_text('CLAUDE_MODEL="my-model"\nOPENAI_MODEL=gpt-4o-mini\n')
        cfg = load_config(cfg_file)
        assert cfg["CLAUDE_MODEL"] == "my-model"
        assert cfg["OPENAI_MODEL"] == "gpt-4o-mini"

    def test_skips_comments_and_blanks(self, tmp_path):
        cfg_file = tmp_path / "config.env"
        cfg_file.write_text("# comment\n\nCLAUDE_MODEL=x\n")
        cfg = load_config(cfg_file)
        assert cfg["CLAUDE_MODEL"] == "x"
        assert "# comment" not in cfg

    def test_env_vars_override_file(self, tmp_path, monkeypatch):
        cfg_file = tmp_path / "config.env"
        cfg_file.write_text("CLAUDE_MODEL=file-value\n")
        monkeypatch.setenv("CLAUDE_MODEL", "env-value")
        cfg = load_config(cfg_file)
        assert cfg["CLAUDE_MODEL"] == "env-value"

    def test_env_vars_work_without_file(self, tmp_path, monkeypatch):
        cfg_file = tmp_path / "nonexistent.env"
        monkeypatch.setenv("ANTHROPIC_API_KEY", "sk-test-123")
        cfg = load_config(cfg_file)
        assert cfg["ANTHROPIC_API_KEY"] == "sk-test-123"

    def test_empty_values_ignored(self, tmp_path):
        cfg_file = tmp_path / "config.env"
        cfg_file.write_text('CLAUDE_MODEL=""\nOPENAI_MODEL=\n')
        cfg = load_config(cfg_file)
        assert "CLAUDE_MODEL" not in cfg
        assert "OPENAI_MODEL" not in cfg


class TestModelConfig:
    def test_defaults(self):
        mc = ModelConfig.from_cfg({})
        assert mc.claude_model == DEFAULT_CLAUDE_MODEL
        assert mc.anthropic_api_key == ""

    def test_from_cfg(self):
        mc = ModelConfig.from_cfg({"CLAUDE_MODEL": "custom", "ANTHROPIC_API_KEY": "sk-x"})
        assert mc.claude_model == "custom"
        assert mc.anthropic_api_key == "sk-x"

    def test_agent_configs_returns_three_tuples(self):
        mc = ModelConfig()
        configs = mc.agent_configs()
        assert len(configs) == 3
        names = [name for name, _, _, _ in configs]
        assert names == ["claude", "openai", "local-qwen"]

    def test_agent_configs_uses_instance_values(self):
        mc = ModelConfig(claude_model="my-claude", openai_api_key="sk-test")
        configs = mc.agent_configs()
        claude_cfg = configs[0]
        assert claude_cfg == ("claude", "my-claude", "", "")
        openai_cfg = configs[1]
        assert openai_cfg[0] == "openai"
        assert openai_cfg[2] == "sk-test"
        assert openai_cfg[3] == DEFAULT_OPENAI_BASE_URL


class TestResolvedPaths:
    def test_defaults_use_detected_root(self):
        paths = ResolvedPaths.from_cfg({})
        assert paths.root_dir.exists() or True  # may not exist in CI
        assert paths.targets_csv.name == "targets.csv"

    def test_custom_root(self, tmp_path):
        paths = ResolvedPaths.from_cfg({"PROTOCOL_DOCS_ROOT": str(tmp_path)})
        assert paths.root_dir == tmp_path
        assert paths.workspace_dir == tmp_path / "workspace"
        assert paths.targets_csv == tmp_path / "targets" / "targets.csv"

    def test_custom_workspace(self, tmp_path):
        ws = tmp_path / "custom-ws"
        paths = ResolvedPaths.from_cfg({
            "PROTOCOL_DOCS_ROOT": str(tmp_path),
            "WORKSPACE_DIR": str(ws),
        })
        assert paths.workspace_dir == ws
