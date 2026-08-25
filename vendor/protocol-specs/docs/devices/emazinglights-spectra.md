# EmazingLights Spectra

> **Status**: Research
> **Protocol**: BLE
> **Manufacturer**: EmazingLights
> **Manufacturer Status**: Abandoned (app delisted; firmware backend dead)

## Overview

EmazingLights Spectra is a programmable LED glove set for gloving light shows. The
system has two halves: the **gloves** themselves, and a **Smart Hub** (called
"PhotoHub" in its firmware-update metadata) that bridges them to your phone. The
phone never talks to the gloves directly — it sends commands over BLE to the hub,
which relays them to the gloves over a proprietary 2.4 GHz radio link.

The product is orphaned: the Android app (`com.emazinglights`) has been delisted
from Google Play, and the server that hosted firmware updates
(`www.facemeltcrew.com`) no longer exists (verified 2026-08-25 — the domain does
not resolve). The good news: **everything about controlling the gloves is local**.
The hub speaks an unencrypted, unauthenticated BLE protocol, fully mapped from the
delisted app, so a replacement app can drive the hardware without any vendor
infrastructure. The app's cloud API only provided community features (sharing
glove sets) and is not needed for control.

## Hardware

| Property | Value |
|----------|-------|
| Model | Spectra Smart Hub ("PhotoHub") + Spectra gloves |
| Chipset | Qualcomm CSR101x family (identified via its CSR OTA service UUIDs) |
| Radio | BLE (phone↔hub); proprietary 2.4 GHz (hub↔gloves) |
| Power | Battery-powered hub (vendor recovery advice: power off or remove batteries) |

## Initial Setup

| Property | Value |
|----------|-------|
| Setup required | No |
| Method | `ble_direct` |
| Setup AP / advertised name | Manufacturer data contains ASCII `LEHUB1` + pairing-mode byte; name is user-renamable and display-only |
| Passphrase protection | not_applicable |
| Confidence | medium (static analysis of the delisted app; no live capture yet) |

Power the hub and scan. The hub announces itself in **manufacturer-specific
advertisement data**, not its name: the company-ID-plus-payload bytes spell the
ASCII string `LEHUB1`, and the final payload byte is a pairing-mode flag — `0x01`
means the hub is in pairing mode and will accept a connection. There is no PIN,
no bonding and no account. Connect and write commands directly; send the
exit-pairing-mode command (opcode `0x09`) when finished, mirroring the original
app.

**Factory reset**: there is no documented reset procedure and no credential state
to clear — the hub holds no network configuration and no pairing bonds. The
vendor's own recovery instruction for a misbehaving hub is to turn it off or
remove its batteries, then power it back on; it advertises again with the
pairing flag set. Whether stored modes and a custom hub name survive a battery
pull is unverified (low confidence).

**Rebinding to a new phone**: nothing binds the hub to a phone, so just connect
from the new one. If the old phone keeps auto-reconnecting and holding the link,
remove the hub from that phone's Bluetooth device list first.

## Protocol Summary

### BLE Services

| UUID | Name | Description |
|------|------|-------------|
| `f4db6da0-2fcf-d296-a741-42ff6328ef42` | Command service | All commands + OTA stream |
| `58511d0a-2cd1-6188-5445-9f98c91be785` | Command characteristic | 20-byte framed commands (write) |
| `0788ead1-3899-45ac-0346-094599b058b8` | Housekeeping service | Battery / firmware version / rename |
| `e3daf87b-abe9-4a8f-9a42-1f27d2faa8fd` | Battery | Read (encoding unverified) |
| `b66dac3c-da9d-dabe-524b-32c864bbba0e` | Firmware version | Read; hex int, high byte = major, low = minor |
| `cba9b4f5-bfed-959d-5741-bf7340d19491` | Hub name | Read/write; rename writes name chars as ASCII hex |
| `8a97f7c0-8506-11e3-baa7-0800200c9a66` | OTA service | Qualcomm CSR firmware-update family |
| `210f99f0-8508-11e3-baa7-0800200c9a66` | OTA new image | 12-byte image header |
| `2691aa80-8508-11e3-baa7-0800200c9a66` | OTA image content | 16-byte blocks |
| `2bdc5760-8508-11e3-baa7-0800200c9a66` | OTA expected sequence | Block flow control |

### Command frame format

Every command is a fixed 20-byte frame written to the command characteristic:

| Offset | Length | Description |
|--------|--------|-------------|
| 0 | 1 | Header `0x55` |
| 1 | 1 | Opcode |
| 2 | 1 | Index / parameter |
| 3–18 | 16 | Payload, zero-padded |
| 19 | 1 | Checksum: XOR of bytes 0–18 |

Writes are plain GATT writes (no encryption, no authentication). When sending a
multi-frame upload, pace frames at **one per 200 ms** — that is the timing the
original app uses.

### Commands (opcodes)

| Opcode | Name | Payload | Description |
|--------|------|---------|-------------|
| `0x01` | writeModeSettings | `[numColors, patternCode, 0, motionType, 1, threshold, low, medium, high]` | Mode header; pattern code `0xFF` = custom pattern (send `0x07` next) |
| `0x02` | writeBlockSettings | `[blockIndex, R, G, B, 0, 1]` | One color of the sequence; one frame per color, in order |
| `0x03` | changeDisplayMode | `[mode]` | App sends `[1]` after an upload ("show uploaded mode") |
| `0x04` | changeRunMode | index `1`, payload `[0, 0]` | Start running the uploaded mode |
| `0x05` | setPWMColor | `[R, G, B]` | Set a direct color immediately |
| `0x07` | flashingPatternSettings | 14 bytes | Custom strobe/gap/fader pattern definition |
| `0x09` | exitPairingMode | all zero | Leave pairing mode |
| `0x0A` | syncStarted | index `1` = start, `2` = end | Brackets a sync/OTA session |

A full mode upload is: `0x01` → one `0x02` per color → optional `0x07` →
`0x03(1)` → `0x04`. Opcode `0x06` is skipped in the app and presumed reserved.

### Firmware updates (OTA)

The hub implements the documented Qualcomm CSR OTA service, and the updater flow
is known: CRC32 the image (zero-padded to a 16-byte multiple), write a 12-byte
header `[CRC32 LE][length LE][00 10 01 08]`, bracket with `syncStarted`, stream
16-byte blocks, abort on a 10-second stall. In practice this is moot today: the
vendor's firmware host is dead, so no image is available to flash unless one is
recovered from the community.

## Open Questions

- Exact company-ID/payload split of the `LEHUB1` manufacturer data (one real
  advertisement capture settles it).
- The built-in flashing-pattern code table (lives in the app's bundled database;
  not yet extracted).
- Battery characteristic encoding (percent vs voltage).
- Whether the hub requires the `0x09` exit-pairing handshake before accepting
  mode writes, and whether the command characteristic notifies.
- `changeDisplayMode` / `changeRunMode` operand semantics beyond the values the
  app always sends.

## Tools Used

- [x] APK static analysis (jadx) of `com.emazinglights` v1.8
- [ ] HCI snoop / live capture against hardware (pending — see Open Questions)

## References

- [ACM TOSN 2023 BLE OTA survey — documents the Qualcomm CSR OTA service family](https://dl.acm.org/doi/fullHtml/10.1145/3579856.3595806)
- [EmazingLights (vendor site)](https://www.emazinglights.com/)
- OTA manifest `http://www.facemeltcrew.com/ios/testmanifest.json` — **dead**
  (domain unresolvable, verified 2026-08-25); recorded as orphan evidence

## Contributors

- Initial research: static analysis of `com.emazinglights` v1.8
