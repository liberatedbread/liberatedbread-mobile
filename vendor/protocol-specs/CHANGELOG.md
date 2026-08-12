# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- Hub children and paired credentials (P12), building on the `method` that
  Roku's remote just added to `commands`: two new parameter `source` schemes
  and one entity key. `credential:<name>` names a per-device secret the
  client stored at pairing; `instance:<key>` names the id of the child a hub
  command currently addresses; both inherit the `source` contract that a
  renderer holding no value must fail the send visibly, because an unpaired
  client quietly issuing requests is the bug the contract exists to prevent.
  `entities[].instances` declares an entity a template stamped out per child:
  the `state_command` reply is a JSON object keyed by child id, enumeration
  and every child's state in one request, and `state_mapping` paths resolve
  inside each child's object. The `method`/`path` pair the Roku work
  introduced now also carries the Hue GET-and-PUT-on-one-resource case in its
  note. A `headers:` vocabulary (CLIP v2 moves the credential into a header)
  is deliberately deferred and flagged in the proposal
- The Hue Bridge spec now walks as well as talks: a `commands:` block
  (`create_user` pairing plus `light_turn_on` / `light_turn_off` /
  `light_set_brightness`, each with its rendered `example_body`), an
  instanced `Hue Light` entity bound to the one `GET …/lights` call that
  enumerates and reads every child at once, `payload_formats.V1Envelope`
  capturing the v1 array envelope and the three error types a client must
  know (101 keep-polling, 1 re-pair, 201 carry-`on:true`), example request
  and response bodies on the Bridge Config / Create User / Lights / Set
  Light State endpoints, and the TLS facts a client cannot proceed without —
  per-device leaf whose CN is the lowercase bridgeid, signed by Signify's
  private `root-bridge` CA, so the correct verification is CN-check plus
  trust-on-first-use pinning keyed by bridgeid, never a public-chain check
  and never an HTTP fallback on pin failure. `scripts/test_hue_spec.py`
  transcribes pairing, rendering, typed substitution (`bri` renders as a
  JSON number), child enumeration and the bridgeid-is-the-MAC-in-EUI-64
  rule from the YAML alone, stdlib only, and diffs them against the spec's
  own examples — the same keep-it-honest bar `test_wemo_spec.py` set for
  SOAP. Brightness is 1–254 with `"on": true` riding along, write replies
  are per-attribute acknowledgements so read-back is mandatory, and the
  YAML spells the `"on"` key quoted because unquoted `on` is a boolean in
  YAML 1.1
- `lifx-z` now documents its LAN control surface byte-for-byte, so the LIFX
  binary UDP protocol is implementable from the spec alone. A top-level
  `payload_formats` block gives the 36-byte header (with the `0x1400`/`0x3400`
  protocol constants and the `source` id spelled out), the HSBK colour, and the
  `SetColor`/`SetPower`/`GetService`/`SetColorZones`/`State`/`StateMultiZone`
  messages as field tables plus full example datagrams; `scripts/test_lifx_spec.py`
  transcribes each message from those field tables and the
  `lifx_lan_protocol.message_types` numbers and checks it reproduces the example,
  the same bar `test_wemo_spec.py` holds the Wemo surface to. `identification`
  gains an `ssdp_search_targets: ["lifx:udp"]` token — the synthetic target a
  client emits after a UDP `GetService` broadcast confirms a LIFX device, so a
  positive LAN probe is a vendor-specific (non-shared) match rather than the
  "possible" a shared `_hap._tcp` sighting earns, which is the discovery path the
  Matter caveat needs. Adds the missing `targets/lifx-z.md`. The control messages
  and the legacy SoftAP onboarding remain `verified: false` — they are documented
  and transcription-checked, but not yet replayed against hardware.
