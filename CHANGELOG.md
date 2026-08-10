# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- `endianness` on BLE characteristic `format` fields — same key, same
  `little`/`big` enum and same `little` default as a bus message field, which
  is where it was already declared. Six BLE fields across `xiaomi-miflora` and
  `pax-vape` had been stating it into a key nothing defined: the schema is
  permissive so it validated, and every parser dropped it. Harmless only
  because all six say `little`, which is what the decoders assume; a `big`
  field would have decoded byte-swapped with nothing to catch it, since a
  big-endian `0x0100` reads as 1 rather than 256 and both are plausible sensor
  readings. `scripts/test_device_specs.py` now pins the two declarations to
  each other so they cannot drift apart again
- Command-level `locate` (`sound` | `flash` | `both`) — declares that a
  command's whole effect is to make the device noticeable so a user can find
  it, and by which modality. It is the spec-command analogue of the SIG
  Immediate Alert service (0x1802) for the many devices that implement the
  same idea with a vendor opcode. Without it a client has only the command's
  name to go on, and the names in this catalogue do not support that: across
  350 BLE commands, `play_effect`, `set_mode`, `identify` and `set_volume_low`
  all read as locators and none is one, while `flash_firmware` reads as one
  and must never be one tap away. Declared on the two commands that qualify
  (`m6-fitness-band` `find_me`, `xiaomi-miflora` `blink_led`). The schema
  forbids `locate` on an `advanced` command in both directions — a locator is
  offered without confirmation, so it cannot also be a command a user needs
  protecting from
- `features[].session_open` and `features[].channel_tag` on an `image_upload`
  — the ordered commands a client sends before the first frame, named from the
  spec's own `commands` so their bytes stay in the command templates and only
  the choreography lives here, and the framing channel tag that flow writes
  under when the bulk characteristic cannot state one because its tag varies
  per transfer. This is the part of an upload a handler cannot derive:
  fragmentation and chunk sizing are properties `framing` already states, but
  which commands open a session is device knowledge. SmartDawn's is
  `[ui_end_sync, doodle_start]` writing under TUTU_RESTORE (4), and the wrong
  opener (`M_DEV_START`) blanks the canvas rather than failing — so a consumer
  that hardcodes the names cannot be pointed at a sibling device on the same
  platform without a code change. SmartDawn's BIN channel also states its
  200-byte `framing.max_chunk_size`, which was documented in prose only
- Command and parameter keys the catalogue was already using with nothing
  declaring them — several of them load-bearing. On a command: `setting_id`
  (which the mobile parser reads), `protocol_id` / `command_id` / `ui_id` /
  `ui_id_range` / `ui_id_min` (the framing-scheme selectors), `fixed_length`,
  `packet_layout` and `observed`. On a parameter: `default` (89 uses, and the
  thing that lets a control send only the parameter it owns), `allowed` /
  `labels` (which a consumer turns into a picker instead of a raw slider),
  `notes`, `endianness`, and `auto` for a value the client derives rather than
  the user supplying — `sequence`, `packet_length`, `checksum`. `endianness`
  on a parameter matters immediately: SmartDawn declares 88 of them `big`, and
  a consumer assuming little-endian writes those two-byte fields byte-swapped
  with nothing to notice
- Entity keys the catalogue was already using with nothing declaring them:
  `icon`, `precision`, `notes`, `variants`, `command_characteristic`,
  `min_temp` / `max_temp` / `temp_step`, `fallback_characteristic` /
  `fallback_state_characteristic`, `value_template`, and the RPC-style
  `state_endpoint` / `state_command` / `state_path` trio Divoom's panels use.
  `state_mapping` gains a description of the key set the catalogue actually
  puts in it (role keys, `scale`, `on_when`/`on_value`, `options`/`states`,
  bare-integer code tables) while staying open

