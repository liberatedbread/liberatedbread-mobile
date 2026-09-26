# SPECS_TO_FIX — problems whose fix lives upstream in liberatedbread-protocol-specs

`vendor/protocol-specs/` is a git subtree and is never edited here. Everything below is a change to open against
[liberatedbread-protocol-specs](https://github.com/liberatedbread/liberatedbread-protocol-specs), then pull with
`./scripts/update-specs.sh`. Where the app's parser could also be made stricter, the finding says so; that half
is tracked in the app-side audit notes, which are kept out of this repo.

Found by the 2026-09-15 review (one reader dedicated to the vendored catalogue against `rust/src/spec` and `rust/src/protocol`,
plus the finders' incidental spec notes). Verified items were put to an adversarial second reader; the rest are single-reader leads.

**5 verified, 10 unverified.**

## Verified

### R-141 — Command declaring both `value` and `template` is accepted; `value` silently wins so xkglow set_rgb_color shows live sliders that are ignored and loses its set_color role

`rust/src/spec/parser.rs:84` · **medium** · spec-upstream · found by rust-spec · verified by 1 adversarial reader

**Evidence.**

`validate_spec` (parser.rs:84-124) never rejects a command with both
envelopes. `encode_command_with_bytes` returns `value` first (`if let Some(ref
value) = command.value { return pad_to_fixed_length(value.clone(), command);
}`, codec/types.rs:470) and `qualify` treats it as fixed (`if
command.value.is_some() || command.payload_bytes().is_some()`,
bindings.rs:807). xkglow-chrome.yaml:245-266 declares `set_rgb_color` with
`value: [0x00,0x00,0x04,0xFF,0x00,0x00]` AND `template: [0x00, "{zone}", 0x04,
"{red}", "{green}", "{blue}"]` plus four parameters, and its light entity
binds both `turn_on: set_rgb_color` and `set_color: set_rgb_color` (xkglow-
chrome.yaml:335-336).

**Scenario.**

The light entity resolves `turn_on` (sends red to zone 0) but `set_color` is
dropped because the command is 'fixed' and needs user input; in the raw
browser `set_rgb_color` shows as a fixed 'Set solid RGB colour' button that
always writes red, ignoring zone/red/green/blue.

**Fix.**

App side (rust/src/spec/parser.rs validate_spec): reject a command that
declares both `value` and `template` (or `value` plus `parameters`) with a new
SpecError, or at minimum log a warning and let `template` win in
encode_command_with_bytes when parameters are declared. Also add a test
fixture with both envelopes so the choice is pinned. Upstream (xkglow-
chrome.yaml): remove `value` from `set_rgb_color`, add `default: 0` to `zone`
so the templated command qualifies for `set_color`, and add a separate fixed
`turn_on` command (e.g. value [0x00,0x00,0x04,0xFF,0xFF,0xFF]) for the
entity's `turn_on` binding. Consider a schema.json `not: {required: [value,
template]}` on the BLE command block so upstream CI catches the next one.

**Verifier's note.**

Every literal claim checks out on this branch. `validate_spec`
(rust/src/spec/parser.rs:84-124) only checks format fields, duplicate names,
parameter validity and `validate_template_references`; nothing rejects or
warns when a command carries both `value` and `template`, and the `Command`
struct (rust/src/spec/types.rs:1770) is a plain serde derive with both as
independent `Option`s. `encode_command_with_bytes`
(rust/src/codec/types.rs:470) returns `pad_to_fixed_length(value)` before ever
looking at `template` or `params`, and the FFI `encode_command`
(device_api.rs:4500) routes the raw browser's params into that same encoder,
so supplied zone/red/green/blue are discarded. `qualify` (bindings.rs:807)
treats `value.is_some()` as a fixed envelope and returns None for any role
that `needs_user_input()`, so `set_color` is dropped while `turn_on` resolves.
The vendored xkglow-chrome.yaml:245-266 does declare both envelopes plus four
parameters, the light entity binds `turn_on` and `set_color` to it (lines
335-336), and the spec is in the shipped index (device-specs/index.json:7036)
which pubspec bundles. The upstream schema.json's command block has no
oneOf/not rule for value vs templat

### R-214 — xkglow-chrome set_rgb_color declares both `value` and `template`; the encoder sends the fixed bytes so the zone/RGB controls in the raw command browser do nothing

`vendor/protocol-specs/device-specs/devices/xkglow-chrome.yaml:248` · **medium** · spec-upstream · found by spec-vs-code · verified by 1 adversarial reader

**Evidence.**

xkglow-chrome.yaml:245-266: `set_rgb_color: value: [0x00, 0x00, 0x04, 0xFF,
0x00, 0x00]` AND `template: [0x00, "{zone}", 0x04, "{red}", "{green}",
"{blue}"]` with four uint8 parameters. `encode_command_with_bytes` returns
`value` first (rust/src/codec/types.rs:470-472) before ever looking at the
template; `CommandDto::from` still lists all four parameters
(device_api.rs:1339-1349) with `is_fixed: true, is_encodable: true`; the typed
command widget draws a control for every user-settable parameter regardless of
isFixed (lib/widgets/typed_command_widget.dart:373-374). bindings.rs:2136-2138
already notes the conflict. The parser accepts the pair without complaint
(parser.rs validate_spec has no value/template exclusivity rule).

**Scenario.**

On an XKGLOW Chrome controller the raw command browser shows
zone/red/green/blue sliders for set_rgb_color; whatever the user picks, Send
writes 00 00 04 FF 00 00 (zone 0, pure red). The light entity's set_color role
is (correctly) refused by qualify(), so there is no colour picker either.

**Fix.**

Upstream (vendor/protocol-specs, via the subtree workflow, not a local edit):
delete the `value:` line from set_rgb_color so the template is the command.
App side: add a value/template exclusivity check to `validate_spec` in
rust/src/spec/parser.rs (next to `validate_template_references`) so a spec
that declares both is rejected at load, and/or make `CommandDto::from` in
rust/src/api/device_api.rs emit an empty `parameters` list when `is_fixed` so
lib/widgets/typed_command_widget.dart cannot draw controls the encoder
ignores. Add a codec test asserting the chosen behaviour for a command
declaring both.

**Verifier's note.**

Every link in the chain is literally true on this branch. (1) vendor/protocol-
specs/device-specs/devices/xkglow-chrome.yaml:245-266 declares `set_rgb_color`
with BOTH `value: [0x00,0x00,0x04,0xFF,0x00,0x00]` and `template:
[0x00,"{zone}",0x04,"{red}","{green}","{blue}"]` plus four uint8 params with
no auto/default/source. (2) rust/src/codec/types.rs:470-472
`encode_command_with_bytes` returns `pad_to_fixed_length(value)` before the
template is ever consulted, so the params are ignored. (3)
rust/src/api/device_api.rs:1325-1349 builds CommandDto with `is_fixed:
cmd.value.is_some()` and still emits every parameter;
rust/src/spec/types.rs:2176 `is_user_settable` is only `auto/default/source`
all None, so all four params come across as userSettable. (4)
lib/widgets/typed_command_widget.dart:172 seeds and :373-374 draws a control
for every userSettable param; the only use of `isFixed` in that widget (:414)
just changes the button label.
lib/widgets/typed_characteristic_widget.dart:38-47 routes to
TypedCommandWidget whenever any command is encodable and the char is writable,
which holds here. (5) The widget's `_send` (:262) calls `codec.encodeCommand`,
which is the Rust encoder above. (6)

### R-216 — sony-bravia and divoom-pixoo `state_command` names resolve to no endpoint or command; Sony's JSON-RPC state reads also need a POST body the http renderer drops

`vendor/protocol-specs/device-specs/devices/sony-bravia.yaml:1179` · **medium** · spec-upstream · found by spec-vs-code · verified by 1 adversarial reader

**Evidence.**

sony-bravia.yaml:1179 `state_command: "getPowerStatus"` (also
getVolumeInformation, getPlayingContentInfo) — but `http_endpoints` are named
"Power Status" / "Volume Information" / "Playing Content Info" and `commands`
are `press_*`; `render_state_request` (rust/src/protocol/http.rs:409-437)
tries endpoint name, command name, then a bare `/path`, and otherwise returns
CommandNotFound. Even with the right name, the endpoint is `method: POST,
path: /sony/system` with `request_body.example: {"method": "getPowerStatus",
...}` and `endpoint_request` (http.rs:277-293) returns only (method, path) —
the body is dropped, so the JSON-RPC call is unrenderable. divoom-pixoo.yaml
has the same shape (`state_command: Channel/GetOnOff`, `Device/GetListV2` vs
endpoints `divoom_api`/`post_api`). Meanwhile `state_binding`
(bindings.rs:1311-1315) admits any `state_command` string unchecked, and
Sony's `press_power_on/off` SOAP commands resolve, so the Power switch is
drawn.

**Scenario.**

A discovered Sony Bravia shows Power / Volume / Now Playing cards; every state
poll fails with CommandNotFound(http_endpoints, getPowerStatus), so the cards
never show a value while the send buttons work — the dead-control case the
surface rule exists to prevent.

**Fix.**

Upstream: point each `state_command` at the `http_endpoints` entry name
("Power Status", "Volume Information", "Playing Content Info"; `divoom_api`
for Pixoo) and give those endpoints a machine-readable `body` (the JSON-RPC /
`{"Command": ...}` document) rather than only `request_body.example`. App side
(portable): (a) in `rust/src/spec/bindings.rs` make `state_binding` return
`StateBinding::Command` only when `http::endpoint_request(spec, name)` or
`spec.commands.get(name)` resolves, so `on_network_surface` hides the entity
instead of drawing it — and count it in `hidden_names`; (b) extend
`http::endpoint_request` / `render_state_request` to carry the endpoint's
`body` (and `request_body.content_type`) so a JSON POST read is renderable
once the spec declares one; (c) add a catalogue test beside
`every_state_topic_in_the_catalogue_resolves_or_is_a_known_backlog_item` in
`rust/tests/vendored_assets.rs` that iterates every `state_command` and
asserts it resolves via the http or soap renderer, with an explicit known-
backlog list, so the next spec with this shape fails CI; (d) in
`lib/screens/network_device_screen.dart` `_refreshState`, catch per-command
render failures so one unreadable state command does not turn `_load` into a
whole-screen error for a device whose send buttons work.

**Verifier's note.**

Every literal claim checks out on this branch.  1. The names do not resolve.
`vendor/protocol-specs/device-specs/devices/sony-bravia.yaml:1179` has
`state_command: "getPowerStatus"` (and :1447/:1453/:1459 for the three
sensors). The `http_endpoints` entries are named "Power Status", "Volume
Information", "Playing Content Info" (lines 535, 578, 611); the only
`commands` entries are `press_*` SOAP keys (line 724 onward).
`rust/src/protocol/http.rs:409-435` (`render_state_request`) tries
`endpoint_request` by name, then `spec.commands.get`, then a leading-`/` bare
path, then returns `CommandNotFound{uuid:"http_endpoints"}`.
`rust/src/protocol/soap.rs:182-190` does the same name lookup via
`find_endpoint` (:219-226) and also returns `CommandNotFound`. divoom-
pixoo.yaml:502/510/515/520 name `Channel/GetOnOff` and `Device/GetListV2`; its
endpoints are named `divoom_api`/`post_api` and its commands are
`screen_on`/`screen_off`/`set_brightness` — `Channel/GetOnOff` appears only in
a comment.  2. The body is dropped. `endpoint_request` (http.rs:277-293)
returns only `(method, path)`; the http `render_state_request` fills `body:
String::new()`. So even a corrected name would render a bodyles

### R-218 — 17 BLE specs declare sensor entities on characteristics with no `format:` block, so their readings can never render (LYWSD03MMC temperature/humidity/battery, iBBQ, Onewheel, Concept2, Fardriver, Spider Farmer, ...)

`vendor/protocol-specs/device-specs/devices/xiaomi-lywsd03mmc.yaml:500` · **medium** · spec-upstream · found by spec-vs-code · verified by 1 adversarial reader

**Evidence.**

Programmatic pass over all 203 specs: sensor/binary_sensor entities whose
`state_characteristic` is declared in `services` but carries no `format:` and
the spec has no protocol_handler: astral-hoops (Battery Level), chef-iq-sense
(Internal/Ambient Temperature), concept2-pm5 (Power, Stroke Rate, Distance),
fardriver-controller (9 sensors), gerbing-thermogauge (Battery 2a19),
hotwired-heated-gear (Battery, Internal Temperature), ibbq-meat-thermo
(Temperature, Battery), itag-ble-tracker (Button, Battery 2a19), motool-
slacker, niimbot-d110 (Battery, Lid, Paper), onewheel-ble (Battery, Speed,
Voltage), spider-farmer-ggs (Temperature, Humidity, VPD), switchbot-ble
(Battery 2a19), ttlock-sciener-ble (Battery 2a19), xiaomi-lywsd03mmc
(Temperature 2a6e, Humidity 2a6f, Battery 2a19 at yaml:500-520), xiaomi-mi-
scale(-s400) (Weight, Impedance). The app carries them across as `has_format:
false` (rust/src/api/device_api.rs:1238-1243) and shows 'awaiting spec
update'; only 180f Battery has a built-in profile (profiles/mod.rs) and that
is not consulted for entity cards. Several are trivially describable SIG
characteristics (2a19 uint8 %, 2a6e int16 scale 0.01 C, 2a6f uint16 scale 0.01
%).

**Scenario.**

A user pairs an LYWSD03MMC thermometer: the app recognises it and lists
Temperature/Humidity/Battery cards that never show a number.

**Fix.**

Upstream: add `format:` blocks for the SIG characteristics (2a19: offset 0
length 1 uint8; 2a6e: int16 scale 0.01 unit C; 2a6f: uint16 scale 0.01 unit %)
and for the vendor ones whose layout the spec's own notes already describe
(iBBQ fff4 int16 LE x0.1, Onewheel e659f303 uint16 BE %). App side could
additionally fall back to the SIG profile decoder for 2a19/2a6e/2a6f when the
spec omits a format.

**Verifier's note.**

Literally true on this branch. (1) vendor/protocol-specs/device-
specs/devices/xiaomi-lywsd03mmc.yaml:459-501 declares 2a6e/2a6f/2a19 with
`properties:` only, no `format:`; entities at :500-520 bind to them; the file
has no protocol_handler. (2) rust/src/api/device_api.rs:1238-1243 sets
`has_format` false when the bound characteristic has no non-empty format. (3)
lib/widgets/entity_value.dart:62-68 short-circuits to
EntityValueStatus.unavailable before any read when `!entity.hasFormat`, and
lib/widgets/entity_sensor_card.dart:252-260 renders "No format block in the
spec yet, so this reading cannot be decoded." (the finding's "awaiting spec
update" is a paraphrase of that text). (4) No SIG-profile fallback on the card
path: `_decodeAndSet` always passes `specYaml`, and
rust/src/protocol/dispatch.rs `select_protocol` returns GenericProtocol
whenever spec_yaml is Some, only consulting `profiles::lookup` when spec_yaml
is None. (5) No advertisement/BTHome decoding exists in the app (no consumer
of `parse_rules`/service data in rust/src or lib), so the spec's advertisement
table does not rescue the entities. (6) Re-ran the programmatic pass: exactly
17 specs, 42 entities, matching the re

### R-213 — yeelight-cube-lamp claims _miio._udp unnarrowed, so every miIO device ties Strong with the Xiaomi platform spec and shows as a nameless 'Supported device'

`vendor/protocol-specs/device-specs/devices/yeelight-cube-lamp.yaml:87` · **low** · spec-upstream · found by spec-vs-code · verified by 1 adversarial reader

**Evidence.**

yeelight-cube-lamp.yaml:87 `mdns_service_type: "_miio._udp.local."` and its
discovery method declares `_miio._udp.local.` with an `identity_mapping` but
no `txt_match`; xiaomi-miio.yaml declares the same type with
`platform_fallback: true`. `_miio._udp` is deliberately NOT in
`is_shared_service_type` (rust/src/api/device_api.rs:4303-4318: "yeelight-
cube-lamp also claims the type unnarrowed, so a vacuum comes back badged as a
lamp ... Filed upstream rather than papered over here"). Because the type is
non-shared, `match_network_axes` puts it in `service_types` and `confidence()`
returns Strong; the platform spec stands aside only for a *narrowed* claimant,
and yeelight-cube-lamp is not narrowed. This is not tracked in
the app-side audit notes.

**Scenario.**

A Roborock S7 or Xiaomi air purifier advertising _miio._udp is listed on the
Wi-Fi tab as a Strong 'Yeelight Cube Lamp' ahead of the honest 'Xiaomi miIO
device' platform entry, with the lamp's controls offered.

**Fix.**

Upstream (vendor/protocol-specs is a subtree): on yeelight-cube-lamp.yaml's
`_miio._udp.local.` discovery method add `txt_match: [{key: model, match:
prefix, value: yeelink.light}]` (or the confirmed cube model prefix once
hardware fills it in), or drop the mDNS claim and rely on the `yeelight-lan`
probe / `wifi_bulb` SSDP target the spec already declares. Once the cube
narrows the type, the existing fallback_ok rule makes xiaomi-miio stand aside
for real cubes and win cleanly for everything else. No app-side code change;
optionally add a matcher test with two identities (platform fallback +
unnarrowed product on a non-shared type) pinning the tie-break so a catalogue
reorder cannot flip which name wins.

**Verifier's note.**

The spec-level facts are literally true on this branch: vendor/protocol-
specs/device-specs/devices/yeelight-cube-lamp.yaml:87 sets
identification.mdns_service_type to `_miio._udp.local.` and its discovery mdns
method (lines 98-111) declares the same type with an identity_mapping and no
txt_match; xiaomi-miio.yaml (lines 68-78) claims the same type with
`platform_fallback: true`; `_miio._udp` is deliberately absent from
is_shared_service_type (rust/src/api/device_api.rs:4291-4330, with a comment
that names this exact defect and says it was "filed upstream"). In
match_network_axes (4123-4200) a non-shared type lands in `service_types`, so
confidence() (3707) returns Strong for BOTH specs; `fallback_ok` only makes
the platform stand aside when another spec NARROWED the type (narrowed_types,
4405-4419), and `platform_fallback_match` only fires for shared types (4193),
so the platform flag is inert here. So a Roborock/purifier advertising
`_miio._udp` produces two Strong matches.  The claimed user-visible
consequence, however, is not what the code does. rank_matches (4462-4469)
breaks a Strong/Strong tie on volunteered-identifier count (1 each) and then
on spec_index, and the catalogue

## Unverified leads

### R-192 — hisense-vidaa.yaml and bambu-lab-lan.yaml declare an MQTT broker without mqtt.transport_security, so the app infers TLS from the port number

`lib/services/mqtt_session.dart:142` · **low** · spec-upstream · found by ios-native-and-boundary · unverified (low; reported by one reader)

**Evidence.**

`MqttConnect mqttConnectorFor(int port) => port == 1883 ? plainConnect :
tlsConnect;` with the comment 'Deriving transport security from the port is a
CONVENTION, not a spec declaration' (142-155);
`selectMqttConnector(declared:…)` only uses the declaration when present
(161-166). `grep -rln transport_security vendor/protocol-specs/device-
specs/devices` returns only dyson-air-purifier.yaml (line 246:
`transport_security: "plaintext"`, with the note 'the spec rather than
inferring it from the port number'); hisense-vidaa.yaml and bambu-lab-lan.yaml
(both 8883/TLS) do not declare it.

**Scenario.**

A Hisense or Bambu firmware that moves its broker to a non-1883 plaintext
port, or a spec pack that adds an MQTT device on 1884, gets a TLS handshake
against a plaintext broker and a 'TLS handshake failed' error with no spec-
level fix available.

**Fix.**

Upstream in liberatedbread-protocol-specs: add `mqtt.transport_security:
"tls"` to hisense-vidaa.yaml and bambu-lab-lan.yaml (and make the schema
require it for every mqtt block); then drop mqttConnectorFor's port heuristic
here once the catalogue is complete.

### R-170 — Five printer/display specs carry their wire contract in prose, so the encoders hardcode opcodes, payload values and channel names the spec should declare

`rust/src/protocol/cat_printer.rs:48` · **low** · spec-upstream · found by rust-proto-ble · unverified (low; reported by one reader)

**Evidence.**

Each handler flags it: cat_printer.rs:47-55 ("the TX characteristic declares
no `commands:` block — so every opcode, fixed payload and default below is
transcribed from device.notes"), 98 (energy byte order unstated), 106-108
(A3/BE/A9 payload byte values guessed as 0x00); fichero_d11.rs:59-66 and
108-117 (density/paper-type vocabularies); ledbadge_bitmap.rs:74-78 (mode
nibble table only in a doc) and 83-85 (8192-byte ceiling);
cdbwsoft_ecb.rs:105-108 (link_flag vocabulary) and 118-126 (bulk channel
chosen by the string "WRITE2" in `name`); idotmatrix.rs:79-84
(`max_chunk_size` declared on the app-proven-unused 0xFEE9 characteristic, not
on 0xFA02) and 87-91 (header time/speed bytes). cat-printer.yaml:47-53
confirms the sequence is prose only.

**Scenario.**

An upstream correction (e.g. apply_energy's byte, set_energy endianness, a
renamed WRITE2) lands in the YAML and the app keeps sending the transcribed
constants; conversely a sibling device on the same family cannot be added as a
spec edit — contradicting the project's spec-driven principle. The cat
printer's guessed A3/BE/A9 payloads and LE energy are also unverified against
hardware (rbaron's client uses `BE 00` for image mode, consistent, but nothing
pins it).

**Fix.**

Upstream: add `commands:` blocks (get_device_state, set_energy with
`endianness`, apply_energy, draw_bitmap, feed_paper;
set_density/set_paper_type/enable/stop; write_badge_data `modes:`;
`framing.max_chunk_size` on 0xFA02; `channel_tag`/role on WRITE2;
`frame_header_defaults`). Here: resolve by name and fall back to the constants
only for pre-key packs, as daniao.rs already does.

### R-223 — Three popled_json specs (autobaba-led-backpack, led-space, nyan-bt-image-controller) declare the identical local_name_prefix "YS" and service 0xFFF0, so every YS* device ties three ways

`vendor/protocol-specs/device-specs/devices/autobaba-led-backpack.yaml:40` · **low** · spec-upstream · found by spec-vs-code · unverified (low; reported by one reader)

**Evidence.**

autobaba-led-backpack.yaml:40, led-space.yaml:60 and nyan-bt-image-
controller.yaml:44 all set `local_name_prefix: "YS"`, all list `0000fff0-...`
in service_uuids and all declare `protocol_handler: popled_json`.
`rank_matches` sorts by confidence then volunteered-count then spec index, so
the tie is broken by catalogue order and the Dart side reports needsChoice.

**Scenario.**

Any YS-prefixed LED panel prompts the user to pick between three identically-
matched specs on every scan.

**Fix.**

Upstream: merge into one `popled` family spec with `variants`, or narrow each
with `discovery.methods[].ble.local_name` regexes on the model suffix.

### R-219 — Twelve SPEC-GAP comments: cat-printer, fichero-d11, idotmatrix, led-name-badge and magic-display protocol facts live only in prose or in Rust constants, not in the spec's command templates

`vendor/protocol-specs/device-specs/devices/cat-printer.yaml:1` · **low** · spec-upstream · found by spec-vs-code · unverified (low; reported by one reader)

**Evidence.**

rust/src/protocol/cat_printer.rs:48-57 (whole opcode set
A1/A2/A3/A4/A6/A9/AF/BD/BE, lattice markers, DPI 50, speed 32, energy 0x3000
transcribed from device.notes; the 0xAE01 TX characteristic declares no
`commands:`), :98 (energy byte order unstated), :106 (state/apply/update
payload byte values unstated); fichero_d11.rs:59-66 (10 FF opcodes, wake-up,
GS v 0, form feed all prose), :108 (density vocabulary), :116 (paper-type
vocabulary); idotmatrix.rs:79-84 (4096-byte chunk stated only on the app-
unused 0xFEE9 char), :87-92 (header time/delay + speed/type bytes unstated);
cdbwsoft_ecb.rs:105 (DATS link_flag vocabulary), :118 (WRITE2 vs WRITE3
distinguishable only by name); ledbadge_bitmap.rs:74-79 (mode enumeration only
in docs), :83-86 (8192-byte payload ceiling only in docs). Also brother_ql.rs
hardcodes the raster language from `payload_hex` prose. These are the owner's
own arch principle inverted: bytes that should be spec data are Rust
constants, so a sibling device (Lujiang-class D11, GB03 variant) is a code
change.

**Scenario.**

A Lujiang-class label printer or a cat-printer variant with a different energy
default cannot be supported by a spec edit; a wrong transcription (e.g. the
unstated energy endianness) prints blank labels with no error.

**Fix.**

Upstream: give each of these characteristics a `commands:` block
(get_device_state, set_dpi_as_200, set_speed, set_energy, apply_energy,
update_device, start_lattice, end_lattice, draw_bitmap, feed_paper;
set_density, set_paper_type, wake_up, enable_printer, form_feed, stop_print),
state the missing byte orders/values, declare `framing.max_chunk_size` on
0xFA02, and add `print_density`/`paper_type`/`modes`/`max_payload_bytes`
fields on the image_upload feature; then delete the Rust constants in favour
of resolving by name (as idotmatrix already does for enter_diy_mode).

### R-220 — divoom-pixoo identification is unusable: comma-joined `local_name_prefix` string and a non-schema `local_name_contains` key

`vendor/protocol-specs/device-specs/devices/divoom-pixoo.yaml:51` · **low** · spec-upstream · found by spec-vs-code · unverified (low; reported by one reader)

**Evidence.**

divoom-pixoo.yaml:51 `local_name_prefix: Pixoo16-WiFi,Pixoo16WiFi,Pixoo64,Di-
Da` — one string, so `Identification::local_name_prefixes()` (types.rs) yields
a single needle 'Pixoo16-WiFi,Pixoo16WiFi,Pixoo64,Di-Da' that no advertisement
starts with; :52 `local_name_contains:` is not in the schema's identification
property list and nothing reads it. The spec's discovery block is `none:`
prose and it declares no default_port, so `match_network_axes` returns empty
before names are consulted.

**Scenario.**

A Pixoo that does advertise over BLE is never recognised; the identification
block is dead weight either way.

**Fix.**

Upstream: rewrite as `local_name_prefixes: [Pixoo16-WiFi, Pixoo16WiFi,
Pixoo64, Di-Da]` and move the contains needle into
`discovery.methods[].ble.local_name: {match: contains, value: PixooLCDWIFI}`;
declare `default_port: 9000` so the network path can at least hear the name.

### R-221 — hotwired-heated-gear, spider-farmer-ggs and gerbing-thermogauge put advertised names under keys the schema and app do not read (advertisement_names, local_name, local_name_contains)

`vendor/protocol-specs/device-specs/devices/hotwired-heated-gear.yaml:42` · **low** · spec-upstream · found by spec-vs-code · unverified (low; reported by one reader)

**Evidence.**

hotwired-heated-gear.yaml:42 `advertisement_names: [BT-912, BT-712]` (should
be `local_names`), no discovery block, so the only identifier is
`0000ffb0-...` (`Identification` sweeps the key into `extensions`,
types.rs:1573-1580); spider-farmer-ggs.yaml:132 `local_name: "SF-GGS-CB"` and
gerbing-thermogauge.yaml:96 `local_name_contains: [Gerbing, Gyde]` are
likewise unread — those two survive only because their
`discovery.methods[].ble.local_name` restates the rule. The schema's
identification block has no `additionalProperties: false`, so validation
passes.

**Scenario.**

A Hotwired controller that does not advertise 0xffb0 in its scan response is
never recognised, and after the post-connect UUID bug is fixed its match is
only 'Strong by a 0xFFxx squat UUID' with no name corroboration.

**Fix.**

Upstream: rename to the schema's `local_names` / `local_name_prefixes`, and
add `additionalProperties: false` (or a lint) to `identification` so stray
keys fail validation.

### R-224 — Commands that can never render: logitech-harmony-hub http commands without path/method, tuya-wifi-gas-sensor heartbeat without body, tuya-bt-soil-tester `transport: ble` top-level commands without a characteristic

`vendor/protocol-specs/device-specs/devices/logitech-harmony-hub.yaml:213` · **low** · spec-upstream · found by spec-vs-code · unverified (low; reported by one reader)

**Evidence.**

logitech-harmony-hub.yaml:213 `get_config: {transport: http}` (also
start_activity, power_off, send_command) with no `path`/`method`;
`qualify_network` (bindings.rs:1090-1100) requires both and declines. tuya-
wifi-gas-sensor `heartbeat: {transport: tcp-json, command: "0x09
(HEART_BEAT)"}` has no `body` (bindings.rs:1130). tuya-bt-soil-tester
`pair`/`dp_query` declare `transport: ble` in the top-level block, a value no
transport arm handles (bindings.rs:1155 `_ => return None`).

**Scenario.**

These commands parse, validate against the schema, and silently resolve to
nothing; the entities that bind them are counted as hidden with no hint why.

**Fix.**

Upstream: give the Harmony commands their real transport (WebSocket on 8088
with `path`/frame), the Tuya heartbeat a `body`, and move the soil-tester's
BLE commands onto the 2b11 characteristic's `commands:`; schema-side, require
`path`+`method` when transport is http and `body` when tcp-json.

### R-151 — magic-home-zengge-wifi declares `auto: "sum_checksum"`, a role no schema vocabulary or encoder knows

`vendor/protocol-specs/device-specs/devices/magic-home-zengge-wifi.yaml:234` · **low** · spec-upstream · found by rust-codec · unverified (low; reported by one reader)

**Evidence.**

`checksum: {type: uint8, auto: "sum_checksum", description: "(sum of preceding
bytes) & 0xFF; encoder-filled."}` on the top-level `set_color` command (`body:
"31 {red} {green} {blue} {white} F0 0F {checksum}"`). The schema's only `auto`
enum is `[sequence, packet_length, checksum, xor_checksum, crc16_modbus]`
(schema.json, services/.../parameters) — the additive role is spelled
`checksum`, and no `auto` key exists on network command parameters at all. The
Rust `SpecCommandParameter` (spec/types.rs:469-497) sweeps the key into
`extensions`, `AutoRole` (spec/types.rs:2084) has no such variant, and
`resolve_parameter` (protocol/mod.rs:114-137) will report
`ParameterMissing(set_color.checksum)` for a value the spec says the encoder
fills. The catalogue's other 16 additive checksums use `auto: "checksum"`.

**Scenario.**

Any consumer that renders `set_color` from this spec either fails with a
missing `checksum` parameter or asks the user for a checksum byte; the frame
can never be sent correctly from spec data alone.

**Fix.**

Upstream (liberatedbread-protocol-specs): change to `auto: "checksum"` with
`checksum_start: 0` (the frame sums from byte 0), and extend the network-
parameter schema with the same `auto` enum so the validator catches the next
misspelling. Locally, nothing to change beyond refreshing the subtree.

### R-222 — Four ONVIF camera specs claim the identical SSDP target urn:schemas-onvif-org:service:Media, which ONVIF devices do not announce over SSDP, so the target is both dead and ambiguous

`vendor/protocol-specs/device-specs/devices/onvif.yaml:75` · **low** · spec-upstream · found by spec-vs-code · unverified (low; reported by one reader)

**Evidence.**

onvif.yaml:75, amcrest-dahua-camera, hikvision-isapi-camera and reolink-camera
all declare `ssdp_search_targets: [urn:schemas-onvif-org:service:Media]`;
ONVIF discovery is WS-Discovery on UDP 3702 (the onvif spec's own
identity_mapping uses `wsdiscovery:uuid`), and the app's scanner only speaks
SSDP M-SEARCH (real_network_scan_service.dart:1758-1780). If a device did
answer, all four tie at Strong (`is_shared_service_type` does not list it, and
SSDP targets have no platform_fallback), with the generic `onvif` spec unable
to stand aside.

**Scenario.**

No ONVIF camera is ever identified by this target; a hypothetical responder is
badged as Amcrest, Hikvision, Reolink and generic ONVIF simultaneously.

**Fix.**

Upstream: drop the SSDP target from the three vendor specs (identify them by
`_http._tcp` txt/`server` header or MAC prefix) and mark the generic onvif
spec as the WS-Discovery platform fallback; add a `ws_discovery` discovery
method type to the schema.

### R-033 — Vizio spec's `arguments` do not describe the wire body its own `example_body` shows, and the byte-for-byte example diff only runs for Hue

`vendor/protocol-specs/device-specs/devices/vizio-smartcast.yaml:597` · **low** · spec-upstream · found by net-control-http · unverified (low; reported by one reader)

**Evidence.**

`arguments: {CODESET: 11, CODE: 1, ACTION: "KEYPRESS"}` (line 597) but
`example_body: {"KEYLIST": [{"CODESET": 11, ...}]}` (line 598-599).
rust/src/protocol/http.rs:124-143 `render_body` emits a flat object from
`arguments`, so the rendered body is
`{"CODESET":11,"CODE":1,"ACTION":"KEYPRESS"}`. The only assertion that a
rendered body matches a published example,
rust/tests/network_control_http.rs:129-155
`every_command_with_an_example_renders_it_byte_for_byte`, loads the Hue spec
only (`assert_eq!(diffed, 4)`).

**Scenario.**

Any spec author who publishes an `example_body` that the flat-`arguments`
renderer cannot reproduce ships a command the app renders wrong, and CI never
notices because the diff is per-spec opt-in. Vizio is the concrete case today.

**Fix.**

Upstream: give the Vizio commands a body shape the renderer can produce (e.g.
`arguments: {KEYLIST: [{...}]}` if nested literals are allowed, or a
`body_template`). Here: turn the byte-for-byte test into a catalogue-wide walk
in rust/tests/vendored_assets.rs — for every vendored spec, every http command
with an `example_body` must render to it (with placeholder values from the
spec's parameter examples) — so a mismatch fails CI rather than a user's TV.

### R-032 — vizio-smartcast key commands declare neither their `AUTH` credential nor their `Content-Type`, so the app cannot authenticate a press; the schema has no `headers` key for a command to declare them under

**Where.** vendor/protocol-specs/device-specs/devices/vizio-smartcast.yaml:583-1000
(every `press_*` command), :285 (`smartcast_common.request_format.http.headers`,
prose only); device-specs/schema.json `commands.additionalProperties.properties`
(no `headers`).

**Evidence.**

The app's HTTP transport now sends per-command headers: the Rust renderer
reads `headers:` off a command (name → value, `{name}` placeholders filled
from `parameters` exactly as a `body` template's are, a `source:
credential:<name>` parameter resolving from the stored credential), and the
sender puts them on the wire, a declared `Content-Type` replacing the one it
infers from the body. Nothing in the vendored catalogue declares one yet. The
Vizio spec states its needs in prose — "Content-Type: application/json on
PUTs; AUTH: <token> on authenticated calls" — but its twenty-two `press_*`
commands and three state paths declare no header and no credential, so
`credentials_for_device` returns nothing, no card asks for the token, and
every press still goes out unauthenticated.

**Fix (upstream).**

1. schema.json: add `headers` to the command object — `{"type": "object",
   "additionalProperties": {"type": "string"}}`, "request headers this
   command sends; values may carry `{name}` placeholders filled from
   `parameters`" — the same shape `websocket.connect.headers` already has.
2. vizio-smartcast.yaml: on every authenticated command declare
   `headers: {Content-Type: "application/json", AUTH: "{auth_token}"}` and
   `parameters: {auth_token: {type: string, source: "credential:auth_token",
   description: "The AUTH_TOKEN pairing issued."}}`; on the pairing
   endpoints, `Content-Type` alone. The `issues_credentials` entry for
   `auth_token` should name `pair_confirm` and its reply path
   `ITEM.AUTH_TOKEN` so the pairing flow, not the person, fills it.
3. The state reads (`/state/device/power_mode`, `/app/current`, the current
   input) are bare `state_topic` paths and can carry no header; declare each
   as a `commands` entry with the `AUTH` header and point the entity's
   `state_command` at it.
4. Render the `KEYLIST` wrapper — R-033 above.

## App-side status of the verified items (2026-09-16)

- **R-141 / R-214 (xkglow-chrome `set_rgb_color`)** — the app now lets
  `template` win when a command declares both, so the zone/RGB sliders work.
  Consequence: the light entity's `turn_on` role, which the fixed `value`
  bytes used to serve, no longer resolves because `zone` has no default.
  Upstream: delete `value:` from `set_rgb_color`, add `default: 0` to `zone`
  (so `set_color` qualifies), add a separate fixed `turn_on` command for the
  entity, and consider a schema rule that forbids `value` and `template` on
  one command.
- **R-211 (hisense-vidaa)** — its only identification axis is the shared
  `MediaRenderer:1`, which the matcher now treats like a SIG-assigned UUID
  (reported, never promoting), so the spec matches nothing on the network scan
  until it names a vendor-specific axis: the manufacturer / modelDescription
  descriptor narrowing its prose describes, or an mDNS type / TXT rule the
  matcher executes.
- **R-152 / R-153** — no spec change needed: the renderer now honours literal
  `body:` templates and the BLE-vocabulary numeric type names (`uint8`,
  `float`, ...) on http arguments.


## From the R-138 / R-140 fix round (2026-09-17)

The app now parses and executes what these two keys promise — `path_fallback`
/ `state_topic_fallback` ride the rendered request and the sender retries on a
404, and `initialization` blocks are resolved into an ordered connect-time
handshake — so these are what the CATALOGUE still gets wrong or cannot say.

### S-01 — `$defs/initialization` does not admit the keys six specs already use

**Where.** vendor/protocol-specs/device-specs/schema.json `$defs/initialization`
(properties: `characteristic`, `write`, `read`, `delay_ms`);
smartdawn-smart-lights.yaml:435-439 (`subscribe: true` ×2),
schlage-smart-locks.yaml:400-430 (`description` ×5),
kingsmith-walkingpad.yaml:497-512 and xkglow-chrome.yaml:153-156 (`notes`).

**Evidence.**

The step object is open, so the extra keys parse — but they are not
documented, which means nothing says what a consumer must do with them, and
two of them change what a step IS. `subscribe: true` is an operation
(SmartDawn opens both DDP notify channels before anything is sent, and a
consumer that only knew `write`/`read` would run neither step). A step with
only `description` is the opposite: prose, not an instruction — schlage's
session resumption is a fresh SPAKE2 exchange per connect whose bytes no YAML
can hold, and a consumer that treated it as an executable step would send
nothing and believe it had handshaked.

**Fix (upstream).**

Add to `$defs/initialization`'s item properties: `subscribe` (boolean, "open
notifications on this characteristic in this step"), `description`/`notes`
(string). Say in the array's description that a step with none of `write`,
`read` or `subscribe` is documentation of a handshake a client must implement
itself, not a step it can execute — the app reports those separately and
declines to run them.

### S-02 — kingsmith-walkingpad's initialization characteristic belongs to no declared service, and its "before EACH command" rule is prose a consumer cannot execute

**Where.** vendor/protocol-specs/device-specs/devices/kingsmith-walkingpad.yaml:497-512.

**Evidence.**

The block hangs off the FTMS service `00001826-…`, but its
`characteristic: d18d2c10-c44c-11e8-a355-529269fb1459` is declared in no
service in the file (the spec's own note says the parent service UUID "must be
captured from hardware"). A consumer resolving a step's service from the
catalogue therefore has only the block's owner, which is the wrong service —
the write will fail at the platform on an MC-21 unit. Separately, the same
note says KS Fit "sends this fixed 8-byte frame before EACH Control Point
command, not just once per connection", and the schema has no way to say that
as data: `initialization` is defined as "executed after connecting and before
normal commands", so a client honouring the block literally runs the preamble
once and every later Control Point write still gets CONTROL_NOT_PERMITTED.

**Fix (upstream).**

1. Capture the vendor service UUID and declare `d18d2c10-…` as a
   characteristic under it, so the step is addressable.
2. Give the schema a way to state the cadence — e.g. `when: "connect" |
   "before_each_command"` on a step, defaulting to `connect` — and mark this
   step `before_each_command`; or, failing that, declare the preamble as a
   `framing`/prefix on the Control Point characteristic, which is where a
   per-write rule belongs.

Until one of those lands the app runs this handshake once per connection and
an MC-21 unit will still refuse the second and later commands.

### S-03 — hyperice-hypervolt-plus states its handshake characteristic in upper case

**Where.** vendor/protocol-specs/device-specs/devices/hyperice-hypervolt-plus.yaml:209-211
(`characteristic: "31CB4570-3c31-4e56-8c2b-e8f479d2b056"`) against :224
(`uuid: "31cb4570-3c31-4e56-8c2b-e8f479d2b056"`).

**Evidence.**

Cosmetic but load-bearing for a consumer that compares UUID strings: the app
matches case-insensitively, so this resolves, but the file is inconsistent
with itself and with the rest of the catalogue, which is lower-case
throughout.

**Fix (upstream).** Lower-case it.

### S-04 — a BLE command parameter's code table is written `values:`, which the schema does not declare

**Where.** `device-specs/schema.json`, the BLE command parameter block
(`services[].characteristics[].commands.*.parameters.*`), against
`devices/elk-bledom-led-strip.yaml` (`set_light_on_off.state`,
`set_scheduler.on_off`, `set_mic_on_off.state`), `devices/lotuslamp-x.yaml`
(`set_timer.timer_type`) and `devices/wl-smartled-pixel-strips.yaml`
(`set_brightness.light_mode`, `set_channel_mask.state`, `set_mic_on_off.state`,
`set_timer.mode`, `query_timer.mode`).

**Evidence.**

Nine parameters across three specs carry `values: {0: off, 1: on}` — a raw →
label code table, the same shape the schema DOES declare on a `format` field
and on a network command's parameter. The BLE parameter block declares no such
key: its vocabulary for an enumeration is `allowed` (the values) plus `labels`
(their names, paired by index). The block does not set
`additionalProperties: false`, so all nine validate, and a consumer that
implemented only what the schema declares saw a parameter with no constraint
at all and drew a 0..255 slider over a two- or four-value switch.

Both spellings say the same thing, and the schema says one of them twice: the
code table is `values` for a reading and `allowed`+`labels` for a write, which
is a difference in direction, not in meaning.

**Fix (upstream).** Either:

1. Declare `values` on the BLE command parameter, with the same description
   the `format` field's carries, and say how it relates to `allowed`/`labels`
   (values IS the set; labels name what allowed lists); or
2. Rewrite the nine parameters as `allowed` + `labels` and say in the block's
   description that `values` is a decode-side key with no meaning here.

The app reads both today (`Parameter::allowed_with_labels`), preferring
`allowed` where a parameter writes both, so either fix is compatible with what
ships.

### S-05 — `state_command`'s own example names something the spec describes nowhere

**Where.** `device-specs/schema.json`, `entities[].state_command`, against
`devices/divoom-pixoo.yaml:502,510,515,520` and
`devices/sony-bravia.yaml:1179,1447,1452,1457`.

**Evidence.**

The key's description ends "Names a command in the spec's own
`http_endpoints`/command vocabulary" — and its example, `'Channel/GetOnOff'`,
is a Divoom WIRE command that appears in neither of those places in
divoom-pixoo.yaml. Sony's four sensors do the same with JSON-RPC method names
(`getPowerStatus`, `getPlayingContentInfo`, `getVolumeInformation`), which the
spec's own notes describe as a transport gap.

A consumer that believes the sentence cannot render a request for any of the
eight: there is no method, path or body to build one from. A consumer that
believes the example has to invent the envelope the vendor's API wants, which
is per-device knowledge the spec exists to carry. The app takes the sentence,
so those eight entities no longer claim a state poll.

**Fix (upstream).** Pick one and make the other conform:

1. If `state_command` is a NAME, give each of the eight an `http_endpoints`
   entry (or a `commands` entry) carrying the method, path and request body
   that fetches it, and point `state_command` at that name. Divoom's is one
   POST to `/post` with `{"Command": "Channel/GetOnOff"}` — the spec already
   documents that envelope for its write commands; and replace the key's
   example with one that resolves.
2. If it is a wire-protocol token to be posted to `state_endpoint`, say so in
   the description, and define how a consumer builds the request around it
   (which is a per-API question the schema would then have to answer).

Sony's four are additionally blocked on the JSON-RPC-plus-auth-header
transport their own notes name; the entities can stay declared, but a
consumer should not be told a poll exists that nothing can issue.

### S-06 — a BLE discovery `manufacturer_data.pattern` does not say whether it starts at the company-id bytes

**Where.** `device-specs/schema.json`,
`discovery.methods[].ble.manufacturer_data` (`match`, `pattern`, `mask`),
against `devices/ideal-led.yaml`, `devices/magic-display.yaml`,
`devices/shining-glasses.yaml`, `devices/shining-mask.yaml` on one reading and
`devices/banlanx-sp6xxe.yaml`, `devices/braun-silk-expert-pro5.yaml`,
`devices/emazinglights-spectra.yaml` on the other.

**Evidence.**

Nine vendored matchers declare a `pattern`, and they measure it from two
different places. The four `company_id: 21076` specs write patterns that
INCLUDE the company-id bytes: ideal-led's `54520061` is "TR" (0x5254
little-endian = 21076) followed by `00 61`, and its own description says the
payload "starts with 0x54 0x52 0x00 0x61". banlanx-sp6xxe and
braun-silk-expert-pro5 say the opposite in as many words — "match on the
payload after the two company-ID bytes" — and their two-byte patterns only
make sense that way; emazinglights-spectra's `48554231` ("HUB1") is likewise
the payload after company `0x454C` ("LE").

The schema says nothing about the origin, so a consumer must guess, and either
guess mismatches half the set. This matters most for exactly the specs that
NEED the pattern: the four sharing company id 21076 are distinguishable by
nothing else, so a scan either ranks all four equally or, with the wrong
origin, matches none of them.

**Fix (upstream).** State the origin in `pattern`'s description — the natural
reading is "the manufacturer-specific AD payload AFTER the two company-id
bytes, since `company_id` already matched those" — and rewrite whichever group
disagrees with it (the four 21076 patterns become `0061`, `0027`, `0041`,
`004e` under that reading). While there: say that `mask` must be the same
length as `pattern`, and that a `masked` match compares
`payload & mask == pattern & mask`.

The app executes none of these today; the ambiguity is why.

### S-07 — lg-webos publishes no per-command `example_body`, so its 32 frames have nothing to diff against while Samsung's 38 do

**Where.** `devices/lg-webos.yaml`, `commands` (all 32), against
`devices/samsung-tizen-tv.yaml`, which publishes `example_body` on 38 of its
39 commands.

**Evidence.**

Samsung declares the exact wire frame for every WebSocket command it carries
(`example_body: '{"method":"ms.remote.control","params":{...}}'`), which is
what lets `rust/tests/websocket_control.rs` compare the renderer's output with
the catalogue byte for byte — the discipline Hue, Roomba and Wemo already
have. LG declares none. It publishes ONE frame, in prose:
`protocol_details.remote_common.request_format.example`
(`'{"id": 12, "type": "request", "uri": "ssap://audio/volumeUp", "payload": {}}'`),
which the same test file diffs — but that covers one command out of 32, and it
is a prose example rather than a field a consumer can enumerate.

The gap is not cosmetic for this spec in particular. LG is the two-socket
device: nine of its commands ride a `pointer` channel that speaks
line-structured plain text (`type:button\nname:HOME\n\n`) on a socket the TV
hands out at runtime, and the other twenty-three ride the JSON `ssap` socket.
A command that lands on the wrong socket is accepted and ignored, which on a
TV is indistinguishable from broken hardware. The test can only assert the
SHAPE of those frames today (it checks the channel, the `type:button` prefix
and the trailing blank line); with `example_body` it could assert the frames.

**Fix (upstream).** Add `example_body` to each of lg-webos.yaml's commands,
spelled exactly as Samsung's are — the rendered JSON for the ssap commands
(with a pinned `id`, as the prose example uses 12), and the literal text frame
including its `\n\n` terminator for the nine pointer buttons. The app side
needs no change: `rust/tests/websocket_control.rs` already enumerates
`example_body` for Samsung and would pick LG's up the moment they exist.

While there: the prose example in `request_format` and the per-command bodies
should agree on the `id` they use, so a reader is not left wondering whether
12 means something.

### S-08 — `payload_formats.V1Envelope` states its shape as prose, so no decoder can follow it

`device-specs/devices/hue-bridge.yaml:344` declares the CLIP v1 outcome
envelope with a `parse_rules:` list of six English sentences: which shape is an
envelope, what a `success` element means, what an `error` element carries, and
which three error types a client has to treat specially (101 keep polling, 1
re-pair, 201 write `on` alongside `bri`). Every one of those is a decision a
decoder has to make, and none of them is expressed in a form a decoder can
read — so the rules are transcribed by hand into
`lib/services/hub_http_client.dart` (`checkV1Envelope`, `parseV1Envelope`),
which is the one piece of device knowledge in a transport class that otherwise
only moves bytes (R-053).

The ask: give the schema a way to state an outcome envelope — the container
shape, where the error type and description live, and which types are
retryable, terminal, or a documented precondition — so the envelope can be
decoded from the spec rather than mirrored in a client. Hue is the only
catalogue entry that needs it today, but "the HTTP status says nothing, read
the outcome from the body" is a common REST shape and the next such device
would otherwise be transcribed by hand too.

### S-09 — a spec cannot say "these devices are driven through a controller, and here is the controller"

`lib/screens/wifi_scan_screen.dart` holds a list of Ubiquiti platform prefixes
(`UNVR`, `UDM`, `UCKP`, `UCK-G2`) and the pictograms that mean "camera", so the
Wi-Fi tab can tell the user a camera it found is managed in UniFi Protect and
point at the controller on the same network. Those are product facts about one
vendor's hardware, sitting in a screen: a new Ubiquiti model is a spec refresh
everywhere else in this app and a Dart edit here (R-086).

The ask: a way for a spec to declare that its devices are driven through a
controller rather than individually, and how to recognise that controller among
discovered devices — something like a `managed_by:` block naming the
controller's search target and a platform pattern. Rust could then answer "is
this device driven elsewhere, and where is elsewhere" from the catalogue, the
way it answers every other identification question, and the client would hold
no vendor list at all. Ubiquiti is the case in hand; anything with a hub or an
NVR has the same shape.

---

## Audit, 2026-09-17: knowledge in the app that belongs in the catalogue

A read-only sweep of `lib/` and `rust/src/` for device, vendor or protocol
knowledge hard-coded in the app rather than declared by a spec. Ten findings
where the knowledge could realistically move; the sweep also separated out the
cases that are genuinely platform or transport concerns, and the ones whose
code comment already explains why they cannot move, so this list is only the
actionable part. Ordered by how much each would reduce "adding a device means
editing the app".

### S-10 — `discovery.methods[].udp_broadcast` was declared by ten specs and executed by none

**Partly addressed in the app.** The blocks are now read as data and the
probes that carry a payload are sent (`CatalogueHandle::udp_broadcast_probes`,
and the catalogue transport in `real_network_scan_service.dart`). What remains
below is what the SPEC still has to change. The count is also corrected: the
original filing said thirteen, counting three specs that mention
`udp_broadcast` but declare no method — both `frigidaire-*-ac` name a SoftAP
provisioning port under `provisioning_local_only`, and `squeezebox-slimproto`
describes a player finding a server, which is not a probe this app sends.

Ten specs carry a real block (`irobot-roomba`, `tplink-kasa-smart-plug`,
`ubiquiti-unifi-device`, `mikrotik-routeros`, `tuya-generic-device`,
`tuya-wifi-gas-sensor`, `unifi-protect-camera`,
`limitlessled-milight-bridge`, `aqara-hub`,
`synology-diskstation`). Rust read `discovery.methods[]` only for
`ble_scan.local_name` and the mDNS keys; `spec/types.rs` says the rest is
"preserved unexecuted".

So eight vendor probes are written in Dart instead —
`real_network_scan_service.dart` holds the ports (LIFX 56700, Ubiquiti 10001,
MNDP 5678, Tuya 6666/6667, Kasa 9999, Yeelight 1982, Govee 4001→4002, Roomba
5678), the broadcast addresses, the reply parsers with their TLV type bytes,
and the `Roomba-`/`iRobot-` hostname prefixes. The probe payloads are Rust
constants (`roomba::DISCOVERY_PROBE = b"irobotmcs"`, and the Kasa and LIFX
equivalents). A comment in that file states that the Roomba transport "takes
its probe from the spec"; it does not — that was verified.

Two consequences, both live today. Six of the thirteen specs declare a probe
the app cannot run, so those devices are undiscoverable however well their
spec is written. And two probes the app does run emit lan-protocol tokens no
spec declares (`govee-lan`, `yeelight-ssdp`), so they can never promote a
match even though eight Govee and Yeelight specs exist.

The schema mostly already covers it: the arm carries `port`,
`broadcast_address`, `probe_hex`, `passive_ok`, `response_format` and
`identity_mapping`, and Kasa already ships its XOR-ciphered probe as
`probe_hex`. To cover the rest it needs `multicast_group` and a `listen_port`
distinct from the send port (Govee sends to 4001 and listens on 4002; Yeelight
is multicast), and a TLV dialect for `identity_mapping.source` — which that
key's own description already contemplates as `tlv:0x0005`.

**Related, and worth fixing in the same pass:** `discovery.methods[].ble
.manufacturer_data.{pattern,mask,match}` is likewise parsed and never
executed — Rust matches company id equality only. S-06 covers the ambiguity
about where the pattern starts; this is the separate fact that nothing reads
it at all.

### S-11 — the "this identifier proves nothing" list is a Rust `matches!`, not a registry

`is_shared_service_type` in `device_api.rs` holds twenty service types and
search targets that must never promote a match on their own: `upnp:rootdevice`,
`ssdp:all`, the three generic UPnP device types, `_hap`, `_airplay`, `_raop`,
`_companion-link`, `_googlecast`, `_http`, `_https`, `_ipp`, `_ipps`,
`_printer`, `_pdl-datastream`, `_workstation`, `_device-info`,
`_services._dns-sd._udp`. It affects every Wi-Fi spec in the catalogue.

Its BLE twin already does this the right way: `is_sig_assigned_service` reads
`registries/bluetooth-service-uuids.tsv` from this repo, and its doc comment
calls the two halves of one rule. The ask is the sibling asset —
`registries/shared-service-types.tsv`, one type per line with a reason column,
pulled by `update-specs.sh` and read the same way. **No schema change at all.**

Why it is worth doing: R-211 was a defect whose fix was adding two strings to
that `matches!`, which shipped as an app release rather than a spec refresh. A
new ecosystem type — `_matter._tcp`, `_meshcop._udp` — is a Rust edit today.

### S-12 — a `format:` field cannot state its device class, so the app guesses from English

`ha_sensor_mapping.dart` decides the Home Assistant device class a reading is
permanently registered under by testing the field's NAME for the substrings
`battery`, `humid`, `temp`, `lux`, `illumin`, `pressure`. The same guessing
feeds icon choice and sensor banding. It affects every BLE sensor spec: 92
bundled `format:` fields, 69 of which carry no unit either.

The file says so itself: "The class is inferred from the field name — the
spec's `format:` block has no device-class vocabulary of its own — but the
UNIT is the spec's to state."

The ask is one additive key: `device_class` on
`services[].characteristics[].format[]`. The vocabulary already exists at
`entities[].device_class`; it is simply not available where a BLE reading is
described. Verified against the schema: `device_class` appears only under
`/properties/entities/items/properties`.

### S-13 — `entities[].commands` can name a command but cannot bind an argument to a role

A role maps to a command NAME and nothing else, so a device whose verbs are
one opcode plus an argument byte cannot express itself. FTMS is the case in
hand: stop and pause are both `stop_or_pause`, distinguished by `action: 1`
versus `action: 2` — and those two bytes are consequently written into a
Flutter widget (`treadmill_control_card.dart`).

That widget also carries a fallback list of eighteen vendor command names
(KingSmith's `start_belt`/`stop_belt`, UREVO's five `ur_*` verbs, an `ft_*`
class, FTMS's three) and uses `unit == 'km/h'` to decide which parameter is the
speed. The code is honest about this being a legacy path — the entity layer
wins wherever it resolves, and the names are "the fallback for specs that
predate the entity bindings" — so half the fix is specs declaring
`entities[].key`. The other half needs the schema.

Ask: let a role's value be either a string or `{command: <name>, values:
{<param>: <literal>}}`. General rather than treadmill-shaped — any device with
one opcode and a selector argument needs it.

### S-14 — the `image_upload` feature cannot state a palette ceiling, so one device's limit is applied to twelve others

The LED editor quantizes every panel to sixteen colours. That number belongs to
exactly one codec: SmartDawn's TUTU run-length format packs its palette index
into a nibble, which is intrinsic and genuinely cannot be a spec number *for
that codec*. But it is applied unconditionally to all thirteen specs that reach
the editor, including seven 1-bit bitmap devices whose real limit is two
(`cat-printer`, `cat-printer-mxw01`, `fichero-d11-printer`, `niimbot-d110`,
`brother-ql-1110nwb`, `bluetooth-led-name-badge`, `magic-display`) and five
whose formats have no palette constraint at all (`autobaba-led-backpack`,
`nyan-bt-image-controller`, `led-space`, `idotmatrix`).

Ask: `features[].max_palette_colors` on the `image_upload` feature, absent
meaning no constraint. This folds into the same "more fields on the
image_upload feature" ask R-219 already makes.

### S-15 — Brother QL print geometry and the DK media table are Rust constants, though the spec states them

`render_brother_ql_test_label` hard-codes a 1296-dot head, a 44-dot right dead
zone, 300 dpi as `mm * 3000 / 254`, a die-cut undershoot of one eighth, and a
400-row continuous strip. `brother-ql-1110nwb.yaml` already declares every one
of those under `protocol_details.brother_ql_raster_protocol.geometry` (`dpi`,
`bytes_per_row`, `head_dots`, `invalidate_bytes`, `min_length_dots`,
`max_length_dots`, `additional_offset_right_dots`) and gives exact dot counts
per DK roll under `media.rolls[]` — the table the millimetre arithmetic is
approximating.

Ask: promote `geometry` and `media.rolls` out of untyped `protocol_details`
into a declared block (`features[].print_geometry` and `features[].media[]`)
so Rust can resolve them by key. Distinct from R-219's brother_ql line, which
is about the raster opcodes; this is geometry and media.

The narrow-media caveat should stay in code: `brother_ql.rs` explains that
getting it exactly right is a hardware-calibration question nobody has driven,
which is a fair reason for that one number and not for the rest.

### S-16 — Rabbit Air's GATT addresses live in Rust because its spec declares no `services:` block

`rabbit_air_ble.rs` holds the service and command-characteristic UUIDs and the
framing scheme (a two-byte little-endian length prefix, then fixed chunks), and
exposes them as spec-less FFI calls. The facts do exist in the spec, but as
`protocol_details.ble.gatt` — a vendor-named prose block nothing parses. A
comment in `rabbit_air_setup_screen.dart` claims the GATT addresses "come from
the spec"; they do not.

Ask: declare the pair as an ordinary `services[].characteristics[]` entry with
`properties: [write, indicate]` and a `framing:` block. The framing vocabulary
already exists and is exercised; it needs one new named scheme value,
`length_prefixed_le16`, registered beside `daniao_fragment`.

### S-17 — a device whose control surface is a byte stream is admitted by naming its handler

`network_control_provider.dart` keeps a raster label printer from being dropped
by the empty-entity check with `protocolHandler == 'brother_ql_raster'`. The
reasoning is right — such a device resolves no entities because its surface is
a raster stream — but the predicate names one handler for what is a class:
Niimbot, the cat printers, any future raw-stream device.

Ask: `features[].type: raster_print` (the enum is already
`image_upload|firmware_update|audio_upload|stored_upload`, so this is one more
value), or a capability flag Rust surfaces, so the question becomes "does this
device have a non-entity control surface".

### S-18 — LIFX's white range is declared by the spec and ignored by the code

`lifx.rs` fixes `KELVIN_MIN 1500`, `KELVIN_MAX 9000`, `KELVIN_DEFAULT 3500` and
builds the user-facing slider from them, mirrored again in
`network_light_card.dart`. `lifx-z.yaml` already declares
`set_color.parameters.kelvin: {min: 1500, max: 9000, default: 3500}`.

No schema change needed — this is the clean case where the spec says it and
the code does not look. A LIFX White 800 (2700–6500 K) is a Rust edit today.
The file's broader argument for hard-coding is sound and should be left alone:
the wire layout, field offsets and HSBK packing are not in the YAML and cannot
be. A per-product limit is not wire layout.

### S-19 — air-quality verdict bands are one vendor's shipped defaults applied to every device

`sensor_reading_level.dart` bands radon at 100/150 Bq/m³, CO₂ at 800/1000 ppm,
VOC at 250/2000 ppb, humidity at 25/30/60/70 %, PM2.5 at 10/25, PM10 at 20/50
and battery at 20/10 %. The file records that four of the seven are Airthings'
shipped defaults, transcribed from that spec's own UI-settings notes.

Ask: `entities[].bands: [{level: fair, above: 100}, {level: poor, above: 150}]`,
with a two-sided form for humidity. Worth noting the Airthings device reports
its own thresholds over `griffin_ui_settings`, so a declarative version would
be strictly more honest than a transcription. Lowest priority of these — the
current numbers are defensible — but it is the same shape as the rest.

### S-20 — the Aqara hub's probe payload is not expressible, so it lives in prose

`aqara-hub.yaml` declares a `udp_broadcast` method with `port: 10008`, a
multicast `broadcast_address: 230.0.0.1`, `passive_ok: false` — and no
`probe_hex`. It is the only block in the catalogue that says neither what to
send nor that the device speaks first, so a client reading the schema alone
gets nothing it can act on.

The reason is in the notes, and it is a real limit rather than an omission: the
datagram is `{"command":"whois","address":"<your LAN IP>","port":"<your UDP
listen port>"}`, so the payload depends on the sending phone. No fixed hex
string can stand for it.

Ask: a templated payload alongside `probe_hex` — say `probe_template` with a
small set of substitutions the client fills in (`{local_ip}`, `{listen_port}`),
and a `response_port` for the unicast reply the hub sends back. Two other
blocks would use the same mechanism if it existed; Govee sends to 4001 and
listens on 4002, which S-10 already asks for.

Also worth stating: this is the catalogue's only `broadcast_address` that is a
multicast group rather than a broadcast address. A client has to JOIN it, not
broadcast to it, and nothing in the block says which. A `multicast: true` flag,
or the `multicast_group` key S-10 asks for, would settle it.

### S-21 — a spec can declare a probe but no token to recognise the answer by

`identification.lan_protocols` is what a device that answered a vendor probe is
matched on: the app tags the discovered device with the token and the matcher
treats it as a strong, never-shared identifier. Eight specs declare one.

Two specs that declare a `udp_broadcast` probe do not:
`limitlessled-milight-bridge` and `synology-diskstation`. The app can now send
their probes and read the MAC and module out of the reply, and the device
appears on the Wi-Fi screen — but nothing joins it back to the spec that found
it, so it is listed as an unidentified host rather than as a MiLight bridge.

Ask: every spec declaring a `udp_broadcast` probe should also declare a
`lan_protocols` token for it. The probe and the token are two halves of one
fact, and a schema rule requiring the second where the first exists would keep
them together.

### S-22 — `identity_mapping.source: tlv:<name>` names a field the spec never defines

Four probes read their identity out of a TLV reply and name the field by a
word: `tlv:mac`, `tlv:serial`, `tlv:hostname` on `synology-diskstation`, and
the same shape on the Ubiquiti pair. Nothing anywhere says which TLV tag number
carries `mac`. The app's Ubiquiti and MikroTik parsers know, because the tag
numbers are hardcoded in `real_network_scan_service.dart` from vendor
documentation; a client with only the spec cannot follow.

This is why the generic reader executes `json:`, `csv:` and `payload` sources
and refuses `tlv:` outright. Reading a MAC from a guessed offset is worse than
finding no MAC, because the MAC is what the device is remembered by.

Ask: either name the tag number in the source (`tlv:0x0005`, which the schema's
own description for that key already contemplates) or give the spec a
`tlv_fields:` table mapping name to tag. The Synology block is the sharper case
— its notes say the reply carries a `SYNO` magic and that the project has never
driven a unit, so the field names appear to be aspirational rather than
observed. Until it says how to recognise a `findhostd` datagram, that probe
cannot be executed safely: it is `passive_ok`, so honouring it means binding UDP
9999 and treating whatever arrives as a NAS.

## Found 2026-09-24, while catching up with upstream #61

Each is proposed on the upstream branch `claude/trusting-hawking-qpl9ut`; the
app already copes with today's catalogue, so these only make it say more.

### S-23 — `shared-service-types.tsv` does not list DIAL

The registry S-11 asked for landed, but without the two DIAL search targets
(`urn:dial-multiscreen-org:device:dial:1`, `…:service:dial:1`). Every smart TV
and streaming stick answers both; sony-bravia and vizio-smartcast each claim
one. The app's own list now carries them (a TCL Roku tied Strong with a Sony
and a Vizio before it did), so adopting the registry in place of the Rust
`matches!` must not lose them. Adopting it also needs matter-device to mark
`_matter._tcp` `platform_fallback`, or a Matter node stops matching the moment
that type becomes shared.

### S-24 — the schema did not say what `labels` name without `allowed`

aranet4's `request_history_v1.param` (`min: 1, max: 4`) and
aurora-led-shoes' `set_power.state` (`min: 0, max: 1`) label a contiguous
range — the natural way to write a set with no gaps, `allowed` being for
sets that have them. The schema described `labels` only beside `allowed`,
so the app drew both as unlabelled sliders. The app now pairs labels with a
min..max range when the count matches, and upstream's branch says so in the
schema and checks the count in its test suite.

### S-25 — the TV specs' remaining remote keys carry no `key`

Power Key/Standby, discrete Play/Pause/Stop/Previous/Next/Record, the digits
and the colour keys are laid out here by display name — the fallback table
`entity_keys.dart` says should shrink. Keying them needs vocabulary upstream
(`power_toggle`, `play`, `previous`, `next`, `record`, `num_0`…`num_9`,
`red`/`green`/`yellow`/`blue`); the app already has slots for every one.

### Also worth extending an existing ask

S-09 (devices driven through a controller) should also cover the sixteen
Ubiquiti platform prefixes that map to glyph tokens in
`real_network_scan_service.dart`. Its stated reason — that the platform is only
known at discovery, from the wire — explains when the value arrives, not why
the MAP lives in the app. A `platform_pictograms:` table on the UniFi spec
would close it.