- `airthings-wave-family` binds temperature and humidity to each model's
  combined packet (Wave Gen 2 `b42e4dcc`, Wave Plus `b42e2a68`, Wave Mini
  `b42e3b98`). The SIG characteristics (2A6E/2A6F) are app-derived and
  unobserved in either hardware capture, while the combined packet is what
  the vendor app reads and is capture-verified — so a unit that never
  exposes the SIG characteristics previously showed radon and battery but
  no temperature or humidity. The SIG bindings are now scoped
  (`variants: Wave (Gen 1), View Plus` — the models with no decodable
  combined packet), so every variant resolves exactly one binding per
  reading under the schema's declared variant model rather than by an
  implicit first-match rule; the combined bindings are also listed first
  for characteristic-keyed consumers meeting hardware that exposes both
  interfaces. Also new: `Ambient Light` on all three combined packets (raw
  0-255 counts, deliberately no `illuminance` class since the counts are
  not lux — the field is capture-verified on Wave Gen 2), and Gen 1's
  dedicated 1-hour radon characteristic (`b42e06dc`) bound as
  `Radon 1h Average`, its third documented radon reading and the
  fastest-moving of them. Variant `sensors` lists gain `light` accordingly
- `airthings-wave-family` surfaces every sensor each model actually has, not
  just the six readings the entity list happened to name. The Wave Plus
  combined characteristic (`b42e2a68`) now carries the shared 20-byte layout
  as a machine-readable `format:` block — the layout was already documented,
  but only as prose pointing at the Wave Gen 2 declaration, and consumers
  resolve byte layouts by characteristic UUID, so every Wave Plus combined
  reading was undecodable. The Wave Mini combined characteristic
  (`b42e3b98`) gains its format too, taken from the decode functions of the
  two vendor-published readers the spec already cited for its UUID
  (wavemini-reader, airthings-ble; MEDIUM confidence, note the centikelvin
  temperature). On top of those: CO₂, VOC and Dew Point entities for Wave
  Plus, VOC and Pressure entities for Wave Mini, and radon entities for Wave
  Gen 2 and Wave Plus bound to their combined packets — the dedicated radon
  characteristics live on the Gen 1 service only, so a Gen 2 or Plus unit
  previously matched no radon binding at all. One logical reading appears
  once per variant-specific binding (same name, disjoint `variants`),
  which a characteristic-keyed consumer resolves to exactly one per unit
- Roku ECP: a channel launcher. The `Channel` select's options are whatever
  the device says it has installed — `options_source` fetches
  `/query/apps`, `state_source` reads the current channel from
  `/query/active-app` (which carries no id on the home screen: that reads
  as nothing selected, not an error), and selecting an option launches it
  via `POST /launch/{app_id}`. Both queries stay open when "Control by
  mobile apps" is disabled, so the list loads even on a TV refusing every
  keypress. The two endpoint entries gain worked response examples, and
  `test_roku_spec.py` runs the source contract against them
- `options_source` / `state_source` on `select` entities — where a select
  gets options the spec cannot enumerate because they live on the device,
  and which of them is current. A deliberately tiny XML contract: the named
  `http_endpoints` entry is the request; every element with the item's
  local name is one entry; the named attribute is the raw value; the
  element text is the label. A select carrying `options_source` needs no
  static options table and no state binding to be offered — the options are
  its surface
- Roku ECP: the remote as a control surface. A `commands` block names one
  `transport: http` invocation per remote key — power, D-pad and navigation,
  playback transport, volume, live-TV channels, and TV input switching — and
  `entities` declares each as a `button` in remote-layout order, covering
  every key the official Roku app's remote sends over ECP. The previous
  `select` entity bound a path string no command declared, so nothing could
  resolve it; the buttons are the resolvable one-command-per-option form.
  An `ecp_common` block records the whole transport (empty POST body, the
  Lit_ percent-encoding rule, the OS 14.1 "Control by mobile apps" 403), the
  endpoint catalogue gains keydown/keyup, icon, tv-channels,
  tv-active-channel and install, and `openness` cites the official ECP
  documentation the vocabulary is transcribed from. `scripts/test_roku_spec.py`
  renders every button from the YAML alone and diffs it against the
  documented key list, including the app-parity claim itself
