# teenage engineering OP-Z

> **Status**: Spec available (official source-derived; untested here)
> **Protocol**: Standard BLE-MIDI; USB content mode for files/configuration
> **Manufacturer**: teenage engineering
> **Manufacturer Status**: Active

## Overview

OP-Z is a 16-track multimedia sequencer and synthesizer in the TE012 family.
This initial spec covers ordinary BLE-MIDI performance, the official incoming
MIDI map, `midi.json`, and the vendor's app/USB lifecycle instructions. It does
**not** expose proprietary app visual/content commands or imply that the
community MIDI parser replaces the official app.

No OP-Z was connected, reset or updated for this document. Protocol facts come
from the official user/MIDI/app/disk-mode guides and the official Android app's
standard BLE-MIDI transport. Packet examples are synthetic, not captures. See
`device-specs/devices/teenage-engineering-op-z.yaml` for machine-readable rules
and vectors.

## Discovery, setup and pairing

**Select OP-Z manually.** Research did not establish an advertised OP-Z local
name. The standard MIDI service is also used by unrelated instruments and
adapters, so it is not an identity signal. Do not infer an advertisement prefix
from `OP-Z`, `TE012`, or the app package name.

| Property | Value |
|----------|-------|
| Setup / account | None for standard local MIDI |
| MIDI service | `03b80e5a-ede8-4b33-a751-6ce34ec4c700` |
| MIDI characteristic | `7772e5db-3868-4112-a1a9-f2669d106bf3`, read + write + notify |
| Official app | OP-Z, `com.teenageengineering.te012` |
| Pairing / bonding | Unknown across independent hosts; official app has a rear-button flow |
| Factory reset | Available in upgrade mode; deletes custom user content |

To use a normal MIDI host, select the intended unit, connect to the standard
service, read the characteristic as the official app does, and enable
notifications and its CCCD. No proprietary authentication command is used by
this spec. Whether an independent host must bond, or accepts only one
connection/bond, remains unknown.

### Enable MIDI on OP-Z

Hold **tempo + screen** together, then use the relevant key:

| Key | Setting |
|---|---|
| 1 | channel one to active |
| 2 | incoming MIDI |
| 3 | outgoing MIDI |
| 4 | MIDI clock in |
| 5 | MIDI clock out |
| 6 | alternate program change |
| 7 | MIDI echo |
| 8 | enable program change |
| track 1–16 | mute MIDI on that track |
| hold track 1–16 + green dial | set that track's channel to 1–16 |

These are toggles: inspect the result instead of blindly repeating a sequence.
Outgoing MIDI must be enabled before a host can rely on performance output.
Incoming clock automatically selects external sync; four green LEDs show tempo
while tempo is held.

### Official app pairing

The official guide's app route is separate from an independent MIDI host:

1. Open the app's devices screen and scan if the platform requires it. Android
   requires location-services permission for BLE connection.
2. Press the **pair** button on the back of OP-Z.
3. Select the intended OP-Z in the app list to connect.

This exact flow is `verified: false` with the official app guide as its basis;
it was not run here. It does not prove that every generic MIDI host needs that
button or an OS bond. No bond-only clearing procedure is established, so do not
use a destructive factory reset as a routine unpair shortcut.

## Standard BLE-MIDI reassembly

A notification is a BLE-MIDI **packet**, not necessarily one complete MIDI
message. Messages can be split across notifications and several messages can be
coalesced into one.

Each packet starts with a header whose top bits are `10`; the low six bits are
the timestamp's high group. When the parser expects a timestamp, a high-bit body
byte supplies its low seven bits and is not MIDI data:

```text
timestamp = ((header & 0x3f) << 7) | (timestamp_low & 0x7f)   # modulo 8192 ms
```

If the low value decreases from the preceding timestamp **within the same
notification**, advance the high group by 128 modulo 8192. Reset that comparison
at each new notification and trust its header; a decrease from the previous
packet is not itself a wrap. The next body byte after a timestamp is MIDI even
when it is another high-bit status byte.

A client must retain the current message, expected data length, SysEx state and
running status across notifications:

- channel statuses `8x`, `9x`, `Ax`, `Bx`, `Ex` take two data bytes; `Cx` and
  `Dx` take one;
- channel running status lets a timestamp be followed by data without a repeated
  status;
