# LEGO Smart Play Smart Brick

> **Status**: Spec Available
> **Protocol**: BLE
> **Manufacturer**: LEGO
> **Manufacturer Status**: Active (LEGO sells the sets and runs the LEGO SMART Assist app; the protocol is undocumented)

## Overview

The SMART Brick is the 2x4 electronic brick at the centre of LEGO's SMART
Play system, launched in 2026. It has:

- a speaker and a sound synthesiser
- an LED array
- an accelerometer, colour and light sensing, and a microphone for sound
  pressure
- coils that charge it wirelessly, read SMART Tags and SMART Minifigures,
  and sense how far away other bricks are and which way they face

It plays on its own, with no phone. The LEGO SMART Assist app is for
grown-ups. It shows the battery level, registers the brick to a LEGO
account and installs firmware updates.

This page covers one mode only: the brick talking to a phone while it sits
on its SMART Charger. In that mode any BLE client can read the model,
firmware version, battery level and MAC, and can read and set the name and
the volume. None of that needs an account, a signature or pairing.
Registration, telemetry consent, factory reset and firmware updates are
different. Each one needs a signature that only LEGO's servers can make.

The spec is built from the
[node-smartplay](https://github.com/nathankellenicki/node-smartplay)
research notes and library. Its authors took the facts from Android HCI
captures of the vendor app, a decompile of that app and a disassembly of the
brick's firmware. The WDX part is checked against Arm's open-source Cordio
BLE stack, which the brick runs. **This project has not run anything against
a brick and holds no capture.** Every protocol fact in the spec is
`reported` or `hypothesis`, and the spec is `untested`. Upstream calls its
own notes incomplete and says some payloads are encrypted.

**Out of scope:**

- Brick-to-brick play. It uses Bluetooth 5.4 PAwR on a separate address,
  with its own internal registers.
- The WDX file-transfer channels (firmware images, fault log, telemetry).
- LEGO Powered Up, BOOST and SPIKE hubs. They speak LWP3, a different
  protocol.
- MINDSTORMS NXT and EV3, which are Bluetooth Classic.

SMART Tag events are not on the BLE surface at all. Upstream's firmware
analysis found no register or notification that reports a tag.

## Hardware

| Property | Value |
|----------|-------|
| Model Number | SMART Brick. Device Information reports manufacturer `LEGO`, model `Smart Brick`. It ships with a SMART Charger in the All-in-One sets (Star Wars 75421, 75423, 75427; Pokémon 72164, 72167) |
| Chipset | EM Microelectronic EM9305 BLE 5.4 SoC running the Arm Cordio stack, plus a custom LEGO mixed-signal ASIC for the coils, sensors, LEDs and sound (upstream, from teardown photos) |
| Radio | BLE only. It uses an LE random address that rotates often. The real MAC (OUI `9c:9a:c0`, LEGO System A/S) is in register `0x84` |
| Power | Rechargeable battery. It charges wirelessly on the SMART Charger, which takes up to two bricks. The charger's LED shows red, yellow or green for the battery level |
| Buttons | None. The brick wakes when shaken (LEGO's getting-started page) |
| Firmware seen | `2.29.2` in upstream's capture |
| FCC ID | `NPI106929` ("Smart brick", LEGO System A/S, granted 2025-12-10). Our manuals pass found this grant on fccid.co. We could not re-fetch the page while writing this, so treat the ID as unconfirmed |

## Initial Setup

| Property | Value |
|----------|-------|
| Setup required | No. Nothing is provisioned. The brick must have started up on its charger |
| Method | `ble_direct` (primary). The vendor app route is `cloud_account` |
| Setup AP / advertised name | `Smart Brick` (exact), company `0x0397` (LEGO), service `0xFEF6` |
| Passphrase protection | not_applicable |
| Confidence | medium (upstream captures and a published open client, not replayed here) |

**The one rule:** the brick accepts connections only if it **started up on
the SMART Charger**. Upstream's firmware analysis says the brick checks for
the dock once, at boot. Two dock types qualify. Nothing after that turns on
connectable advertising: not motion, not play, not a timer, and not setting
a running brick on the charger.

| How the brick started | What a scanner sees |
|---|---|
| On the charger | Connectable `Smart Brick` advertising with `0xFEF6` |
| Off the charger, single-brick content | Nothing |
| Off the charger, multi-brick content | `Smart Brick` advertising that cannot be connected, plus PAwR on another address |
| On the charger, then lifted off | Probably still connectable. Upstream infers this: the stack restarts advertising after each disconnect without checking the dock again |
| Firmware update | Its own update-mode advertising only |

To bring a brick up from a client:

1. Let the brick go to sleep, set it on a SMART Charger, and wake it there.
   LEGO's guide says a SMART Brick wakes when shaken. Nobody has documented
   whether setting a sleeping brick on the charger starts it by itself.
2. Close the SMART Assist app on any phone near by.
3. Scan for a *connectable* advertisement named exactly `Smart Brick` with
   manufacturer data under company `0x0397`. Service `0xFEF6` is advertised
   too, but every Cordio WDX product uses it. The address rotates, so do not
   store it.
4. Connect, open notifications in the vendor app's order, and run the
   handshake (see [Connection sequence](#connection-sequence)).
5. Keep polling about every 500 ms. Each poll reads `0x93`, sends the
   keepalive, and reads `0x20`.

**Factory reset**: there is one, but only through the app. Register `0x95`
resets the brick, and it acts only after a server-signed command of type 3
in the same connection. So the reset needs the SMART Assist app, signed in,
with the brick docked. No button or charger gesture is known. What the reset
clears (registration, name, volume, consent, bonds) is not documented. The
spec records the procedure as `verified: false`, with upstream's register
map as its `basis`.

**Rebinding**: there is no network to rejoin. The local surface belongs to
no phone, so any client can connect to a brick that started on the charger.
Moving a brick to a different LEGO account is a registration matter for the
app and LEGO's backend (ownership proof is signature-gated), not a BLE one.

## Pairing

| Property | Value |
|----------|-------|
| Pairing required | No |
| Security mode | `app_layer`. Link-layer pairing is not needed; privileged operations need an ECDSA signature |
| Bonding | `optional`. Reading register `0x86` makes the brick request pairing |
| PIN source | None |
| One central at a time | Unknown |
| One bond at a time | Unknown |
| Confidence | medium |

**Entering pairing mode**: here this means connectable mode, which is the
[one rule](#initial-setup) above: start the brick on the charger. The brick
shows no sign that it is connectable. The charger's LED shows the battery
level.

**Unpairing**: unknown. The stock WDX register set has a delete-bonds
register (`0x07`), but nobody has shown that LEGO implements it. Forgetting
the brick in the phone's Bluetooth settings drops the phone's half of any
bond.

**Recovery**: close the SMART Assist app. If a phone asks to pair out of
nowhere, something read register `0x86`. Nothing on the local surface needs
that register.

## Protocol Summary

### Advertising

| Field | Value |
|---|---|
| Local name | `Smart Brick` |
| Address | LE random, rotates often |
| AD flags | `0x06` (LE General Discoverable, BR/EDR not supported) |
| Service UUIDs | `0000fef6-0000-1000-8000-00805f9b34fb` (WDX; SIG member UUID of Wicentric, shared by every Cordio WDX product) |
| Manufacturer data | `97 03` (company `0x0397`, LEGO System A/S) then `00 60 00 00 00 00` in the one published capture. The meaning is unknown, so do not match on it |

### BLE Services

| UUID | Name | Description |
|------|------|-------------|
| `00001800-0000-1000-8000-00805f9b34fb` | Generic Access | Device Name `Smart Brick`, Appearance `0x0000` |
| `00001801-0000-1000-8000-00805f9b34fb` | Generic Attribute | Service Changed `00002a05-…` (the app subscribes to it) |
| `0000180a-0000-1000-8000-00805f9b34fb` | Device Information | Manufacturer `LEGO`, model `Smart Brick`, firmware and software revision (e.g. `2.29.2`) |
| `0000fef6-0000-1000-8000-00805f9b34fb` | WDX | Cordio's Wireless Data Exchange service; characteristics below |
| `005f0002-2ff2-4ed5-b045-4c7463617865` | Control Point | write + notify. **Every register read and write goes here.** This is Cordio's Device Configuration characteristic |
| `005f0003-2ff2-4ed5-b045-4c7463617865` | File transfer control | write without response + notify. Cordio's File Transfer Control. Not documented here |
| `005f0004-2ff2-4ed5-b045-4c7463617865` | File transfer data | write without response + notify. Cordio's File Transfer Data. Not documented here |
| `005f0005-2ff2-4ed5-b045-4c7463617865` | WDX authentication | write + notify. Idle in normal use. LEGO's signed commands use register `0x87` instead |
| `005f0001-3ff2-4ed5-b045-4c7463617865` | LEGO custom service | Purpose unknown |
| `005f0009-3ff2-4ed5-b045-4c7463617865` | Unknown input | write. Takes writes and shows no effect |
| `005f000a-3ff2-4ed5-b045-4c7463617865` | Unknown channel | read, write, notify. Sends empty notifications now and then |

The trailing bytes of the WDX base, `4c7463617865`, spell "exactLE"
backwards. That was the stack's name before it became Arm Cordio. The UUIDs
and properties of `0002`–`0005` match the open-source Cordio definitions
exactly.

### Register framing

Everything goes through the Control Point, written as an ATT Write Request.

| Frame | Bytes | Direction |
|---|---|---|
| Read | `01 RR` | client → brick |
| Write | `02 RR VV…` | client → brick |
| Reply / update | `03 RR VV…` | brick → client, by notification |

- A reply echoes the register it answers. Match replies to requests by
  register, and keep one request per register in flight.
- A reply has no status byte. If you need to know that a write took, read
  the register back.
- Do not count on a reply to a write. The keepalive gets none.
  node-smartplay waits for `03 81` after a volume write, but upstream shows
  no reply there, and the library does not wait after a name write.

These are Cordio's WDX get, set and update operations. Registers
`0x01`–`0x25` are the stock Cordio set; `0x80`–`0x96` are LEGO's.

### Register map

Sizes count value bytes only, without the `03 RR` header.

**Local surface (no signature):**

| Reg | Access | Value | Notes |
|---|---|---|---|
| `0x08` | read | uint16 LE | ATT MTU (`f4 00` = 244 in upstream's capture) |
| `0x20` | read | uint8 | Battery, 0–100 % |
| `0x21` | read | string, 18-byte field, null-terminated | Model identifier |
| `0x22` | read | 16 bytes ASCII, null-padded | Firmware version, e.g. `2.29.2` |
| `0x80` | read/write | up to 12 bytes UTF-8, null-padded | Brick name. The limit is 12 *bytes*, not characters |
| `0x81` | read/write | uint8 code | Volume: `0x0a` low (10), `0x28` medium (40), `0x64` high (100) |
| `0x84` | read | 6 bytes, most-significant first | Brick MAC, e.g. `9c 9a c0 dd ee ff`. **The stable identity** |
| `0x85` | read | uint8 code | Upgrade state: 0 ready, 1 in progress, 2 battery too low |
| `0x88` | read | 20 bytes | Firmware build fingerprint. Upstream found it the same on every brick it checked |
| `0x89` | read | uint8 code | Build pipeline stage (development, QA, staging or release). The number-to-stage mapping is unknown |
| `0x90` | write | `ea 00` | Keepalive. No reply |
| `0x93` | read | uint8 | Charging/connection state. Only `0xa1` has been reported; the bits are unknown |

**Needs a signature first:**

| Reg | Access | Role |
|---|---|---|
| `0x23` / `0x24` | write / read | Enter diagnostic mode / diagnostic mode complete |
| `0x25` | write | Disconnect and reset |
| `0x26` | write | Disconnect, arm the firmware update, reset (the last step of an update) |
| `0x91` | write | Ownership proof |
| `0x95` | write | Factory reset |

**Signed-command registers:** `0x86` (read, 8-byte nonce; reading it
triggers pairing) and `0x87` (write, 75 bytes). See
[Signed commands](#signed-commands).

**Stock WDX link registers:**

- `0x01`: ask for a connection-parameter update
- `0x02`: current connection parameters
- `0x03`: ask the brick to disconnect
- `0x04`: security level
- `0x05`: ask for link security
- `0x06`: service changed
- `0x07`: delete bonds
- `0x09`: ask for a PHY update
- `0x0a`: current PHY

**Not understood:**

- `0x82`: file-transfer write offset
- `0x83`: internal state
- `0x92`: one byte; upstream guesses it is tag-reader status
- `0x94`: upstream reads it as a hardware timer
- `0x96`: travel (shipping) mode. The payload and the effect are not
  documented, and the spec declares no command for it

### Connection sequence

This is the vendor app's sequence as upstream captured it.
node-smartplay follows it.

1. Open notifications in this order:
   1. `005f000a-3ff2-…`
   2. `005f0002-2ff2-…` (the Control Point)
   3. `005f0003-2ff2-…`
   4. `005f0004-2ff2-…`
   5. `005f0005-2ff2-…`
   6. `00002a05-…`

   **The first CCCD write to the Control Point may fail. Retry it after
   about 5 s.**
2. The brick may send `03 02 00 0c 00 00 00 f4 01` before any request.
   Upstream calls this frame an idle beacon.
3. Handshake reads (the app runs these four reads three times over):
   ```
   → 01 22    ← 03 22 "2.29.2" + nulls   firmware, 16 bytes
   → 01 81    ← 03 81 64                 volume high (100)
   → 01 84    ← 03 84 9c 9a c0 dd ee ff  MAC (placeholder after the OUI)
   → 01 80    ← 03 80 "Smart Brick"      name
   ```
4. Setup: send `02 90 ea 00` (the keepalive, no reply), then `01 08`. The
   reply `03 08 f4 00` is the MTU.
5. Poll every ~500 ms: `01 93` → `03 93 a1`, then `02 90 ea 00`, then
   `01 20` → `03 20 xx`.

Nobody has established whether the brick drops the link when the
keepalive stops.

**The idle beacon, a hypothesis.** The beacon has exactly the shape of the
connection-parameter update in the open-source Cordio WDX profile. Cordio
sends that update each time the link's parameters change (`wdxs_main.c`,
`wdxs_dc.c`). Read that way it decodes as:

- register `0x02`
- status 0
- connection interval `0x000c` × 1.25 ms = 15 ms
- latency 0
- supervision timeout `0x01f4` × 10 ms = 5 s

If this is right, the frame is the brick reporting the parameters the
central just negotiated, and it will come again whenever they change. Nobody
has confirmed it on a brick.

### Volume and name

```
→ 01 85        ← 03 85 00      upgrade state must be 0 (ready)
→ 02 81 0a                     volume low (0x28 medium, 0x64 high)
→ 01 81        ← 03 81 0a      confirm
```

```
→ 02 80 <1-12 bytes UTF-8, no terminator>
→ 01 80        ← 03 80 <name, null-padded>   confirm
```

### Signed commands

The privileged operations need an ECDSA P-256 challenge-response. The
brick checks the signature against a public key built into its firmware.
The matching private key exists only on LEGO's servers, and the app asks
LEGO's backend to sign for the signed-in owner. A replacement client cannot
make these signatures. This spec gives no way round that. It documents the
layout so an implementer recognises the exchange.

1. Read `0x86` → `03 86` + 8-byte nonce. The nonce is fresh on every
   connection. **This read makes the brick request link-layer pairing.**
2. message = nonce ‖ `02 02 01`; digest = SHA-256(message).
3. The signature is r ‖ s, 32 bytes each, big-endian, made with LEGO's key.
4. Write `02 87` + the 75-byte payload below.
5. The brick replies `03 87 01` (accepted) or `03 87 00` (rejected). The
   app then writes the operation's register.

| Offset | Length | Field |
|---|---|---|
| 0 | 8 | Nonce echo, exactly as read from `0x86` |
| 8 | 3 | `02 02 01` (the only value in published captures) |
| 11 | 32 | ECDSA r, big-endian |
| 43 | 32 | ECDSA s, big-endian |

Upstream lists four signed command types: 1 unlock, 2 telemetry consent,
3 factory reset and 4 start firmware upgrade. Nobody has shown whether the
last suffix byte carries the type.

Test vector for building the message (invented nonce):

- nonce `0123456789abcdef`
- message `0123456789abcdef020201`
- SHA-256 `5c8468499fbcba5e62727e9301ff46ec15ad99f4ba916376a81f1705b6592bf6`

The 77-byte write needs an ATT MTU of at least 80. Everything on the local
surface fits the default 23-byte MTU.

### Firmware updates

Updates come only through SMART Assist, with images from LEGO's backend.
Upstream gives an outline and says it inferred it from the decompiled app:

1. Check that `0x85` is 0.
2. Upload the image over the WDX file-transfer characteristics in chunks of
   at most 100 bytes.
3. Verify the image.
4. Write `0x26`, which disconnects, arms the update and resets the brick.

Starting an upgrade needs a signed command (type 4). The image header has a
signature field. No update bytes appear in the spec, and a client should
never interrupt an update in progress. The spec records this as a
`firmware_update` feature, `vendor_ble`, `in_place`.

## Troubleshooting

- **A "Smart Brick" is in the scan but will not connect.** The brick
  started off the charger, or it is in multi-brick play. It checks for the
  dock only at boot. Let it sleep and restart it on the charger.
- **No "Smart Brick" at all.** The brick is asleep, or it started off the
  charger with single-brick content, which does not advertise. It could also
  be mid-update, which uses a different advertisement.
- **Enabling notifications on the Control Point fails.** Upstream saw the
  first CCCD write fail. Wait about 5 s and try again.
- **The phone suddenly asks to pair.** Something read `0x86`. The local
  surface never needs it.
- **Volume will not change.** `0x85` was not 0: an update is running (1) or
  the battery is low (2). The only levels known are 10, 40 and 100.
- **A reply "never arrives" after a write.** Many writes get no reply. Read
  the register back instead of waiting.
- **Replies arrive in the wrong order.** The unprompted `03 02 …` frame can
  come first. Match replies by register byte.

## Tools Used

- [x] node-smartplay research notes (`PROTOCOL.md`, `FIRMWARE.md`,
  `FILE_TRANSFER.md`, `BACKEND.md`, `HARDWARE.md`, main `5b46706`)
- [x] node-smartplay 1.0.0 library source
- [x] Arm/Packetcraft Cordio WDX profile source (`wdx_defs.h`,
  `wdxs_dc.c`, `wdxs_main.c`, `svc_wdxs.c`)
- [x] Bluetooth SIG assigned numbers and the IEEE OUI registry
- [x] LEGO's SMART Play web pages (archived copies)
- [ ] A connection to a real brick started on the charger: handshake,
  `0x20` and `0x84` reads. **Still needed**
- [ ] A capture showing whether the `03 02 …` frame recurs when connection
  parameters change

## References

- [LEGO: Tips for getting started with SMART Play sets (archived)](https://web.archive.org/web/20260406021009/https://www.lego.com/en-us/smart-play/getting-started).
  LEGO publishes no PDF manual for the brick.
- [node-smartplay](https://github.com/nathankellenicki/node-smartplay):
  - [PROTOCOL.md](https://github.com/nathankellenicki/node-smartplay/blob/main/research/notes/PROTOCOL.md)
  - [FILE_TRANSFER.md](https://github.com/nathankellenicki/node-smartplay/blob/main/research/notes/FILE_TRANSFER.md)
  - [HARDWARE.md](https://github.com/nathankellenicki/node-smartplay/blob/main/research/notes/HARDWARE.md)
  - [smart-brick.ts](https://github.com/nathankellenicki/node-smartplay/blob/main/src/devices/smart-brick.ts)
- Cordio WDX:
  - [wdx_defs.h](https://github.com/packetcraft-inc/stacks/blob/master/ble-profiles/sources/profiles/include/wdx_defs.h)
  - [wdxs_dc.c](https://github.com/packetcraft-inc/stacks/blob/master/ble-profiles/sources/profiles/wdxs/wdxs_dc.c)
  - [wdxs_main.c](https://github.com/packetcraft-inc/stacks/blob/master/ble-profiles/sources/profiles/wdxs/wdxs_main.c)
- [Bluetooth SIG assigned numbers](https://www.bluetooth.com/specifications/assigned-numbers/)
- [Pairing, Bonding and Unpairing](../protocols/pairing.md)
- [Firmware Update (DFU / OTA)](../protocols/firmware-update.md)
- [Initial Device Setup](../protocols/device-setup.md)

## Contributors

- Claude Code agent: spec written from the node-smartplay research notes
  and library and the open-source Cordio WDX profile (no hardware, no
  capture)
