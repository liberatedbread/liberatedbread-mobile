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

### Changed

- **`assets/` is gone; everything ships from the vendored subtree.** Both the
  device specs and the number registries were duplicated — 1.2MB and 1.7MB of
  byte-identical copies of `vendor/protocol-specs/`, made by
  `scripts/sync_device_specs.sh` and committed alongside their originals. Two
  copies of the same data with nothing checking they agree is a bug waiting for
  someone to edit the wrong one.

  `pubspec.yaml` now bundles the subtree paths directly, and the loader reads
  upstream's own `index.json` instead of a rewritten `manifest.json`. Refreshing
  the catalogue becomes `git subtree pull` and nothing else, so
  `sync_device_specs.sh` is deleted rather than kept as a step people can forget.

  Not symlinks: a Windows checkout without developer mode or `core.symlinks`
  writes a text file containing a path, and Flutter's asset pipeline treats
  symlinks inconsistently across platforms. Both failures are silent — an empty
  catalogue, no error — where a wrong path is a loud missing asset.

  **Remote spec packs are unaffected**, and now have tests saying so: bundled
  specs are keyed by subtree asset path and remote ones by `pack:<name>/<file>`,
  and the two namespaces are pinned as non-overlapping so neither half can
  shadow the other in the merged catalogue.
- **iOS deployment target 12.0 → 13.0.** Flutter 3.44 no longer supports an
  iOS 12 target. The Podfile now pins the platform explicitly rather than
  leaving it commented out, so CocoaPods and the Xcode project cannot drift
  apart. Flutter 3.44 also stopped building 32-bit x86 for Android, so the APK
  ABI assertions no longer name it.

### Fixed

- **iOS could never have discovered a Wi-Fi device.** Since iOS 14 an app may
  not touch a multicast address over a raw socket without
  `com.apple.developer.networking.multicast`, and there was no entitlements
  file in `ios/` at all. `NSBonjourServices` does not substitute for it: that
  key covers mDNS done through the Bonjour APIs, where `mDNSResponder`
  multicasts on the app's behalf, and this app uses neither — `multicast_dns`
  binds UDP 5353 and joins 224.0.0.251 itself, and the SSDP half sends
  M-SEARCH to 239.255.255.250 from its own socket. Both were blocked.

  Nothing said so. The sockets bound, the queries went out, the OS dropped
  them, and `scanFailureFor()` read the silence exactly as designed and told
  the user their Local Network permission might be off — pointing at a toggle
  that was already on.

  `ios/Runner/Runner.entitlements` now declares it and all three app build
  configurations reference it. Apple grants this entitlement by manual request
  rather than a checkbox, so signed device builds fail at signing until the
  request is approved and the provisioning profile reissued;
  `docs/ios-from-linux.md` covers what to file and what breaks meanwhile.
  Simulator builds, including all of CI, are unaffected — they do not sign.

- **macOS release builds lost half the Wi-Fi scan.**
  `com.apple.security.network.server` was in `DebugProfile.entitlements` but
  not `Release.entitlements`, on the reading that it belonged to the Dart VM
  service. Under the App Sandbox it is also what permits binding a listening
  socket, which is what `multicast_dns` does to join 224.0.0.251 on port 5353.
  So mDNS worked in `flutter run -d macos` and threw in a release build, which
  then discovered only what SSDP happened to find. The macOS local-network
  usage string also described only Home Assistant, though the prompt now
  fires when a user taps Scan.

- **A `--` inside an XML comment broke the Android manifest.** XML forbids it —
  it is the first half of the comment terminator — and the manifest merger fails
  the whole build with "Error parsing AndroidManifest.xml" and no line number.
  Every existing platform test passed, because the hand-rolled comment stripper
  in `test/platform/platform_config_reader.dart` just scans to the next `-->`.
  `test/platform/xml_wellformedness_test.dart` now closes that gap for the
  manifest, both plists and both entitlements files.

### Added

- **The device screen says who made the thing, and shows its address.** The
  IEEE and SIG registries have been vendored and searched for a while, but the
  BLE detail screen never read them: it showed a name, a status dot and a
  service count, and the MAC only by accident, when a device had no name and
  the title fell back to `Unknown (<id>)`. It now carries the address and what
  the registries make of it, and the Wi-Fi details sheet gained the `MAC` row
  its existing `Address block` row was silently drawing its conclusion from.

  The two sources stay separate rows rather than collapsing into one
  "manufacturer" line, because they answer different questions: a company ID
  is something the device put in its own advertisement, while an address block
  names whoever bought the block — frequently the radio module's vendor, which
  is why the Lutron Caséta bridge resolves to Texas Instruments. Labelling
  them apart ("Advertises as" / "Address block") is what makes showing the
  registry safe at all. Nothing new looks anything up: this is
  `describeWith` + `DeviceDescription`, already used by the scan list.

  On Apple platforms both rows are simply absent — CoreBluetooth substitutes a
  per-host UUID for the hardware address, so there is no address to show and no
  block to look up, and printing the UUID under "Address" would invite exactly
  the lookup that cannot work.
- **`scripts/update-specs.sh`** — refreshing the vendored specs is a script
  now, not a remembered `git subtree pull`. It takes a ref, and `--from` takes
  any remote including a local checkout, so a spec change can be pulled from
  the branch it is still being written on. Afterwards it asserts that every
  path `pubspec.yaml` bundles actually arrived: a pull that drops
  `registries/ieee-oui36.tsv` fails nothing at build time, it just makes the
  app quietly stop naming vendors.