- `button` entity platform — a momentary action with no state to read back.
  Binds exactly one role, `press`, whose command must have no caller-supplied
  blanks, and is the one platform excused from naming a state source:
  statelessness is the honest description of a keypress. Added for the Roku
  remote; the enum note says which consumer it is kept aligned with
- `method` on spec `commands` — the HTTP method of a `transport: http`
  command, stated on the command itself so a consumer can send it without
  joining two blocks by name. Roku's whole control surface addresses by
  method and path; the SOAP commands that resolve their address by service
  URN never state it
- `status` on `http_endpoints` entries (`active` | `sunset` | `unverified`) —
  Roku's `/search/browse` has carried `status: "sunset"` since the OS 12.0
  removal notice and SmartThings' port-8081 root carried `"unverified"`, both
  into a key the schema did not declare. Declared, so a consumer can filter
  on lifecycle as data rather than parse SUNSET out of prose
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
- A control surface for the two Wemo devices we have hardware for — the smart
  plugs (`F7C063` Mini, `WSP080`, and the Outdoor and Insight plugs that share
  the surface) and the Crock-Pot Smart Slow Cooker. `wemo-devices.yaml` could
  already be *found* and *provisioned* from the file alone; controlling one
  still meant reading prose and knowing UPnP. It now carries `entities` (which
  controls to draw and where each reads its state) bound to a new top-level
  `commands` block (what to send, with the arguments already chosen), both
  naming actions documented in `http_endpoints`. A consumer that already
  renders a BLE spec's entities needs one new transport, not one new device:
  five entities land through the mobile app's own parser today, roles and
  variant scoping intact, with only the SOAP execution missing
- Top-level `commands` in `schema.json` — named invocations for devices with
  no GATT characteristic to hang a command on, keyed by name so an entity's
  role map (`turn_on: plug_turn_on`) resolves the same way whatever the
  transport underneath it is. Two keys carry the weight. `source`
  (`state:GetCrockpotState.time`) says where a client reads a value it is
  *not* the one setting: `SetCrockpotState` carries mode and cook time
  together, so switching a slow cooker to Warm without sending the current
  time back also clears the timer, and a spec that leaves that implicit
  produces exactly that client. `default` is what makes a command sendable at
  all — a control can only send a command whose every blank it can fill.
  `airthings-wave-family` has kept a top-level command catalogue since before
  anything declared one, so the block is deliberately not
  `additionalProperties: false`
- `example` on an `http_endpoints` request and response body, and `example_body`
  on a command — the literal bytes, for the same reason crypto blocks carry
  test vectors: they turn "the device rejects this and I cannot tell which
  half is wrong" into a diff. `scripts/test_wemo_spec.py` renders the plug and
  Crock-Pot commands from the published `arguments`/`parameters` and diffs
  them against those bodies, then drives all four Crock-Pot entities out of
  the published `GetCrockpotState` response and the plug's out of a
  `GetBinaryState` long form — stdlib only, importing none of our code
- `soap_common.eventing` — the UPnP `SUBSCRIBE`/`NOTIFY` flow Wemo devices push
  state on, with the callback header shape (the angle brackets are part of the
  value), renewal on the `TIMEOUT` the device grants rather than the one you
  asked for, and the property names each device sends (`BinaryState`;
  `mode`/`time`/`cookedTime` on the Crock-Pot; `InsightParams`). Polling
  `GetBinaryState` cannot see somebody pressing the button on the device
