# Sev2 follow-ups

This file tracks the lower-priority polish items deferred from the
opengreeniot-core code review. They're all real, but none of them block
shipping. Pick them up in any order — most are independent.

When picking one up, please cross-reference the original code review
discussion (reviewer: in the persona of Lily Mara) and the architectural
decisions captured in the Phase 1/Phase 2 commits on
`claude/fix-build-and-sample-app-ddV7l`.

## 2.1 — Audit `EncodingFailed(String)` for unstructured failure sites

**Status:** mostly subsumed by Sev1.1 (the `unsupported parameter type`
use site became `ProtocolError::UnsupportedParameterType`).
**Action:** confirm `ProtocolError::EncodingFailed(String)` has no remaining
users; if so, delete the variant. If new users have appeared, give each one
a structured variant rather than letting the unstructured catch-all stick
around.

## 2.2 — Decide on `SpecError`'s shape

After Sev1.2 added two new `SpecError` variants, the wrapper is justified.
**Action:** none required, but if the variant set settles back to one,
collapse to `pub type SpecError = serde_yaml::Error;`. Don't keep the
wrapper "for forward compat" if it doesn't earn its keep.

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

## 2.4 — Drop `once_cell` in favor of `std::sync::LazyLock`

`once_cell::sync::Lazy` is replaced by `std::sync::LazyLock` (stable in
Rust 1.80; this project requires 1.82). Two call sites:
- `rust/src/api/mock_api.rs::MOCK_STATES`
- `rust/src/api/mock_api.rs::WARNED_SPEC_FAILURES`

**Action:** convert both, then delete the `once_cell` line from
`rust/Cargo.toml`.

## 2.5 — Pre-normalize UUIDs at parse time

`DeviceSpec::find_characteristic` (`rust/src/spec/types.rs:19`) calls
`to_lowercase()` on the target *and* every characteristic UUID it walks,
on every invocation. The dispatcher refactor amplified this — every
encode/decode now runs the lookup.

**Action:** during `parse_device_spec`, normalize each UUID once and
store it on the struct (e.g. `lowercase_uuid: String` field, or a thin
newtype `NormalizedUuid(String)`). Then `find_characteristic` becomes a
borrowed compare. Bonus: `eq_ignore_ascii_case` on the way through is
cheap and zero-allocation.

## 2.6 — `normalize_uuid` returns `Cow<'_, str>`

`rust/src/protocol/profiles/mod.rs::normalize_uuid` always allocates a
`String`. For inputs that are already short and lowercase, the allocation
is wasted.

**Action:** return `Cow<'_, str>`; allocate only on the slow path
(format conversion or case folding). Same for the `strip_leading_zeros`
helper.

## 2.7 — Surface the silent `u64 → i64` saturation

`rust/src/api/device_api.rs` `impl From<(&str, &DecodedValue)> for
DecodedValueDto` does:
```rust
DecodedValue::Uint(v) => dto.uint_value = Some((*v).min(i64::MAX as u64) as i64),
```
For real-world BLE values you'll never hit this, but a `u64::MAX` value
gets silently clamped to `i64::MAX` and the Dart side can't tell.

**Action:** when the saturation triggers, also stuff the original value
into `string_value` so the UI can show the truthful number alongside the
clamped one. Inline comment in `device_api.rs` already references this
plan file.

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

## 2.9 — Reject empty parameter names in `TemplateElement` deserializer

`rust/src/spec/types.rs::TemplateElement::deserialize` accepts `"{}"`,
producing `TemplateElement::Param("".to_string())`. Then encode-time
fails with `ParameterMissing("")` — useless message.

**Action:** in `visit_str`, use
`v.strip_prefix('{').and_then(|s| s.strip_suffix('}'))` so `"{"` (one
char) is rejected, then check the resulting name is non-empty. Reject at
parse rather than at encode.

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