- `device.category` — a **required** field carrying a broad device class from a
  closed 25-value vocabulary (`light`, `display`, `sensor`, `motor`, `switch`,
  `lock`, `tv`, `printer`, `climate`, `hub`, `vehicle`, `scale`, …). It is the
  field a program branches on, where free-form `device.type` is the field a
  person reads: the mobile app picks the icon it draws beside a scan result
  from `category`, so a device without one is drawn as an anonymous Bluetooth
  address — the same as a device nobody has documented at all. That is why the
  vocabulary is closed and the field is required rather than optional; an
  invented value degrades to the generic icon exactly like a missing one, so
  the schema rejects it instead. Backfilled across all 78 specs, and published
  in both machine indexes (`device-specs/index.json` and the JSON API
  manifest) so a consumer can categorise the catalogue without fetching a
  single spec. Reference specs take `category: reference`, and the schema
  enforces that this agrees with a `reference-` `type` in both directions — a
  device may no more claim `category: reference` than a reference may claim
  `light`, so a standalone consumer validating against the published schema
  cannot publish real hardware as a protocol reference. Locked down by
  `scripts/test_device_specs.py`, which reads the vocabulary out of
  `schema.json` rather than restating it; documented in
  `device-specs/README.md` and `docs/api/spec-format.md`

### Fixed

- **Two specs failed to parse outright, and each was a key saying something
  the vocabulary did not define.** Both are now fixed, and both classes are
  pinned by `scripts/test_device_specs.py` so they cannot come back quietly.
  - `fardriver-controller` declared `data: {type: bytes, min: 1, max: 26}`,
    meaning "1 to 26 bytes". `min`/`max` bound a *number* everywhere else, and
    a run of octets has no numeric range, so a consumer reading it that way
    rejected the parameter and lost the whole 500-line spec with it. `bytes`
    parameters now use `min_length`/`max_length`, and the schema rejects
    `min`/`max` on one — the two readings were indistinguishable and each was
    plausible.
  - `seeblue-motorcycle-led` spelled its transport envelope into nine command
    templates as `{message_length}`/`{message_index}`/`{checksum}`
    placeholders that no command declared and no client could fill, while the
    packet a client could actually send sat in `payload_template`, which
    nothing reads. Those bytes belong to the framing layer, so the
    characteristic now declares `framing.scheme: seeblue_envelope` (new, beside
    `daniao_fragment`) and every command's `template` is the packet alone —
    which is what the framing contract already said it should be. A further 26
    commands referenced parameters they never declared; those are declared now
    too. The spec went from 0 usable commands to 36.

### Removed

- `parameters.color_order` — a per-command declaration of RGB channel byte
  order, sitting beside a `template` that already emitted the channels in an
  order. Two statements of one fact with no stated precedence, so a spec whose
  two halves disagreed had no correct reading. All eight uses said `rgb` next
  to a template already naming `{red}`/`{green}`/`{blue}` in that order, and
  the schema's own example — "Shining Mask uses 'rbg'" — contradicted the
  Shining Mask spec, which says `rgb` and cites three public implementations
  for it. The template is the byte order: a device wanting GRB is written
  `template: ["{green}", "{red}", "{blue}"]`

### Changed

- Every key used in the blocks a client *executes* — `entities`,
  characteristic `format:` fields, commands and their `parameters` — must now
  be one `schema.json` declares, enforced by `scripts/test_device_specs.py`
  against
  the schema itself rather than a list of known slips, so an invented key
  fails too. Permissiveness is there to let a spec record vendor detail the
  vocabulary has no word for yet; in an executed block it means an invented
  key is not an extension but a control that silently does nothing. This
  generalises the existing `device.identification` near-miss check, which
  caught the same defect one name at a time
- `hotwired-heated-gear`'s entities now reach a consumer. Its climate entity
  declared `write_characteristic`, which nothing reads — the vocabulary is
  `command_characteristic` — so the entity that exists to set the heat level
  had no write path at all. Its battery sensor's code table was under
  `mapping` rather than `state_mapping`, and shaped as a list of single-key
  maps rather than a map, so it reached nothing either
- Four `format` fields in `airthings-wave-family` and `pax-vape` spelled their
  per-field caveat `description`; the declared spelling is `notes`