- `scheduling` — how a device performs an action at a future time BY ITSELF,
  with nothing else on the network. Worth a block of its own because the
  difference is invisible from the control surface and decides what an
  integration can promise: a client can always send an on command at 17:00 if
  it happens to be running, and on a sleeping phone it will not be. Wemo keeps
  a SQLite database of rules that it hands out and takes back over SOAP
  (`rules#FetchRules` → version + URL, `GET` the ZIP, edit, `rules#StoreRules`
  with the base64 wrapped in an XML-escaped CDATA marker that looks like a
  typo and is not), and runs the schedule off its own clock. Documented with
  both tables, two worked rows — one written by pywemo, one captured from a
  device the Wemo app configured — and, as prominently, the limits: a rule's
  action is `1.0` on / `0.0` off / `2.0` toggle, so a scheduled Crock-Pot
  *mode* is not expressible, and the Crock-Pot's own `time` is a countdown the
  appliance runs rather than a start time. `open_questions` names what is
  inference rather than evidence, `DayID`'s encoding first: a schedule written
  from a guessed column fires on the wrong day
- `http_endpoints[].service` — the service an action belongs to, as data. The
  Wemo endpoint descriptions all quoted the SOAPACTION URN in prose, and the
  repo's own tests even asserted the quoting — but a client that must build
  the header for a state read (`GetCrockpotState` is invoked by nothing in
  `commands`; it is only read from) had nowhere to get the URN except parsing
  a sentence. Declared on all ten SOAP endpoints;
  `scripts/test_wemo_spec.py` pins that every endpoint an entity reads state
  from declares it, and that it agrees with the URN the description still
  quotes — two spellings of one fact are only safe while something checks them
- `payload_formats.delimiter` — the separator for a payload that packs several
  fields into one string, so `fields[].index` becomes executable. "Split on
  `|` and take field 0" had been the documented rule for Wemo's `BinaryState`
  for as long as the format has been written down, and prose is not something
  a decoder can follow: every consumer either hardcoded it per device or got a
  plausible wrong answer, since `8|1492338954|…` read whole is not a number
  and a client that gives up there shows a live plug as off. Declared on
  `BinaryState` and `InsightParams`; `scripts/test_wemo_spec.py` now splits on
  the declared value rather than a hardcoded pipe
- `payload_formats.CrockpotMode` — `0` off, `50` warm, `51` low, `52` high, with
  the two things the bare table does not say: the numbers are not an ordering,
  and an unrecognised value must not be folded into `off`, which would tell a
  user their cooker is off while it is heating

### Fixed

- `schema.json` no longer defines the parameter `auto` key twice. The
  checksum extension added a second `"auto"` member to the same `properties`
  object instead of extending the first; JSON objects cannot carry duplicate
  keys, so permissive loaders silently kept whichever one they preferred and
  a strict loader could reject the whole schema. One definition remains,
  merging both descriptions (the checksum algorithm and the
  never-render-as-a-control consumer rule)
- `urevo-walking-pad` research note: the `set_speed_and_slope` example frame
  carried checksum `0x73` — the pre-XOR sum, contradicting the note's own
  formula `((B + C + payload) & 0xFF) ^ 0x5A` and every literal frame beside
  it (stop/pause/resume/status all verify). The example now shows `0x29`, a
  frame a pad should actually accept. The two `query_*_config` frames'
  checksum comments still do not reproduce their dumped bytes under any
  consistent rule and are left as dumped — flagged for re-verification
  against the disassembly rather than silently "corrected"
- `airthings-wave-family`'s radon entities no longer claim
  `device_class: volatile_organic_compounds_parts`. Radon in Bq/m³ is a
  radioactivity concentration, not a chemical one, and the class was not
  cosmetic: a class-driven consumer would band, convert or chart the reading
  against VOC ppb semantics — Home Assistant validates the class/unit pair
  and Airthings' own VOC thresholds (250/2000 ppb) are nothing like its radon
  ones (100/150 Bq/m³). There is no radon device class to claim, so the
  entities carry `icon: mdi:radioactive` and the unit says the rest
- `airthings-wave-family`'s radon entities also dropped the "Wave Plus"
  variant claim from the Gen-1-service bindings (`b42e01aa`/`b42e0a4c`):
  those characteristics live on the Gen 1 air sensor service and were never
  confirmed on Plus hardware, whose radon the vendor app reads from the
  combined packet (now bound by dedicated Wave Plus entities)
