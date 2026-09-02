# Aurora LED Shoes

> **Status**: Complete (protocol mapped from app analysis; live capture pending for details)
> **Protocol**: BLE
> **Manufacturer**: jtkj (app developer; shoe hardware OEM unknown)
> **Manufacturer Status**: Unsupported

## Overview

Aurora LED Shoes are Bluetooth-controlled light-up rave shoes driven by the "Aurora LED Shoes"
app (`com.jtkj.auroraled`, v1.0.1 analyzed). The protocol is about as simple as BLE control
gets: one service, one characteristic, and a handful of 1–4 byte opcode-first packets with no
handshake, no pairing, no checksum, no encryption, no OTA and no vendor backend. Everything the
app does can be reproduced locally — these shoes have no cloud dependency at all.

One phone can drive many shoes at once: the app holds several connections and broadcasts every
command to all of them, so a pair (or a whole dance floor) stays in sync.

!!! note "Same developer as CoolLED1248 — different protocol"
    The app developer (jtkj) also ships CoolLED1248 (`com.jtkj.led1248`). The apps share a BLE
    wrapper library and coding style, but the GATT profiles and opcodes are **different**
    (CoolLED1248 is the `0xFFE5`/`0xFFE9` family). The two are not interchangeable.

## Hardware

| Property | Value |
|----------|-------|
| Model Number | Unknown (generic "FS"-named BLE module) |
| Chipset | Unidentified — `0xFFF0`/`0xFFF1` is the classic cheap BLE-UART-bridge profile |
| Radio | BLE |
| FCC ID | Unknown |

## Initial Setup

No provisioning of any kind. The shoes advertise as soon as they are powered on and accept a
connection from any central — no account, no pairing PIN, no credentials.

| Property | Value |
|----------|-------|
| Setup required | No |
| Method | `ble_direct` |
| Setup AP / advertised name | Name prefix `FS` + advertised service `0xFFF0` (the app's scanner requires both) |
| Passphrase protection | not_applicable |
| Confidence | high (from app code); live scan still pending |

**Factory reset**: there is nothing to reset — the shoe stores no credentials or bonds.
Power-cycling drops the current connection, which is the actual fix for the most common failure
mode: the shoe still being connected to another phone (only one central can hold the link).

**Rebinding to a new controller**: just connect from the new phone. The catch is the old phone:
the vendor app caches previously-connected MAC addresses and auto-reconnects to them, so close
the app (or unpair/forget at the OS level) on the old phone before expecting the new one to
connect.

## Protocol Summary

### BLE Services

| UUID | Name | Description |
|------|------|-------------|
| `0000fff0-0000-1000-8000-00805f9b34fb` | Control Service | Sole service |
| `0000fff1-0000-1000-8000-00805f9b34fb` | Control | Write + notify; all commands and the state reply |

Commands are raw opcode-first packets of 1–4 bytes, one write (write-without-response) per
command. No header, length field, checksum or encryption.

### Commands

| Command | Bytes | Description |
|---------|-------|-------------|
| Music color | `01 RR GG BB` | Set displayed color live (app feeds this from phone-mic FFT; any color source works) |
| Solid color | `03 RR GG BB` | Set static RGB color |
| Power toggle | `04` | Flip on/off |
| Set power | `05 VV` | `01` = on, `00` = off |
| Set speed | `10 VV` | Pattern speed — **lower = faster** (inverted slider); exact range unconfirmed |
| Slow color change | `07 04 NN` | NN: 00 blue, 01 green, 02 red, 03 cyan, 04 purple, 05 yellow, 06 white, 20 seven-color, 30 red+green, 40 red+blue, 50 green+blue |
| Flash | `07 05 NN` | NN: 00 blue, 01 green, 02 red, 03 cyan, 04 purple, 05 yellow, 06 white, 10 seven-color |
| Shining presets | `07 …` | Ten fixed presets: `07 06 01 00`, `07 01 08`, `07 01 13`, `07 03 01 00`, `07 09 00`, `07 09 01`, `07 0A 01`, `07 0A 02`, `07 01 01`, `07 02 00` — visual semantics unmapped |
| State query | `F0` | Reply on notify: `F0 FLAG SPEED` (FLAG 00/01 = power, SPEED = speed echo). Defined in the app but only logged — possibly unused |

### Notifications

The only device→app frame is the 3-byte `F0 FLAG SPEED` reply to the state query, delivered as
a notification on `0xFFF1` (enable via CCC `0x2902`; the app does this ~500 ms after connect).
There is no handshake or authentication sequence — you can write commands immediately after
connecting.

### Music mode

All signal processing happens on the phone: the app runs an FFT over microphone input (35 bins,
picks peaks per 11-bin third, maps to RGB) and streams `01 RR GG BB` writes. The shoe simply
displays the last colour it received, so a replacement app can drive "music mode" from any audio
pipeline — or any other live colour source.

## Open Questions

- Exact on-wire range and direction of the speed byte (`10 VV`): the app computes it as an
  inverted slider value with a default of 120, but the slider maximum wasn't recoverable from
  the decompiled code. Needs a live capture.
- Which visual effect each of the ten `07 …` shining presets produces.
- Whether the `F0` state query is actually sent in normal app use, and whether state
  notifications also arrive unsolicited.
- Full advertised device name (beyond the `FS` prefix) and MAC OUI — needs a hardware scan.

## Tools Used

- [x] APK static analysis (jadx) — `com.jtkj.auroraled` v1.0.1, unobfuscated, complete command table recovered
- [ ] HCI snoop / live capture (pending — speed range, shining presets, state query, advertised name)

## References

- [Aurora LED Shoes on Google Play](https://play.google.com/store/apps/details?id=com.jtkj.auroraled)
- [FastBle — the open-source BLE wrapper the vendor app is built on](https://github.com/Jasonchenlijian/FastBle)
- [CoolLED1248 on Google Play — sibling jtkj app, different BLE profile](https://play.google.com/store/apps/details?id=com.jtkj.led1248)

## Contributors

- Liberated Bread research — protocol recovery from app analysis