- `proglow-motorcycle-led` stated its channel bit masks in a bespoke
  `channel_masks` table beside a `channel_mask` parameter declared as a plain
  0-15 range. The vocabulary for "these exact values, with these names" is
  `allowed` + `labels`, which a consumer renders as a picker — so the masks are
  now reachable rather than being a table only a human could read
- The nine specs that already carried an ad-hoc `category` now use the
  controlled vocabulary: `smart_lock` → `lock` (Kevo, Nuki, Schlage),
  `automotive` → `reference` on the three published-protocol references
  (SAE J1979, ISO 14229, ISO 15765-2), `environmental` → `sensor`
  (SensorPush), `kitchen` → `sensor` (ThermoPro TempSpike). Nothing consumed
  those values — the mobile Rust parser swept `category` into `extensions`
  unread — and the four spellings for what turned out to be three classes are
  the drift the closed vocabulary exists to stop

- Number semantics in the device-spec schema (`$defs/number_semantics`): every
  numeric wire value — BLE command `parameters`, characteristic `format`
  fields, `bus` message fields, `payload_formats` fields — can now say what it
  *means*: a `unit`, an invertible linear transform (`scale` /
  `value_offset`), a `values` code table, and the C-vs-F machinery
  (`unit_source: fixed | device_setting` with a required `unit_reference` and
  a `unit_values` map) for devices such as the Inkbird iBBQ that transmit
  temperatures in whichever unit they are currently set to. Command
  parameters also gained `description`, `number` entities gained
  `min`/`max`/`step` in decoded terms, and HTTP/MQTT payload fields gained
  `unit`. Backfilled as worked examples: Ember Mug (fixed centi-°C wire unit
  vs display-only C/F characteristic, plus `values` tables for liquid state,
  volume and push events), Gerbing ThermoGauge (`value = raw × 0.5 + 85` °F —
  the `value_offset` case), Inkbird iBBQ (device-setting units), Wemo
  InsightParams (mW / mW·min columns). Contract-tested by
  `scripts/test_schema_number_semantics.py`; documented in
  `device-specs/README.md` and `docs/api/spec-format.md`

- `registries/` — the IEEE MAC address block listings (MA-L, MA-M and MA-S) and
  the Bluetooth SIG company IDs and service UUIDs, vendored as sorted
  fixed-width TSV so a consumer can binary-search the raw bytes and name a
  device that is in no catalogue at all. Regenerated by
  `scripts/fetch_registries.py`; invariants enforced by
  `scripts/test_registries.py`; provenance, licensing and the "an OUI names
  whoever bought the block" caveat in `registries/SOURCES.md` and
  `docs/api/registries.md`
- `device.identification.mac_prefixes` and `device.identification.manufacturer_data`
  in `schema.json`, so a scanner can rank an advertisement as *likely one of ours*
  before connecting — and `docs/api/spec-format.md` now explains why the four BLE
  identification signals are not equally strong, with `mac_prefixes` documented as
  a ranking hint that must never on its own claim a device is supported
- A per-entry `confidence` on `mac_prefixes` (`low` — the default — `medium`,
  `high`), because "weakest signal" was hiding a spread that matters: `C4:7C:8D`
  is an IEEE Registration Authority block that fifteen unrelated companies hold
  28-bit slices of, while `00:17:88` really is Philips Lighting's. An entry may
  now be a bare string (still `low`) or a `{prefix, confidence, notes}` map, so
  the finding that produced the verdict travels with it. Consumers can rank the
  two apart instead of flattening every OUI to the same hint — and a shared
  block can no longer act as half of a "two signals agree" promotion
- `device.identification.local_name_prefixes`, for a family sold as several
  rebadged models. `local_name_prefix` holds one string, so
  `inkbird-bbq-thermometer` — eight names, no shared prefix — had been carrying
  a `local_name_prefixes` key that was not in the schema and that no consumer
  read, leaving that family with no working name signal at all. The entries are
  alternatives, not a conjunction: matching any one means what matching the
  singular key means. Written up beforehand as P11 in
  `docs/contributing/spec-evolution.md`, now marked landed
