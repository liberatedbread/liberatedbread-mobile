# Spec Evolution Proposals

A standing, evidence-backed list of ways the device-spec schema could get better,
so the next change is chosen rather than improvised. Nothing here is applied yet;
each proposal is written so a maintainer can accept, defer or reject it on its
merits, and every one carries a compatibility note because the schema has real
consumers (the Flutter+Rust mobile app, the Home Assistant integration) that a
careless change would break.

Grounded in a read of the current schema, all 70 device specs, and a look at how
[Buttplug](https://buttplug.io/) — a mature open-source BLE device-abstraction
library — solves the same problems from the opposite direction.

## First, the thing not to lose

The design decision that makes this registry worth having is **implementable from
the file**. The bytes are in the YAML; `scripts/test_wemo_spec.py` proves a spec
can be transcribed into a working client using only the standard library. That is
the bar, and every proposal below is judged against it: does it make specs *more*
reproducible from the file alone, or does it push knowledge back out into code?

## What Buttplug does, and what to take from it

Buttplug is the closest thing to a sibling project: an open catalogue of BLE
device protocols with thousands of devices. It is worth studying precisely because
it made the **opposite** core choice.

| | This registry | Buttplug |
|--|--------------|----------|
| Where the bytes live | In the spec (`value`/`template`) | In Rust protocol handlers |
| What the config carries | The full protocol | Device identity + named endpoints (`tx`/`rx`) + declared capabilities |
| Escape hatch | `protocol_handler` for the few devices YAML can't express | The handler **is** the model |
| Consumer contract | Parse the spec, speak the protocol | Call a normalized capability API (`ScalarCmd`, `SensorReadCmd`) |
| User overrides | `variants` | Base config + a user config file (UDCF) that merges over it |

Buttplug's model is right **for Buttplug**: it ships one client that must drive
every device through a uniform API, so it hides the bytes behind handlers and
exposes capabilities. This registry's model is right **for a repair archive**: the
knowledge has to survive without the code, so the bytes stay in the file. We should
not adopt the handler-first model — that would defeat the purpose.

But three of Buttplug's ideas are additive and worth taking:

1. **A normalized capability vocabulary.** Buttplug describes what a device can
   *do* — actuator types (`Vibrate`, `Rotate`, `Oscillate`, `Constrict`,
   `Position`, `Led`, `Temperature`) and sensor types (`Battery`, `RSSI`,
   `Button`, `Pressure`) — independently of the bytes. Our `entities` and
   `features` blocks gesture at this but are thin. A small controlled vocabulary
   would let a consumer answer "show me every dimmable light" or "every battery
   sensor" without per-device code. See [P7](#p7).
2. **Actuator resolution as data.** Buttplug's `StepCount`/`StepRange` records a
   control's real granularity. We bury min/max in per-command `parameters` but
   never say "this is the device's actual resolution." Folds into [P7](#p7).
3. **Named endpoint roles.** Buttplug names characteristics by role (`tx`, `rx`,
   `whitelist`, `firmware`). We name them by human string, which is friendlier but
   not machine-routable. A minor optional `role` enum is noted in [P7](#p7).

Everything else Buttplug does — handler dispatch, a merged user-config layer — is
either already covered (`protocol_handler`) or a consumer concern, not a spec
concern.

---

## Recommended now

Low risk, high value, purely additive — existing specs keep validating unchanged.

### P1 — A reproducible checksum descriptor { #p1 }

**Problem.** A checksum in a spec is only useful if an implementer can reproduce
it, and today many can't be reproduced from the file. `framing.checksum` is
`enum: [crc32, xor, sum]` — it cannot say *which bytes* are covered, and "crc32"
does not pin the polynomial or reflection. `bus.checksum` is better (it has a
`scope` string) but still can't parameterize a CRC. So specs describe checksums in
prose, and "CRC-16" is ambiguous across ~20 real functions.

**Evidence.** 18 device specs carry checksum/CRC logic. The NIIMBOT D110 documents
both an XOR checksum *and* a CRC32 firmware-upgrade variant entirely in prose. The
Bafang BBS02 sums different byte ranges on read vs write — the asymmetry that most
often causes a first implementation's writes to be silently rejected.

**Proposal.** A shared `$defs/checksum` used by both `framing` and `bus`:

```yaml
checksum:
  algorithm: "crc16"          # xor | sum8 | sum8-mod256 | crc8 | crc16 | crc32 | custom
  catalogue: "CRC-16/MODBUS"  # optional: a CRC RevEng catalogue name
  params:                     # optional: full parameters when not using a catalogue name
    width: 16
    poly: 0x8005
    init: 0xFFFF
    refin: true
    refout: true
    xorout: 0x0000
  scope: "bytes 2..n-3, i.e. command through last data byte; excludes header and trailer"
  check: "0x4B37"             # known-good CRC of the ASCII string \"123456789\", per the catalogue
```

Cite the [CRC RevEng catalogue](https://reveng.sourceforge.io/crc-catalogue/all.htm)
for names and the `check` convention. The `check` value is the important part: it
turns "my CRC is wrong and I don't know why" into a one-line unit test.

**Compatibility.** Additive. The existing `enum`-only form stays valid; `params`,
`catalogue`, `scope` and `check` are all optional. No consumer breaks.

**Effort.** Small schema change; back-fill is opportunistic, spec by spec.

### P2 — Mark SIG-standard services and characteristics { #p2 }

**Problem.** Standard GATT characteristics are re-documented, by hand, in every
spec that uses them — and their format is often just omitted, left to the reader's
knowledge of the [GATT Specification Supplement](https://www.bluetooth.com/specifications/gss/).
A consumer cannot tell "this is standard Battery Level `0x2A19`, decode as
uint8 percent" from a vendor characteristic that happens to look similar.

**Evidence.** 9 specs reference `0x180A`/`0x180F` and the standard characteristics
under them. In `xiaomi-lywsd03mmc.yaml` the Battery Level (`0x2A19`) and the Device
Information strings (`0x2A29`/`0x2A24`/`0x2A26`) are genuinely exposed GATT
characteristics listed with `properties: [read]` and **no `format`** — their decode
is left to the reader's knowledge of the GSS rather than stated. (The same spec's
`0x2A6E` entry is deliberately *not* cited here: it is a passive-beacon placeholder
whose decode already lives in `payload_formats`, which is [P6](#p6)'s territory, not
P2's — marking it `standard: true` would wrongly point a consumer at a GATT read
that does not exist.)

**Proposal.** An optional boolean on services and characteristics:

```yaml
- uuid: "00002a19-0000-1000-8000-00805f9b34fb"
  name: "Battery Level"
  properties: ["read"]
  standard: true    # SIG-defined; decode per the GSS, resolve name from Assigned Numbers
```

`standard: true` means: this is not ours, its authoritative decode is the GSS, and
a consumer may resolve its name and format from the
[Bluetooth numbers database](https://github.com/NordicSemiconductor/bluetooth-numbers-database)
rather than trusting local prose. See
[Standards Worth Citing](../protocols/standards-and-references.md) for the list of
standards involved and the Base-UUID shorthand rule.

**Compatibility.** Additive boolean, default false. Existing specs unchanged.

**Effort.** Small. Pairs naturally with a CI check that a `standard: true`
characteristic's UUID actually is SIG-assigned.

### P3 — Endianness on BLE `format` fields { #p3 }

**Status: landed.** `endianness` is on BLE `format` items in `schema.json`, with
the same enum and the same `little` default as the `bus` field it mirrors, and
`test_device_specs.py` pins the two declarations to each other so they cannot
drift. The mobile decoder honours it. The six fields that were already stating
the key — five in `xiaomi-miflora`, one in `pax-vape` — now mean something;
before, they were writing into a key nothing defined, tolerated by a permissive
schema and dropped by every parser. Kept here as the worked reasoning; the rest
of this section is written as it was proposed.

**Problem.** A multi-byte value read from a BLE characteristic has no byte order in
the schema. `bus.fields` carry `endianness` (default `little`); the BLE `format`
items — `offset`/`length`/`name`/`type` — do not. A `uint16` temperature is
therefore ambiguous, and specs resolve it in prose.

**Evidence.** The `bus` block already has the field (`schema.json` field
`endianness`, default `little`). The BLE `format` array does not. The Xiaomi PVVX
payload's `int16` little-endian temperature is documented only in a
`parse_rules` string, not in the `format` block that ought to carry it.

**Proposal.** Add the same optional field to BLE `format` items:

```yaml
format:
  - offset: 0
    length: 2
    name: "temperature"
    type: "int16"
    endianness: "little"   # little (default) | big
    scale: 0.01
```

Default `little` matches BLE convention and every current implicit assumption, so
nothing changes for existing specs.

**Compatibility.** Additive with a safe default. Aligns BLE with `bus`.

**Effort.** Trivial. This is the cleanest correctness fix in the list.

---

## High value, needs consumer coordination

Additive to the schema, but only useful once the Rust/HA consumers honour them, so
land them in step with the consumer.

### P4 — Bit-field decoding in `format` { #p4 }

**Problem.** Status and flag bytes pack several values into one byte. The schema
decodes at byte granularity only (the `bus` block has a `bitfield` *type* but no
bit offset or mask; BLE `format` has neither), so bit-packing is explained in prose.

**Evidence.** The ATC beacon's battery byte is "bits 6–0 = battery %, bit 7 =
trigger flag" — currently a `parse_rules` string. This pattern recurs in status
notifications across the LED and sensor specs.

**Proposal.** Optional bit addressing on a `format` field:

```yaml
- offset: 2
  name: "battery_percent"
  type: "uint8"
  bit_offset: 0
  bit_length: 7
- offset: 2
  name: "trigger_flag"
  type: "bool"
  bit_offset: 7
  bit_length: 1
```

**Compatibility.** Additive; absent bits mean "whole field", as today. Rust decoder
needs the masking logic before specs rely on it.

**Effort.** Small schema, moderate consumer work.

### P5 — Symmetric command responses on BLE { #p5 }

**Problem.** A BLE `command` documents the bytes written but not the reply, even
though request/response over a notify characteristic is everywhere — printers,
locks, challenge-response auth. The OBD side already models this: `obd.requests`
carry `expected_response`. BLE commands have no equivalent, so correlation is prose.

**Evidence.** `obd.requests[].expected_response` exists in the schema; BLE
`commands` have no response field. The Ember Mug's first-writer claim, the NIIMBOT
print-status replies and every challenge-response device document their responses
only in `notes`.

**Proposal.** Optional response fields on a BLE command, mirroring OBD:

```yaml
commands:
  get_status:
    description: "Request printer status"
    value: [0x1A, 0x01]
    response_characteristic: "0000ff02-0000-1000-8000-00805f9b34fb"
    expected_response: "5A ?? ?? AA"   # ?? = variable byte, same convention as obd/bus
```

**Compatibility.** Additive. Brings BLE to parity with a pattern the schema already
blesses elsewhere.

**Effort.** Small schema; consumers that only write are unaffected.

### P6 — First-class advertisement / beacon payloads { #p6 }

**Problem.** Passive sensors broadcast their state in the advertisement and are
read without ever connecting. The schema can *match* on advertisement data
(`discovery.manufacturer_data`) but has nowhere to say "the temperature comes from
these bytes of the service data," so these devices are modelled with a workaround.

**Evidence.** `xiaomi-lywsd03mmc.yaml` lists a `format`-less characteristic under
Environmental Sensing with a `notes` disclaimer: "Not used as a GATT service — data
is obtained from passive BLE scanning of the advertisement payload." Govee and
SwitchBot specs have the same shape.

**Proposal.** An optional top-level `advertisement` block, and an entity binding
that points at it:

```yaml
advertisement:
  service_data:
    uuid: "0000fcd2-0000-1000-8000-00805f9b34fb"   # BTHome v2's own SIG-allocated service-data UUID
    format: "bthome-v2"        # a named open format (see standards page) …
  # … or a custom layout under the device's own service-data UUID: the ATC/PVVX
  #   formats live on 0x181A, not 0xFCD2, and would give an explicit field layout
  #   here reusing the format/payload_formats machinery
entities:
  - platform: "sensor"
    name: "Temperature"
    state_source: "advertisement"   # vs a GATT characteristic
```

Naming [BTHome v2](https://bthome.io/) as a format lets the pvvx-firmware devices
skip re-documenting a payload that is already an open standard.

**Compatibility.** Additive. Removes a standing workaround rather than adding a new
convention on top of it.

**Effort.** Moderate; worth it because passive sensors are a large, growing slice of
the registry.

---

### P10 — Multi-byte command parameters that encode one number { #p10 }

**Problem.** `$defs/number_semantics` made a numeric value's meaning
machine-readable, and deliberately kept the transform linear so a command
parameter can be **encoded** by inverting it. That works when one parameter
carries the whole number. It does not when a device splits the number across
several byte-wide parameters, which is the normal shape for any 16-bit value
sent over a byte-oriented template. Nothing in the schema says those parameters
belong together, or which end is which, so a consumer that wants to set the
value has to be told in prose — and prose is exactly what the number-semantics
work removed everywhere else.

**Evidence.** `ember-mug.yaml`'s `set_target_temp` is the worked case:

```yaml
template: ["{temp_low}", "{temp_high}"]
parameters:
  temp_low:
    type: uint8
    description: >
      Low byte of the little-endian uint16 target in centi-°C. The pair
      encodes round(target_c * 100): 56.5 C -> 5650 -> temp_low 0x12,
      temp_high 0x16.
```

Everything a client needs is in that sentence and none of it is in a field.
The matching `format` block one level up *is* fully machine-readable
(`target_temp_raw`, `uint16`, `scale: 0.01`), so the mug's target temperature
can be read generically and written only by hand — the asymmetry
number-semantics set out to fix. The same shape recurs wherever a template is a
byte list: `ibbq-meat-thermo.yaml`'s `set_target_temp` splits two probe
thresholds across four bytes (`low_lo`/`low_hi`/`high_lo`/`high_hi`), and
`idotmatrix.yaml`'s `set_password` splits one value across three.

A consumer is already blocked on this, which is what distinguishes it from the
other proposals in this section: the Flutter+Rust app resolves a `number`
entity's setpoint to a sendable command only when exactly one parameter is
un-defaulted, and deliberately refuses the Ember case rather than guess a byte
order. Guessing wrong writes 0x1216 instead of 0x1612 — 46.6 °C asked for,
56.5 °C delivered, on a heater.

**Proposal.** An optional `encodes` block on a command, declaring that some of
its parameters jointly carry one number:

```yaml
set_target_temp:
  description: "Set target temperature"
  template: ["{temp_low}", "{temp_high}"]
  parameters:
    temp_low:  { type: uint8 }
    temp_high: { type: uint8 }
  encodes:
    # Significance order, least-significant FIRST. The list is the byte
    # order, so there is no separate `byte_order` key to disagree with it.
    parameters: ["temp_low", "temp_high"]
    type: "uint16"     # width and signedness of the assembled value
    unit: "C"          # ...plus the rest of $defs/number_semantics
    scale: 0.01
```

Encoding is then fully determined, in the same terms the schema already uses:

```
raw   = round((value - value_offset) / scale)      # number_semantics, inverted
byte0 = raw        & 0xFF   -> parameters[0]
byte1 = (raw >> 8) & 0xFF   -> parameters[1]
...
```

Listing the parameters in significance order rather than adding a `byte_order`
enum is the deliberate choice: a list and an enum can contradict each other,
and the contradiction is silent and catastrophic. One ordered list cannot.
`encodes.parameters` is also independent of `template` order, so a device that
interleaves the bytes with other protocol filler still describes itself
correctly.

Reusing `$defs/number_semantics` on the block means `unit`, `scale`,
`value_offset` and `values` all mean exactly what they already mean elsewhere;
`encodes` adds only `parameters` and `type`.

**Compatibility.** Additive and inert. No existing spec has an `encodes` block,
so nothing changes until one is written; a consumer that ignores it behaves
exactly as today. Validation should require that every name in
`encodes.parameters` is a declared parameter of the same command, that each is
an integer type, and that their widths sum to the width of `encodes.type` —
all checkable at load time, which turns a whole class of silent
wrong-temperature bugs into a spec error.

**Effort.** Small schema, small validator. The consumer work is real but
bounded: assemble on encode, and the existing `format` block already handles
the decode direction. Backfilling `ember-mug`, `ibbq-meat-thermo` and
`idotmatrix` would move three known devices from prose to reproducible.
### P11 — Plural `local_name_prefix` { #p11 }

**Status: landed.** `local_name_prefixes` is in `schema.json`, and the mobile
matcher reads the singular and plural keys together, so a match on any one of
them carries the weight a `local_name_prefix` match always did. Kept here as the
worked reasoning; the rest of this section is written as it was proposed.

**Problem.** `device.identification.local_name_prefix` holds exactly one string,
but a device family that ships under several rebadged names has several. There is
nowhere to put the rest, so the ones that do not fit are unmatched at scan time —
the cheapest, earliest identification signal, missing for exactly the families
most likely to be mislabelled.

**Evidence.** `inkbird-bbq-thermometer` advertises under eight names (`BG-BT1X`,
`IBBQ-4BW`, `BBQ-4BW`, `IBT-4XS`, `IBT-2X`, `IBT-24S`, `IBT-26S`, `Inkbird@`) with
no shared prefix. Its spec carries `local_name_prefixes:` — plural, and not a
schema key, so `identification` sweeps it into extensions and no consumer reads
it. All eight names are in the `discovery` block, which consumers do not execute,
so today the family has no working name signal at all. `admore` hits the same
wall from the other side, declaring `local_name_dfu` and `local_name_armband*`
as separate extension keys.

**Proposal.** Accept either form on the same key, the way `mac_prefixes` accepts
either a bare string or a map:

```yaml
identification:
  local_name_prefix: "Ember"              # unchanged, still valid
  # or
  local_name_prefixes: ["IBT-", "IBBQ-", "BG-BT1X", "Inkbird@"]
```

A match on any one of them means what a match on the single prefix means today,
so the confidence rules do not change.

**Compatibility.** Additive. Consumers reading only `local_name_prefix` keep
working; specs using the plural form gain matching they do not have now.

**Effort.** Small schema, small consumer work — the matcher already loops over
`service_uuids` and `mac_prefixes` the same way.

### P12 — Executable HTTP commands, paired credentials, and hub children { #p12 }

**Status: landed.** `method` on commands, the `credential:`/`instance:` schemes
on parameter `source`, and `instances:` on entities are in `schema.json`; the
hue-bridge spec exercises all three and the mobile consumer executes them. Kept
here as the worked reasoning; the rest of this section is written as it was
proposed.

**Problem.** The `commands:` block made a role map executable for exactly one
transport. `transport: http` was in the enum from the start, but an http
command carried only `path` — no method — and a REST-shaped API answers GET and
PUT on the same path with different operations, so the file could not say which
one a command performs. Two further gaps sat behind that one. First, real HTTP
paths carry values the spec cannot know: a per-client credential issued at
pairing time (every Hue call after the link-button handshake embeds the issued
`username` in the path), and the identifier of whichever child a hub command
addresses. `source` could only say `state:<command>.<field>`, which covers
neither. Second, an entity binds to exactly one reading, but a hub is one
network presence fronting a population — which lights sit behind a Hue bridge
is the owner's business, not the spec's, so no fixed list of entities can
describe one.

**Evidence.** `hue-bridge.yaml`: discovery, identification, pairing and
endpoints live-verified against hardware, and every byte of it declarative.
The mobile app finds the bridge, badges it, and has nothing to offer — the
protocol is documented and none of it is executable, which is precisely the
gap `commands:` closed for SOAP.

**Proposal.** Three additive pieces of vocabulary:

```yaml
commands:
  light_turn_on:
    transport: "http"
    method: "PUT"                              # new: the missing half of the address
    path: "/api/{username}/lights/{id}/state"  # placeholders now substitute from parameters
    arguments: { on: true }
    parameters:
      username: { type: "string", source: "credential:username" }  # new scheme
      id:       { type: "string", source: "instance:id" }          # new scheme

entities:
  - platform: "light"
    name: "Hue Light"
    instances: { keyed_by: "id", label_path: "name" }   # new: entity as per-child template
    state_command: "Lights"
    state_mapping: { is_on: "state.on", brightness: "state.bri" }
```

`method` pairs with `path` the way `service` pairs with `action`.
`credential:<name>` names a per-device secret the client stored when it paired;
`instance:<key>` names the current child's id. Both inherit `source`'s
contract: no default, and a renderer with no value must fail the send visibly —
an unpaired client erroring at `credential:username` is the correct behaviour.
`instances:` declares the entity a template: the `state_command` reply is a
JSON object keyed by child id, enumeration and state in one request, with
`state_mapping` paths resolving inside each child's object.

**Compatibility.** Additive. SOAP specs are untouched; existing consumers that
predate the keys see an http command with no method (declarative, as ever) and
an instanced entity whose paths resolve nothing from the response root — the
correct degraded behaviour for a hub they do not understand.

**Effort.** Small schema; the consumer work is the real half (an HTTP renderer
beside the SOAP one, credential storage, instance enumeration) and landed with
it. Deliberately deferred: a `headers:` vocabulary. Hue's CLIP v2 API moves the
credential from the path into an `hue-application-key` header, and other
devices will want `Authorization:`; that is the next piece of this vocabulary
when a spec needs v2, and it should follow the `arguments` substitution model
rather than invent its own.

### P13 — Power as a stateful control, and the toggle problem { #p13 }

**Problem.** A consumer cannot turn a TV off from these specs without guessing.
All nine `category: tv` specs express power as a stateless `button`, and the
schema *enforces* that shape: the button contract in
`entities.items.allOf[0]` requires exactly the `press` role and forbids every
state binding. That is right for a remote key — a keypress is honestly
stateless — but it leaves no role meaning "make this device off", so a
consumer wanting one has to match on command names.

Command names will not carry that weight. The same idea is spelled
`press_power_off` (Roku, Sony, Vizio, Philips), `power_off` (LG),
`press_power` (Samsung, Panasonic, Hisense, Android TV), `press_standby`
(Philips) and `press_power_toggle` (Vizio) — and the last three are
**toggles**, so a consumer that globs `*power*` will turn a sleeping TV on.
Worse, the toggle/discrete distinction exists today only in prose:
`panasonic-viera.yaml` marks it in a YAML comment
(`# -- Power. NRC_POWER is a TOGGLE, not discrete on/off.`) and
`vizio-smartcast.yaml` in an entity `notes:` string. Neither is machine-readable,
so nothing in the file distinguishes the two operations.

**Evidence.** `lg-webos.yaml` already proves the fix is expressible today: its
Mute control is a `switch` entity binding `turn_on`/`turn_off` with a
`state_topic`, on a Wi-Fi device, with no schema change. Power is the same
shape and simply was never written that way. Meanwhile the mobile consumer's
bulk operations resolve strictly by entity action role — deliberately, so that
destructive verbs are unreachable from a fan-out by construction rather than by
blacklist — which means TVs are currently excluded from bulk control entirely,
not by policy but for want of a role to bind.

**Proposal.** Give each TV spec a `platform: "switch"`, `name: "Power"` entity
**alongside** its existing remote buttons. The buttons stay: a remote's power
key is still a keypress, and removing it would break every remote UI.

```yaml
  - platform: "switch"
    name: "Power"
    icon: "mdi:power"
    commands:
      turn_on: "press_power_on"      # only where network power-on really works
      turn_off: "press_power_off"    # only where a discrete off exists
      toggle: "press_power"          # new role, for the toggle-only sets
    state_endpoint: "/sony/system"   # where the device reports power at all
    state_command: "getPowerStatus"
```

`toggle` is the one new role, and it is what makes the distinction
machine-readable: a command bound to `toggle` is declared to flip state, so a
consumer knows it must establish the current state before sending. Each spec
binds only the roles its hardware honestly supports:

| Spec | `turn_off` | `turn_on` | `toggle` | Power state readable |
|---|---|---|---|---|
| `roku-ecp` | `press_power_off` | `press_power_on` (warm standby only) | — | no |
| `sony-bravia` | `press_power_off` | `press_power_on` | `press_power` | yes — `Power Status` |
| `vizio-smartcast` | `press_power_off` | `press_power_on` | `press_power_toggle` | yes — `Power Mode` |
| `philips-jointspace` | `press_power_off` | `press_power_on` | `press_standby` | yes — `Power State`, v6 only |
| `lg-webos` | `power_off` | — | — | no |
| `samsung-tizen-tv` | `press_power` † | — | — | no |
| `hisense-vidaa` | — | — | `press_power` | yes — `TV State` |
| `android-tv-remote` | — | — | `press_power` | yes — `Power State` |
| `panasonic-viera` | *no switch entity — see below* | | | no |

† Samsung's `KEY_POWER` is nominally a toggle, but the spec records that the
network stack is down in standby, so **no network client can reach an off set**.
The toggle is therefore discrete-off in practice, and binding it as `turn_off`
with that reasoning in `notes:` is the honest description rather than a
convenient one. This is a *verified protocol signal*, not an assumption — which
is exactly what separates it from Panasonic.

**Panasonic is deliberately excluded.** It is the one set that is toggle-only
*and* reachable while off: `panasonic-viera.yaml` states that power-on over the
network works from network standby ("Powered On By Apps" / "Networked Standby"),
with Wake-on-LAN needed only when that is disabled or on several older plasma
models. So a Viera in standby **will** receive `NRC_POWER-ONOFF` and turn on. It
also reports no power state, so a consumer can never establish that it is safe
to send. Giving it a Power switch would ship a control that is either inoperable
under the rule below or actively harmful in a bulk off; it keeps its remote
button and nothing else until it gains a readable state or a discrete off.

`turn_on` is deliberately unbound for LG, Samsung and Hisense: those specs state
that no network command can wake a standby set, because the network stack is
down. Note this is "cannot wake over the network", which is a different claim
from Panasonic's "has no *discrete* on command" — Panasonic can wake, it just
cannot be told which direction to go. Wake-on-LAN, the documented route for the
first group, has no declarative representation in the schema — **out of scope
here**, and worth its own proposal rather than a field smuggled in beside
`commands`.

**Bind Philips' discrete off, which is documented but unreachable.**
`philips-jointspace.yaml` catalogues "Set Power State" under `http_endpoints`
and never exposes it as a `command`, so no consumer can invoke it:

```yaml
  set_power_standby:
    transport: "http"
    method: "POST"
    path: "/{api_version}/powerstate"
    arguments: { powerstate: "Standby" }
```

Genuinely cheap — a flat scalar body, the same shape Vizio's and Philips' own
existing HTTP commands already render through `arguments` — and it gives Philips
an off that does not depend on a key code being accepted.

**Sony's equivalent is *not* cheap, and this proposal should not pretend it is.**
`sony-bravia.yaml` documents `setPowerStatus`, but every Sony REST call is a
JSON-RPC envelope — `{"method": …, "params": [ … ], "id": N, "version": "1.x"}`,
where the spec states `params` is **always** an array. `arguments` cannot
express that: the schema constrains its values to
`["string", "number", "boolean"]`, so an array containing an object has nowhere
to live. `body:` does not rescue it either — the schema defines `body` as the
counterpart of `arguments` for SOAP and `path` for HTTP, i.e. *for a
JSON-over-socket protocol* (`tcp-json`), not for HTTP.

So binding Sony's REST off depends on a prior extension: literal or nested
body values for `transport: http`. That is a vocabulary gap of its own and
belongs in its own proposal — the same call P12 made when it deferred a
`headers:` vocabulary rather than widening its scope. **Sony loses nothing in
the meantime**: its `press_power_off` IRCC command already works over SOAP, and
that is what the table above binds.

**A note the consumer contract needs.** On a toggle-only set the Power switch
resolves *only* `toggle`, so a consumer predating the role sees a switch with no
resolvable actions. `docs/api/spec-format.md` should state that a control which
resolves no roles must be hidden, not rendered dead — otherwise this proposal
ships a non-functional toggle to older clients.

**A failed read is not the same as "off", and the contract must not conflate
them.** A state read can fail from packet loss, a stale address, an auth
failure, or an endpoint that was never there — `philips-jointspace.yaml`
explicitly documents 403/404 as *endpoint-not-present*, which says nothing about
power at all. Two separate rules, then:

- **Infer standby only from a verified, protocol-specific signal.** Some specs
  supply one: a Sony in standby answers control calls with the error string
  `"not power-on"`, which its spec says "a client should read as 'off', not
  'broken'"; Vizio documents its state endpoint as unreachable rather than wrong
  while the set is asleep. Where such a signal is documented, a consumer may act
  on it.
- **Otherwise the state is *unknown*, and must be surfaced as unavailable —
  never as off.** Unknown still means "do not send the toggle", because
  declining to act is the safe default for a bulk off. But that is a rule about
  the *toggle decision only*: it must not suppress ordinary retries or hide a
  recoverable network or configuration fault behind a confident-looking "off".

**Compatibility.** Additive. The button contract is untouched, every existing
`button` entity keeps working, and a consumer that does not know `toggle`
degrades to "this TV offers no bulk power control" — which is exactly today's
behaviour, so nothing regresses. The switch is also shaped to map cleanly onto a
Home Assistant `media_player`/`switch` with `assumed_state: true` where no state
is readable, keeping that consumer's route open.

**Effort.** Small per spec — one entity each, plus one new command for Philips.
Sony's REST off is explicitly *not* in scope, for want of an HTTP nested-body
vocabulary. The real half is consumer work: a `toggle` role in the mobile app's
role tables, and the read-state-then-toggle rule that makes it safe. As with
P12, the schema change is not the interesting part.

## Strategic / optional

### P7 — A normalized capability vocabulary { #p7 }

**Problem.** There is no machine-readable answer to "what can this device do?" that
is independent of its bytes. `entities` maps to Home Assistant platforms and
`features` enumerates three upload types, but a consumer that wants "every device
with a dimmable output" must special-case each spec.

**Proposal (the Buttplug idea, kept as an optional layer).** A small controlled
vocabulary describing capabilities, sitting *on top of* the byte-level spec, never
replacing it:

```yaml
capabilities:
  - type: "actuator"
    kind: "dimmer"            # dimmer | switch | color | rotate | oscillate | vibrate | position | temperature
    resolution: { min: 0, max: 100, steps: 100 }   # Buttplug's StepRange, as data
    maps_to: "set_brightness"                        # the command that drives it
  - type: "sensor"
    kind: "battery"           # battery | temperature | humidity | pressure | rssi | button | weight
    maps_to: "0000181a-...-battery_percent"
```

This is what would let a generic client or a cross-device search work without
per-device code — Buttplug's central win — while keeping our byte-level ground
truth intact. It also subsumes P3-era range metadata and could carry an optional
endpoint `role` for the machine-routing Buttplug gets from `tx`/`rx`.

**Partially landed since this was written.** The schema now has
`$defs/number_semantics` — `unit`, an invertible linear `scale`/`value_offset`
transform, `values` code tables, and `unit_source`/`unit_reference`/
`unit_values` for devices whose wire unit follows a device setting (C-vs-F on
the Inkbird iBBQ) — shared by BLE command `parameters`, BLE `format` fields,
`bus` fields and `payload_formats` fields; `number` entities carry
`min`/`max`/`step` (Buttplug's StepRange, as data). That covers this
proposal's resolution/range half. The capability *vocabulary* — `actuator` /
`sensor` kinds independent of the bytes — remains open and still deserves its
design pass.

**Compatibility.** Fully additive and ignorable. The risk is scope, not breakage:
a controlled vocabulary has to be curated or it rots into free text. Start with the
handful of kinds the registry actually has and grow it deliberately.

**Effort.** Larger, and worth a design pass of its own before any schema change.

---

## Governance

### P8 — Resolve the `advanced` / `command_class` name collision { #p8 }

**Problem.** "advanced" already means two different things, and
[CLEANROOM_RULES](../CLEANROOM_RULES.md#three-separate-axes-do-not-conflate-them)
flags it as an open decision: on BLE commands `advanced` is a *consequence* signal,
while `obd.requests[].command_class: basic | advanced` is an *adapter-capability*
signal.

**Proposal.** Rename the OBD field `command_class` → `adapter_class` (it really is
about the adapter), keeping `command_class` as a deprecated alias for one minor
version so nothing breaks immediately. Then `advanced` means "consequence"
everywhere, with no gloss required.

**Compatibility.** Needs an alias window; the validator and index generator accept
both during it.

**Effort.** Small, but touches the OBD specs and the consumer — do it deliberately.

### P9 — Version the schema with SemVer { #p9 }

**Problem.** Schema changes are tracked only in prose (the CHANGELOG) and an
implicit `schema_version` in the generated index. `schema.json`'s `$id` is not
versioned, and there is no stated compatibility policy — so a consumer cannot pin a
version or reason about whether an update is safe. Buttplug versions its config
format explicitly (v3 → v4) for exactly this reason.

**Proposal.** Adopt [SemVer 2.0.0](https://semver.org/) for the schema: embed the
version in `$id` (`…/device-spec.schema.v1.json`) and optionally a top-level
`spec_version`, and write the policy down — *additive field = minor; a new
required field, a removed field, or a narrowed enum = major*. Keep the JSON Schema
2020-12 dialect.

**Compatibility.** Process change, not a breaking one. Makes every future change on
this page classifiable.

**Effort.** Small, and it is the change that makes the rest safe to make.

---

## Summary

| # | Proposal | Value | Risk | Verdict |
|---|----------|-------|------|---------|
| [P1](#p1) | Reproducible checksum descriptor | High | Low | Recommended now |
| [P2](#p2) | Mark SIG-standard GATT entries | High | Low | Recommended now |
| [P3](#p3) | Endianness on BLE `format` | Medium | Very low | **Landed** |
| [P4](#p4) | Bit-field decoding | Medium | Low | With consumer |
| [P5](#p5) | Symmetric BLE command responses | High | Low | With consumer |
| [P6](#p6) | First-class advertisement payloads | High | Medium | With consumer |
| [P10](#p10) | Multi-byte command parameters | High | Low | With consumer — one is blocked today |
| [P11](#p11) | Plural `local_name_prefix` | Medium | Very low | **Landed** |
| [P12](#p12) | Executable HTTP commands + hub children | High | Low | **Landed** |
| [P13](#p13) | Power as a stateful control + `toggle` role | High | Low | With consumer |
| [P7](#p7) | Normalized capability vocabulary | High | Medium | Needs a design pass |
| [P8](#p8) | Rename `command_class` → `adapter_class` | Low | Low | Governance |
| [P9](#p9) | SemVer the schema | Medium | Low | Governance — enables the rest |

The through-line: **P1, P2 and P6 all push in the same direction** — put the
standard-shaped parts of a protocol (checksums, SIG characteristics, open beacon
formats) in terms of published standards instead of local prose, so more of every
spec is reproducible from the file. That is the same lever `test_wemo_spec.py`
already pulls, applied to the parts of a spec that are currently prose-only.

**P10 is the same lever pointed at the write direction.** Number semantics made
reading a value reproducible from the file; a device that splits that value
across byte parameters is still readable and no longer writable without prose,
which is the one place the asymmetry now shows.
