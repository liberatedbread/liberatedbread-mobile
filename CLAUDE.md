# CLAUDE.md

The full agent guide for this repo lives in **[AGENTS.md](AGENTS.md)** — read it
first. It covers the project's two transports (BLE and Wi-Fi/LAN), setup, and
the build/test/lint commands.

The rules most likely to bite if skipped:

- **Never edit `vendor/protocol-specs/`** — it's a git subtree; edit specs
  upstream and refresh with `./scripts/update-specs.sh`.
- **Never hand-edit generated FRB bindings** (`lib/src/rust/**`,
  `rust/src/frb_generated.rs`) — regenerate with `flutter_rust_bridge_codegen
  generate`.
- Mirror CI before you're done: `./scripts/test.sh`. The local-network
  discovery suites are excluded from `flutter test` — run
  `./scripts/ci-netdisco-tests.sh` when you touch the Wi-Fi path.