- `F0` starts SysEx and clears channel running status; buffer through `F7`,
  however many notifications that takes;
- `F1`/`F3` take one data byte, `F2` two and `F6` none; system-common messages
  clear running status;
- `F8`–`FF` are zero-data real-time statuses. Deliver them immediately without
  clearing channel running status or inserting them into an enclosing SysEx;
- continuation data below `80` is legal at the start of a packet body. Emit only
  complete messages and reject unexpected data or implausible truncation.

The official app has a 240-byte outgoing packet allocation and a 1024-byte
decoder allocation. These are implementation observations, **not** a universal
MTU or maximum SysEx length. Honor the negotiated ATT limit and bound partial
buffers in production.

Synthetic examples in the spec cover a single CC, fragmented SysEx, coalesced
clock/CC/start messages, a split CC, running status, real-time clock inside
SysEx, and timestamp wrap. For example:

```text
notifications:  80 80 f0 01 02 | 80 03 04 | 80 80 f7
MIDI message:   f0 01 02 03 04 f7
```

The middle notification starts with continuation data, not a new SysEx header.
`scripts/test_teenage_engineering_op_z.py` implements the parser using only the
standard library and checks all vectors.

## Official incoming MIDI map

The following reproduces the official guide's incoming table. “Relative” values
are only `1` and `127`; the guide does not establish here which one increments
or decrements, so this spec does not guess.

### Track parameters

All rows use channels 1–16 and absolute values 0–127.

| Parameter | Absolute CC | Relative CC | Relative values |
|---|---:|---:|---|
| parameter 1 | 1 | 32 | 1, 127 |
| parameter 2 | 2 | 33 | 1, 127 |
| filter cutoff | 3 | 34 | 1, 127 |
| filter resonance | 4 | 35 | 1, 127 |
| envelope attack | 5 | 36 | 1, 127 |
| envelope decay | 6 | 37 | 1, 127 |
| envelope sustain | 7 | 38 | 1, 127 |
| envelope release | 8 | 39 | 1, 127 |
| LFO depth | 9 | 40 | 1, 127 |
| LFO speed | 10 | 41 | 1, 127 |
| LFO target | 11 | 42 | 1, 127 |
| LFO shape | 12 | 43 | 1, 127 |
| FX 1 send | 13 | 44 | 1, 127 |
| FX 2 send | 14 | 45 | 1, 127 |
| pan | 15 | 46 | 1, 127 |
| volume | 16 | 47 | 1, 127 |
| portamento | 17 | 48 | 1, 127 |
| note style | 18 | 49 | 1, 127 |

### System and track controls

| Control | CC | Channels | Values |
|---|---:|---|---|
| track gain | 50 | 1–16 | 0–127 |
| track gain (relative) | 51 | 1–16 | 1, 127 |
| reset track gains | 52 | any | any |
| mute | 53 | 1–16 | 0–1 |
| audio mute | 54 | 1–16 | 0–1 |
| mute group | 55 | any | 0–9 |
| tempo | 56 | any | 0–127 |
| swing | 57 | any | 0–127 |
| select pattern | 103 | 1–10 | 0–15 |
| next pattern | 103 | any | 16 |
| previous pattern | 103 | any | 17 |
| track step count | 60 | 1–16 | 1–16 |
| track step length | 61 | 1–16 | 1–16 |
| quantize | 62 | 1–16 | 0–127 |
| note length | 63 | 1–16 | 0–127 |

### Other, real-time and UI messages

| Message | Status / CC | Channels / values |
|---|---|---|
| start | `FA` | system real-time |
| stop | `FC` | system real-time |
| continue | `FB` | system real-time |
| clock | `F8` | system real-time; selects external sync |
| program change, first documented form | program change | channels 1–10, values 0–15 |
| program change, second documented form | program change | channels 1 or 2, values 0–127 |
| pitch bend | standard 14-bit MIDI | channels 1–16 |
| song pointer | not used | — |
| active sense | not used | — |
| active track | CC 102 | channel 0, values 0–15 |
| parameter page | CC 102 | channel 1, values 0–3 |

## `midi.json` in USB content mode

The official guide names these settings in `midi.json` on the content-mode disk.
It does not give enough evidence here to assert the complete JSON nesting or
array shape. Back up and preserve the existing file's structure rather than
constructing a new file from this table alone.

