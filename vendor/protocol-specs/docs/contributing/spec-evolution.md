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
| [P3](#p3) | Endianness on BLE `format` | Medium | Very low | Recommended now |
| [P4](#p4) | Bit-field decoding | Medium | Low | With consumer |
| [P5](#p5) | Symmetric BLE command responses | High | Low | With consumer |
| [P6](#p6) | First-class advertisement payloads | High | Medium | With consumer |
| [P7](#p7) | Normalized capability vocabulary | High | Medium | Needs a design pass |
| [P8](#p8) | Rename `command_class` → `adapter_class` | Low | Low | Governance |
| [P9](#p9) | SemVer the schema | Medium | Low | Governance — enables the rest |

The through-line: **P1, P2 and P6 all push in the same direction** — put the
standard-shaped parts of a protocol (checksums, SIG characteristics, open beacon
formats) in terms of published standards instead of local prose, so more of every
spec is reproducible from the file. That is the same lever `test_wemo_spec.py`
already pulls, applied to the parts of a spec that are currently prose-only.
