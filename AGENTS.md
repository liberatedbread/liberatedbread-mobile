# Agent guide — Liberated Bread Mobile

Guidance for AI coding agents (Claude Code and others) working in this repo.
Humans: see [README.md](README.md) and [CONTRIBUTING.md](CONTRIBUTING.md).

## What this is

A cross-platform **Flutter + Rust** app for discovering and controlling
locally-controllable IoT devices **without the vendor cloud**. It speaks two
transports from one catalogue of YAML device specs:

- **BLE** — GATT scan, connect, read/write, standard SIG profiles.
- **Wi-Fi/LAN** — discovery over mDNS/DNS-SD and SSDP/UPnP, control over HTTP
  and SOAP.

Flutter owns the UI, transports, and permissions; the Rust core
(`rust/src/`, wired via `flutter_rust_bridge`) owns all protocol logic — spec
parsing, byte codecs, BLE profiles, and rendering the HTTP/SOAP requests that
drive Wi-Fi devices. Both transports run through the same spec-driven pipeline,
so a change that only touches one transport should still leave the other whole.

## Setup

- **Local:** `./scripts/setup.sh` (Linux/macOS) installs Flutter, Rust, FRB
  codegen, and the platform toolchains.
- **Claude Code on the web:** `.claude/hooks/session-start.sh` provisions the
  session automatically (Flutter + host Rust always; Linux-desktop deps and the
  Android SDK/emulator when the machine can use them). Toolchain versions are
  read from `.github/workflows/ci.yml` by `scripts/ci-versions.sh` — never pin
  them here.

## Build, test, lint

```bash
./scripts/test.sh          # local CI mirror (format, analyze, flutter test, clippy)
flutter test               # Dart unit + widget tests (builds the host Rust lib on demand)
cd rust && cargo test      # Rust unit tests
flutter analyze --fatal-infos
cd rust && cargo clippy --all-targets -- -D warnings
```

`flutter test` **excludes** the local-network discovery suites
(`@Tags(['netdisco'])`): they bind ports 5353/1900 and wait real seconds for
real datagrams. Run those on their own, backed by the stdlib responder
`scripts/net_virtual_device.py`:

```bash
./scripts/ci-netdisco-tests.sh          # what CI's Local-network discovery job runs
```

Testing devices without hardware (fakes, mock mode, emulated BLE peripherals,
virtual BlueZ, and the network responder) is documented in
[CONTRIBUTING.md](CONTRIBUTING.md#testing-ble-without-hardware). Tests are not
optional here — they're a feature.

## Load-bearing rules

- **Never edit `vendor/protocol-specs/`.** It is a git subtree vendored
  unmodified from
  [liberatedbread-protocol-specs](https://github.com/liberatedbread/liberatedbread-protocol-specs).
  Edits are invisible upstream and CI fails the PR. To change a spec, open a PR
  against that repo, then refresh here with `./scripts/update-specs.sh`.
- **Never hand-edit generated FRB bindings** (`lib/src/rust/**`,
  `rust/src/frb_generated.rs`). Regenerate with
  `flutter_rust_bridge_codegen generate` after changing `rust/src/api/**`. CI
  fails if the bindings are out of sync.
- **Keep both transports in mind.** BLE lives in `*ble_service.dart` /
  `rust/src/protocol/profiles/`; Wi-Fi lives in `*network_scan_service.dart`,
  `*_control_service.dart` (HTTP/SOAP), and `rust/src/protocol/{http,soap}.rs`.
- Adding a *bundled* fallback spec means updating the hardcoded list in
  `lib/providers/device_spec_provider.dart` **and** the assertion in
  `rust/tests/vendored_assets.rs`.
- Follow existing style: `dart format` / `cargo fmt`, lines ~80 cols, and keep
  `clippy -- -D warnings` clean.

## More

- [docs/BUILD_AND_TEST.md](docs/BUILD_AND_TEST.md) — build/run/test guide
- [docs/WALKTHROUGH.md](docs/WALKTHROUGH.md) — E2E architecture + spec format
- [docs/ios-from-linux.md](docs/ios-from-linux.md) — iPhone workflows from Linux
