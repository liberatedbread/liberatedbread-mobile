# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Fixed

- **The catalogue validates against its own schema again — 188/188.** `main`
  had been red: nineteen specs failed `validate_specs.py` and seventeen pytest
  guards failed. The fifty-spec expansion wave was written against the schema as
  it stood when its branch opened, and the spec-driven-controls work tightened
  three things underneath it, so the merge produced a catalogue that no longer
  satisfied its own rules with nothing re-running to say so. Sixteen specs
  carried a bespoke block at a top level that had since closed — their protocol
  facts were somewhere no reader would look for them — and three declared a
  `websocket:` block in the shape the first-class one replaced, so nothing could
  execute it. Each moved to where it belongs, verified by round-tripping every
  file: the content is byte-identical as data.

- **Thirteen `GET /` endpoints hedged "placeholder" in prose while leaving
  `status` off**, which by the schema's own rule reads as active and usable —
  the opposite of what the prose said.

- **bambu-lab-lan's four MQTT commands named no topic.** On MQTT the topic IS
  the address, so they had nowhere to publish. They address
  `device/{serial}/request`, with the serial declared `credential:serial` — it
  is read off the touchscreen beside the Access Code, which the credentials
  block now records.

- **euc-wheellog-ble carried a `ble_scan` method with an empty matcher.** The
  spec already explained why nothing can match: the BLE module is generic and
  the brand is only known from the first notification packets, which is a scan's
  output and not its input. That is `discovery.none`, and it says so now.

- Five sensors spelled degrees `°C`/`°F` where the unit vocabulary is `C`/`F`;
  four reference specs claimed a `model` where a standard states `coverage`.

### Added

- **A documented vocabulary for `entities[].commands` role names**, per
  platform, pytest-enforced — the same shape as `entities[].key` and
  `category`, and for the same reason: a list rather than a schema enum keeps
  growth additive and never hard-fails a strict parser.

  The key was declared as a bare `{"type": "object"}`, so any key validated,
  while every consumer matches a closed set of role names and passes over the
  rest without a word. A binding outside that set therefore reads as wired,
  resolves nothing, and produces no error, no warning and no missing-control
  note — the entity resolved its OTHER roles, so nothing reports it. Eighteen
  bindings across seven specs had drifted out that way, found by a consumer
  holding its resolver's table against this catalogue; the catalogue could not
  have found them itself.

  Four specs were wrong and are fixed: openevse's amp setpoint bound `turn_on`
  (a fixed role, on a `number`); yeelight-cube-lamp spelled its colour roles
  after the commands they name rather than after the vocabulary, so the lamp
  offered power and brightness and nothing else; a name badge bound `set_text`
  to the chunk write of a bitmap upload; and ember-mug's two selects have one
  parameterless command per option, a shape no role describes — those bindings
  moved into notes that state the gap, since it is a schema question and not a
  per-device one. Two role groups the catalogue was already using are declared
  rather than removed: `set_color_temperature` on a light, and power plus
  `set_hvac_mode`/`set_fan_mode` on climate.

- **govee-h5075's `request_history` states its nine pad bytes and its trailing
  checksum in the template**, rather than leaving them to `fixed_length`. A
  consumer that pads a short frame pads at the END, which would bury the
  checksum at byte 10 and leave byte 19 zero; `packet_layout` has always said
  where they go, and the template now says it in the form an encoder reads.