| Key | Type / range | Meaning |
|---|---|---|
| `channel_one_to_active` | true / false | redirect incoming channel 1 to the active track |
| `incoming_midi` | true / false | enable incoming MIDI |
| `outgoing_midi` | true / false | enable outgoing MIDI |
| `timing_clock_in` | true / false | enable incoming clock |
| `timing_clock_out` | true / false | enable outgoing clock |
| `enable_program_change` | true / false | enable program change in/out |
| `alt_program_change` | true / false | true: bank 1–16 / program 1–16; false: bank 1 / program 1–128 and bank 2 / program 1–32 for patterns 1–160 |
| `midi_echo` | true / false | echo on the same port and through to other ports |
| `track_enable` | true / false, per track | enable MIDI on a track |
| `track_channels` | 1–16, per track | set outgoing channel |
| `parameter_cc_out` | 0–255, per parameter per track | assign outgoing CC value; 0–255 is the official documented range |

To enter **content mode**, start with OP-Z off and hold **track** while turning
it on. All track LEDs turn green. Connect USB and open the removable OP-Z disk.
Back up files before editing. Safely eject before unplugging; OP-Z then
synchronizes changes and restarts in normal mode. Do not power it off during
that process.

This content route can back up or restore projects, samples, bounces and
configuration. USB-C also supports MIDI according to the vendor, but detailed
USB-MIDI behavior is outside this initial spec.

## Factory reset

**This deletes custom user content. Back up first.** The official procedure is
recorded with `verified: false` and the official disk-mode guide as its basis:

1. Start with OP-Z off. Hold **screen** while turning it on to enter upgrade
   mode. The kick LED blinks white and all parameter-dial LEDs are white.
2. In upgrade mode, hold **screen + stop** together for **one second**.
3. Wait for a blinking white LED and four green LEDs, which indicate that the
   reset has finished.
4. Safely eject OP-Z, power cycle it, and verify normal startup.

The guide says original factory settings are restored and custom user content
is removed. Whether every host-specific Bluetooth bond is cleared is not
separately established. Changing MIDI hosts does not ordinarily require this
reset: manually select a new standard-MIDI host or repeat the app's rear-button
flow.

## USB firmware update

The firmware flow also begins in **upgrade mode** (hold **screen** while turning
on). The official procedure, again `verified: false` with the guide as its
basis, is:

1. Connect OP-Z to a computer with USB and open its removable disk.
2. Copy a vendor-supplied file intended for **OP-Z** onto the disk and ensure it
   is copied in full. Do not substitute an OP-1 or OP-1 Field image.
3. Safely eject the disk.
4. Wait for OP-Z to update and restart in normal mode. **Do not power it off
   during the update.**

No latest version, image URL, signature rule or interrupted-update recovery is
asserted. No firmware image was downloaded and no update was attempted. Use the
vendor's guide to select the correct image.

## Remaining gaps

- Establish the advertised local name and real-world advertisement contents.
- Capture OP-Z BLE-MIDI fragmentation/coalescing, running status and clock/SysEx
  behavior; confirm actual MTU and host pairing behavior.
- Compare a real `midi.json` before and after app edits to establish its JSON
  container shape.
- Determine bond-only clearing and exactly what reset clears beyond user content.
- Research app-specific visual/content protocols and USB-MIDI separately.
- Establish firmware image format, signing, version selection and recovery after
  interruption rather than guessing.

## References

- [Official OP-Z user guide](https://teenage.engineering/guides/op-z) — product and linked lifecycle chapters
- [Official OP-Z MIDI guide](https://teenage.engineering/guides/op-z/midi) — settings, `midi.json` and incoming map
- [Official app pairing](https://teenage.engineering/guides/op-z/app#pairing) — rear pair-button flow
- [Official USB disk modes](https://teenage.engineering/guides/op-z/disk-modes) — content, firmware and reset procedures
- [nbw/opz, pinned community parser](https://github.com/nbw/opz/tree/17b3f031c61d5f9ff9b7e7e8685083763cd7a6e4) — ordinary MIDI event parsing
- [chrisdiana/OPZgo, pinned community backup tool](https://github.com/chrisdiana/OPZgo/tree/5f818fe729220eb7c26b667b5dc3090637925b9f) — USB content backup
