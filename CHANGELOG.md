# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

No tagged release has been cut yet. Everything below is work toward the first
`0.1.0` release; once it ships, these entries move under a dated `## [0.1.0]`
heading.

### Security

- **Home Assistant token no longer leaks into logs.** A corrupt stored config
  was logged via `'$e'`, and `FormatException.toString()` quotes a window of
  its source — which here was the *decrypted* config, exposing 36 contiguous
  characters of the long-lived access token and the entire webhook id to
  logcat and terminals. Now only the exception type is logged; `redact()` /
  `redactAll()` / `logSafeUrl()` helpers and a redacting `HaConfig.toString()`
  make a repeat structurally hard.
- `run-remote-mac.sh` no longer interpolates `--remote-dir` unescaped into
  remote `ssh` commands (a quote in the path could execute arbitrary commands
  on the remote Mac).

### Added

- **Bottom ad banner on the scan screen** — a small dismissible house-ad bar
  pointing at the new liberatedbread.com/shop/ affiliate page (dead devices
  cheap, WeMos boards, liberation gear). Content comes from
  `https://liberatedbread.com/app/banner.json` fetched in the background, so
  the promotion can change — or be switched off — without an app-store
  release; a bundled fallback (and a cache of the last fetched config) renders
  from the first frame, so a slow or absent network never blocks anything.
  Dismissal is remembered per promotion id.
- **Linux desktop target (x86-64)** — build and iterate without an emulator:
  `./scripts/run-linux.sh --mock`, committed `linux/` scaffold, a
  `verify_linux_bundle.sh` that checks the Rust library is bundled *and*
  reachable (`RUNPATH` contains `$ORIGIN/lib`), and a CI job that builds
  release without the mock define and runs the integration tests headlessly
  under Xvfb — the first integration coverage needing no emulator/simulator.
- **Structured logging** (`lib/core/log.dart`) — levelled, six fixed
  categories (`[ble]`, `[spec]`, `[ha]`, `[packs]`, `[app]`, `[ui]`),
  timestamps, an injectable sink for tests, and a warning floor in release
  builds; ~40 log points across the BLE lifecycle, HA forwarding, spec
  matching, and pack installs.
- **Enumerated command parameters** — spec `allowed` values + `labels` now
  cross the FFI boundary (`ParameterDto`) and render as a labelled dropdown
  instead of a free-range slider; mismatched labels are dropped rather than
  mispaired.
- **Platform config-audit tests** (`test/platform/`) — 35+ fast tests pinning
  the Android manifest, iOS/macOS plists, entitlements, application-identity
  consistency, and the permission_handler-iOS Podfile invariant, each failure
  message naming the user-visible breakage.
- **CI artifact verification** — `scripts/verify_apk.sh` (Rust `.so` per ABI,
  merged-manifest permissions, application id) and `scripts/verify_ios_app.sh`
  (usage-description keys, linked FRB symbols) run against every built
  artifact; Android additionally builds release/R8 with the real (non-mock)
  BLE path compiled in; iOS runs simulator integration tests; `ios/Podfile`
  is now committed.
- **Android release signing** via a gitignored `android/key.properties`,
  falling back to debug keys with a loud warning instead of silently
  producing an unpublishable APK.

- **Liberated Bread rebrand** — new Material 3 theme and palette
  (`LiberatedBreadApp` / `LiberatedBreadTheme`), regenerated platform icons, a
  `tool/branding/` pipeline (`brand.json` + `generate_icons.mjs`),
  `docs/BRANDING.md`, and `test/core/brand_test.dart` contrast checks so a
  palette change that breaks WCAG contrast fails CI.
- **E2E screenshot walkthrough** — `scripts/e2e-walkthrough.sh` +
  `scripts/e2e_shot_server.py` drive
  `integration_test/e2e_walkthrough_test.dart` through the whole app on the
  iOS Simulator, snapshotting each step; tagged `e2e` in `dart_test.yaml` and
  excluded from CI's emulator job via `--exclude-tags=e2e`.
