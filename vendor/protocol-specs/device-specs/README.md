# Device Specs

Machine-readable specifications for IoT devices — BLE, WiFi and hub-attached.
Both the OpenGreenIoT mobile app and the Home Assistant integration consume
these specs, and they are published as JSON by the
[Data API](../docs/api/index.md).

Reading one: [`docs/api/spec-format.md`](../docs/api/spec-format.md).

## Format

Device specs are YAML files describing how to find a device, how to get it onto
the network, and how to control it — BLE GATT services and characteristics, or
HTTP endpoints and MQTT topics for WiFi devices.

```yaml
# device-specs/examples/example-bulb.yaml
device:
  name: "Example Smart Bulb"
  manufacturer: "Acme Corp"
  manufacturer_status: "abandoned"
  protocol: "ble"
  category: "light"
  identification:
    # How to identify this device during BLE scanning
    local_name_prefix: "ACME_"
    service_uuids:
      - "0000fff0-0000-1000-8000-00805f9b34fb"

services:
  - uuid: "0000fff0-0000-1000-8000-00805f9b34fb"
    name: "Control Service"
    characteristics:
      - uuid: "0000fff1-0000-1000-8000-00805f9b34fb"
        name: "Command"
        properties: ["write"]
        commands:
          power_on:
            description: "Turn the bulb on"
            value: [0x01, 0x01]
          power_off:
            description: "Turn the bulb off"
            value: [0x01, 0x00]
          set_brightness:
            description: "Set brightness level"
            template: [0x02, "{brightness}"]
            parameters:
              brightness:
                type: "uint8"
                min: 0
                max: 100
                unit: "%"   # what the number means — see "Number semantics" below

      - uuid: "0000fff2-0000-1000-8000-00805f9b34fb"
        name: "Status"
        properties: ["read", "notify"]
        format:
          - offset: 0
            length: 1
            name: "power_state"
            type: "bool"
          - offset: 1
            length: 1
            name: "brightness"
            type: "uint8"

entities:
  # How this device maps to Home Assistant entities
  - platform: "light"
    name: "Bulb"
    features: ["brightness"]
    state_characteristic: "0000fff2-0000-1000-8000-00805f9b34fb"
    state_mapping:
      is_on: "power_state"
      brightness: "brightness"
    commands:
      turn_on: "power_on"
      turn_off: "power_off"
      set_brightness: "set_brightness"
```

## Required vs Optional Fields

### `device` (required)