- **Denon AVR-S720W** (`denon-avr-s720w`) — a 2016 KnOS-generation Denon
  receiver, and the registry's first AV receiver. Four surfaces on one
  address: the undocumented `/goform/` HTTP API on port 80, the
  vendor-published ASCII control protocol on port 23, a UPnP MediaRenderer,
  and AirPlay 1 + Spotify Connect sinks. The two control routes carry the
  *same* command vocabulary — `GET /goform/formiPhoneAppDirect.xml?PWON` and
  `PWON\r` on port 23 are one command — so every entity binds over HTTP and a
  consumer that cannot hold a socket loses only the state push. There is no
  authentication anywhere on the local surface; reachability *is* the access
  model, and the spec says so rather than implying a credential protects it.

  Discovery is the hard half, because everything the receiver announces is a
  generic standard (`_http._tcp`, `_airplay._tcp`, `_raop._tcp`,
  `_spotify-connect._tcp`; SSDP `MediaRenderer:1`). Three vendor-shaped
  details do the identifying instead, all three observed on live hardware: the
  SSDP `SERVER` header reads `KnOS/3.2 UPnP/1.0 DMP/3.5` and `KnOS/` is D&M's
  firmware platform; the UDN's node field is the MAC, so a UDN ending in
  twelve hex digits starting `0005cd` is a D&M device (a vendor signal and the
  stable identity — but not a join key against the AirPlay `deviceid`, since a
  receiver has two MACs and the records may carry different ones); and the
  Spotify Connect
  `cpath` is `/goform/spotifyConfig`, putting D&M's own web-API namespace in a
  TXT record. `device.testing` is `untested`/`capture-verified` accordingly —
  the discovery half is quoted from a contributed live scan, the control half
  is graded `reported` from Denon's control-protocol documents and from
  denonavr and the openHAB denonmarantz binding.

  The traps are written down where a consumer will hit them. Volume is
  expressed two ways on two routes that both work — signed dB in the status
  documents and on `formiPhoneAppVolume.xml`, an offset integer on the ASCII
  route, differing by 80 (`dB = MV - 80`), so `-20.0` is `MV60` and sending
  `MV20` instead lands 40 dB quiet. -40 dB is the one level where the two
  encodings share their digits, so it is the one value a round-trip test must
  not use; the spec says so where the conversion is defined. At minimum
  the receiver reports the literal string `--` rather than a number;
  `VolumeDisplay: Absolute` changes only the front panel; mute reads lower
  case and writes upper case; surround selection is a *request* the receiver
  may substitute and report back with no error; port 23 accepts one client
  and holding it locks out the vendor app; and the whole LAN surface is
  powered down in standby unless **Setup > Network > Network Control** is
  "Always On", with no documented Wake-on-LAN path. Also recorded is what is
  *absent*, so a probe that finds nothing is not read as a fault: no HEOS
  Built-in and therefore a closed TCP 1255 (HEOS arrived with the 2018
  AVR-S750H), AirPlay 1 only with no `pk` record, and a single zone.

  The WiFi discovery guide gains a section on this shape of device — one
  that offers no vendor search target at all — since it generalises past
  Denon: identify on the M-SEARCH *reply* rather than the query, using the
  `SERVER` header, the UDN's node field (very often the MAC, so an OUI lookup
  names the vendor with no HTTP request at all), and TXT records belonging to
  third-party protocols, which routinely leak the vendor's own namespace.

  The TXT-record signals are declared machine-readably, not just narrated:
  the spec claims `_spotify-connect._tcp` with an `mdns_txt_match` on
  `cpath = /goform/spotifyConfig`, and its AirPlay/RAOP discovery methods
  carry `txt_match` conditions (`deviceid` prefix `00:05:CD`, `am` prefix
  `AVR`) — the platform-service-type contract the ESPHome fix established,
  applied at authoring time. The advertised-but-unmatchable `_http._tcp`
  record stays in the evidence and out of the methods, since with no TXT
  data to narrow it a method there would claim every web server on the
  link. Only the `KnOS/` SERVER header remains prose, because the schema
  has no SSDP-reply matcher slot yet.