- **Remote spec packs** — download a JSON-manifest pack of device specs at
  runtime (same-origin-only, size-capped, validated through the Rust codec
  before install): `SpecPackService`, `spec_pack_provider`, and
  `SpecPackSettingsScreen`, plus a `SettingsStore` abstraction with
  `PrefsSettingsStore` and new `http`/`path_provider`/`shared_preferences`
  dependencies.
- **Home Assistant companion mode** — register with HA's native `mobile_app`
  API and forward spec-decoded BLE readings as sensor entities: HA
  models/services/providers and `HaSettingsScreen`, `ha_url` +
  `ha_sensor_mapping` helpers, a `TailscaleSuggestionCard` with remote-access
  hints, and secure keychain/keystore token storage via
  `flutter_secure_storage` (`secure_settings_store.dart`).
- **Spec-driven typed control UI** — matched device specs render buttons,
  sliders, and decoded values instead of raw hex:
  `typed_characteristic_widget`, `typed_command_widget`,
  `decoded_value_widget`, backed by `device_spec_match_provider`,
  `spec_codec_provider`, and `real_spec_codec`; plus cargokit native-build
  wiring so `flutter build` compiles the Rust crate on every platform.
- `scripts/run-ios-device.sh`, `.github/workflows/ios-adhoc.yml`, and
  `docs/ios-from-linux.md` — build and run on a physical iPhone: locally from
  a Mac (`--list`/`--device`), or as an ad-hoc IPA built in CI for Linux-bound
  developers.
- `scripts/run-android.sh` and `scripts/run-ios.sh` — build, boot the
  emulator/simulator if needed, install, and run.
- **Platform scaffolds** — Android (`android/`) and iOS (`ios/`) folders are now
  committed. `flutter build apk` and `flutter build ios` work out of the box.
- **CI overhaul** — separate jobs for Flutter (analyze + test + format +
  Codecov), Rust (fmt + clippy + test), Android debug-APK smoke build, iOS
  simulator build on macOS, and Android emulator integration tests.
- **Test coverage** — reusable `FakeBleService` plus widget/screen tests for
  `ScanScreen`, `DeviceScreen`, `DeviceControlPanel`, `RawCharacteristicWidget`,
  a provider test for `deviceSpecsProvider`, and unit tests for `bytesToHex`,
  `normalizeUuid`, and `mapConnectionState`.
- **Integration tests** under `integration_test/` covering the mock scan →
  connect → discover flow and the error + retry path.
- `scripts/test.sh` — one-shot local CI mirror.
- `scripts/run-remote-mac.sh` — build and run on an iPhone from Linux via a
  remote Mac over SSH: rsyncs the tree, launches `flutter run` remotely, and
  auto-hot-reloads on every local save (docs/ios-from-linux.md Option C).
- `pubspec.lock` is now committed for reproducible app builds.
- `lib/core/hex.dart` — `bytesToHex` and `normalizeUuid` helpers (deduplicated
  from three call sites).
- **FRB wiring** — `flutter_rust_bridge` 2.9.0 bindings are generated and
  committed (`lib/src/rust/`, `rust/src/frb_generated.rs`). `RustLib.init()`
  runs at app startup; `MockBleService` now delegates read/write to
  `rust/src/api/mock_api.rs` with a Dart fallback when the native library
  isn't loaded. CI builds the host Rust lib before `flutter test` and checks
  the bindings are in sync with the Rust API (drift check).
- Lint additions in `analysis_options.yaml`: `cancel_subscriptions`,
  `close_sinks`, `unawaited_futures`.
- Standard Bluetooth profile controllers: Battery Service (0x180F) and
  Device Information Service (0x180A)
- Protocol error types module (`error.rs`) with `ProtocolError` and `SpecError`
- FFI API: `load_device_spec()`, `match_device_to_spec()` (returns
  `Vec<MatchResult>` with categorical match reasons), unified
  `encode_command()`/`decode_value()` that take optional `spec_yaml` and
  `service_uuid` (spec wins when both supplied), and
  `identify_standard_profiles()` for service-UUID discovery