- **Bottom ad banner on the scan screen** — a small dismissible house-ad bar
  pointing at the new liberatedbread.com/shop/ affiliate page (dead devices
  cheap, WeMos boards, liberation gear). Content comes from
  `https://liberatedbread.com/app/banner.json` fetched in the background, so
  the promotion can change — or be switched off — without an app-store
  release; a bundled fallback (and a cache of the last fetched config) renders
  from the first frame, so a slow or absent network never blocks anything.
  Dismissal is remembered per promotion id.
- **Wi-Fi device discovery, as a destination of its own.** Half the catalogue is
  hardware with no Bluetooth at all — bridges, plugs, printers — and a BLE scan
  could never see any of it. The new Wi-Fi tab asks over both mDNS/DNS-SD and
  SSDP, because the two do not overlap: modern local-first devices announce over
  mDNS only, while Wemo and pre-2020 Hue bridges are SSDP-only, so running one
  would silently miss half the devices. Discovery is by the generic DNS-SD
  service enumeration rather than a fixed list, so it finds hardware whose spec
  nobody has written yet. A host answering on both transports is merged into one
  row carrying what each said. Tapping one shows everything it advertised.

  Matching reuses the same `MatchConfidence` core as the BLE path, so a badge
  means the same thing on either tab: an mDNS service type or an SSDP search
  target is a vendor-specific identifier and rates Strong, while a default port
  is the network's equivalent of an OUI — port 80 says nothing about who is
  listening — and only ever ranks. A spec that declares nothing about the
  network can never match a host on it, so a BLE spec whose name prefix happens
  to prefix an mDNS instance name stays off this tab.

  Platform notes: iOS will not deliver mDNS answers for a service type absent
  from `NSBonjourServices`, and fails silently when one is missing, so the plist
  now declares them; Android needs `CHANGE_WIFI_MULTICAST_STATE` or the Wi-Fi
  driver filters multicast out to save power. A denied local-network permission
  looks exactly like an empty network from inside the app, so on Apple platforms
  that case gets its own guidance and a settings link rather than a "no devices
  found" dead end.
- **Saved devices are a top-level destination, not a footer.** They were a
  "History" section pinned below however many strangers' earbuds the last scan
  turned up. The app now has a bottom bar — Nearby, Saved, Wi-Fi — and saved
  devices get a pane with room for the address, the vendor the address block
  belongs to, and an empty state that says how devices get there.
- **The scan list leads with devices we can probably talk to.** A scan in any
  populated building returns mostly noise — earbuds, laptops, a neighbour's TV —
  and the previous list sorted purely by signal strength, so a supported device
  across the room sat below every anonymous radio on the desk. Advertised
  service UUIDs, manufacturer-data company IDs and the MAC OUI are now read at
  scan time alongside the local name, matched against the spec catalogue, and
  the results split into a **Likely supported** section above the rest, each row
  badged with what the catalogue thinks it is.

  The four signals are weighted rather than pooled, because they are not equally
  telling (`MatchConfidence` in `rust/src/api/device_api.rs` is the single source
  of that judgement, shared by the scan and post-connect matchers). A vendor
  service UUID is near proof; a name prefix or company ID is good evidence; a MAC
  OUI is a vendor, not a product, so an OUI-only match stays out of the promoted
  section and reads "Possibly Xiaomi" rather than naming a device. Apple
  platforms report a per-host CoreBluetooth UUID instead of an address, so the
  OUI signal is simply absent there and is never confused for one.

  Matching is keyed on a device's identity rather than its id, so the hundreds of
  advertisements a device emits during one scan cost a single match; only the
  identifying fields of each spec cross the FFI boundary, not the parsed
  catalogue. Demo mode's mock devices now advertise a different signal each, so
  every rung of the ladder is visible without hardware.
- **Find Device view** — a "Find device" button on the connected-device
  header opens a hot/cold locator: live RSSI polled once a second, a
  distance guess from the log-distance path-loss model (presented as a
  rough bucket, with the raw dBm readings, extremes and a sparkline shown
  alongside), and a getting-closer/farther trend. When the device can make
  itself noticeable, one-tap alert buttons appear — from the standard BLE
  Immediate Alert service (0x1802, key finders/fitness bands) or from
  spec-declared beep/blink commands (`find_me`, `blink_led`); the
  spec-driven detection is transport-agnostic, so Wi-Fi device specs gain
  the same buttons once a Wi-Fi transport exists.
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

- **`./scripts/run*.sh` keep the repo-managed Flutter SDK on CI's pin.** When
  the run scripts use the SDK they install at `~/.flutter-sdk` and CI's
  `FLUTTER_VERSION` (in `.github/workflows/ci.yml`, surfaced by
  `scripts/ci-versions.sh`) has moved ahead of what is on disk, a run would
  otherwise fail deep inside `flutter pub get` on pubspec's Dart SDK
  constraint. `run.sh`, `run-linux.sh`, `run-android.sh` and `run-ios.sh` now
  source a shared `scripts/flutter-ensure-version.sh` that upgrades that SDK in
  place before running, so a bump in `ci.yml` no longer needs a separate
  `./scripts/setup.sh`. It is deliberately narrow: only an SDK that actually
  lives under `FLUTTER_HOME` is ever replaced — a Flutter from Homebrew,
  Android Studio, the distro, or a checkout elsewhere is left alone and only
  warned about, exactly as `setup.sh` does. A failed download leaves the
  existing SDK intact and the run continues (offline degrades to "slightly
  stale", not "cannot run"). Set `LB_FLUTTER_AUTO_UPGRADE=0` to skip the check.

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