- **`commands[].path_fallback` and `entities[].state_topic_fallback`**
  ([P15](docs/contributing/spec-evolution.md#p15)): a second address for the
  same invocation or reading, for a family whose firmware generations name
  entities differently — the HTTP siblings of `fallback_characteristic` and of
  `state_mapping`'s `<role>_fallback`. Try `path`, and fall back only on an
  unambiguous 404, never a timeout and never a blind second send; a door that
  opens twice because the first request was slow is worse than the 404 the key
  exists to survive. `ratgdo` carries the legacy ESPHome object_id paths this
  way, so boards on firmware older than 2026.1 stay drivable from the file
  rather than only from its prose.

- **ESPHome is a platform, not a garage door.** `_esphomelib._tcp` is the
  service type of the ESPHome *firmware*, and `ratgdo` was the only spec
  claiming it — so a consumer resolving a service type to a spec labelled every
  ESPHome node on the LAN a garage-door opener, complete with `/cover/door`
  controls for entities those nodes do not have. Three changes fix the class of
  bug, not just this instance ([P14](docs/contributing/spec-evolution.md#p14)):

  - **Schema**: `$defs/mdns_txt_match` plus `identification.mdns_txt_match` and
    `discovery.methods[].mdns.txt_match` — ANDed conditions on TXT records
    (`exact`/`prefix`/`contains`/`regex`/`present`/`absent`) that narrow a
    platform service type to one product — and
    `discovery.methods[].mdns.platform_fallback`, which marks the one spec per
    service type that is *meant* to catch everything no matcher claimed.
    Additive: a consumer reading only `mdns_service_type` is unchanged.
  - **`esphome-device`** (new spec): the ESPHome platform itself, as the
    fallback. It deliberately declares no `entities` — it cannot know what a
    node has — and instead documents how to ask: `GET /events` emits one
    `state` event per entity on connect (the enumeration path; there is no
    list-entities URL), the REST grammar `/<domain>/<entity>[/<action>]` with
    the sub-device forms, the native API's framing (`0x00` plaintext, `0x01`
    Noise `NNpsk0_25519_ChaChaPoly_SHA256`, prologue `NoiseAPIInit`), the full
    mDNS TXT set a node publishes, and ESPHome's `web_server`/`captive_portal`
    provisioning and factory-reset paths.
  The catch-all flag sits on the `_esphomelib._tcp` method only: the spec's
  auxiliary `_http._tcp` method (for API-less builds, matched on ESPHome's
  `config_hash` TXT key) is narrowed and nothing else, because being the
  fallback for a service type ESPHome does not own would rebuild the same bug
  with printers in it. `esphome-device` is `integration: identify_only` rather
  than `supported`, which is what the field actually asks: with no static
  entities and an optional HTTP surface, what a consumer does today is name the
  node and hand the user to its web UI. It flips to `supported`, unchanged
  otherwise, once a consumer implements runtime enumeration.

  - **`ratgdo`**: now matches `project_name` prefix `ratgdo.` in both blocks
    (every published board config sets `ratgdo.<board>`), so it claims its own
    hardware and nothing else. Konnected's blaQ ships its own build whose
    project_name has not been observed here, and is no longer claimed by
    implication.

- Stateful **Power** `switch` entities on seven TV specs, landing the spec
  half of [Spec Evolution P13](docs/contributing/spec-evolution.md#p13):
  discrete `turn_on`/`turn_off` bindings where the hardware honestly has
  them (`roku-ecp`, `sony-bravia`, `vizio-smartcast`, `philips-jointspace`;
  `lg-webos` off-only; `samsung-tizen-tv` off-only, because its standby
  network stack being down makes the one KEY_POWER toggle discrete-off in
  practice), and the new **`toggle`** role — a command declared to *flip*
  power, which a consumer must not send without establishing state first —
  where a flip is all the set offers (`sony-bravia`, `vizio-smartcast`,
  `philips-jointspace` as alternates; `hisense-vidaa` as the only binding,
  gated on the `state_topic` it declares). `panasonic-viera` and
  `android-tv-remote` are deliberately excluded on the same test:
  toggle-only, reachable in network standby, and no readable state a
  binding can name — the set a bulk off could turn on. Android TV does push
  `remote_start { started }`, and it is surfaced as a Power State
  `binary_sensor`, but it arrives over the session rather than a pollable
  endpoint, so no `state_*` field can point at it and nothing ties the
  sensor to a switch. The remote `button` entities keep the key, renamed
  `Power Key` where a `Power` switch now shares the file — two controls
  with one name are indistinguishable to a consumer that keys on the name.

- `set_power_standby` on `philips-jointspace`: the `/powerstate` resource
  written instead of read — documented under `http_endpoints` all along,
  now invocable as a command. A second discrete off for v6 sets that answer
  powerstate but do not honour the PowerOff key, and an explicit state
  request rather than a keypress. Narrower than the key route rather than a
  fallback for it: older sets have no powerstate resource at all, which is
  why the Power switch still binds `turn_off` to the key and leans on the
  universally-accepted Standby key as its state-gated `toggle`.

- **Final acquisition sweep (2026-08-19).** The APKs that failed in the
  2026-08-12 wave were retried through working mirror flows: Omron Connect
  JP acquired via Aptoide (the 2026-08-12 failures traced to a wrong
  package name), Lutron's current app (`com.lutron.mmw`) — yielded LEAP
  `GoToDimmedLevel`/`GoToSwitchedLevel` corrections (no plain `GoToLevel`
  exists in the vendor enum) and the full LAP `/pair` CSR-signing
  exchange, Wemo v1.30.2 (smartsetup/remoteaccess services mapped), Hue
  v5.73.0 (spec confirmed, no changes), SensorPush's legacy package
  (model table incl. a new Aqua water sensor, factory-recovery service),
  and Inkbird's current `engbird` app (advertisement bytes 4-6 decoded,
  fff1/fff6/fff8/fff9 and the PhyPlus OTA path added). iBBT Go and the
  Vizio SmartCast app are delisted everywhere and unacquirable (their
  specs rest on stronger community sources anyway). SPOTLED firmware is
  confirmed unrecoverable — the Wayback Machine never crawled the host.
  An HA/ESPHome reference sweep linked ~80 specs to their real
  integrations (core, HACS, ESPHome, Theengs); the ~43 without any are
  verified to genuinely have none. `ember-mug` now records that the
  advertised company ID varies by unit — 0x03C1 (Ember's assigned ID) or
  0xFFFF (measured on a Mug 2) — matching python-ember-mug's fallback.

- **Seven more specs from the expansion wave (2026-08-19).**
  `brother-ql-1110nwb` (P-touch raster language over TCP 9100 / BT Classic
  SPP — no BLE GATT; status via `ESC i S` 32-byte reply), `flowtoys-props`
  (props speak proprietary nRF24 RF, not BLE; the FlowtoysConnect bridge
  exposes BLE Nordic UART + OSC/UDP — Flowtoys-commissioned open-source
  firmware exists), `limitlessled-milight-bridge` (live-probed on the
  project LAN: legacy v3–v5 HF-LPB130 bridge, 3-byte command frames on
  UDP 8899), `enphase-iqbattery-ble` (Encharge/Enpower BLE = stock Digi
  XBee 3 BLE service, SRP-6a unlock with factory-default password,
  user-data-relay frames + EnsObjMdlMessage object model),
  `cat-printer-mxw01` (AE30 service, new 0x22 0x21/CRC-8 framing,
  cross-checked against three independent implementations),
  `xiaomi-mi-scale-s400` (encrypted MiBeacon obj 0x6E16 bit layout +
  mible-login GATT path), `veryfit-2-fitness-band` (Veryfit 2.0/ID107
  0x0AF0 protocol promoted from the m6-fitness-band appendix).
  `chamberlain-garage-opener-secplus` gained a verified-live note on the
  MYQ-G0401 Smart Garage Control hub found on the project LAN
  (unauthenticated `/jabout` identity endpoint).

- **Five more specs from the second acquisition wave (2026-08-19).**
  `qh-happylighting-led-strips` (Triones/QHM car-LED family, FFD5/FFD9 +
  legacy FFE0 layouts, all command frames), `tuya-bt-soil-tester`
  (zwjcy category, encrypted GATT 0xFD50, SGS01BTHome reflash path),
  `zigbee-soil-tester` (Tuya TS0601 soil family — five DP-map fingerprint
  groups; pairs to any coordinator, no Tuya hub needed),
  `vevor-vt256-thermal-imager` (Hti HT-W01 rebadge; RTSP + 0xFB-framed
  TCP command channel fully mapped with 14 byte-exact example frames),
  `ipixel-color-led-panel` (TIRO/Heaton FA02 family covering the
  JTPD-03-011 and HCZ-001/002 reseller SKUs; PNG/GIF upload framing).
  `jlx-laser-distance-meter` was re-verified against five sibling OEM app
  builds (Precaster attribution corrected, errorN/Zbleoff behaviors, a
  possible 0xDB-checksum firmware variant flagged). Firmware harvesting:
  11 Heaton/TIRO OTA images captured via the unauthenticated
  getFirmwareInfo API, 4 Yeelight images (ble1 + gingko), and the JieLi
  `*_ota_mi.bin` obfuscation was fully reversed (fixed 256-byte
  substitution; deobfuscated iDotMatrix images verify with intact GIF89a
  and font tables) — artifacts and hashes in `~/research`, per clean-room
  rules nothing vendor-owned is committed here.

- **Ten new device specs (2026-08-19), all from fresh APK/firmware
  acquisition and static analysis.** BLE: `beurer-po60-pulse-oximeter`
  (custom FF12 service, 3-command protocol, 24-byte history records),
  `beurer-series800-blood-pressure` (BM92/"PREMIUM800" — standard Blood
  Pressure Profile with Beurer's big-endian-SFLOAT quirk),
  `hyperice-hypervolt-plus` (MAC+seed password handshake through a fixed
  256-entry S-box; covers the whole legacy HV/HV2/Vyper family),
  `biokey-touchlock-fingerprint-lock` (no cloud exists at all; timestamp
  "rolling password"; 20-byte frame opcode table), `safetech-smart-padlock`
  (defunct vendor; cleartext 4-byte password, unlock = write 0x01 to
  0xFFD9; full FFD0/FFF0/FFE0 service map incl. RFID share codes),
  `led-helmet-display` (TIRO/Heaton JieLi family, FA02 command channel,
  JieLi AE00 OTA; firmware TR2306R009-2.ufw captured from the vendor's
  live firmware API). Wi-Fi: `yeelight-cube-lamp` (vendor LAN protocol +
  Matter, cube pixel commands marked community-sourced),
  `tuya-wifi-gas-sensor` (TuyaMCU rqbj family, DP table, LAN 6668
  framing), `june-oven` (cloud-only, no local surface; SRP-6a pairing,
  message-code tables, OTA service mapped; **all June cloud services
  retire 2026-09-22** — pairing-material export documented as the top
  owner action), `brava-oven` (cloud-only; DeviceNet socket.io protocol
  recovered; vendor ceased operations 2026-03-06, DNS-redirect rescue
  path documented, gated on oven-side TLS pinning).

- **Keeping Devices Alive guide** (`docs/keeping-devices-alive.md`) — a
  per-device playbook for keeping the fleet working without vendor clouds:
  local-API devices and their HA integrations, cloud-redirection targets
  (concrete hostnames per device), replacement firmware (bbs-fw, TSDZ2
  OSF, ATC, WireOS, ratgdo, badgemagic), BLE-only options (ESPHome
  proxies, Theengs, ble_monitor), and an honest dead-end list.

- **Artifact re-mining wave (2026-08-18).** Eight specs re-audited against
  their already-downloaded jadx/firmware artifacts to close long-standing
  `unknown`/`TBD` markers. Highlights: `admore-light-bar` — the bundled DFU
  package decodes as nrfutil Secure DFU (ECDSA-signed init packet,
  SoftDevice S132 v7.0.1), pinning the SoC to nRF52832 and ending hopes of
  self-authored firmware. `kwikset-kevo` — Lock Information Certificate TLV
  field map recovered (`0xB4` battery, `0xB5` lock state incl. jammed
  states), the advertisement trailing counter identified as a state-change
  sequence number, and time sync shown to be cloud-mediated (a real
  dead-cloud consequence). `kingsmith-walkingpad` — KS Fit app decompiled;
  found the Xiaomi MIOT alternate ecosystem (`ksmb.walkingpad.v1` et al. on
  the public MIOT registry → python-miio / HA Xiaomi MIOT path for Wi-Fi
  models) plus an 83-model prefix/max-speed table. `urevo-walking-pad` —
  BluePack B frame layout and CRC-16/CCITT coverage fully recovered from
  the Dart AOT snapshot, `ur_get_controller_version` command added, full
  response dispatch table mapped, and two hardcoded plain-HTTP cloud IPs
  recorded. `magic-display` — command table byte-verified against the app's
  own `Agreement` class (MODE/LIGHTON/SCHD/SMVEW/…), unencrypted Quintic
  OTA service documented, `cloud`/`local_access` blocks added (backend is
  app-side only; nothing breaks when it dies). `iledcolor-led-panel` —
  playlist opcodes `0x03`/`0x07`/`0x08`, password set/change layout, A952
  chunk framing and A953 status-code table pinned, advertisement offsets
  fixed incl. the old-protocol screen-type exception. `chef-iq-sense` —
  Wi-Fi provisioning payloads shown to be JSON over UTF-8 string
  characteristics, session TLV attributes 52–92 added, hardware table
  corrected to ESP32-WROVER-E, OTA metadata API and MQTT `ota` topic
  documented. `motool-slacker` — command bytes proven unrecoverable
  statically (ARM32-only Dart AOT, no relocation entries; documented why),
  a speculative notification-relay claim corrected, vendor-cloud liveness
  checked (app-side Firebase only, device has no cloud dependency).
  Remaining gaps on all eight are hardware-capture-only and say so.

- **Rabbit Air verified against hardware (2026-08-15).** The BLE
  provisioning flow in `rabbit-air-purifier` was replayed end-to-end on a
  real MinusA2 gen2 (Wi-Fi module mcu 2.2.8): cleartext cmd 255/4/7/0/1,
  cmd 5 type 4 (client-generated user key), cmd 2 — then encrypted
  cmd 9/255/0/4 over both UDP 9009 and BLE under the pushed key. The spec
  flips to `testing.status: verified` / setup `confidence: high`, the BLE
  method to `verified: true`. Hardware corrected two decompile readings:
  the command characteristic's server-to-client leg is ATT **indications**
  (properties 0x28, CCCD default-on), not notifications; and setup-command
  failures DO surface as `{"id":…,"error":true}` (seen re-sending cmd 1/2
  after setup). New facts recorded: `security: 3` = WPA2-PSK in cmd 0/1;
  cmd 7 replies `{mode, setup}`; cmd 0 lists one entry per BSSID and its
  `ip` field tracks join progress (the verified join took ~4 minutes);
  cmd 255's `mac` is the WI-FI MAC, which differed from the BT MAC in the
  last octet; a unit provisioned without the cloud flow has no Thing ID
  (`name: ""`) and falls back to mDNS hostname `RabbitAir-<WIFI MAC>` with
  TXT `id=<MAC>`; a keyed unit outside setup mode answers no cleartext
  command and intermittently rejects writes with ATT error 0x87.

- `commands:` blocks for seven specs whose entity role maps named no command
  — `ratgdo`, `wled-controller`, `lifx-z`, `divoom-pixoo`,
  `frigidaire-window-ac`, `frigidaire-portable-ac` and (by removal)
  `rachio-controller`. A role map "carries a name, not a payload", as the
  `commands` key has always said, but these carried request prose
  (`'POST /cover/door/open'`), a protocol message type (`'SetPower'`), an
  attribute name (`'targetTemperatureC'`) or an MQTT topic — none of which any
  consumer can resolve, and none of which the schema rejects. 46 bindings now
  name real commands. Two specs are deliberately left: see #41.

- `auto: crc16_modbus`, for MODBUS-RTU framing (reflected polynomial 0xA001,
  init 0xFFFF, no final xor). Two bytes wide, so the parameter declares
  `type: uint16` and MODBUS's low-byte-first convention comes from this
  schema's default `endianness` rather than from the role. `bluetti-power-
  station` declared the CRC on all three of its commands as an ordinary
  parameter, which asked a caller for a value it has no way to produce;
  they now carry the role with `checksum_start: 0`, the address byte being
  covered.

- `auto: xor_checksum`, a fourth encoder-filled parameter role. `auto:
  checksum` is an additive sum8 salted by `checksum_xor`; the Govee 20-byte
  frames end in an XOR fold over bytes 0-18 instead (`checksum_start: 0`) —
  the same shape, a different reduction, and no way to say so. Without a term
  for it a spec has to declare the byte as an ordinary parameter, which makes
  a generic UI render a checksum control and makes the command unsendable
  without a value the caller cannot know. Deliberately a distinct `auto`
  VALUE rather than a modifier key beside `checksum`: consumers ignore
  unknown keys by design, so a `checksum_op: xor` would be read as plain
  additive and emit a byte the device silently drops, from a spec that
  validates. An unrecognised `auto` value cannot be misread as a mode the
  reader knows. `checksum_xor` stays additive-only for the same reason.

- Eight smart-TV local-control specs: `android-tv-remote` (Remote Protocol
  v2 protobuf-over-TLS, plus Fire TV ADB variant), `hisense-vidaa` (MQTT
  over TLS), `lg-webos` (WebSocket SSAP), `panasonic-viera` (plain SOAP,
  fits the reference app's transport today), `philips-jointspace` (HTTP
  JSON on 1925/1926), `samsung-tizen-tv` (WebSocket `ms.remote.control`,
  plus the pre-2016 TCP 55000 legacy protocol), `sony-bravia` (IRCC SOAP +
  JSON REST), and `vizio-smartcast` (HTTPS with PIN-paired AUTH token).
  Each records its transport gap against the reference app's
  GET/POST-empty-body HTTP and header-less SOAP transports rather than
  inventing commands that could not work on a real TV.

- A `text` entity platform (schema enum + `roku-ecp` `Keyboard` entity):
  text entry into whatever field the device has focused, binding a valued
  `submit` role that takes the one character being typed (Roku's
  `Lit_{char}` key form — the wire carries no string type) plus a fixed
  `press` role for the backspace key. Like a button it names no state
  source: the device never reports what its focused field holds.

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
- `tplink-kasa-smart-plug` documents the Kasa-era TP-Link local protocol
  (HS100/HS110 and the same-protocol HS103/HS105, KP105/KP115): JSON over a raw
  TCP socket on port 9999, obfuscated by a trivial XOR-autokey cipher (initial
  key `0xAB`) with 4-byte big-endian length framing and no authentication,
  discovered by a UDP broadcast of the encoded `get_sysinfo` to
  `255.255.255.255:9999`. The outlet is a `switch`/`outlet` entity whose
  `turn_on`/`turn_off` bind `set_relay_state` commands and whose state polls
  `get_sysinfo`'s `relay_state` — the same control shape as the Wemo plug over
  a new transport. This needed a new command `transport` value, `tcp-json`
  (added to `schema.json`), and a `body` field for the JSON an invocation IS —
  what `arguments` is to SOAP and `path` is to HTTP. The cipher and the
  discovery/command byte vectors are reproduced from the YAML alone by
  `scripts/test_kasa_spec.py` (the sibling of `test_wemo_spec.py` and
  `test_roku_spec.py`); the get_sysinfo vector matches the canonical
  softScheck / python-kasa datagram. `manufacturer_status: active` because
  TP-Link is alive — what is endangered is this local protocol, which newer
  firmware (HS100 hw v4 fw 1.1.0+) and the KLAP/Tapo line have retired. Power
  strips (HS300/KP303/EP40, which address per-outlet `children`) are noted as a
  separate future spec
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
- **`tplink-kasa-smart-plug` gains energy monitoring.** The HS110's
  `emeter.get_realtime` — previously only named in the command tree — is now
  a `get_emeter` command with documented returns, and four HS110-only sensor
  entities (Voltage, Current, Power, Total Consumption) whose `state_mapping`
  values are dotted JSON paths from the reply root
  (`emeter.get_realtime.power`, etc.). The field-name quirk is documented as
  data, not folklore: current firmware reports plain float fields already in
  V/A/W/kWh, HS110 hardware v1 reports `voltage_mv`/`current_ma`/`power_mw`/
  `total_wh` in milli-units, and consumers normalize as python-kasa's
  `EmeterStatus` does — both code paths confirmed by a clean-room jadx audit
  of the vendor app (recorded under the spec's `evidence:` block).
  `scripts/test_kasa_spec.py` now pins the get_emeter request to its exact
  framed bytes and decodes a sample emeter reply through the sensor mappings.
  The paths are rooted at the reply root because the reference app's
  `kasaSysinfoFields` flattener lifts only `system.get_sysinfo` replies — it
  needs extending for the nested emeter reply before these sensors resolve
  there
- **`rabbit-air-purifier` becomes consumable, not just documented.** The spec
  — the vendor's own published LAN library, transcribed — gains the
  `commands:` block a client binds (`get_state`/`time_sync`/`get_info` for
  cmd 4/9/255, `turn_on`/`turn_off`, parameterized `set_mode` and
  `set_speed`, ionizer and child-lock toggles), each body carrying only the
  static envelope fields while `id`/`ts` stay runtime-generated per the new
  `client_rendering` note: wrap minified `{id, cmd, ts, data}`, AES-128-CBC
  with the per-device user key, random IV appended as the datagram's last 16
  bytes, one datagram to UDP 9009. The entities are rewritten from prose into
  bindable form — power switch, mode select with static options, fan-speed
  number, air-quality/filter-life/RSSI sensors, ionizer and child-lock
  switches — with state paths rooted at the reply's `data` object, and the
  two candidate BLE provisioning GATT UUIDs move into `identification` as
  hypothesis-marked hints so a BLE scan can flag an unprovisioned unit.
  `scripts/test_rabbit_air_spec.py` (sibling of `test_kasa_spec.py`)
  transcribes the envelope, cipher and substitution rules from the YAML
  alone, reproduces the spec's `example_exchange` plaintexts byte-for-byte,
  and round-trips every command through the cipher; `cryptography` joins the
  dev requirements for it
- **`enphase-envoy` gains a bindable telemetry surface.** A `commands:`
  block names the four local GETs (`get_production_v1`, `get_production_json`,
  `get_inverters`, `get_info`) as invocations, and the sensor entities —
  Solar Production, Lifetime Energy, plus a new Today's Energy — move off the
  unconsumed `state_topic` onto `state_command: get_production_v1` with flat
  dotted-path mappings (`wattsNow`, `wattHoursLifetime`, `wattHoursToday`).
  The flat `/api/v1/production` object is the binding target precisely
  because `/production.json`'s per-type array (`production[i].wNow`) cannot
  be named by a flat path; both forms stay documented. The firmware-7+ JWT
  gating caveat is unchanged and applies to every command.
- **New device: `jlx-laser-distance-meter`.** The Johnson JLX LDM330
  (40-6013) and its rebadge family (the vendor app's own build enum spans
  Johnson Measure-Up, Starrett STR3, Ronix, MeasureMate and more) speak an
  ASCII BLE protocol with no pairing: subscribe to the `f154` notify
  characteristic, write a six-byte init handshake, and the meter streams
  10-byte measurement frames — a 6-char decimal always in meters plus a
  display-unit code — while commands are 13-byte checksummed frames.
  Recovered by clean-room jadx analysis of the Measure-Up app
  (`com.winho.measure_up`, APK hash in the research note); marked untested
  with the open questions (advertised name/UUIDs, the byte-0 prefix,
  error-frame formats) listed for the first hardware session.
- **`schlage-smart-locks` gains its first live-hardware evidence.** A
  read-only BLE + LAN session against a real installed fleet (2026-08-14)
  caught one commissioned lock advertising once — name `SCHLAGE` + serial
  suffix, Allegion's Bluetooth company ID 315 (checked against the repo's
  own registry), MAC embedded in the manufacturer payload — and then
  silence: idle locks advertise rarely enough that a 75-minute scan saw one
  packet, so GATT enumeration stays app-derived. On the LAN the locks make
  no mDNS/SSDP announcements of any kind and no HomeKit `_hap` presence —
  consistent with, not proof of, the no-local-WiFi-API claim. Recorded as
  an `evidence: live_hardware:` block with per-claim verdicts (confirmed /
  not-observed / consistent / untested), names and MACs truncated; the
  DataTransfer UUID's absence from the idle advertisement is logged as
  "not observed", pending a capture from a woken lock.
- **`schlage-smart-locks` WiFi surface, settled from both directions.** A
  code-level audit of the app's WiFi path (com.allegion.leopard 3.6.0;
  research-notes/schlage-wifi-local-surface.md) confirms provisioning is
  100% BLE-driven — the app pushes credentials and the cloud-minted JITR
  blob over the encrypted uWeave channel and never opens a socket to a lock,
  and the lock hosts no softAP or listener — while a full-/16 LAN census of
  the household (88 live hosts, OUI-resolved, candidates port-scanned) found
  no lock-like listener on any host. Firmware: residential images are not on
  the commercial release-notes page; metadata is
  `GET api.allegionengage.com/api/firmware/{platformType}` with a
  server-supplied binary URL and content-length-only verification, and WiFi
  locks can self-download (interior button ×5). The one local WiFi surface
  in the family is the Sense's BR400 adapter: an unauthenticated LAN HTTP
  API including a firmware-update endpoint taking an arbitrary URL —
  accessory-scoped, absent on Encode-family locks. Corrects the JITR status
  enum to 0..5 (no state 6 exists) and records the hardcoded WiFi security
  field.

### Fixed

- **ESPHome addressing and cover-position corrections on `ratgdo`.** Two facts
  the spec had wrong, both from ESPHome's own source. (1) Entity addressing
  changed generation, and in two steps a release apart: `<= 2025.12` matches
  the slugified `object_id` and emits `id: "cover-door"`; `2026.1.0`-`2026.6`
  match the entity NAME with an object_id fallback and add `name_id` (from
  2026.1.3); `2026.7` drops the URL fallback, so URLs are the percent-encoded
  name (`/cover/Door`, `/lock/Lock%20remotes`) while `id` is still legacy; and
  `>= 2026.8` moves `id` itself to `cover/Door` and stops sending `name_id`.
  2026.7 is the release that punishes deriving a URL from `id`. Paths and `state_topic`s move to the name form
  current ratgdo firmware requires, with the legacy form documented and the
  rule for picking one at runtime (read the identifier out of `/events`; a
  wrong form is a 404, never a silent no-op). (2) `set?position=` takes
  ESPHome's cover scale `0.0`-`1.0`, not a percentage — the old `0..100`
  `uint8` meant every "half open" request drove the door fully open. Also:
  the legacy `api: password:` was removed in ESPHome 2026.1.0, and
  `api_encryption` vs `api_encryption_supported` distinguish "PSK set, Noise
  required" from "Noise-capable, still accepts plaintext".

- `tplink-kasa-smart-plug` stops offering the energy meter on plugs that do not
  have one. The four emeter sensors were unscoped, so a consumer drew Voltage /
  Current / Power / Total Consumption on an HS100, HS103, HS105 or KP105 —
  models with no metering hardware, which answer `emeter.get_realtime` with an
  error — leaving four tiles permanently unavailable. The spec now carries a
  `device.variants` table of the six covered models, each identified by a new
  `identification.model_prefix` (matched as a prefix against `get_sysinfo`'s
  `model`, because the reply is `"HS110(US)"`, region suffix and all), and the
  sensors carry `variants: ["HS110", "KP115"]`. `get_sysinfo`'s `feature` field
  is documented alongside as the better runtime test — `"ENE"` in that
  colon-separated list means this unit has the meter, which is what
  python-kasa's `has_emeter` checks and what stays correct when a new model
  ships.

- `tplink-kasa-smart-plug` makes the HS110 hardware-v1 emeter reply actually
  resolvable. Hardware v1 does not merely scale its readings, it *renames*
  them: `voltage_mv` / `current_ma` / `power_mw` / `total_wh`, in milli-units,
  with the modern keys absent from the reply entirely. The sensors' dotted
  paths therefore found nothing on that hardware and prose telling a consumer
  to divide by 1000 could not help — there was no key to divide. Each sensor
  now declares `state_mapping.value_fallback` (`path` plus `scale: 0.001`), the
  legacy field family is declared in `get_emeter`'s `returns` rather than
  described only in prose, and `scripts/test_kasa_spec.py` decodes both reply
  shapes through one reader. The fallback is deliberately not a variant split:
  a consumer ignoring `value_fallback` keeps working on current firmware,
  whereas two entities per reading would make a consumer ignoring `variants`
  draw every meter tile twice.

- `schlage-smart-locks` stops using the BLE address as lock identity.
  `discovery.identity.stable_keys` was `["address"]`, contradicting the
  2026-08-14 live-hardware finding recorded in the same file: both observed
  lock addresses have the locally-administered bit set, so these are
  random-static addresses the lock may rotate — a client keying on one either
  loses a lock it already knows or enrols the same lock twice. Identity is now
  the full `SCHLAGE<8 hex>` local name, whose suffix is serial-derived and
  survives a rotation, with the address demoted in `identity.notes` (a new,
  documented key) to an ephemeral connection locator to be re-resolved by
  scanning. Discovery gains the two match rules the evidence supports —
  Allegion manufacturer-data company ID 315, and the `SCHLAGE` name prefix —
  ahead of the DataTransfer service UUID the one captured advertisement did not
  carry. The sighting record's "public Bluetooth address with OUI `B7:AC:C2`"
  is corrected: that prefix is not a vendor OUI, and whether the MAC embedded
  in the Allegion payload is the stable public address or a copy of the
  rotating one is called out as unresolved, for the planned HCI-snoop session.

- Nineteen specs kept their reference links under a top-level `references:`
  key that nothing reads. `helpful_urls` is the field the index generator and
  the JSON API pick up, so 126 links — teardowns, protocol write-ups, FCC
  filings and the working implementations the specs were derived from — sat
  in the YAML and never reached a generated artifact. They are now
  `helpful_urls` entries with a `title` and a `description` saying what each
  link is good for, as the schema wants: `ble-pulse-oximeter`,
  `bmw-motorcycle-diagnostics`, `cat-printer`, `divoom-pixoo`, `ember-mug`,
  `etekcity-smart-scale`, `gerbing-thermogauge`, `govee-h5075-thermo`,
  `govee-h5080-plug`, `govee-h6001-bulb`, `hotwired-heated-gear`,
  `iledcolor-led-panel`, `inkbird-ibs-th`, `jlx-laser-distance-meter`,
  `m6-fitness-band`, `omron-connect`, `oral-b-io-smartbrush`,
  `thermopro-tp357` and `triumph-tiger-900`.

- `govee-h5080-plug` and `govee-h6001-bulb` filed their command byte
  sequences under `payload.bytes`, which the schema does not define. Only the
  mobile Rust crate could still read them, and only because it carries a
  bespoke shim for this exact misfiling; to the JSON API, the index and
  anything else working from the schema, every command in both specs was a
  command with no bytes. The plug's frames were already complete 20-byte
  frames and move to `value` unchanged. The bulb's were 3-to-7-byte prefixes
  of a 20-byte frame, so the shim emitted short writes the hardware rejects —
  they are now written out in full: fixed frames (`power_on`, `power_off`,
  `keep_alive`) as `value` with the byte-19 XOR computed, and the
  parameterized ones (`set_brightness`, `set_color`, `set_color_white`) as
  `template` plus `parameters`, which is what a brightness slider needs in
  order to be more than one hardcoded level. Three packet descriptions
  counted a zero byte too many and now agree with the frames beside them.

- `schema.json` closes the two doors those mistakes walked through, against
  the permissive habit of the rest of the file. A top-level `references:` is
  now rejected outright, and a command's `payload` takes only `key` and
  `value_type`. Both are cases where an unknown key is not bespoke metadata
  travelling alongside the standard fields — the design the permissiveness
  exists for — but a standard field spelled wrong, which nothing downstream
  can distinguish from a key it was meant to ignore. A `references:` nested
  inside a bespoke block (devolo's `zwave:`) is prose citation and stays
  legal.

- `roku-ecp` corrects the "Control by mobile apps" gating from a live
  2026-08-11 probe of the OS 15.2.4 fleet: the middle **Limited** position
  refuses more than the OS 14.1 notice implies — `/query/apps` answers
  "ECP command not allowed in Limited mode." as 400 on one TV and 403 on
  two others (the same TV switching spellings within minutes), and
  `/query/media-player` answers 403, while `/query/device-info` and
  `/query/active-app` stay open. Also documents **ECP2**, the authenticated
  WebSocket session the official app uses, from a jadx teardown of The Roku
  App (Official) 14.0.0.9462138 plus a live re-implementation: client-id
  auth needs no Roku account (the secret ships in the APK), and over it
  `query-apps` and `key-press` answer 200 even in Limited mode.

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

- `device-specs/index.json` is now built and committed by CI (the
  `publish-index` job) on every push to main instead of by hand in each spec
  PR. It is a generated file that every spec branch touched, so any two open
  spec PRs conflicted on it — 60 kB of machine-written JSON whose only honest
  resolution is to regenerate. Branches no longer carry it at all: a PR that
  modifies it fails `validate-specs`, which still *builds* the index (and so
  still catches a spec the generator chokes on) but no longer diffs it against
  the committed copy. The file stays checked in because it is a shipped asset —
  the mobile app vendors this repo as a subtree and bundles it — so consumers
  see no change beyond it landing one commit after the spec rather than in the
  same one. `scripts/generate_index.py` gained `--check` (report staleness,
  write nothing) and a `collect_entries()` entry point the tests use to verify
  coverage without touching the working tree
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