- Protocol dispatcher (`protocol::dispatch::select_protocol`) routes
  encode/decode requests to either a YAML-driven `GenericProtocol` or a
  built-in standard profile, with content-hash spec caching
- Spec format gains `mock_default` per format field; the simulator
  consults it before the name-based heuristic
- Parse-time spec validation: rejects fixed-width fields with the wrong
  `length`, parameter `min`/`max` bounds outside the declared type,
  and inverted `min > max` bounds
- `#[serde(deny_unknown_fields)]` on the protocol-execution spec structs
  (`DeviceInfo`, `Service`, `Characteristic`, `Command`, `Parameter`,
  `FormatField`) catches typos in YAML at parse time; `DeviceSpec`,
  `Identification`, and `ParameterSet` instead sweep unrecognized keys into an
  `extensions` catch-all (see the Changed entry on spec tolerance)
- Mock simulator with smart default values per field type
- E2E architecture walkthrough documentation (`docs/WALKTHROUGH.md`)
- Build and test guide for Linux and macOS (`docs/BUILD_AND_TEST.md`)
- Expanded README with architecture diagram, setup instructions, and Rust core docs
- Initial app scaffold: project structure; the `IoTDevice` and
  `BleDiscoveredService` models; the `BleService` layer and device manager; the
  scan and device screens; and Android BLE manifest permissions plus
  iOS `Info.plist` usage descriptions

### Fixed

