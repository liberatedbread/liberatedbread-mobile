# Fisher-Price Lumalou (GLD09)

> **Status**: Spec Available
> **Protocol**: BLE
> **Manufacturer**: Fisher-Price (Mattel)
> **Manufacturer Status**: Shutdown (the Smart Connect app was delisted in March 2025 and its backend went dark in August 2025; the device itself is controlled locally)

## Overview

The Lumalou "Better Bedtime Routine System" is a cloud-shaped night light
for a child's room. It mounts on the wall. It has:

- a colour night light with ten presets, including rainbow
- a speaker with twelve lullabies and six sound loops (pink noise, ocean,
  rain, brown noise, nature, highway)
- a clock
- a sleep-trainer star: red means "stay in bed", green means "OK to wake"
- a strip of routine task icons: eight fixed tasks and three custom ones
- an infrared button remote that toggles soothing and checks off tasks

Most features were set up from the Fisher-Price Smart Connect app. The app
is gone, but it never used the cloud for control. Everything goes over a
local, encrypted BLE session, and any client in range can open one. No
per-device secret, no account and no bond are needed. The upstream
write-ups call the vendor's BLE stack "MPID", and this page does too.

Two independent open-source clients drive the unit today:
[stramanu/lumalou](https://github.com/stramanu/lumalou) (Python, TypeScript
and a web app) and [kvdb/gld09-control](https://github.com/kvdb/gld09-control)
(Python). Both authors report running them against real hardware. This spec
is built from their write-ups and source, the vendor manual and the vendor
FAQ. **This project has not run anything against a unit and holds no
capture.** Every protocol fact in the spec is `reported`, and the spec is
`untested`.

**Out of scope.** The Nordic DFU service on the same device: never write to
it. Other Smart Connect products are also out of scope. The upstream author
says the Bunny (`gmn58`) and Whisper (`ghp38`) share this generation's
handshake but not its commands, and nobody has tested them. The older
swings, mobiles, sleepers and soothers use a different protocol.

## Hardware

| Property | Value |
|----------|-------|
| Model Number | GLD09 (vendor app product code `gld09`, API level 1) |
| Chipset | Not confirmed. The Nordic legacy DFU service implies a Nordic nRF5 BLE module. The upstream write-up calls the part behind it the "toy IC" |
| Radio | BLE only. No Wi-Fi |
| Power | 5 V 1 A AC adapter (the unit draws 0.3 A max). The remote takes two AAA cells |
| Clock | Volatile: lost on any power cut |
| Firmware seen | `0.3.7` in the advertisement, on both open clients' units |
| FCC ID | None printed in the manual (Part 15 Class B and ISED text only). No GLD09 grant was found under Mattel's grantee code `PIY` |

## Initial Setup

| Property | Value |
|----------|-------|
| Setup required | No. Nothing is provisioned. The client should set the clock |
| Method | `ble_direct` |
| Setup AP / advertised name | The unit's ten-digit AP number (not "Lumalou"). Match manufacturer data instead: company `0x03B6` (Mattel) with payload starting `4d 42` ("MB") |
| Passphrase protection | not_applicable |
| Confidence | medium (two open clients, unreplayed here) |

To bring a unit up from a client:

1. Plug the unit in. The clock lights at once.
2. Close the Smart Connect app on any phone that still has it. The unit
   takes one central at a time.
3. Scan for manufacturer data company 950 (`0x03B6`) with a payload starting
   `4d 42`. Byte 3 of the payload should be `0x00` (idle). Bit 7 set means a
   central is already connected.
4. Connect, subscribe to `rx`, read the factory token, do the ECDH, write the
   session characteristic, and send `ENABLE_RX`. See the handshake below.
5. Send `SET_CURRENT_DATE` with local time. The manual says routines and the
   sleep trainer stay off until the clock is set after a power cut.

The vendor app's flow used the **pairing button** on the unit: open the app,
stand within about 6 ft (1.8 m), press the button, and wait for the clock to
update. The open clients do not press it, so it is not part of the protocol
a replacement client needs. It is kept in the spec as a `historical` method.

**Factory reset**: none is documented. The manual's only reset is a power
cycle: unplug the AC adapter for about 10 seconds and plug it back in. That
loses the time. Whether schedules, routines and the custom playlist survive
is not known. The spec lists the power cycle as `verified: false` with the
manual as its basis.

**Rebinding**: nothing binds the unit to a phone. A new controller just
connects once the old one lets go.

## Pairing

| Property | Value |
|----------|-------|
| Pairing required | No |
| Security mode | `none`. The MPID session is key agreement, not authorisation |
| Bonding | `none` |
| PIN source | None. The vendor FAQ warns that pairing from phone settings shows a PIN prompt; the app never needed one |
| One central at a time | Yes (vendor FAQ: "Someone else is already connected") |
| One bond at a time | Not applicable: no bond is made |
| Confidence | medium (vendor FAQ and two open clients) |

**Entering pairing mode**: not needed. The pairing button puts the unit in
operation mode 4 and sets bit 6 of the advertised state byte. That only
served the vendor app's own flow, which ended with a command whose arguments
are not documented (`SEND_PAIRING_COMPLETE`, `0x34`). Do not send it.

**Unpairing**: nothing to unpair.

**Recovery**: if the unit will not accept a connection, close the Smart
Connect app or the other client. The FAQ says to wait about 30 seconds after
that. If it still refuses, unplug the adapter for 10 seconds.

## Protocol Summary

### BLE Services

| UUID | Name | Description |
|------|------|-------------|
| `4cea0001-c678-4202-b5d3-712dbb5e5b14` | MPID control | The whole control surface. Not advertised |
| `00001530-1212-efde-1523-785feabcd123` | Nordic legacy DFU | Firmware update. **Never write to it**: the upstream author reports a wrong write bricks the unit |

| UUID | Name | Properties | Role |
|------|------|------------|------|
| `4cea0002-c678-4202-b5d3-712dbb5e5b14` | tx | write, write without response | Encrypted command frames, app to device |
| `4cea0003-c678-4202-b5d3-712dbb5e5b14` | rx | notify | Encrypted responses and events, device to app |
| `4cea0004-c678-4202-b5d3-712dbb5e5b14` | factory | read | 192-byte manufacturing token, cleartext |
| `4cea0005-c678-4202-b5d3-712dbb5e5b14` | session | write | App public key and nonce, once per connection |

### Advertising

Company `0x03B6` is "Mattel" in the Bluetooth SIG company list. The payload
after the company ID:

| Offset | Length | Field |
|--------|--------|-------|
| 0 | 2 | ASCII `MB` (`4d 42`) |
| 2 | 1 | Format byte, opaque |
| 3 | 1 | Connection state: bit 7 connected, bit 6 pairing, `0x00` idle |
| 4 | rest | Firmware version, ASCII (e.g. `0.3.7`) |

The local name is the unit's AP number, a ten-digit decimal string that also
sits inside the factory token's serial. The service UUID is not advertised.

### Factory token (`4cea0004`)

192 bytes, readable by anyone. Field map from kvdb/gld09-control:

| Offset | Length | Field |
|--------|--------|-------|
| 0 | 1 | Token version (10 on reported units) |
| 1 | 24 | ASCII serial. Bytes 7–16 are the AP number, bytes 19–24 the item number |
| 25 | 33 | Device P-256 public key, compressed |
| 58 | 5 | Not described |
| 63 | 2 | Machine ID |
| 65 | 3 | Manufacturing key ID, big-endian (12 on reported units) |
| 68 | 2 | Config table ID |
| 70 | 54 | Config table |
| 124 | 64 | ECDSA P-256 / SHA-256 signature over bytes 0–123, raw `r ‖ s` |
| 188 | 4 | Device salt (outside the signed part) |

A client may check the signature against the manufacturing public key the
vendor app carries for key ID 12. That key is not reproduced here. The open
clients carry it, and skipping the check still gives a working session. It
only drops the assurance that the peer is a genuine unit.

### Handshake (every connection)

1. Subscribe to `rx`.
2. Read the factory token. Take the device key from bytes 25–57 and the salt
   from the last four bytes.
3. Make an ephemeral P-256 key pair and 4 random bytes (the app nonce).
   `shared` = ECDH X coordinate, 32 bytes.
4. Stretch it. Start with `state = shared`. For each round `r` from 0 to 99,
   encrypt all 32 bytes of `state` in place with AES-128-CTR. The key is
   `state[0:16]`. The IV is `00 00 00 00 ‖ r (uint32 BE) ‖ 00 "mattel" 00`.
   The session key is `state[0:16]` after the last round. `"mattel"` is a
   fixed protocol constant, not a secret.
5. Write the 33-byte compressed app key and then the nonce (37 bytes) to
   `session`, with response. Wait about 400 ms.
6. Send `ENABLE_RX` (plaintext `01 50 01`) as the first encrypted frame. Until
   this is sent the unit only acknowledges requests. After it, the unit
   streams `CURRENT_DATE` about once a second. It also pushes `GLOBAL_STATE`
   and routine progress whenever something changes on the unit.

### Frames

A command is built in layers, then encrypted:

```
application command   opcode, args...
FE frame              fe | n | opcode, args... | x        n = 1 + len(args), x = n XOR every opcode/arg byte
route                 01 10 | FE frame                   (to the toy controller)
MPID frame            7e | seq u32 BE | len u16 BE | crc8(7 header bytes) | AES-128-CTR(plaintext | crc8(plaintext))
```

| Item | Value |
|------|-------|
| `len` | Plaintext length + 1 (the CRC byte) |
| IV, app to device | `seq ‖ app nonce ‖ device salt ‖ 00 00 00 00` |
| IV, device to app | `seq ‖ device salt ‖ app nonce ‖ 00 00 00 00`. Nonce and salt swap places |
| CRC-8 | Poly `0x07`, init `0xFF`, no reflection, no final XOR (check value `0xFB` over `123456789`) |
| Sequence | Starts at 1 for `ENABLE_RX`; +1 per frame |
| Spacing | About 150 ms between writes; the upstream author says the unit dislikes bursts |
| MTU | Frames reach 29 bytes, so an ATT MTU above 23 is needed. Common stacks negotiate one on their own |

On `rx`, application responses are `01 50 | FE frame` holding the response
opcode and data. Acknowledgements `00 7f 01 XX 00 00 00 00 00` and
`01 10 XX 00` carry no data. Match replies by opcode: the unit also pushes
state on its own. The spec's `protocol_details.mpid.test_vectors` has our
own vectors (invented keys) for every step. Both open clients reproduce
them.

### Commands

The spec declares each of these on `tx` as a template of the plaintext body.

| Opcode | Command | Arguments |
|--------|---------|-----------|
| `0x03` | Soothing on/off | 1 byte: 1 start, 0 stop |
| `0x3C` | Light colour (turns the light on) | 1 byte: 0 warm, 1 red, 2 yellow, 3 orange, 4 green, 5 blue, 6 purple, 7 night light, 8 cool, 9 rainbow |
| `0x3A` | Light brightness | 1 byte, 0–9 |
| `0x3E` | Light off | none |
| `0x6C` | Light timer | 1 byte: 0 15 min, 1 30, 2 60, 3 90, 4 continuous, 5 1 min |
| `0x3F` | Play sound | 1 byte: 0 sleep playlist, 1 custom playlist, 2 pink noise, 3 ocean, 4 rain, 5 brown noise, 6 nature, 7 highway |
| `0x38` | Sound off | none |
| `0x37` | Volume | 1 byte, 0–9 |
| `0x42` | Sound timer | 1 byte: 0 15 min, 1 30, 2 60, 3 90, 4 120, 5 continuous, 6 1 min |
| `0x40` | Custom playlist | 12 bytes: song IDs 1–12, 0 = empty slot |
| `0x30` | Set clock | 4 BCD bytes: hour, minute, second, weekday (0 = Sunday) |
| `0x79` | Clock settings | 2 bytes: display on/off; `brightness << 4 \| format` (0 = 12 h, 1 = 24 h) |
| `0x44` | Sleep trainer on/off | 1 byte |
| `0x48` / `0x46` | Bedtimes / wake times | 14 bytes: seven `[BCD hour, BCD minute]` pairs, Sunday first; `ff ff` = none |
| `0x4A` | Wake alarms | 4 bytes: seven nibbles Sunday first, then one trailing nibble. 0 at wake time, 1–8 = 15–120 min after, 9 none, 10 = 1 min after |
| `0x4D` | Start nap | 1 byte: 0 stop, 1–10 = 15, 30, 45, 60, 75, 90, 105, 120, 150, 180 min, 11 = 1 min |
| `0x58` | Routines on/off | 1 byte |
| `0x5A`–`0x66` (even) | Day routine, Sunday to Saturday | 14 bytes: start time (BCD, or `ff ff`) then 12 slots of `step << 4 \| task icon` |
| `0x69` | Routine music and reward sounds | 2 bytes: music on/off; `task reward << 4 \| routine reward` |
| `0x77` | Routine volume | 1 byte (range assumed 0–9) |
| `0x7B` | Start routine now | none |
| `0x6B` | Routine control | 1 byte: 0 complete task, 1 previous, 2 restart, 3 complete routine, 4 cancel |
| `0x53` | Request state | none. Reply `0x02` |
| `0x52` | Clock speed (test) | **Advanced.** 0 real time, 1 10×, 2 60×, 3 3600×. Always set it back to 0 |

Task icons: 1 change clothes, 2 wash up, 3 brush teeth, 4 go potty, 5 pack
bag, 6 eat, 7 read, 8 clean up, 9–11 the three custom tasks.

Requests with known reply layouts: current date (`0x31` → `0x13`), playlist
(`0x41` → `0x19`), clock settings (`0x7A` → `0x99`), bedtimes (`0x49` →
`0x23`), wake times (`0x47` → `0x22`), alarms (`0x4C` → `0x27`), day routines
(odd opcodes `0x5B`–`0x67` → `0x2B`–`0x2F`, `0x90`, `0x91`) and routine
progress (`0x68` → `0x94`). The spec lists every other known request and
response opcode in `protocol_details.opcodes`.

Left undeclared on purpose:

- `0x01` aggregate state setter: kvdb/gld09-control reports the unit applies
  only part of it.
- `0x4F` nap alarm: reported inert.
- `0x34` pairing complete: arguments unknown, listed unsafe upstream.

### GLOBAL_STATE (response `0x02`)

Thirteen bytes, read as 26 nibbles, high nibble first. The nibble number is
also the position in the reply's data.

| Nibble | Field | Values |
|--------|-------|--------|
| 0 | Operation mode | 0 soother, 2 daytime awake, 3 sleepy time, 4 pairing, 5 firmware update, 6 nap time, 7 routine |
| 1 | Activity state | Not established |
| 2 | Music status | Not established (likely playing / not) |
| 3–4 | Current song | 0 none, 1–12 lullabies, 13–18 sound loops |
| 5 | Volume | 0–9 |
| 6 | Sound timer | As command `0x42` |
| 7 | Light status | 0 off, 1 on |
| 8 | Light brightness | 0–9 |
| 9 | Light colour | As command `0x3C` |
| 10 | Nap status | Not established |
| 11 | Nap length | As command `0x4D` |
| 12 | Sleep trainer | 0 off, 1 on |
| 13 | Wake alarm status | Not established |
| 14 | Clock speed | As command `0x52` |
| 15 | Stage | 0 none, 1 ready, 2 settle, 3 sleep |
| 16 | Clock display | 0 off, 1 on |
| 17 | Clock brightness | 0–9 |
| 18 | Clock format | 0 12 h, 1 24 h |
| 19 | Routine music | Raw |
| 20 | Task reward sound | Raw |
| 21 | Routine reward sound | Raw |
| 22 | Light timer | As command `0x6C` |
| 23 | Routine volume | Raw |
| 24 | Routines | 0 off, 1 on |
| 25 | Alarm sounding | Not established |

GLOBAL_STATE is a runtime summary. It leaves out the playlist, schedules,
alarms and routines; read those with their own requests.

## Troubleshooting

- **No replies at all.** `ENABLE_RX` was not sent. The unit then only sends
  acknowledgement events.
- **Every notification fails its CRC.** The receive IV has the device salt
  first and the app nonce second, the mirror of the transmit IV. The other
  common mistake is using the raw ECDH secret instead of the 100-round
  stretch.
- **Routines and the star do nothing.** The clock was lost in a power cut.
  Send `SET_CURRENT_DATE`. kvdb/gld09-control also reports that the
  red-to-green cycle needs both a bedtime and a wake time. The green star only
  changes when an audible alarm is armed for that day. For a silent wake cue,
  that project uses a one-icon routine instead.
- **Routine icons disappear later in the day.** The unit clears a morning
  routine on its own, some hours after the start time. There is no command to
  clear or extend it (kvdb/gld09-control, observed).
- **Nap will not start.** kvdb/gld09-control reports a nap only starts with
  the sleep trainer on.
- **Upstream naming trap.** `spec/protocol.json` in stramanu/lumalou at
  `9fa5ecf` calls `0x68` `SET_ROUTINE_TASK_STATUS`. It is a request: send it
  without arguments and read reply `0x94`. PR #2 there corrects it.
- **Playlist rejected.** Song IDs above 12 are refused. The sound loops are
  played with `0x3F`, not queued in the playlist.

## Tools Used

- [x] stramanu/lumalou: protocol and reversing write-ups, the opcode JSON,
  the Python and TypeScript clients (main `9fa5ecf`), and unmerged PR #2
- [x] The upstream author's deployed web client bundle, for the schedule,
  alarm and routine argument layouts
- [x] kvdb/gld09-control (`6e3aff8`), an independent client tested on
  hardware by its author
- [x] The GLD09 owner's manual and Mattel's Smart Connect FAQ
- [x] Our own test vectors from invented keys, checked against both open
  clients
- [ ] A handshake and a `GLOBAL_STATE` read against a real unit:
  **still needed**

## References

- [Fisher-Price Lumalou GLD09 owner's manual (PDF, Mattel)](https://service.mattel.com/instruction_sheets/GLD09-0970-1102345604-DOM.pdf)
- [Mattel Smart Connect app FAQ (GLD09)](https://service.mattel.com/us/FAQ_Results.aspx?CatID=0&index=0&flag=0&siteid=27&prodno=GLD09)
- [stramanu/lumalou](https://github.com/stramanu/lumalou):
  [protocol.md](https://github.com/stramanu/lumalou/blob/main/docs/protocol.md),
  [reversing.md](https://github.com/stramanu/lumalou/blob/main/docs/reversing.md),
  [spec/protocol.json](https://github.com/stramanu/lumalou/blob/main/spec/protocol.json),
  [Python package](https://github.com/stramanu/lumalou/tree/main/packages/python/src/lumalou),
  [pull request #2](https://github.com/stramanu/lumalou/pull/2)
- [Lumalou web client](https://lumalou.emanuelestrazzullo.dev/)
- [kvdb/gld09-control](https://github.com/kvdb/gld09-control)
- [Bluetooth SIG assigned numbers (company identifiers)](https://www.bluetooth.com/specifications/assigned-numbers/)
- [Pairing, Bonding and Unpairing](../protocols/pairing.md)
- [Firmware Update (DFU / OTA)](../protocols/firmware-update.md)
- [Initial Device Setup](../protocols/device-setup.md)

## Contributors

- Claude Code agent: spec written from two open-source clients, their
  write-ups and the vendor manual and FAQ (no hardware)