- A `source` parameter no longer carries a `default`, and the schema now
  forbids the pair outright. Review (PR #16) caught what the first published
  version got wrong: `default: 0` sitting beside every Crock-Pot read-back as
  a "fallback" is a renderer papering over a failed read with a constant —
  a cleared timer when changing the mode, or `mode: 0` stopping a RUNNING
  cooker when the user only adjusted the time, with nothing on screen saying
  so. The two keys answer "the caller supplied nothing" with opposite
  instructions (substitute the constant vs. fail the write visibly), so a
  parameter now carries exactly one; the stray `required: true` on read-backs
  is gone too, since `required` means the caller supplies it and a read-back
  is the client's job. `scripts/test_wemo_spec.py` renders the failure paths:
  a mode change without the read-back value raises, and only `turn_off` — the
  one write with nothing to read first — renders from a cold start
- `scheduling.supported` is scoped. It said `true` for the whole family while
  `open_questions` admitted nobody knows whether the appliance classes honour
  rules at all — so a consumer branching on the field would advertise
  on-device scheduling for a slow cooker nobody has scheduled. `applies_to`
  (new schema key) names the eight switch-family variants the evidence
  covers; outside the list the honest reading is UNKNOWN, not yes
- The empty-rules-database recovery path is now implementable: the seven
  tables beyond RULES/RULEDEVICES were named but not described, so a client
  whose device 404s the database download (never held a rule) could not
  build the empty one the spec tells it to create. All nine tables' columns
  are now transcribed from pywemo's ORM — the same code that both reads real
  devices' databases and creates the empty one — including the two standing
  oddities (RULES.Sync, INTEGER holding 'NOSYNC'; BLOCKEDRULES.ruleId, a
  string where every other rule id is an integer)
- The Crock-Pot variant no longer reads as though `GetBinaryState` were a state
  reading on it. It listed the action under `basicevent` beside the two
  Crock-Pot ones and said nothing further, so the obvious implementation — the
  one every other Wemo switch uses — ships a cooker that reads as permanently
  off with a toggle that springs back, and nothing in the response says why.
  The device answers `0` there whatever it is doing; on/off is `mode != 0`
  from `GetCrockpotState`. Said in the variant, at the `GetBinaryState`
  endpoint, on the entity that had to avoid it, and pinned by a test. Also
  spelled out that the appliance actions live on `basicevent` rather than the
  `crockpotevent` service catalogued next to them, which is marked
  `hypothesis` — it came from the Jarden family's shape, not from a
  Crock-Pot's own `setup.xml`, and nothing drives it
- `hotwired-heated-gear`'s climate entity can be driven at all. Its write
  characteristic carries an 8-byte `AA <status> <level> 00 00 00 00 55` frame,
  so there is no bare value for the direct-write path to write, and the command
  that builds the frame sat in a top-level `commands:` block — a byte-by-byte
  `frame:` table no consumer reads. `set_heat` is a real characteristic command
  with a template now, and the entity binds to it explicitly; `status` defaults
  to ON so a level control supplies only the level. The duplicate top-level
  block is gone rather than left to disagree with it, with its worked hex
  examples, echo acknowledgment and 3-second retransmit folded into the
  command's description
- `seeblue-motorcycle-led`'s framing no longer claims `checksum: sum`. The
  enum's `sum` means the sum itself is appended and this protocol appends its
  8-bit two's complement, so a consumer executing the generic field would emit
  a different final byte on nearly every frame. The scheme states the real
  algorithm; a near-miss generic value contradicting it is worse than no value
- `smartdawn-smart-lights`' BIN notes told a reader to open with
  `M_DEV_START + M_DOODLE_START`, which the same spec's feature block warns
  blanks the canvas. That sentence is the one a byte-level implementer reads
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