- **Real BLE scanning tore itself down as soon as the native scan started**
  (`startScan` returns at scan *start*), so real hardware showed "No devices
  found" while the scan ran unwatched. The scan now waits for the adapter to
  actually stop, coalesces result batches (stable `discoveredAt`, no
  re-delivery of the previous scan's devices), and reports rssi/name changes
  only.
- **iOS could never scan**: with no `ios/Podfile`, permission_handler's iOS
  Bluetooth strategy is compiled out and answers every request "permanently
  denied" — before CoreBluetooth was ever reached. iOS now lets CoreBluetooth
  prompt natively and maps the adapter's `unauthorized` state to the
  permission-denied error.
- **Android 5.0–11 BLE**: the manifest declared only the API 31+ permissions;
  the legacy `BLUETOOTH`/`BLUETOOTH_ADMIN` pair (with `maxSdkVersion="30"`)
  is now declared, so scanning no longer throws `SecurityException` on the
  older half of the supported range.
- **macOS**: `keychain-access-groups` added to both entitlements files
  (sandboxed `flutter_secure_storage` failed with `errSecMissingEntitlement`,
  so the HA token could not be stored) plus the local-network usage string.
- **Rust core**: over-length fixed-width format fields no longer panic the
  mock simulator (writes fill only the low `fixed_byte_size` bytes); a 64 KiB
  parse-time cap stops spec-controlled multi-GB allocations; the dispatch
  spec cache is bounded and shares parsed specs via `Arc`; `bool` template
  parameters encode as a single 0/1 byte; typo'd `{parameter}` template
  references are rejected at parse time instead of failing on first write.
- `ref`-after-dispose guards in the HA and spec-pack settings screens; HA
  toggle/disconnect failures are surfaced instead of silently dropped; mock
  notify timers no longer outlive `dispose()`; `openAppSettings()` failures
  are caught.
- cargokit's Linux/Windows CMake exported a pre-rebrand
  `_bundled_libraries` variable, so the Rust cdylib would silently not be
  bundled into desktop builds; `rust_builder/android` carried the pre-rebrand
  namespace.
- `e2e-walkthrough.sh` could exit 0 with zero screenshots (no shot-server
  readiness check); the shot server could hang on `simctl` and accept a stale
  PNG as fresh; `session-start.sh` leaked temp files.
- CI now installs the Android NDK the build actually uses
  (`FLUTTER_NDK_VERSION` pinned to 23.1.7779620 — Flutter 3.24.5 hardcodes it;
  installing anything else just made cargokit download this one mid-build),
  and the emulator job's disk-cleanup `rm -rf` on SDK paths is guarded against
  an unset `ANDROID_SDK_ROOT`.
- `HaSensorForwarder` recovers dropped readings when a push to Home Assistant
  fails, instead of reporting phantom success.
- `MockBleService.subscribeCharacteristic` no longer leaks the periodic
  `Timer` when the subscriber cancels without disconnecting.
- `RealBleService` now caches discovered GATT services per device, eliminating
  a redundant round-trip on every read/write/subscribe. Cache is invalidated on
  disconnect.
- `deviceSpecsProvider` distinguishes "missing asset" (silent) from "malformed
  YAML" (logged), so real errors are no longer swallowed.
- UUID normalization now handles all-zero prefixes correctly (e.g. `000000f0`)
- Mutex lock recovery at FFI boundary (prevents panic on poisoned mutex)
- Overflow guard in codec field offset calculation
- Saturating cast for u64→i64 in DTO conversion

### Changed

- **New mascot, and a palette re-derived from it.** The 2026 logo keeps the
  loaf and the arms but swaps the ground it flexes on from turquoise to blush
  pink, and outlines the mascot in navy rather than warm brown. Because
  `brand.json` is sampled from the artwork, the palette followed:
  `teal` → `blush` (`#2FB9BF` → `#EBA1C6`), `tealDark` → `blushDeep`,
  `breadOrange` `#E8963C` → `#EF900A`, `face` `#3A2410` → `#112545`. All 43
  platform icons, the Android adaptive-icon background and the web manifest
  colours were regenerated by `tool/branding/generate_icons.mjs`. Contrast
  held: `ink` on blush is 7.60:1 and on bread orange 6.30:1, both up from the
  old 6.1:1, and `brand_test.dart` still enforces the 4.5:1 floor.
  `app_icon_mascot.svg` is gone — the new artwork was supplied as raster, so
  the committed PNG is the master and a stale vector of the old logo would
  have silently won back if the PNG were ever removed.

- **The Android emulator job stopped hanging on a settling race.** It had hung
  for its full timeout with zero Dart output while the same suites passed on
  Linux and the iOS simulator, which reads as a graphics flake and is not one:
  diffing the failing run's logcat against a passing one shows
  `FlutterRenderer: Width is zero. 0,0` in *both*, while only the failing run
  recreates `MainActivity` for a configuration change four seconds after the
  Dart VM service came up — orphaning the isolate `flutter_tools` had attached
  to, which then waited forever. It happened while the launcher and Play
  Services were still ANR-ing their way through startup. The manifest already
  declares Flutter's own `configChanges` set, so the fix is to remove the
  churn: CI now boots `aosp_atd` (Google's CI image, no launcher or Play
  Services, and faster to boot), and the test run makes two attempts each
  bounded by `ANDROID_EMULATOR_ATTEMPT_TIMEOUT` — a bound rather than a bare
  retry, because the failure hangs instead of exiting, so the step timeout
  alone left nothing to retry with. A passing retry still warns and uploads
  both attempts' logcats. That logic is a real script,
  `scripts/ci-emulator-tests.sh`, rather than an inline `script:` block:
  `android-emulator-runner` splits that input on newlines and execs each line
  as its own `/usr/bin/sh -c`, so a function body or an `if`/`fi` cannot
  parse, nothing carries between lines, and the shell is dash. The workflow
  now passes one line and the retry runs under bash — where it can also be
  exercised against stub `flutter`/`adb` binaries locally.

- **CI's toolchain pins are declared once and read once, instead of being
  grepped out of the whole workflow.** `scripts/ci-versions.sh` used to hunt
  values out of step bodies: the highest `platforms;android-NN` anywhere in
  the file, the first `targets:` line containing `-android`, packages
  recovered from `apt-get install` and its line continuations, the emulator's
  settings found by scanning forward from a marker. Every one of those could
  be tripped by a **comment** — naming an API level in prose really did change
  what developer machines installed, twice, while this file was being edited.
  Now every pinned version lives in ci.yml's top-level `env:` block, each step
  interpolates it, and the parser reads that one block and nothing else, so
  prose and configuration can no longer be confused. Output is unchanged apart
  from a new `CI_CMAKE_VERSION`, and `scripts/setup.sh` plus the session hook
  now install the matching CMake so dev machines stop hitting the same
  mid-build install CI did. GitHub does not expose the `env` context to
  `strategy:`, so the emulator's `api-level` matrix is the one repeated
  literal — `test/platform/deployment_targets_test.dart` asserts it matches
  its env key.
- **Platform SDK floors raised to what the pinned Flutter actually supports,
  and locked together by a test.** Every platform declared its floor in more
  than one file and nothing cross-checked them, so they had drifted apart in
  every direction:
  - **iOS 12.0 → 13.0** across `ios/Runner.xcodeproj`, `AppFrameworkInfo.plist`
    and the commented `ios/Podfile` platform line; the Rust core podspec went
    **11.0 → 13.0**.
  - **macOS 10.14 → 10.15**, with the macOS podspec **10.11 → 10.15**.
  - **`rust_builder` Android `compileSdkVersion` 33 → 36** (matching the app's
    `flutter.compileSdkVersion`) and **`minSdkVersion` 19 → 24** (matching the
    app's). The stale 33 also made Gradle stop mid-build to download an SDK
    platform nothing else wanted — measured at 2.5s, so the reason to fix it
    is the three-release gap against the app, not the seconds.
  - **CI installs API 36** instead of 34, which no module compiled against,
    and pins `cmake;3.22.1` alongside it — Flutter's own Gradle plugin wires a
    `CMakeLists.txt` into `:app` for its Android 15 16 KB page-size support,
    so AGP was installing CMake mid-build on every run (1.2s). Both are about
    installing the build's inputs in one visible, retryable step rather than
    having Gradle pause to accept a licence and fetch over the network.
    The emulator stays on API 34; it is a separate axis.
  - `rust_builder` no longer declares its own AGP on the buildscript classpath.
    cargokit's template pinned 7.3.0 there, which could never take effect —
    `android/settings.gradle` resolves AGP 8.6.0 first and a parent-first
    classloader means the loaded class wins — so it only fetched a second,
    ancient AGP while presenting a version number that looked authoritative.

  13.0 and 10.15 are what Flutter 3.44.8 scaffolds for a new app, so this is
  catching up to a decision the toolchain already made rather than a new one;
  the practical effect is that iOS 12 and macOS 10.14 are no longer claimed.
  New `test/platform/deployment_targets_test.dart` asserts every file
  declaring a floor agrees and that none drops below the pinned Flutter's, so
  the next bump cannot move one file and leave five behind.
- **The ad-hoc IPA workflow no longer pins its own toolchain.** It had drifted
  to Flutter 3.24.5 while CI moved to 3.44.8, so the one artifact that gets
  installed on real hardware was built with an SDK nothing else tested.
  `ios-adhoc.yml` now sources `scripts/ci-versions.sh` — the parser dev
  environments already provision from — and feeds the Flutter version and the
  iOS Rust target list out of `ci.yml` into its setup steps, so the two cannot
  diverge again. Reading it after checkout means an ad-hoc build of an older
  ref uses that ref's pins. The target list also fixes real work the old pin
  caused: it carried only `aarch64-apple-ios`, so the no-secrets simulator
  fallback made cargokit install `aarch64-apple-ios-sim` mid-build instead of
  in the cached setup step.
- **The Android emulator job got its Gradle cache and stopped building ABIs it
  cannot run.** It never used `gradle/actions/setup-gradle` (the APK job always
  had it), so it rebuilt Gradle's dependency cache every run — the same
  `flutter build apk --debug` cost ~2m40s in one job and ~5m40s here. Its
  warm-up build now also passes `--target-platform android-x64`: the AVD is
  x86_64 and the test-phase build compiles exactly x86/x86_64, while the
  warm-up had been compiling the Rust crate four times, including two arm
  targets nothing in the job could load.
- **CI's device integration tests now run as one cycle per platform, and the
  iOS simulator boots while the build runs.** On a device, every file passed
  to `flutter test` is its own kernel-compile → native build → install →
  launch cycle (~2 minutes each on the 10x-billed macOS runner, even fully
  cached); the new `integration_test/ci_all_test.dart` bundles the mock-safe
  suites so the iOS and Android jobs pay that cycle once. It initialises the
  integration-test binding itself, before the groups: the binding registers its
  end-of-run `tearDownAll` in its constructor, so leaving that to the first
  imported suite would scope the "all tests finished" hook to that suite and
  fire it between the two.
  `test/platform/integration_aggregate_test.dart` asserts both directions — a
  mock-safe suite missing from the aggregate never runs on a device, and an
  e2e-tagged one added to it would run where its host-side screenshot server is
  unreachable. The linux-desktop job still runs each file in its own process,
  so per-file isolation coverage survives. The iOS job also starts `simctl boot`
  right after checkout and only waits for it after the build, turning ~65 serial
  seconds of boot wait into overlap. Together: ~10m10s → ~7m of macOS wall
  clock on a warm run, and the emulator job sheds a cycle too.

  The iOS job's warm-up build now compiles the **test** entrypoint
  (`--target=integration_test/ci_all_test.dart`) rather than `lib/main.dart`.
  It exists to move the app build outside `flutter test`'s hardcoded
  12-minute loading window, but it was building a different Dart entrypoint
  than the tests use — so the kernel differed, Xcode relinked, and a warm run
  paid 95.7s there plus another 64.1s inside the window for largely the same
  work. Both invocations also pass `--no-pub`, since the job already ran
  `flutter pub get`. The simulator boot moved to just before that build:
  ~2 minutes of build already covers a ~65s boot twice over, and starting it
  at checkout only left a booted simulator idling through the SDK restore and
  rustup, holding memory and cycles on a 3-core runner during the CPU-bound
  part of the job.
- **Dev environment setup now follows CI instead of re-pinning it.**
  `scripts/ci-versions.sh` reads the Flutter/NDK/Android API/build-tools/FRB
  pins, the rustup target lists, the Linux desktop apt packages and the
  emulator's API level, system image and device profile out of
  `.github/workflows/ci.yml`; `scripts/setup.sh` and the Claude Code session
  hook provision from those values (each has a fallback, and a parse miss
  warns). `scripts/setup.sh` also gained the Linux desktop toolchain install
  and now creates the `liberated_bread_test` AVD from CI's exact system image
  and device profile. Both paths now compare the *installed* Flutter against
  the pin rather than accepting any SDK that exists — the session hook
  replaces a stale one, and `setup.sh` says so without touching an SDK it
  didn't install — so a `FLUTTER_VERSION` bump actually reaches dev
  environments instead of surfacing later as a Dart SDK constraint failure.
- **Claude Code web sessions can build and run Android and Linux desktop.**
  `.claude/hooks/session-start.sh` grew two auto-detected tiers on top of the
  host toolchain: the Linux desktop dependencies (wherever apt is usable) and
  the Android SDK/NDK, emulator and AVD (when `/dev/kvm` and disk allow).
  Both skip with a logged reason rather than failing the session, and can be
  forced or suppressed with `LB_SETUP_LINUX_DESKTOP` / `LB_SETUP_ANDROID`.
- Spec parsing is now tolerant of real-world protocol-docs specs: `DeviceSpec`,
  `Identification`, and `ParameterSet` dropped `deny_unknown_fields` in favor
  of a flattened `extensions` catch-all, so WiFi specs and vendor extension
  blocks parse instead of being rejected (`rust/tests/spec_tolerance.rs`
  documents the intent with vendored real specs).
- `scripts/test.sh` now mirrors CI's FRB binding drift check locally (skipped
  with a warning when the pinned codegen isn't installed).
- Migrated from the archived `serde_yaml` crate to the maintained
  `serde_yaml_ng` fork (imported under the same name via a Cargo rename).
- `MockBleService` deduplicates its two mock devices' service definitions into
  shared `_controlService` / `_batteryService` constants.
- `DeviceScreen` extracts a file-private `_CenteredProgress` widget used by the
  connecting/discovering states.