- Identification data backfilled from what the specs already documented in prose or
  under `discovery`: manufacturer-data company IDs for Govee H5075, SwitchBot,
  Shining Glasses and the Oral-B iO (which had no `identification` block at all and
  advertises no service UUID, so the company ID is its only pre-connect signal), and
  MAC OUIs for Mi Flora and the Hue bridge

### Fixed

- **Two identification signals that named the wrong device, and one that named
  none.** The Hue bridge declared `upnp:rootdevice` and
  `urn:schemas-upnp-org:device:Basic:1`; Roku declared `_airplay._tcp`; lifx-z
  and rachio-controller declared `_hap._tcp`. Those are the generic UPnP,
  AirPlay and HomeKit announcements — every router, printer, NAS, Apple TV and
  HomeKit accessory on the link answers one of them, and a consumer treating a
  matched service type as identification badged all of them with those product
  names. Removed from `identification` (the `discovery` blocks still document
  them, because they *are* how you find these devices — they just cannot say
  that what you found is one). The Oral-B's `company_id` was the wire bytes
  read big-endian, `0xDC00` = 56320, which is unassigned; BLE carries the ID
  little-endian so the real value is 220 (Procter & Gamble, as the file's own
  byte map said) — and since that spec declares no local name and no service
  UUID, the brush could not be matched at all. The free-form
  `device.manufacturer_id` and three lines of prose still quoted `0xDC00`
  alongside the corrected value, telling a human reader the unassigned number;
  they now read `0x00DC` and say which end of the wire that is
- **SwitchBot no longer claims every Nordic and ESP32 device.**
  `additional_company_ids: [89, 741]` listed Nordic Semiconductor and Espressif
  — the SoC vendors' own assignments, carried by default by an enormous
  population of unrelated products — while the schema defines entries there as
  equivalent to `company_id`. Moved to prose, matching how
  `govee-h5075-thermo` already reasons about Nokia's widely-squatted 0x0001
- **Wemo's SSDP targets reach a consumer.** They lived only in the nested
  `identification.ssdp.search_targets` block, which sweeps into extensions, so
  the family the SSDP transport exists for ranked on its port alone. Added the
  flat `ssdp_search_targets` the matcher reads, alongside the nested M-SEARCH
  recipe — all seventeen vendor-specific targets, including the `motion`,
  `sensor` and `outdoor` types and the six Holmes/Mr. Coffee ones, which nine
  models in the file's own `variants` block answer on and nothing else does
- **`ssdp_search_targets` and `manufacturer_data.description` are now declared
  in the schema.** Both were in use and read by consumers but undeclared, so
  they validated only because `identification` has no `additionalProperties`,
  and the next typo in either would have been another silent no-op. The
  near-miss test now also asserts that every key it *recommends* is one the
  schema declares — it had been pointing authors at `ssdp_search_targets` while
  that key was itself undeclared
- **`fetch_registries.py` cannot silently destroy the vendored registries.**
  The builders key off literal upstream column headers, so a renamed column (or
  an error page served with a 200) made every row fail its width check,
  `_render([])` returned `""`, and the script overwrote a good file with an
  empty one and exited 0 — while `--check` in that state printed "run
  fetch_registries.py to refresh", i.e. the command that does the damage. Now
  each builder has a minimum-row floor and refuses to write below it. Reads and
  writes also pin `newline`, so regenerating on Windows cannot put CRLF into
  files whose contract is byte-offset binary search (and `--check` can no longer
  translate it back and report OK). A tautological test that recomputed its own
  constant is replaced by ones that check the floors cover every builder, that
  the committed data clears them, and that no registry contains a CR byte
- **`mac_prefixes` can express a 28- or 36-bit block.** The schema pattern —
  and the conventions test beside it — required whole colon-separated octets,
  so the only prefixes an author could write were the 24-bit MA-L ones. That is
  the width the confidence flag exists to warn about: `C4:7C:8D` is fifteen
  unrelated companies. Both now accept a trailing half-octet, matching the
  6-to-10-hex-digit rule the consumer already applied and the MA-M/MA-S tables
  vendored in `registries/`. Mi Flora, whose note had said in so many words that
  it could not express what it knew, now carries `C4:7C:8D:6` at `high` — sole
  assignment to HHCC Plant Technology, the OEM in its own model number — with
  the enclosing 24-bit block kept at `low` for octet-only consumers