| Field | Required | Description |
|-------|----------|-------------|
| `name` | Yes | Human-readable device name |
| `manufacturer` | Yes | Original manufacturer name |
| `manufacturer_status` | Yes | One of: `abandoned`, `shutdown`, `unsupported`, `active` |
| `protocol` | Yes | Primary protocol: `ble`, `wifi`, `zigbee`, `zwave`, `obd2` |
| `category` | Yes | Broad device class from a closed vocabulary — see [The `category` vocabulary](#the-category-vocabulary) |
| `type` | No | Free-text device class, e.g. `smart-scale`. `reference-*` marks a published-protocol reference |
| `notes` | No | Free-text notes about the device |
| `testing` | Yes* | Spec-level hardware-testing status — see [`testing`](#testing) below. Required by the test suite on every non-reference device spec |
| `identification` | No | How to auto-discover during scanning |
| `discovery` | No | Machine-readable discovery methods and identity keys |
| `setup` | No | One-time provisioning, factory reset and rebinding |

### `testing`

Whether **this project** has exercised the spec against real hardware, stated
once for the spec as a whole. The finer-grained machinery (`verification` per
fact, `setup.methods[].verified` per onboarding flow, `setup.confidence` per
section) never rolls up to the verdict a consumer wants first: has anyone
driven a device with this document?

| Field | Required | Description |
|-------|----------|-------------|
| `status` | Yes | `untested` (nobody here has driven hardware from this spec) or `verified` (at least one documented flow was executed against real hardware by this project). Third-party success stories support per-fact `verification: reported`, not this flag |
| `detail` | No | Refines `status`. With `untested`: `capture-verified` — key facts checked against over-the-air captures of real hardware traffic in the research store. With `verified`: `minimally-verified` (one or a few flows driven) or `mostly-verified` (the majority of the surface driven). A bare status is its weakest reading |
| `notes` | No (required by tests for anything above bare `untested`) | The evidence: which captures, which hardware unit, which flows, dated |

### The `category` vocabulary

`category` and `type` both name the device class. `type` is free text for a
human — `smart-scale`, `ebike-controller` — and you should make it as precise
as you like. `category` is a closed vocabulary for a program, it is required,
and a value outside the list below is a validation error:

| | | | | |
|---|---|---|---|---|
| `appliance` | `camera` | `climate` | `display` | `energy` |
| `fitness` | `health` | `hub` | `irrigation` | `light` |
| `lock` | `motor` | `printer` | `reference` | `robot` |
| `scale` | `sensor` | `speaker` | `switch` | `tool` |
| `tracker` | `tv` | `vehicle` | `wearable` | `other` |

The closed list is the point. Downstream consumers branch on this field — the
mobile app picks the icon it draws beside each scan result from it — so the
three specs that would otherwise say `smart-scale`, `kitchen-scale` and
`body-composition-scale` have to agree on one word. A typo'd or invented
category is indistinguishable at the consumer from a device nobody ever
documented: both come out as an anonymous radio icon, which is exactly what
the field exists to prevent.

Choose the word someone would use from across the room, not the most precise
one available:

- an LED strip controller is a `light`; an LED matrix panel is a `display`
- an e-bike mid-drive is a `motor`; a car's diagnostic connector is `vehicle`
- a BBQ probe is a `sensor`, whatever the kitchen has to do with it
- a bridge or gateway you talk to *instead of* the device is a `hub`

Two cases are not judgement calls. Reference specs — the ones whose `type`
starts with `reference-` — take `category: reference`, and the schema rejects a
file where the two fields disagree, in either direction: a device may no more
claim `category: reference` than a reference may claim `light`. And `other` is for a device the vocabulary
genuinely cannot describe: treat reaching for it as a prompt to propose a new
value in `schema.json`, not as a place to leave the device.

### `identification` (optional)

| Field | Required | Description |
|-------|----------|-------------|
| `local_name_prefix` | No | BLE advertisement local name prefix. Omit it rather than setting `""` — an empty prefix matches every device. |
| `service_uuids` | No | BLE service UUIDs (full 128-bit format) |

### `setup` (optional)

Describes how a factory-fresh device is brought onto the network — deliberately
separate from `discovery` (finding an already-provisioned device) and from
`initialization` (the per-connection handshake that runs on *every* connect).

A BLE device with an encrypted command channel has both an `initialization`
block and a `setup` block saying `required: false`. That is not a
contradiction: there is nothing to provision, but every connection still needs
a handshake.

| Field | Required | Description |
|-------|----------|-------------|
| `required` | No | Whether provisioning is needed at all. `false` for most BLE devices — say so explicitly; "no setup needed" is a feature. |
| `confidence` | No | `high` (replayed against hardware or a working open implementation), `medium` (public source/vendor docs), `low` (inferred) |
| `methods` | No | Ordered onboarding methods, preferred first |
| `factory_reset` | No | What a reset clears, and the per-variant procedures that trigger it. Set `applicable: false` with an `effect` explaining why when the device genuinely has none — a vehicle reached over a diagnostic connector, say — rather than inventing a procedure to fill the field |
| `rejoin` | No | Whether a device can be moved to a new network without a reset |
| `credentials` | No | How the passphrase is protected, what the device stores, what it issues to the client |
| `notes` | No | Prose overview, including what is and is not confirmed |

#### `methods[]`

`type` is one of `none`, `ble_direct`, `softap_http`, `softap_soap`,
`ble_provisioning`, `wps`, `smartconfig`, `wired`, `device_ui`,
`button_pairing`, `hub_pairing`, `cloud_account`.

| Field | Description |
|-------|-------------|
| `type` | Onboarding model (above) |
| `description` | What this method actually does |
| `verified` | **Always set this.** `true` only if this exact flow has been run against hardware. An absent flag reads as an oversight rather than as "not yet verified". |
| `softap` / `ble` / `cloud` | Detail block for the relevant transport |
| `steps` | The flow, in order |
| `payload_formats` | How to parse non-obvious response payloads, keyed by value name |
| `timing` | Constants a client must honour |
| `troubleshooting` | Symptom/causes pairs for known failure modes |

#### `steps[]`

Each step names who acts and what success looks like. `actor` is `user`,
`client` or `device` — a `user` step cannot be automated, so a client rendering
these as a wizard knows where to stop and prompt. `expect` is the observable
success signal. `request` carries `protocol`, `service`, `action` and
`arguments` when the step is machine-executable.

#### Writing a `setup` block that is actually implementable

The test is whether someone with your hardware and none of your context could
follow it. In practice that means:

- **Name the response values and how to parse them.** `payload_formats` should
  spell out the traps — header lines to skip, trailing separators, columns that
  must be located from the end rather than by index — and carry a literal
  `example` real enough to test against.
- **Write encryption as a procedure, not a description.** "AES-128-CBC with a
  key derived from device metadata" is not implementable. State whether values
  are UTF-8 or hex-decoded, how many hash rounds, the padding, the output
  encoding, and any length suffix — including its zero-padding.
- **Publish test vectors.** They let an implementer verify their crypto against
  known-good values before touching hardware, turning "it fails and I don't
  know which half is wrong" into one answerable question. Use a
  documentation-range MAC and an invented serial so the vectors identify no
  real device, and add a test asserting they stay reproducible.
- **Record the timing constants.** Minimum poll timeouts and deliberate
  duplicate sends look arbitrary and are not.
- **List the failure modes.** Onboarding fails for a small number of recurring
  reasons; naming them is often the difference between a working implementation
  and an abandoned one.

`devices/wemo-devices.yaml` is the worked reference — it is written so a Wemo
device can be provisioned from that file alone. `scripts/test_wemo_spec.py`
proves it: the module transcribes the published algorithm using nothing but
`hashlib`, `base64` and `openssl`, imports none of our own code, and asserts
the transcription reproduces the spec's own test vectors. If the transcription
cannot be written, the spec is underspecified and CI fails.

That is also why there is no supported client surface here. Existing libraries
do discovery, control and provisioning, and are tested against far more
hardware than we are; the spec is our contribution, and proving it
implementable is the test. The same module reconstructs the SSDP datagram, the
description parser and the SOAP request builder from the YAML and diffs each
against the spec's own published examples.

The Wemo scripts under `scripts/` are not an exception to that: they exist to
check the spec against hardware while every `verified` flag in it is still
`false`, and are tracked for deletion once it is done.

Full field-by-field walkthrough:
[`docs/api/spec-format.md`](../docs/api/spec-format.md). Patterns across
devices: [`docs/protocols/device-setup.md`](../docs/protocols/device-setup.md).
`schema.json` is the source of truth for names and enums.

### `services` (required, array)

| Field | Required | Description |
|-------|----------|-------------|
| `uuid` | Yes | BLE service UUID (full 128-bit format) |
| `name` | Yes | Human-readable name |
| `characteristics` | Yes | Array of characteristic definitions |

### `characteristics` (required within services, array)

| Field | Required | Description |
|-------|----------|-------------|
| `uuid` | Yes | Characteristic UUID (full 128-bit format) |
| `name` | Yes | Human-readable name |
| `properties` | Yes | Array of: `read`, `write`, `write_without_response`, `notify`, `indicate` |
| `commands` | No | Named commands for writable characteristics |
| `format` | No | Binary format for readable/notifiable characteristics |

### Number semantics — what a numeric value *means*

`type`, `min` and `max` say how wide a number is; they do not say what it
**is**. Anywhere a spec carries a numeric wire value — a command parameter, a
characteristic `format` field, a `bus` message field, a `payload_formats`
field — it can also carry the shared number-semantics vocabulary
(`$defs/number_semantics` in `schema.json`):

| Field | Meaning |
|-------|---------|
| `unit` | Unit of the **decoded** value: `"C"`, `"F"`, `"%"`, `"km/h"`, `"ms"`. States what is on the wire, not what the device displays. |
| `scale` | `value = raw × scale (+ value_offset)`. Absent means 1. |
| `value_offset` | Additive term applied after `scale`. Absent means 0. Covers the ubiquitous `x − 40`-style scalings that a bare multiplier silently drops. |
| `unit_source` | `fixed` (default) or `device_setting` — whether the wire unit is a constant of the protocol or follows a device setting. |
| `unit_reference` | Where a client learns the active unit. Required with `device_setting`. |
| `unit_values` | Map from that setting's raw values to units, e.g. `{0x46: "F", default: "C"}`. |
| `values` | Code table for numbers that are really enumerated codes: `{0: "low", 1: "medium", 2: "high"}`. |

The transform is deliberately linear so command parameters can be **encoded**
by inverting it — `raw = round((value − value_offset) / scale)`. The OBD
blocks keep their free-form decode `formula` for non-linear read-only
scalings; a formula cannot be run backwards, which is exactly why it is not
used here.

Temperature devices are the motivating case, because C-vs-F comes in two
genuinely different shapes that must not be conflated:

```yaml
# Ember Mug: the wire unit is FIXED. Temperatures are always centi-°C;
# the separate C/F characteristic changes only what the mug displays.
format:
  - offset: 0
    length: 2
    name: "target_temp_raw"
    type: "uint16"
    scale: 0.01
    unit: "C"

# Inkbird iBBQ: the wire unit FOLLOWS A DEVICE SETTING. The same raw 165
# means 165 °C or 165 °F depending on state — query before decoding.
unit_source: "device_setting"
unit_reference: "get_temp_unit (command 04; response prefix 03/04)"
unit_values:
  0x46: "F"       # unit byte is ASCII 'F'
  default: "C"
```

Two conventions to keep straight:

- **`min`/`max` on a command parameter stay raw.** They bound the byte the
  template emits; the real-world bound is `min × scale + value_offset`. On
  entities it is the other way around — see below.
- **`value_offset` earns its keep on offset scalings.** The Gerbing heat
  controller's temperature is the worked example: one raw byte with
  `value = raw × 0.5 + 85` (°F, inferred) — a decode that `scale` alone
  cannot express.

Worked examples in the tree: `devices/ember-mug.yaml` (fixed wire unit +
display-unit select, `values` code tables), `devices/inkbird-bbq-thermometer.yaml`
(device-setting units), `devices/gerbing-thermogauge.yaml` (`value_offset`),
`devices/wemo-devices.yaml` (`payload_formats` units).

### Advanced opcodes

Any command may set `advanced: true` with an `advanced_reason` string. This marks an
opcode that goes further than a typical consumer app would — it can damage hardware, void
a warranty, or change a vehicle's legal classification.

The project default is to **expose everything the protocol supports**; this flag labels
the capability, it does not withhold it. See
[Capability disclosure](../docs/CLEANROOM_RULES.md#capability-disclosure-writing-the-advanced-flag)
for the full policy.

```yaml
commands:
  write_basic_parameters:
    description: "Write the basic parameter block"
    advanced: true
    advanced_reason: "Raises current limits; can overheat the motor if set beyond its rating"
    template: [0x16, 0x52, "{length}", "{data}", "{checksum}"]
```

The flag is advisory metadata — it does not change how the command is encoded or sent.
It is a **signpost, not a gate**: consumers should keep the capability available and put
it behind a deliberate action (a toggle or a confirmation) so nobody trips into it by
accident, showing `advanced_reason` at that moment. They should not hide it, require an
account, or nag — repair cafés and independent technicians are expected users.

Write `advanced_reason` concretely: what changes, the realistic consequence, and how to
recover. Absent or `false` means an ordinary command.

`advanced` is orthogonal to confidence. It describes what happens **if the command
works**; how sure we are that it works is a separate `verification` field on the same
command — `confirmed` / `reported` / `hypothesis`, the same vocabulary the `obd` blocks
use. A well-verified opcode can still be advanced, and an unverified one can be mundane.

```yaml
write_parameter:
  description: "Write a controller register"
  verification: "hypothesis"   # how sure we are it works
  advanced: true               # what happens when it does
  advanced_reason: "..."
```

### `entities` (optional, array)

Maps device capabilities to Home Assistant entity types. See the example spec
for details. A `number` entity may carry `min`, `max` and `step` — stated in
the entity's `unit`, i.e. **after** the bound field's `scale`/`value_offset`
are applied, because they describe the control a user sees rather than the
byte on the wire. Record the device's real resolution in `step` where known,
not a cosmetic rounding.

## OBD-II devices (`obd`)

A spec satisfies the schema by carrying `services` (BLE), `http_endpoints` or
`mqtt_topics` (Wi-Fi), **or** `obd` — for devices reached through a vehicle
diagnostic connector rather than a radio. Set `device.protocol: "obd2"` and
describe the diagnostic surface:

```yaml
device:
  name: "Example Motorcycle"
  manufacturer: "Acme Motors"
  manufacturer_status: "active"
  protocol: "obd2"

obd:
  role: "vehicle"                # vehicle | adapter | module
  connector:
    standard: "sae-j1962"        # or iso-19689 (6-pin Euro 5 motorcycle), proprietary
    location: "under the pillion seat"
  transport:
    standard: "iso15765-4"       # CAN with ISO-TP segmentation
    bitrate: 500000
    addressing: "11bit"
    request_id: "0x7E0"
    response_id: "0x7E8"
    verification: "confirmed"
  requests:
    - name: "read_vin_did"
      command_class: "advanced"  # basic = legislated OBD-II; advanced = UDS/manufacturer
      requires: ["custom_headers", "multiframe_rx"]
      service: "22"
      request: "22 F1 90"
      expected_response: "62 F1 90 ??"
      writes: false
      verification: "confirmed"
```

### Device categories

`obd.role` says what the device is on the diagnostic link — `vehicle` (the thing being
diagnosed), `adapter` (the dongle bridging a host to the connector), or `module` (a single
ECU documented on its own).

An `adapter` also carries an `adapter_profile` classifying what it can actually do:

| Class | Hardware | Adds |
|-------|----------|------|
| `basic-clone` | Cloned "ELM327 v2.1" firmware | `single_frame` only |
| `standards-elm327` | Genuine ELM327 v1.4/1.5 | `multiframe_rx`, `custom_headers` |
| `advanced-stn` | STN chipset (OBDLink LX/MX+/CX) | `multiframe_tx`, `flow_control`, `raw_frames` |
| `native-can` | SocketCAN, PCAN, Kvaser | `monitor_all`, `non_standard_bitrate` |

`alt_can_bus` (Ford MS-CAN / GM SW-CAN) is orthogonal to the tiers — only the OBDLink
MX / MX+ / EX carry it, and tools such as FORScan need it for body and chassis modules.

### Referencing vendor description files

Manufacturers describe each ECU in a machine-readable file — a BMW/EDIABAS SGBD (`.prg`)
selected by a group file (`.grp`), or an ODX/PDX container, CDD, A2L or CAN database. Those
files are the authoritative definition of a module's jobs, results, addressing and scaling,
so a spec can point at them instead of relying only on hand-recovered offsets:

```yaml
obd:
  description_files:                 # vehicle level — usually the .grp entry points
    - type: "sgbd-grp"
      name: "D_MOTOR.grp"
      provides: ["jobs", "results"]
      source: "EDIABAS/INPA/ISTA installation (ECU directory)"
      verification: "hypothesis"
  ecus:
    - name: "KOMBI (instrument cluster)"
      description_files:
        - type: "sgbd-prg"
          name: "KOMBI.prg"
          provides: ["jobs", "results", "ecu_address", "scaling"]
  requests:
    - name: "read_odometer"
      request: "22 E1 19"
      job: "STATUS_LESEN"           # the job this frame implements
      results: ["STAT_SERVICE_KMSTAND_DATA"]
```

`job` and `results` tie a recovered frame back to its definition, which is how a consumer
resolves units and scaling without hardcoding byte offsets.

**Reference these files; never commit them.** They are vendor copyright. `source` records
where a licensed copy comes from — an EDIABAS/INPA/ISTA installation, a vendor tool bundle
— not a redistribution link. `sha256` pins the exact file a fact came from so a consumer
can tell whether it is looking at the same one.

### Basic vs advanced commands

Each request carries `command_class` and a `requires` list of capability tokens:

- `basic` — legislated OBD-II (SAE J1979 modes), single-frame, no session or security
  prerequisite. Works on essentially any adapter.
- `advanced` — UDS or a manufacturer dialect: non-default session, security access,
  custom headers, multi-frame, or any write. Needs a capable adapter.

`command_class` defaults to `advanced`, so an unclassified request is never assumed to be
the safe kind. Matching a request's `requires` against an adapter's
`adapter_profile.capabilities` answers "can this dongle run this command?" before
connecting, instead of failing halfway through a write.

Two further conventions differ from the BLE blocks, on purpose:

- **Byte sequences are hex strings** (`"22 F1 90"`), not integer arrays, matching how
  automotive traces are conventionally written. `??` marks an unknown byte position.
- **Every fact carries a `verification`** — `confirmed` (observed in our own capture or
  read back from the device), `reported` (stated by vendor/community documentation but
  not reproduced here), or `hypothesis` (inferred, untested). This lets a spec record
  ranked candidate messages without them being mistaken for facts. Anything not
  `confirmed`, and anything with `writes: true`, must not be executed against a vehicle
  without review.

Vehicles are safety-critical, so specs here document read paths and owner-facing
maintenance functions only. See [`docs/protocols/obd2-common.md`](../docs/protocols/obd2-common.md)
for the transport background and
[`docs/devices/triumph-tiger-900.md`](../docs/devices/triumph-tiger-900.md) for a worked
example.

`device.protocol: "obd2"` is not yet consumed by the mobile Rust `Protocol` enum, so
these specs are documentation and tooling targets today rather than mobile-app targets.

## Cloud-dependent devices (`cloud`) and how they get freed (`local_access`)

Some devices have no local path at all. `cloud` records that dependency as data rather than
as a caveat in a notes field:

```yaml
device:
  name: "Example Scooter"
  manufacturer: "Acme"
  manufacturer_status: "active"
  protocol: "wifi"

cloud:
  required: true                      # the flag that marks a device cloud-only
  vendor_service: "Acme cloud"
  hosts: ["https://api.example.com"]
  failure_mode: >
    Total loss of documented function; the vehicle still rides but every
    connected feature stops.
  data_leaves_device:
    - "location (personal data about a person, not machine telemetry)"
  auth:
    type: "oauth2"
    endpoint: "/v3/api/oauth2/token"
  endpoints:
    - path: "/v5/scooter/list"
      method: "GET"
      returns: "Scooters on the account"
      verification: "reported"
```

**A spec may satisfy the schema on `cloud` alone.** That is the point: "cloud-only, no local
path" becomes a state a consumer can read and act on — presenting the device as
vendor-tethered — instead of silently offering endpoints that will one day 404. Record the
auth *shape* only; never a real token, account identifier or serial.

### `local_access` — can anything be done about it?

| Status | Meaning |
|--------|---------|
| `native` | Speaks a local protocol as shipped. The normal case here. |
| `bridge_hardware` | A local interface exists but reaching it needs an adapter that isn't part of the product. |
| `replacement_hardware` | No local interface on the stock part; local control means swapping a component. |
| `firmware_replacement` | Stock hardware can be freed, but only by replacing its firmware. |
| `none_known` | No path known today — an honest dead end, not an omission. |

```yaml
local_access:
  status: "replacement_hardware"
  covers:
    - "motor drive parameters via the replacement part's own BLE app"
  not_covered:
    - "telemetry and position — still the vendor's cloud"
    - "GPS and alarm — advertised as continuing to work, i.e. still tethered"
  hardware:
    - name: "Aftermarket Bluetooth Controller"
      vendor: "example.com"
      url: "https://example.com/product/..."
      role: "replacement_part"        # bridge | replacement_part | diagnostic_adapter | programmer
      replaces: "stock motor controller"
      reversible: true
      verification: "reported"
```

**Fill in `not_covered`.** Aftermarket hardware routinely frees one subsystem and leaves the
rest tethered — a replacement controller that makes the drivetrain programmable while GPS,
alarm and telemetry stay on the vendor's cloud has freed the throttle map, not the vehicle.
A spec that lists only `covers` reads as a bigger win than it is.

Hardware entries are documentation of what exists, not endorsements: we generally have not
tested them, commercial listings go dead, and parts that raise current limits on a road
vehicle carry the usual thermal and legal consequences.

## Wired bus devices (`bus`)

For devices with **no radio and no diagnostic connector** — an e-bike motor talking to its
display over UART, or an internal CAN bus carrying raw frames. Set `device.protocol` to
`uart` or `can` and describe the bus:

```yaml
device:
  name: "Example Mid-Drive"
  manufacturer: "Acme"
  manufacturer_status: "active"
  protocol: "uart"

bus:
  link:
    type: "uart"                 # uart | can
    baud: 9600                   # or `bitrate` for CAN
    framing: "8N1"
    wiring:
      - signal: "motor TX (display RX)"
        wire_colour: "brown"
        connector: "6-pin"
  style: "stream"                # request_response | stream | broadcast
  checksum:
    algorithm: "sum8"
    scope: "8-bit sum of all preceding bytes, both directions"
  messages:
    - name: "motor_status"
      direction: "from_device"
      start_byte: "43"
      length: 9
      rate_hz: 8
      verification: "reported"
      fields:
        - offset: 1
          name: "battery_level"
          type: "uint8"
          encoding: "0x00 red blinking; 0x0A+ full green"
```

### Choosing a `style`

`style` decides which message fields apply and what a consumer has to implement:

| Style | Shape | Messages carry | Example |
|-------|-------|----------------|---------|
| `request_response` | Host asks, device answers | `request`, `response` | Bafang BBS02 |
| `stream` | Both ends push at a fixed rate | `start_byte`, `rate_hz` | Tongsheng TSDZ2 |
| `broadcast` | Frames keyed by identifier on a shared bus | `can_id` | Bosch CAN |

`stream` has a consequence worth internalising: a control packet **writes by existing**. It
re-asserts its fields on every repetition, so `writes: true` there does not mean "sends a
command once" — it means "continuously asserts state". A read-only consumer of a `stream`
device must never transmit at all.

### Repeated fields — use `array_len`

Where a block holds one value per level or per channel, say so with `array_len` rather than
describing it in prose:

```yaml
- offset: 2
  name: "assist_current_limit"
  array_len: 10        # ten consecutive bytes, levels 0-9
- offset: 12
  name: "assist_speed_limit"
  array_len: 10        # then ten more
```

This is deliberately not expressible as "ten (current, speed) pairs" — a real and easily
made misreading of exactly this block, which yields plausible values attached to the wrong
level instead of an obvious failure.

### Entities on a bus device

Bus devices have no GATT characteristic to bind to, so entities use `state_field` with a
`message_name.field_name` reference:

```yaml
entities:
  - platform: "sensor"
    name: "Speed"
    device_class: "speed"
    state_field: "motor_status.speed"
```

### `bus` vs `obd`

Both can be CAN, and they are still different things. `obd` models a **diagnostic session**
reached through a standardised socket: connector standard, ECU addressing, UDS services,
security access, adapter capability tiers. `bus` models an **internal bus** whose traffic is
simply there to be read — no session, no addressing scheme, no adapter negotiation. A Bosch
e-bike is CAN but is not OBD-II, and putting it in `obd` would imply a diagnostic layer that
does not exist.

Messages carry `advanced` / `advanced_reason` with the same meaning and the same enforced
pairing as BLE commands, plus `writes` and `verification`. Reaching any of these devices
needs a physical adapter, so specs here are documentation and bridge-building targets rather
than mobile-app targets today.

## Extended / optional fields

The schema is intentionally **permissive** (no `additionalProperties: false`),
so specs may carry bespoke, device-specific metadata alongside the standard
fields. In addition to the required fields above, `schema.json` formally
defines several **optional** blocks for richer protocols — including
characteristic-level `encryption` and `framing`, top-and-service-level
`initialization` handshakes, `device.variants`, command-level `encoding` /
`payload` / `locate`, top-level `features` and `protocol_handler`. See
`schema.json` (the source of truth) for the exact shapes and enums. Some
optional fields are declarative and require dedicated consumer-side code;
those carry a `NOTE` in the schema `description`.

### Permissive does not mean anything goes

Permissiveness exists so a spec can record vendor detail the vocabulary has no
word for yet. It is not licence to invent keys in the blocks a client
*executes* — `entities`, characteristic `format:` fields, and command
`parameters`. Consumers drop what they do not recognise, without complaint, so
an invented key there is not an extension: it is a control that silently does
nothing. An entity that says `write_characteristic` where the vocabulary says
`command_characteristic` validates, reads correctly to a human, and cannot be
written to by any client.

`scripts/test_device_specs.py` enforces this: every key used in those three
blocks must be one `schema.json` declares. If you need a key that does not
exist, add it to the schema in the same change — that is the cheap half, and
it is what makes the value reachable.

Two keys were removed rather than declared, because each restated something
the spec already said in a place that actually drives bytes:

- `parameters.color_order` — the `template` already names `{red}`/`{green}`/
  `{blue}` in the order they are emitted. A device wanting GRB is written
  `template: ["{green}", "{red}", "{blue}"]`. All eight uses said `rgb` beside
  a template already in R,G,B order, and nothing defined which won if they
  disagreed.
- `format` fields spelled `description` — `notes` says the same thing and is
  the declared spelling.

## Schema Validation

All specs under `device-specs/` are validated against `schema.json` on every
push and pull request by the `validate-specs` job in
[`.github/workflows/ci.yml`](../.github/workflows/ci.yml). The same job also
builds `device-specs/index.json` and throws the result away — a spec the index
generator cannot handle fails there, but the committed index is written by the
`publish-index` job on main, not by contributors. The
`build` job additionally runs `python scripts/build_index.py --check`,
re-validating every published spec against the schema before the docs (and JSON
API) are built.

To validate locally:

```bash
pip install -r requirements.txt        # installs jsonschema + pyyaml
python scripts/validate_specs.py        # PASS/FAIL per file; exits non-zero on any failure
```

`scripts/validate_specs.py` discovers every `device-specs/**/*.yaml` (top-level,
`examples/`, and `devices/`), validates each against the draft 2020-12 schema,
and prints a `PASS`/`FAIL` line per file with the failing JSON path on error.

## Machine-consumable spec index (`device-specs/index.json`)

`device-specs/index.json` is a generated manifest that lets consumers enumerate
specs automatically instead of hardcoding a file list. It is a JSON array,
sorted by path, of `{ name, path, protocol, category, manufacturer, manufacturer_status,
helpful_urls (if set), helpful_videos (if set), protocol_handler (if set),
schema_version }`. Absent helpful-reference fields are omitted rather than
emitted as empty arrays.

**CI writes this file; do not commit it.** The `publish-index` job in
[`.github/workflows/ci.yml`](../.github/workflows/ci.yml) regenerates it on
every push to main and commits the result as `github-actions[bot]`, so it lands
once, after the specs, instead of once per branch. It used to be regenerated by
hand in every spec PR, which meant any two concurrent spec PRs conflicted on it
— on a 60 kB generated file whose only resolution is to regenerate. A PR that
carries a modified `index.json` now fails CI with the command to drop it.

It stays committed rather than being built at consume time because it is a
shipped asset: the mobile app vendors this repo as a git subtree and bundles
`device-specs/index.json` directly. Only the writer changed.

You can still build it locally to look at:

```bash
python scripts/generate_index.py        # idempotent: no diff on re-run
python scripts/generate_index.py --check  # is the committed one current? (writes nothing)
```

Never edit it by hand — it is produced from the specs.

## Machine-consumable manifest (JSON API)

The single source of truth for consumers is the versioned JSON API generated by
[`scripts/build_index.py`](../scripts/build_index.py). It discovers every spec
under `device-specs/devices/`, validates each against `schema.json`, and emits:

- `site/api/v1/manifest.json` — a registry index with per-device `id`, `name`,
  `manufacturer`, `protocol`, `status`, `updated_at`, `url`, and `sha256`
  checksum.
- `site/api/v1/devices/<id>.json` — each spec normalized to JSON.

```bash
python scripts/build_index.py           # generate site/api/v1/**
python scripts/build_index.py --check   # validate every spec without writing (CI gate)
```

The API is also regenerated into the published site automatically by the
`scripts/mkdocs_hooks.py` post-build hook, so `mkdocs build` always ships a
fresh manifest. See [`docs/api/index.md`](../docs/api/index.md) for the consumer
guide. Only specs under `device-specs/devices/` are published;
`examples/example-bulb.yaml` is a reference example and is intentionally not
included in the manifest.

## Structure

```
device-specs/
├── README.md          # This file
├── schema.json        # JSON Schema for validation
├── index.json         # Generated spec index (scripts/generate_index.py)
├── examples/          # Example specs for reference (not published in the API)
│   └── example-bulb.yaml
└── devices/           # Published device specs (surfaced in the JSON API)
```

## Contributing

1. Reverse engineer the device's BLE protocol (see `docs/re-guide/`)
2. Create a YAML spec following the format above
3. Validate against `schema.json`
4. Place it in `device-specs/devices/`
5. Submit a PR

Even partial specs are welcome -- someone else can fill in the gaps.
