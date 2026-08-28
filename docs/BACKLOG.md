# Backlog — deferred items from the 2026-08 weekly review

Findings the review chose NOT to fix in its pass, each with the reason it
waits and what unblocks it. Nothing here is forgotten-by-accident; deleting
an entry means either doing it or deciding it will never be done, in writing.

## Cross-repo: schema fields the handlers transcribe by hand (SPEC-GAP)

The five BLE image-upload/printer handlers carry twelve `SPEC-GAP` comments
— places where a device fact lives in a spec's prose (or in Rust) because
the schema has no field for it. Each is an upstream schema ask first and a
handler simplification second; grep `SPEC-GAP` in `rust/src/protocol/` for
the exact sites.

- `cdbwsoft_ecb` (Magic Display): the `link_flag` vocabulary is undeclared
  (hardcoded 0 — a daisy-chained display is a rebuild); WRITE2/WRITE3 are
  structurally identical and distinguished by matching the literal string in
  `characteristic.name` — wants a declared `channel_tag`. The 12-row panel
  type is refused by name (column-pair packing order undocumented).
- `cat_printer`: the whole command set is transcribed from prose (no
  `commands:` block to resolve); the energy byte order and fixed payload
  values are unstated in YAML.
- `fichero_d11`: command set in prose; the density (`nn`) and paper-type
  vocabularies are not declared fields, and both are user-facing settings.
- `idotmatrix`: the 4096-byte chunk payload and the static image's
  time/delay+speed header bytes are prose-only.
- `ledbadge_bitmap`: the slot-mode enumeration lives only in the vendored
  doc; the 8192-byte flash ceiling is not in the YAML.

## Mobile features waiting on protocol work

- **MQTT pairing flows.** The state-subscription plumbing and the credential
  store are in; what makes them fully live is the pairing that MINTS the
  credentials: Hisense's on-TV authorisation of a client id (the spec's
  `remoteapp_common.pairing`), Dyson's WiFi-credential key derivation.
  Until then the credentials card asks and a person types.
- **Samsung `client_name_encoding`.** The app hardcodes "standard base64 of
  the UTF-8 name" because the spec records that fact in prose
  (`protocol_details`); a declared encoding field would let a future set
  differ without a code change.
- **Glyph rendering + the `device.pairing` block.** Upstream now ships
  pairing/reset glyphs (`glyphs/`, Git LFS — a subtree pull carries 3-line
  pointer files by design) and a first-class `device.pairing` block that 115
  specs already carry (`enter_pairing_mode` procedures, `press_count`,
  `power_state`, `indicator_glyph`). The setup screen renders none of it
  yet. Rendering needs an art decision first: fetch LFS in
  `update-specs.sh` and bundle upstream's SVGs, or ship our own set keyed by
  the same names. Alt text lives in `glyphs/MANIFEST.yaml`.
- **Rachio Gen 3 local HTTPS (TCP 443).** Telemetry-only (no zone control —
  that stays HAP), behind a vendor-pinned CA (`Rachio Device CA`,
  `CN=*-rachio.local`), and the listener WEDGES until reboot under probe
  bursts — the spec says "probe gently" and means it. If implemented, it
  needs a custom trust anchor, its own resolver, and a strict request
  budget; it must never join generic spec-driven polling. Today the spec is
  deliberately inert to the app (no `commands:`, role-less entity) and must
  stay that way until this entry is done properly.

## Deliberate refactor deferral

- **W15: the ×5-duplicated handler plumbing.** `resolve_tx_characteristic`
  is verbatim-identical between the two printers; the
  `max_payload_per_write` guard and the `row[x/8] |= 0x80 >> (x%8)` raster
  loop repeat across all five upload handlers. Deferred on purpose: it is a
  pure refactor across byte-level encoders whose tests are hardware-shaped
  pins, the highest regression-risk-per-benefit item the review found. Do
  it as its own change, moving the pinned tests with it, or not at all.

## Admitted limitations carried in commit messages

Sixteen limitations the original authors stated when landing the work, kept
here so they outlive `git log` archaeology: the uploader-characteristic
heuristic remains as documented fallback (391faa9); `set_cover_position` is
deliberately not filtered for stateless entities (a0f3a45); `auto: sequence`
has no ceiling of its own (4259b20); the MQTT topic catalogue rides
`extensions` rather than a typed field (e503bf0); `macos/` and `web/` are
committed but unsupported (145c08d); mDNS narrowing drops a
`txt_match`/`platform_fallback` naming a different service type (3d392d6);
`load_device_spec` and `soft_ap_profiles` deliberately stay off the spec
cache (1672bed); two threads missing the same YAML both parse it, as the
accepted cost of releasing the lock (8f50027); and the per-handler items the
SPEC-GAP section above absorbs.

## Follow-up chores

- **Refresh the vendored specs** after the weekly-review branch of
  `liberatedbread-protocol-specs` merges: an ordinary
  `./scripts/update-specs.sh`, then `./scripts/test.sh`. Expected deltas:
  ignis-pixel stops auto-matching the shared Nordic UART UUID, hello-fairy's
  variant matcher narrows, clean-room placeholder text, and the Samsung
  connect path may spell `{samsung_token}` (the fill rule handles both).
- **Dependabot [#55](https://github.com/liberatedbread/liberatedbread-mobile/pull/55)**
  (cargo aes/cbc/getrandom/md-5/base64): merge after this branch lands — the
  Magic Display decrypt roundtrip in `vendored_assets.rs` is the regression
  net those bumps need. Re-check it still applies cleanly post-merge.
