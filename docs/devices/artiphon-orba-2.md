# Artiphon Orba 2

> **Status**: Spec Available (capture-verified upstream; untested here)
> **Protocol**: BLE-MIDI and proprietary SysEx
> **Manufacturer**: Artiphon, Inc.
> **Manufacturer Status**: Shutdown — liquidated in 2025

## Overview

Orba 2 is a handheld instrument and looper whose performance and
configuration paths work without Artiphon's app or cloud. Standard MIDI
carries playing data; a proprietary SysEx command layer carries transport,
tempo, key/scale, quantization and mix settings. The same SysEx works over
USB-MIDI and BLE-MIDI.

This document covers **Orba 2 only**. The public protocol source's live
hardware and captures are Orba 2, not Orba 1. Do not infer compatibility with
Orba 3, Chorda or INSTRUMENT 1. The recovered Orba 2 companion package is
`com.artiphon.kestrel`; the older Orba 1 app is a different target.

An immediate alternative is [Orba Console](https://holofermes.github.io/orba-console/),
a browser controller using Web Bluetooth or Web MIDI with no account.

## Initial Setup and Pairing

No account or provisioning is required. Wake the Orba and close any other
central, then connect to the device whose advertised name is exactly
`Artiphon Orba 2` **and** which carries the BLE-MIDI service. Neither signal is
enough alone: the BLE-MIDI service is on every BLE-MIDI product, and this spec
has destructive erase commands. The name read after connecting can differ
from the advertised one, so match on the advertisement. A unit advertising
another name is not matched automatically; the user picks it. The device
holds one BLE central at a time.

| Property | Value |
|----------|-------|
| Setup required | No |
| Pairing / bonding | None required |
| Service | `03b80e5a-ede8-4b33-a751-6ce34ec4c700` |
| MIDI I/O | `7772e5db-3868-4112-a1a9-f2669d106bf3`, write + notify |
| Factory reset | Unknown; erase-song is not a factory reset |

Enable MIDI notifications and serialize every write of a command.

## SysEx framing

The command payload is `02` for GET or `03` for SET, then a domain and a
16-bit big-endian register address, followed by any values. Wrap it as:

```text
82 01 <message-id> <payload-length:u16be> <payload> <crc:u16be>
```

CRC-16 uses reflected polynomial `A001`, initial zero, over `82` through the
last payload byte. Repack the packet from 8-bit to 7-bit **LSB-first**, prefix
`00`, and delimit with `F0` and `F7`.

BLE-MIDI splits that stream into ordered writes, normally at 20 bytes:

```text
first:        80 80 <up to 18 stream bytes>
continuation: 80 <up to 19 stream bytes>
end:          80 80 F7
```

Incoming notifications require the mirror reassembly through `F7`; a single
notification is not necessarily a complete reply. Message ids correlate
responses. Do not blind-scan registers: invalid reads can fault and reboot
the instrument.

## Useful commands

| Command | Payload |
|---|---|
| Select part | `03 01 00 03 <0 Lead / 1 Chord / 2 Bass / 3 Drum>` |
| Record / overdub | `03 07 00 02 01` |
| Play / resume | `03 07 00 02 05` |
| Pause, preserving the loop | `03 07 00 02 06` |
| Tempo | `03 07 00 07 <BPM x100:u16be>` |
| Scale | `03 03 00 13 <index>` |
| Battery request | `02 03 00 0f` |

Quantization is per part at `07@0003` through `07@0006`: `0` as played,
`1` snap to grid, `2` Orba groove. Scale indexes `0–10` are Major, Natural
Minor, Harmonic Minor, Melodic Minor, Major Pentatonic, Minor Pentatonic,
Dorian, Phrygian, Lydian, Mixolydian and Locrian respectively.

Per-part FX lives at `02@50xx`: part bases Lead `00`, Chord `08`, Bass `10`,
Drum `18`, offsets volume `+0`, pan `+1`, reverb `+2`, delay `+3`. Values
`0–255` map to `0–100%`. The trailing `00 01 04` is required; without it the
Orba can acknowledge but ignore a write. Changing a preset resets that part's
FX.

Erase-active-loop (`…02`), erase-song (`…03`) and fresh-record (`…04`) are
advanced, destructive operations, not ordinary transport stop commands.
Preset selection uses a 129-byte filename and a separate commit; it is not
exposed as an ordinary command here.

## Verification and open questions

The canonical public specification reports replaying 31 captured writes and
acceptance of synthesized writes by a live Orba 2. This project has not run
the hardware. `scripts/test_artiphon_orba_2_spec.py` independently rebuilds
short and fragmented reference vectors, including the mandatory FX trailer.

Open: the exact metronome enum, battery reply semantics, preset-file
workflow, and compatibility with every other Artiphon model.

See `device-specs/devices/artiphon-orba-2.yaml` for the machine-readable
spec.

## References

- [holofermes/orba-protocol specification](https://github.com/holofermes/orba-protocol/blob/main/spec/SPEC.md) — capture-verified protocol; code MIT, specification CC BY 4.0
- [Orba Console](https://holofermes.github.io/orba-console/) — local browser controller