- **The documented `additional_company_ids` example was the anti-pattern.**
  `docs/api/spec-format.md` showed `[89, 741]` — Nordic and Espressif, the two
  SoC-vendor IDs stripped from `switchbot-ble` two entries above — so an author
  copying the canonical example reintroduced the bug. Now shows a vendor's own
  second allocation (Google's 224 and 398), with the SoC case called out as the
  thing never to put there
- **`fetch_registries.py --check` ran at all.** The freshness comparison read
  its file with `Path.read_text(encoding=..., newline="")`, and `read_text` only
  grew a `newline` parameter in Python 3.13 — this project targets 3.12, so the
  check downloaded all five registries and then died on a `TypeError` before
  comparing one of them. Spelled as `open(...).read()`, which has taken
  `newline` since forever

- Two `identification` keys that no consumer has ever read. Roku declared
  `ssdp_search_target` and WLED `mdns_service_types`; neither is a schema key,
  and `identification` sweeps unrecognised keys into extensions rather than
  rejecting them, so a singular/plural slip is not an error — it is a silent
  no-op. Roku's `roku:ecp` is an exact, unambiguous SSDP target and it reached
  nothing. WLED's plural only added `_http._tcp`, which every web-serving device
  answers, so that one is dropped rather than migrated, with a note saying why.
  A new conventions test fails on the whole class. `inkbird-bbq-thermometer`'s
  `local_name_prefixes` was the same slip but could not be renamed — the family
  ships under eight names and the singular key holds one — so the schema grew
  the plural key instead (see Added), and the spec now reads as written
- The Lutron Caséta bridge carries no `mac_prefixes` after all. Its captured
  address `b8:94:d9:…` sits in a Texas Instruments block — it identifies the
  radio module inside the bridge, not Lutron, and listing it would have flagged
  every TI-radio device on the network. Found by checking the OUI against the
  newly vendored IEEE registry, which is the point of vendoring it
- `docs/protocols/standards-and-references.md` — the published standards this
  registry does or should cite instead of re-deriving them: Bluetooth SIG
  Assigned Numbers, the GATT Specification Supplement, the Base-UUID shorthand
  rule, the Nordic bluetooth-numbers-database, BTHome v2 for passive beacons, the
  CRC RevEng catalogue for reproducible checksums, and the automotive/interchange
  standards already cited by the OBD and `bus` specs
- `docs/contributing/spec-evolution.md` — a standing, evidence-backed list of
  proposed schema improvements (reproducible checksum descriptor, SIG-standard
  markers, `format` endianness and bit-fields, symmetric BLE command responses,
  first-class advertisement payloads, a normalized capability vocabulary, and
  SemVer for the schema), each with a compatibility note, informed by a
  comparison with the Buttplug BLE device-abstraction library
- Optional top-level `helpful_urls` and `helpful_videos` fields in device specs,
  with HTTP(S)-only reference entries and generated index/API exposure for
  website "Further reading / Watch" sections
- SPOTLED LED panel device doc, device spec and target starter — the OEM matrix-panel family
  (hats, badges, packs, banner signs) behind `com.led.spotled`, now the canonical home for the
  `0xFF20` protocol
- LED sign & panel design app survey (`docs/devices/led-sign-apps.md`) mapping design apps to
  device families, OEM platform clusters, and a triage checklist for unknown signs
- CoolLEDX / CoolLED1248 device doc, device spec and target starter — the unbranded BLE LED sign
  platform behind most AliExpress/Amazon car, bike, backpack and badge signs
- Target starters for iLEDColor (`com.led.iledcolor`), LED space (`com.yj.led`) and
  Divoom Pixoo (`com.divoom.Divoom`)
- OBD-II / vehicle diagnostics support: `docs/protocols/obd2-common.md` covering
  connectors (SAE J1962, ISO 19689), transports, ISO-TP framing, UDS services and
  capture methodology
- OBD-II Bluetooth adapter (ELM327 / STN) device doc and spec — BLE GATT families,
  Bluetooth Classic SPP, and the AT/ST command set
- Triumph Tiger 900 device doc, target spec and device spec, including the recovered
  service interval reset message (`33 <km/100>` / `34 <miles/100>` on CAN 0x701 to the
  instrument cluster) and the surrounding diagnostic surface — four separate stacks,
  UDS DIDs, DTC read/clear, ABS bleed, TPMS/immobiliser and instrument settings —
  derived from static analysis of the freeware TigerTool V3.51 and independently
  confirmed by decompiling TuneECU 23
- `obd` block and `obd2` protocol value in `device-specs/schema.json`, with a
  per-fact `verification` level so untested hypotheses cannot be mistaken for facts
- OBD-II device classification: `obd.role` (vehicle / adapter / module),
  `obd.adapter_profile` capability tiers (basic-clone, standards-elm327,
  advanced-stn, native-can), and per-request `command_class` (basic vs advanced)
  with a `requires` capability list, so a consumer can tell before connecting
  whether a given adapter can run a given command
- BMW motorcycle diagnostics device doc and spec — BMW's 0x6F1 D-CAN addressing with
  CAN extended addressing, the service interval data model (distance/date/valve-clearance),
  cluster-owned service data, module list, and the service reset itself — UDS
  WriteDataByIdentifier on BMW's 0xE1xx DIDs (`2E E1 2B/2C/2D`) with matching reads —
  recovered from the shipped MotoScan app
- BMW motorcycle / MotoScan target starter (`de.wgsoft.motoscan`) — the same
  service-interval-reset problem as the Triumph work, with an analysis plan and the
  observation that the app vendor also makes the UCSI-2100 adapter whose 255-byte
  message support exists because BMW's protocols need it
- Named OBD-II adapter coverage: UniCarScan UCSI-2100, OBDLink MX and OBDLink MX+,
  with per-model capability profiles, plus an `alt_can_bus` capability (Ford MS-CAN /
  GM SW-CAN) and a tool-requirement matrix covering FORScan, TuneECU, TigerTool,
  MotoScan, BimmerCode, OBD Fusion and Torque Pro
- `scripts/obd_discover.py` — read-only ECU and DID reconnaissance over an
  ELM327-class adapter, plus working vehicle modes: `--triumph-sia` /
  `--triumph-reset` for the Triumph cluster and `--bmw-scan` / `--bmw-module` for
  BMW's 0x6F1 addressing. The BMW scan supplies the module addresses the decompile
  did not; the Triumph reset reads state before and after and refuses to run
  without `--yes-write`
- Vendor ECU-description file references in the schema: `obd.description_files` at
  vehicle and per-ECU level for BMW/EDIABAS SGBD `.prg` and `.grp` files (plus ODX,
  PDX, CDD, A2L and DBC), and per-request `job` / `results` linkage so a recovered
  frame ties back to its authoritative definition. Files are referenced and
  checksummed, never redistributed
- Triumph odometer reply decoded from TigerTool's parser: `0D 01` answers
  `704 8D 01 <b1> <b2> <b3>`, a 24-bit big-endian value in kilometres, with
  `5E 01` -> `704 DE` flagging a TFT dash and selecting which mile divisor
  (1.60934 vs 1.6099895) the tool applies
- Initial device setup (provisioning) coverage:
  - `device.setup` block in `device-specs/schema.json` — onboarding methods,
    factory reset procedures, rebinding, and credential handling
  - `device.setup` populated for every device spec, including the OBD-II
    vehicles and adapter, where `factory_reset.applicable: false` records
    that a vehicle has no reset rather than inventing one
  - `docs/protocols/device-setup.md` — cross-device onboarding patterns for
    WiFi (SoftAP) and BLE devices
  - `docs/devices/wemo-setup.md` — Wemo factory reset, provisioning over the
    device's setup AP, and rebinding to a new network via `ReSetup`
- `scripts/test_wemo_scaffolding.py` — pins the Wemo scaffolding to the spec it
  verifies, so a script that has drifted cannot pass for a verified document.
  Skips cleanly when the scripts are removed
- `scripts/test_wemo_spec.py` — proves the Wemo spec is implementable from the
  spec alone for all three client jobs (discover, control, provision):
  transcribes the published protocol using only the standard library and
  `openssl`, and asserts the transcription reproduces the spec's own examples
  and test vectors
- `docs/api/spec-format.md` — how to read a device spec, with the `setup` block
  covered field by field
- `scripts/test_device_specs.py` — cross-spec consistency checks for conventions
  the schema cannot express (explicit `verified`, reset procedures with steps,
  `rejoin` answering the router-replacement question, and so on)
- Schema documents the well-known `setup` extension blocks — `payload_formats`,
  `timing`, `troubleshooting`, and a much richer `credential_encryption`
  including `algorithm_steps`, `variants` and `test_vectors`
- `wemo-devices.yaml` is now implementable on its own: SOAP wire format,
  `MetaInfo`/`ApList` payload layouts, the encryption algorithm step by step
  with reproducible test vectors, timing constants and a troubleshooting table
- `requirements-dev.txt` and `pyproject.toml` — ruff and pytest configuration
- CI `lint-and-test` job running `ruff check` and `pytest`
- Initial project structure
- Device documentation template
- Getting started guides
- MkDocs Material theme configuration

### Changed

- Reframed the OBD-II guardrails for repair-café use: maintenance writes (service
  interval resets, TPMS sensor IDs, clearing recorded faults) are in scope and are the
  point, with a function-risk tier table and bench sequences for the Triumph and BMW
  service resets
- Coding, flashing, immobiliser and key work are documented and flagged
  `advanced: true` in the schema rather than excluded — reviving an old bike needs
  them. Only odometer falsification and work on a moving vehicle stay out
- LEDs2Rave4 / Lunchbox Dream LED docs now map each product generation to its design app
  (LED CHORD → SPOTLED → iLEDColor) and document the SPOTLED framed BLE protocol on `0xFF20`,
  corroborated against `python-spotled`
- The Wemo protocol now lives in `device-specs/devices/wemo-devices.yaml`
  rather than in scripts: the SSDP datagram and response handling, the rule
  separating Wemo from other UPnP responders, the description parse rules
  including Belkin's vendor extensions, the SOAP wire format, and
  `payload_formats` for `BinaryState`, `InsightParams` and `MetaInfo`.
  `scripts/wemo_discover.py`, `wemo_control.py` and `wemo_setup.py` are
  retained only as verification scaffolding until the spec has been checked
  against hardware, and are marked as such (#16).

### Fixed

- `InsightParams` was documented without the `wifipower` field, which shifts
  every power reading one column left — now published field by field with an
  example
- `test_build_index.py`: hardcoded device list had rotted into a failing test
- `mkdocs.yml`: ten device pages existed but were missing from the nav
- `docs/devices/wifi-discovery.md`: content appeared above the page title
- `docs/devices/vector-robot.md`: corrected the repository URL and a heading level
- `docs/devices/discovery.yaml`: split into separate YAML documents; the four
  examples shared one top-level key and collided
- Device specs: removed `local_name_prefix: ""` values, which match every
  BLE device when used as a scan filter
- `targets/wemo-devices.md` claimed WiFi provisioning was app-only and out of
  scope, gave the setup AP prefix as `WeMo.Setup.`, and called `InsightParams`
  colon-delimited — all three contradicted by this branch's own findings
- `VERIFICATION_REFERENCE.md` now says on its face that it is not reproducible,
  since its APK column probes the gitignored workspace directory (#18)
- Wemo SOAP requests put action arguments in the service namespace
  (`<u:BinaryState>`); UPnP arguments are unqualified, and the request body now
  matches the wire format pywemo and ouimeaux send
- Wemo setup: the passphrase length suffix was not zero-padded, so any length
  below 16 produced a blob the device rejects; MetaInfo field order was
  documented backwards (field 0 is the MAC, field 1 the serial); only one of
  the three encryption variants was implemented; `ReSetup` was called without
  its required `Reset` scope argument; and `ApList` parsing did not skip the
  header line or read the auth/cipher pair from the last column
