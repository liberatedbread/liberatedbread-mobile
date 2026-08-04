# Sev2 follow-ups

This file tracks the lower-priority polish items deferred from the
liberated-bread-core code review. They're all real, but none of them block
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

## 2.3 — ✅ Done

Migrated to `serde_yaml_ng = "0.10"` via Cargo's package-rename
(`serde_yaml = { package = "serde_yaml_ng", ... }`) so call sites
keep using `serde_yaml::*` and source code didn't need to change.
All tests pass on the new parser.

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

## 2.8 — ✅ Done

`protocol::dispatch` now memoizes parsed specs in
`SPEC_CACHE: LazyLock<Mutex<HashMap<String, Arc<DeviceSpec>>>>`, keyed
deliberately by the **full YAML `String`** — not a hash. An earlier draft
keyed on `DefaultHasher` over the YAML bytes, but specs can arrive from
arbitrary remote pack URLs, and a hostile author could craft two specs
whose 64-bit non-cryptographic hashes collide, serving the wrong
`DeviceSpec` for encode/decode; the full-text key makes collisions
impossible (rationale comment on `SPEC_CACHE` in `dispatch.rs`).
Because those same remote URLs can also feed an endless stream of
*distinct* keys (each whitespace variation is a new entry), the cache is
now bounded at `SPEC_CACHE_MAX_ENTRIES = 32` — on hitting the bound it
clears and refills rather than pulling in an LRU dependency. Repeat
calls with identical YAML skip the parse and share the cached
`Arc<DeviceSpec>` (held by `GenericProtocol` directly, so a cache hit is
a refcount bump, not a deep clone). Tests use `Arc::ptr_eq` to prove
cache hits and the capacity eviction without depending on the
multithreaded test runner's shared cache state.

## 2.9 — ✅ Done

`visit_str` now uses `strip_prefix('{')` + `strip_suffix('}')` and
rejects empty names at parse time with
`"parameter name cannot be empty"`. New parser test covers `"{}"`.

## Test fixture centralization — ✅ Resolved (differently than planned)

The planned `example_bulb_yaml()` helper was never built, and by the time
this item was revisited it had become obsolete: the sites listed as
"duplicates" deliberately diverged into minimal, purpose-built fixtures
that no longer share a common bulb document:

- `rust/src/api/mock_api.rs::TEST_YAML` — trimmed to exactly what mock
  read/write needs (one readable characteristic, two fields).
- `rust/src/protocol/dispatch.rs::BULB_YAML` and
  `SPEC_OVERRIDING_BATTERY` — dispatcher-routing shapes (one probes
  spec-vs-standard-profile precedence; neither is the bulb).
- `rust/src/protocol/generic.rs::example_spec()` — six commands in
  deliberately scrambled order to catch IndexMap→HashMap ordering
  regressions; sharing it would destroy its point.
- `rust/src/api/device_api.rs::TEST_YAML` / `ORDERING_YAML` —
  purpose-built adversarial ordering (declaration order ≠ template
  order, plus never-referenced parameters).

`test_fixtures::make_minimal_spec` already centralizes the one genuinely
shared skeleton (validation tests wrapping a characteristic block). The
only full bulb copy left in Rust is `spec/parser.rs::EXAMPLE_BULB_YAML`,
which is single-sited — a shared helper would have exactly one caller.

The one true duplication found instead was **shipped asset ↔ vendored
test fixture**: `assets/device_specs/example-bulb.yaml` had drifted from
`rust/tests/specs/example-bulb.yaml` (the fixture carried an `entities:`
block the asset lacked, despite `spec_tolerance.rs` describing fixtures
as verbatim upstream copies). The asset now carries the block, and
`rust/tests/vendored_assets.rs::shipped_example_bulb_matches_test_fixture_semantically`
pins the pair to the same `serde_yaml::Value` so any future drift fails
CI. The Dart test fixture stays separate (different boundary), as
originally noted.
