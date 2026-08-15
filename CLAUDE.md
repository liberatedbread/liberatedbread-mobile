# CLAUDE.md

The full agent guide for this repo lives in **[AGENTS.md](AGENTS.md)** — read it
first. It covers the clean-room rules, the BLE and Wi-Fi/LAN spec formats, and
the setup/test commands.

The rules most likely to bite if skipped:

- **Clean-room:** never commit APKs, decompiled source, `*.pcap` captures, or
  vendor assets — only derived facts and your own writing. See
  [docs/CLEANROOM_RULES.md](docs/CLEANROOM_RULES.md).
- **Never commit `device-specs/index.json`** — it is generated, and CI rebuilds
  and commits it on main. A branch carrying it fails CI (it is the file every
  parallel spec PR used to conflict on). `python scripts/generate_index.py`
  still writes it locally if you want to look at it; just don't stage it.
- Validate before you're done: `python scripts/validate_specs.py`,
  `ruff check .`, `pytest -q`, `mkdocs build --strict`.
