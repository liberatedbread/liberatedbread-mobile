# CLAUDE.md

The full agent guide for this repo lives in **[AGENTS.md](AGENTS.md)** — read it
first. It covers the clean-room rules, the BLE and Wi-Fi/LAN spec formats, and
the setup/test commands.

The rules most likely to bite if skipped:

- **Clean-room:** never commit APKs, decompiled source, `*.pcap` captures, or
  vendor assets — only derived facts and your own writing. See
  [docs/CLEANROOM_RULES.md](docs/CLEANROOM_RULES.md).
- After changing any spec, regenerate the index (`python
  scripts/generate_index.py`) — CI fails on a stale `device-specs/index.json`.
- Validate before you're done: `python scripts/validate_specs.py`,
  `ruff check .`, `pytest -q`, `mkdocs build --strict`.
