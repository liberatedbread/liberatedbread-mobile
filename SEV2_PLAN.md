# Sev2 follow-ups

This file tracks the lower-priority polish items deferred from the
opengreeniot-core code review. They're all real, but none of them block
shipping. Pick them up in any order — most are independent.

When picking one up, please cross-reference the original code review
discussion (reviewer: in the persona of Lily Mara) and the architectural
decisions captured in the Phase 1/Phase 2 commits on
`claude/fix-build-and-sample-app-ddV7l`.

## 2.1 — ✅ Done

`ProtocolError::EncodingFailed(String)` had no remaining users after Sev1.1
replaced its only call site with `UnsupportedParameterType`. Variant
deleted.

## 2.2 — ✅ Done (no action required)

After Sev1.2 added `FieldLengthMismatch` and `ParameterRangeOutsideType`,
the `SpecError` wrapper has three variants and earns its keep. Keep as-is.

## 2.3 — Migrate off `serde_yaml` (unmaintained)

`serde_yaml = "0.9"` was archived by its author (dtolnay) in early 2024.
No upstream parser-bug or CVE fixes will arrive.
**Action:** swap to `serde_yaml_ng = "0.10"` (the actively-maintained
community fork). Should be drop-in; if not, `serde_yml` is a viable
alternative.
**Watch out for:** `serde_yaml::Value` is used in
`rust/src/spec/types.rs::FormatField::mock_default` and
`rust/src/mock/simulator.rs::coerce_mock_default` — they need to migrate
together.

## 2.4 — ✅ Done

Both call sites in `rust/src/api/mock_api.rs` migrated to
`std::sync::LazyLock`. `once_cell` removed from `rust/Cargo.toml`.

## 2.5 — ✅ Done

`DeviceSpec::find_characteristic` (and the device-matching loop in
`device_api::match_device_to_spec`) now use `eq_ignore_ascii_case`
instead of `to_lowercase()`-then-equate. Zero allocations on the
comparison path. The data model stays unchanged (no `lowercase_uuid`
field needed).

## 2.6 — ✅ Done

`normalize_uuid` returns `Cow<'_, str>` and short-circuits to
`Cow::Borrowed` when the input is already a short ASCII-lowercase UUID
with no leading zeros. `strip_leading_zeros` returns `&str` instead of
`String`. New tests pin the borrowed/owned distinction.

## 2.7 — ✅ Done

When the `u64 → i64` clamp fires, the `From` impl now also writes the
original value to `string_value`. Tests cover both the within-range
no-op and the at-`u64::MAX` surfacing path.

## 2.8 — Cache parsed specs in `device_api.rs`

Every FFI call to `encode_command` / `decode_value` re-parses the YAML.
For a UI reading three characteristics on one screen, that's three
`serde_yaml::from_str` runs. For hot paths it's overhead worth
avoiding.

**Action:** add a `LazyLock<Mutex<HashMap<u64, Arc<DeviceSpec>>>>` keyed
by `fxhash(yaml)` (or any content hash); look it up in the dispatcher.
Specs are immutable assets, so no invalidation logic is required. Keep
the cache size sane — the realistic upper bound is "number of distinct
device specs the app ever loads," which is tiny.

## 2.9 — ✅ Done

`visit_str` now uses `strip_prefix('{')` + `strip_suffix('}')` and
rejects empty names at parse time with
`"parameter name cannot be empty"`. New parser test covers `"{}"`.

## Test fixture centralization

The bulb-YAML constant is duplicated across:
- `rust/src/api/mock_api.rs::TEST_YAML`
- `rust/src/spec/parser.rs::EXAMPLE_BULB_YAML`
- `rust/src/protocol/generic.rs::example_spec()` (inline, not a const)
- `rust/src/protocol/dispatch.rs::BULB_YAML` and `SPEC_OVERRIDING_BATTERY`
- `test/services/mock_ble_service_rust_test.dart::_bulbYaml` (Dart side)
- `assets/device_specs/example-bulb.yaml` (canonical asset)

**Action:** promote to a `tests/fixtures.rs` helper module with a
`pub fn example_bulb_yaml() -> &'static str`. The Dart test fixture and
the asset file should stay separate (different boundaries).
