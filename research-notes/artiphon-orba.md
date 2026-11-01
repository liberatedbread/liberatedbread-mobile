# Artiphon Orba — Research Notes

## Scope correction (2026-11-01)

The capture-verified `holofermes/orba-protocol` specification is for **Orba
2**, not Orba 1 as the earlier draft said. Its identity is `Artiphon Orba 2`
and its official companion is `com.artiphon.kestrel` (recovered 1.0.670).
Orba 1's `com.artiphon.orba` is a different target. Orba 3, Chorda and
INSTRUMENT 1 are not proven compatible.

The validated spec is now `device-specs/devices/artiphon-orba-2.yaml` and the
owner guide is `docs/devices/artiphon-orba-2.md`.

## Local protocol

- Standard BLE-MIDI service `03b80e5a-ede8-4b33-a751-6ce34ec4c700` and I/O
  characteristic `7772e5db-3868-4112-a1a9-f2669d106bf3`, write + notify.
  Filter on the service because the post-connection name can differ.
- One BLE central at a time. No account or cloud is needed for playing or
  configuration. USB-MIDI carries the same SysEx command layer.
- SysEx contains `00` followed by LSB-first 8-to-7-bit packing of
  `82 01 <id> <length:u16be> <payload> <crc:u16be>`. CRC-16 uses reflected
  polynomial `A001` and initial zero. GET is `02`; SET is `03`, followed by a
  domain and big-endian register address.
- BLE-MIDI packetization and exact register maps are declared in the
  validated spec. Never blind-scan registers: invalid reads can reboot the
  device. Erase and fresh-record operations are destructive.

## Evidence and immediate owner route

[holofermes/orba-protocol](https://github.com/holofermes/orba-protocol)
(code MIT, specification CC BY 4.0) reports byte-identical checks against
captures and live Orba 2 responses. This project has not repeated the hardware
run. [Orba Console](https://holofermes.github.io/orba-console/) is a working
local browser controller and should be the first owner recommendation.

## Remaining unknowns

Metronome's exact enum, battery reply semantics, the preset-file workflow,
firmware/content archives, and compatibility with every other Artiphon model.
