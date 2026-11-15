# Acaia Coffee Scales (Pearl / Lunar / Pyxis)

> **Status**: Spec Available (open implementations cross-checked against a static read of the delisted vendor app; no capture, not run against hardware)
> **Protocol**: BLE
> **Manufacturer**: Acaia
> **Manufacturer Status**: Active (the Acaia Coffee app this spec was checked against is delisted from Google Play; Acaia ships newer apps)

## Overview

Acaia's Bluetooth coffee scales (Pearl, Lunar, Pearl S, Pyxis, and the
Cinco the vendor app also knows) stream weight, a timer and battery level to
a phone. They also take tare, timer and a few settings writes back. All of
it runs over BLE GATT from the phone straight to the scale. There is no
Wi-Fi, no LAN and no cloud path for any scale function. The vendor apps'
servers only ever held recipes and social content, so losing them costs a
client nothing it needs.

The wire protocol is a small framed stream: `0xef 0xdd`, a command id, a
payload and a two-byte checksum. The same framing runs on two different
GATT attribute sets, so this page keeps two things apart:

- **Which attribute set** carries the frames. Newer scales use a
  Microchip/ISSC BM70/BM71 transparent-UART module. Older ones expose a
  single read/write characteristic, `00002a80-0000-1000-8000-00805f9b34fb`.
- **Which framing** is spoken. Every client that works (pyacaia,
  AcaiaArduinoBLE, Beanconqueror, and the vendor app itself) speaks the
  framed protocol described here on *both* sets. The vendor app also
  carries an older, obfuscated framing with a smaller command set, but it
  never selects it. That older framing is described in
  [First-generation material](#first-generation-material) so the next person
  recognises it.

The one thing that trips up every reimplementation is the **keep-alive**. A
client has to write a heartbeat frame every few seconds for as long as it
wants weight, or the scale stops streaming.

The machine-readable spec is
[`device-specs/devices/acaia-coffee-scale.yaml`](https://github.com/liberatedbread/liberatedbread-protocol-specs/blob/main/device-specs/devices/acaia-coffee-scale.yaml).
Everything in it is `verification: reported`. The checksum rule, the
handshake frames and the weight layout come from
[pyacaia](https://github.com/lucapinello/pyacaia) and
[AcaiaArduinoBLE](https://github.com/tatemazer/AcaiaArduinoBLE), whose
authors ran them against real scales. A static read of the delisted vendor
app (Acaia Coffee for Android, 2.5.10) was used to check those and to fill in
the tables no open implementation carries: the per-command payload lengths,
result codes, settings items and the handshake timing. This project has not
connected to a scale.

**In scope:** Acaia BLE coffee scales on either attribute set: discovery,
the identify / event-subscription / heartbeat handshake, weight, battery
and timer notifications, tare and timer commands, and the settings writes
the vendor app makes (marked partial).

**Out of scope:**

- **Firmware update.** The ISP command (9), the file-transfer command (14)
  and the module's air-patch characteristic are described by role only,
  with no payload bytes, because a wrong or partial update can leave a scale
  unusable.
- **The link password** (command 15). Role only, for the same reason: a
  scale locked with a forgotten password may not be recoverable.
- **Other brands.** Felicita scales speak a different protocol. Bookoo
  publishes its own
  [official BLE protocol](https://github.com/BooKooCode/OpenSource) and is
  only linked here.
- **Acaia's newer apps and cloud services**, and its binary SDKs.

## Hardware

| Property | Value |
|----------|-------|
| Model Number | Pearl (original) AP001AT / AP004AT; Pearl 2021 AP007 / AP008 / AP009; Lunar (original) AL001 / AL006 / AL007; Lunar 2021 AL008 / AL009 / AL010 / AL012 / AL013; Pearl S PS001 / PS002; Pearl S 2022 PS003 / PS004; Pyxis (2019) AC002; Pyxis Black APS001 (all from Acaia's manuals) |
| Chipset | Newer scales: Microchip/ISSC BM70/BM71 transparent-UART module (its stock service UUID). Older scales: a UART bridge behind service `00001820-0000-1000-8000-00805f9b34fb`; the vendor app's naming for that pair points to a CSR (Cambridge Silicon Radio) part (inferred only) |
| Radio | Bluetooth 4.0 (original Pearl, original Lunar, original Pearl S, 2019 Pyxis); Bluetooth 5.0 (Pearl 2021, Lunar 2021, Pearl S 2022); Bluetooth 5.4 (Pyxis Black), per the manuals |
| Power | Built-in rechargeable battery; Micro-USB on the older models, USB-C (PD) on the 2021/2022 models and the Pyxis Black |
| Advertised name | Starts with `ACAIA`, `PROCH`, `LUNAR`, `PEARL`, `PYXIS`, `CINCO` or `INFOS` (the union of the vendor app's and the open implementations' filters) |
| FCC ID | None found. No manual prints one and no Acaia grantee turns up on the FCC ID aggregators; the scales probably rely on the radio module's modular grant |

## Initial Setup

| Property | Value |
|----------|-------|
| Setup required | No |
| Method | `ble_direct` |
| Setup AP / advertised name | Name prefixes above; no advertised service UUID is relied on |
| Passphrase protection | not_applicable |
| Confidence | medium (three independent open implementations connect this way; not run here) |

There is nothing to provision: no account, no Wi-Fi, no bond. A scale with
Bluetooth enabled in its settings menu (the default) advertises while it is
on and accepts a connection from any central. Every connection runs the
same steps:

1. Turn the scale on. If it does not appear, check that Bluetooth is On in
   its settings menu (`bt_SEt` on the LED models, "Bluetooth Setting" on the
   Pearl S) and that no other phone or the vendor app is connected.
2. Scan for a local name starting with one of the prefixes above and
   connect.
3. Request an ATT MTU of 247. The vendor app does this on the ISSC module
   before discovery, and pyacaia notes the Pyxis needs it for its longer
   notifications.
4. Discover services and pick the attribute set by what is there (see
   [Attribute sets](#attribute-sets)). Probing the GATT table is more
   reliable than going by name or model year.
5. Enable notifications on the notify characteristic.
6. Write the **identify** frame, then the **event-subscription** frame.
7. Write the **heartbeat** frame straight away, and then at least every
   3 s for as long as the session should last.

The frames are in [Session](#session). The vendor app's own timing is
recorded in the spec's `setup.methods[0].timing` block.

**Factory reset**: the scale's own settings menu has a **Reset to Default**
item (`rESEt.d` on the LED models). It returns the settings (sleep timer,
beep, unit, resolution, modes, Bluetooth on/off) to factory defaults. The
scale holds no bond, so there is nothing Bluetooth-related to clear.
Whether it clears a link password set with command 15 is not established.
From the manuals, not performed here:

- **Lunar, Lunar 2021, Pyxis (2019), Pearl 2021, Pearl S:** with the scale
  off, hold Power until the display shows `ACAIA` and then `SEt`
  ("Settings" on the 2022 Pearl S), and release. Tap Tare to enter Settings,
  then tap Tare to step to `rESEt.d`. Hold Tare to open it, tap Tare to
  choose YES, and hold Tare for about 1 s to save. Tap Power to leave
  (double-tap on the Pearl S).
- **Original Pearl (FW 2.0.x):** the settings menu sits behind a passcode.
  With the scale off, hold Power; when `ACAIA` and then `SEt` show, keep
  holding and tap Tare. Release at `F.0000`, then hold Tare four times to
  accept the default passcode `0000` and step through the digits. Then
  reset as above and double-tap Power to leave. The 1.8.x firmware has no
  reset item.
- **Pyxis Black (APS001):** a different menu. Hold Power through the
  countdown and release on SETTINGS, step to RESET TO DEFAULT with Tare,
  hold Tare, choose YES, hold Tare to save, and hold Power to leave. Whether
  this model speaks the protocol on this page at all is not established.

**Rebinding**: nothing binds a scale to a phone. Close the vendor app (or
disconnect any other client) and connect from the new one.

## Pairing

| Property | Value |
|----------|-------|
| Pairing required | No |
| Security mode | `none` |
| Bonding | `none` |
| PIN source | Not applicable at the link layer. The optional application-layer link password (command 15) is not documented here |
| One central at a time | Yes (Acaia's help centre calls the scale-to-app link one-to-one) |
| One bond at a time | No (nothing is bonded) |
| Confidence | medium |

**Entering pairing mode**: not needed. The scale is connectable whenever it
is on and Bluetooth is enabled in its settings. There is no pairing button.

The vendor app connects with a plain GATT connection and never creates a
bond, and pyacaia, AcaiaArduinoBLE and Beanconqueror do the same. The
identify frame is an application-layer hello with a fixed payload, not
authentication.

**Unpairing**: there is no bond to drop.

**Recovery**: close the vendor app on this phone and on any other phone
nearby, or disconnect any other client. If the scale still does not
advertise, power-cycle it.

## Protocol Summary

### Attribute sets

| Set | Service | Client writes to | Client subscribes to | Who has it |
|-----|---------|------------------|----------------------|------------|
| ISSC transparent UART | `49535343-fe7d-4ae5-8fa9-9fafd205e455` | `49535343-8841-43f4-a8d4-ecbe34729bb3` (the module vendor's "Transparent UART RX") | `49535343-1e4d-4bd9-ba61-23c647249616` ("Transparent UART TX") | Pyxis, Pearl S, Cinco, and scales advertising `PEARL-` or `LUNAR-` |
| First-generation | `00001820-0000-1000-8000-00805f9b34fb` | `00002a80-0000-1000-8000-00805f9b34fb` | `00002a80-0000-1000-8000-00805f9b34fb` (same characteristic) | Pre-2021 Lunar and the original Pearl, and at least some 2021 Lunar builds (AcaiaArduinoBLE sees a Lunar 2021, model AL008, on this set) |

**Direction on the ISSC module.** The client **writes** frames to
`49535343-8841-43f4-a8d4-ecbe34729bb3` and **receives** notifications on
`49535343-1e4d-4bd9-ba61-23c647249616`. Some write-ups label these the other
way round. The vendor app, pyacaia and AcaiaArduinoBLE all write `8841` and
subscribe to `1e4d`.

The vendor app picks the set by advertised name: `CINCO`, `PEARLS`, `PYXIS`,
`PEARL-` and `LUNAR-` go to the ISSC module, and everything else to
`0x1820`. The open implementations probe the GATT table instead, which is
what a new client should do: if `8841` and `1e4d` exist, use them;
otherwise use `2a80` for both directions.

`0x1820` and `0x2a80` are Bluetooth SIG numbers (Internet Protocol Support
service, Age characteristic) reused for a UART bridge, so generic GATT
browsers mislabel them. Other products reuse the pair too: the Fellow Stagg
EKG+ kettle also sits on `0x1820` with a `0xef 0xdd` delimiter. Check the
name before treating a `0x1820` device as a scale.

### BLE Services

| UUID | Name | Description |
|------|------|-------------|
| `49535343-fe7d-4ae5-8fa9-9fafd205e455` | ISSC Transparent UART | The module vendor's stock service, so it marks the radio module, not an Acaia product. Carries the framed protocol |
| `00001820-0000-1000-8000-00805f9b34fb` | First-generation data service | One characteristic, `00002a80-0000-1000-8000-00805f9b34fb`, for both directions. Carries the same framed protocol |

The ISSC service has three more characteristics that the vendor app looks
up but never reads or writes. Leave them alone:

| UUID | Role |
|------|------|
| `49535343-6daa-4d02-abf6-19569aca69fe` | Connection parameters |
| `49535343-4c8a-39b3-2f49-511cff073b7e` | Transparent-UART control point |
| `49535343-aca3-481c-91ec-d85e28a60318` | The module's air-patch / ISP path, part of the firmware-update route |

### Frame

One layout in both directions and on both attribute sets:

| Offset | Length | Field |
|--------|--------|-------|
| 0 | 2 | Header `ef dd` |
| 2 | 1 | Command id (see [Command ids](#command-ids)) |
| 3 | n | Payload. Fixed length per command id, or variable: then the first payload byte is a length that **counts itself** |
| 3 + n | 1 | Checksum A: sum of payload bytes at even offsets (0, 2, 4 …), mod 256 |
| 4 + n | 1 | Checksum B: sum of payload bytes at odd offsets (1, 3, 5 …), mod 256 |

The header and the command id are not summed. For example, a lone weight
event is a variable-length frame whose payload starts `08 05`: 8 payload
bytes including the length byte itself, so the whole frame is 13 bytes.

The schema has no checksum role for two interleaved sums, so every command
in the spec is a precomputed `value`. The settings writes are the exception:
their checksum reduces to copies of their own bytes, so they are templates.

**Receiving.** Treat notifications as a byte stream, not as one frame each.
Frames can arrive split across notifications (pre-2021 Lunar firmware sends
the header and command id separately from the rest) or several to one
notification.

1. Search for `ef dd` and discard anything before it.
2. Read the command id and look up its payload length. If it is variable,
   the next byte is the length n.
3. Wait until 5 + n bytes are buffered, check both checksum bytes, then
   dispatch.
4. The vendor app pads its own writes with zeros to 21 bytes, so the scale
   evidently skips bytes until the next `ef dd`. Send exact lengths anyway.

### Command ids

The 18 command ids. "Variable" means the first payload byte is a length that
counts itself.

| Id | Role | Direction | Payload | Notes |
|----|------|-----------|---------|-------|
| 0 | System message | both | variable | The heartbeat is `02 00` (length 2, message 0 = alive). Message codes: 0 alive, 1 ack, 2 Bluetooth message |
| 1 | String message | both | variable | Types 0 error, 1 warning, 2 ok, 3 debug. The vendor app ignores incoming ones |
| 2 | Battery | to scale | 1 | Not sent by the vendor app |
| 3 | Weight | to scale | 2 | Not sent by the vendor app |
| 4 | Tare | to scale | 1 | Payload `00` |
| 5 | Custom | both | variable | Not sent by the vendor app |
| 6 | Status request | to scale | 1 | Payload `00`; the scale answers with command 8 |
| 7 | Info | to app | variable | The scale identifies itself (ISP and firmware version numbers; field order not established). The vendor app answers with identify |
| 8 | Status report | to app | variable | See [Status frame](#status-frame) |
| 9 | ISP (firmware update) | to scale | 15 | **Advanced; role only.** Can leave the scale unusable |
| 10 | Setting change | to scale | 3 | `00`, item, value. See [Settings](#settings-partial) |
| 11 | Identify | to scale | 15 | 15 ASCII bytes |
| 12 | Event | both | variable | To the scale: a subscription. From the scale: weight, battery, timer, key, setting, countdown and ack reports |
| 13 | Timer | to scale | 2 | `00`, action: 0 start, 1 stop and zero, 2 pause (hold), 3 start on weight |
| 14 | File transfer | to scale | variable | **Advanced; role only.** Believed to carry firmware images alongside ISP |
| 15 | Set link password | to scale | 15 | **Advanced; role only.** Locks the scale behind a password; ack results report success or failure |
| 16 | Piece-count weight | to scale | variable | Not sent by the vendor app |
| 17 | Pre-tare | to scale | variable | Not sent by the vendor app |

### Session

| Frame | Bytes | When |
|-------|-------|------|
| Identify, digit form | `ef dd 0b 30 31 32 33 34 35 36 37 38 39 30 31 32 33 34 9a 6d` | After subscribing. The vendor app's form on the ISSC module, and AcaiaArduinoBLE's for every scale |
| Identify, dash form | `ef dd 0b 2d 2d 2d 2d 2d 2d 2d 2d 2d 2d 2d 2d 2d 2d 2d 68 3b` | pyacaia's form for the `2a80` scales. The vendor app sends it in reply to the scale's info message (command 7) |
| Event subscription | `ef dd 0c 09 00 01 01 02 02 05 03 04 15 06` | After identify. pyacaia's and AcaiaArduinoBLE's form |
| Event subscription, vendor-app form | `ef dd 0c 09 00 01 01 02 02 01 03 04 11 06` | The same with a timer argument of 1. The vendor app sends it once, after the first status frame |
| Heartbeat | `ef dd 00 02 00 02 00` | Immediately, then at least every 3 s |
| Status request | `ef dd 06 00 00 00` | Optional. The vendor app sends it 200 ms after each heartbeat |

The subscription payload is a length (9) and then pairs of event type and
argument: weight (argument 1), battery (argument 2), timer (argument 5),
then key and setting with no argument. pyacaia calls the timer argument the
number of heartbeats between timer messages. Otherwise the arguments' meaning
is not established.

Which identify string the scale expects, if it checks at all, is not
established. Both forms work on the scales the open implementations were
tested on.

**Keep-alive timing.** Every working client keeps the heartbeat going:

| Client | Heartbeat interval | Treats the link as lost after |
|--------|--------------------|-------------------------------|
| Vendor app | 3 s (first beat 2 s after its protocol handler starts), each followed by a status request 200 ms later | 1.5 s with nothing received, checked when it is about to write |
| AcaiaArduinoBLE | 2.75 s | 5 s without a weight frame |
| pyacaia | 1 s on bluepy, 5 s on pygatt | — |

How long the scale itself waits before it stops streaming or drops the link
is not established. The spec recommends a 2 s interval, well inside every
figure above. pyacaia's comments say a newer official app sends identify,
heartbeat and a status request together once a second to the Pyxis, and
Beanconqueror likewise re-sends identify with each heartbeat on the ISSC
module.

### Events

Command 12 from the scale carries one or more events after its length byte.
Each is a type byte and that type's fixed-size data. Read events until the
length is used up.

| Type | Event | Data bytes | Notes |
|------|-------|------------|-------|
| 5 | Weight | 6 | See [Weight event](#weight-event) |
| 6 | Battery | 1 | Percent, 0–100 |
| 7 | Timer | 3 | Minutes, seconds, tenths of a second: value = min × 60 + s + tenths ÷ 10 |
| 8 | Key | 1 | Which button action happened (below); usually followed in the same frame by a weight and/or timer event |
| 9 | Setting | 2 | Not decoded |
| 10 | Countdown | 3 | Not decoded |
| 11 | Ack | 2 | Ack id, then a result byte (bits 0–4 result type, bits 5–7 result value). Often followed in the same frame by a weight or timer event; pyacaia calls this the heartbeat response |

Types 0–4 are the subscription side: weight, battery and timer take a
one-byte argument, key and setting take none.

**Key ids** (data byte of a key event): 0 tare, 1 ISP mode, 2 weighing
mode, 3 timer-and-weight mode, 4 timer mode, 5 kg, 6 lb, 7 oz, 8 timer
start, 9 timer stop (zero), 10 timer pause, 11–13 countdown start, stop and
pause. pyacaia and Beanconqueror call 9 "reset" and 10 "stop".

**Ack results.** Result type 0 is a command result: 0 weight command ok,
1 battery command ok, 2 set password ok, 3 set password failed, 4 tare
done, 5 ISP ok, 6 ISP failed, 7 alive (keep-alive acknowledged). Result type
1 is a timer result: 0 start, 1 pause, 2 stop, 3 start on weight. Types 2–6
report unit, sleep, key disable, resolution and capacity. The vendor app
only looks for type 0 with value 7.

### Weight event

Six data bytes after the event type `05`:

| Offset | Length | Field | Encoding |
|--------|--------|-------|----------|
| 0 | 4 | Magnitude | uint32, little-endian |
| 4 | 1 | Decimal places | 1–4: value = magnitude ÷ 10^decimal places |
| 5 | 1 | Flags | bit 0: 1 = unstable; bit 1: 1 = negative; bits 2–7: weight type (0 net, 1 not established, 2 tare) |

`weight = (−1 if flags & 0x02 else 1) × magnitude ÷ 10^decimal_places`, in
the scale's current unit (grams unless the status frame reports ounces).

A whole notification that holds exactly one weight event, as the Pyxis
sends, looks like this:

| Offset | Field |
|--------|-------|
| 0–1 | `ef dd` |
| 2 | `0c` (event) |
| 3 | `08` (length) |
| 4 | `05` (weight event) |
| 5–8 | Magnitude, uint32 LE |
| 9 | Decimal places |
| 10 | Flags |
| 11–12 | Checksum |

Newer Lunar firmware sends 17-byte notifications that start the same way.
Do not rely on fixed offsets on the `2a80` scales, whose frames arrive
split.

The sign bit is fixed by every open implementation testing `0x02`. The
stable flag's position follows from the vendor app declaring the fields in
the order stable, sign, type with least-significant-bit-first packing; no
open implementation reads it.

### Status frame

Command 8, variable length. The vendor app decodes the first nine payload
bytes. pyacaia and Beanconqueror index up to payload byte 9, so some
firmware sends at least ten.

| Payload offset | Field | Encoding |
|----------------|-------|----------|
| 0 | Length | Counts itself |
| 1 | Battery | bits 0–6, percent. Bit 7: timer running (polarity not established) |
| 2 | Unit | bits 0–6: 2 = g, 5 = oz. Bit 7: countdown running |
| 3 | Scale mode | bits 0–6. Bit 7: tare flag |
| 4 | Sleep timer | Index: 0 off, 1 = 5 min, 2 = 10 min, 3 = 20 min, 4 = 30 min, 5 = 60 min |
| 5 | Key disable | Seconds |
| 6 | Beep | 0 off, 1 on |
| 7 | Resolution | Only 0 = default is named |
| 8 | Capacity | 0 = 1000 g, 1 = 2000 g |

The vendor app's unit table also names 0 off, 1 kg, 3 lb, 4 ct and more
(troy ounce, grain, piece count, percent), but it only ever offers grams and
ounces.

### Commands

| Command | Bytes |
|---------|-------|
| Tare | `ef dd 04 00 00 00` |
| Timer start (or resume) | `ef dd 0d 00 00 00 00` |
| Timer stop and zero (pyacaia and AcaiaArduinoBLE call this "reset") | `ef dd 0d 00 01 00 01` |
| Timer pause, holding its value (pyacaia and AcaiaArduinoBLE call this "stop") | `ef dd 0d 00 02 00 02` |
| Status request | `ef dd 06 00 00 00` |

### Settings (partial)

Command 10 with payload `00`, item, value. Because the first payload byte is
zero, the checksum is simply value then item, so a setting write is
`ef dd 0a 00 <item> <value> <value> <item>`.

| Item | Setting | Values |
|------|---------|--------|
| 0 | Unit | 2 grams, 5 ounces |
| 1 | Sleep timer | Index 0 off, 1 = 5 min, 2 = 10 min, 3 = 20 min, 4 = 30 min, 5 = 60 min |
| 2 | Key disable | Seconds, 0 re-enables. The vendor app's toggle sends 60 or 0 |
| 3 | Resolution | Only 0 = default is named. Not declared as a command |
| 4 | Capacity | 0 = 1000 g, 1 = 2000 g (from the Pearl era) |
| 5 | Beep | 0 off, 1 on |

These are the vendor app's item and value tables, and the index values match
the option sets the manuals print. They are **partial**: only the items the
app offers are named, what the newer scales do with each write is not
established, and resolution has no value table. The Pyxis Black's manual
lists different sleep options (10, 20, 30, 50 min, off), so the sleep indices
are at least suspect on it.

### Test vectors

The checksum vectors are real frames pyacaia and AcaiaArduinoBLE send. The
event frames are **constructed** from the layouts above, not captured.

| Frame | Meaning |
|-------|---------|
| `ef dd 0a 00 00 05 05 00` | Set unit to ounces |
| `ef dd 0c 08 05 d2 04 00 00 01 00 db 09` | Weight 123.4, stable, net |
| `ef dd 0c 08 05 34 00 00 00 01 02 3d 07` | Weight −5.2, stable |
| `ef dd 0c 08 05 39 30 00 00 02 00 43 35` | Weight 123.45 (two decimals, as a Pyxis sends) |
| `ef dd 0c 05 07 01 05 03 09 0c` | Timer 1 min 5.3 s = 65.3 s |
| `ef dd 0c 03 06 55 58 06` | Battery 85 % |

### First-generation material

Two different things carry the "first generation" label, and they are not
the same:

1. **The `0x1820` / `0x2a80` attribute set.** The older scales still expose
   it, and in the vendor app and in every open implementation it carries the
   **framed protocol above**. A client for a pre-2021 Lunar or a Pearl should
   start there. On this set the vendor app subscribes 500 ms after service
   discovery, writes without response, and sends identify only in reply to
   the scale's info message; pyacaia writes identify and the subscription
   straight after subscribing.
2. **An older, obfuscated framing** with its own smaller command set. The
   vendor app files it beside the `0x1820` attribute names and keeps a slot
   for it, but always asks for the framed protocol, so this build never
   uses it. Which hardware, if any, still speaks it is not established. It
   is recorded so the next person recognises it, not so a client implements
   it.

The older framing's frame starts `df 78`, then a length (payload length
+ 5), the command, a counter byte (the app pins it to 1), a zero byte and
the payload length. The payload goes through a 256-entry byte-substitution
table after the counter is added to each byte. An 8-bit sum of the bytes
from the command through the encoded payload follows, then `00`. The
substitution table is its obfuscation key and is not reproduced here.

| Id | Command (older framing) |
|----|-------------------------|
| 0 | none |
| 1 | string |
| 2 | battery request (empty payload) |
| 3 | battery reply (1 byte) |
| 4 | weight request (3 bytes) |
| 5 | weight reply (7 bytes) |
| 6 | weight reply, long form (12 bytes) |
| 7 | tare (6 bytes) |
| 8 | sound (3 bytes) |
| 9 | sound on/off (1 byte) |
| 10 | light on (2 bytes) |
| 11 | file |
| 12 | custom (sub-command in the first payload byte) |
| 13–15 | info request, info reply (4 bytes), ISP / firmware (advanced; role only). These three appear only in a second copy of the table inside the older parser |

The custom sub-commands cover key (tare, zero), unit, setting set/read/reply,
timer start/pause/stop/read/reply, A/D read/reply and countdown
start/pause/stop/read/reply. The full table is in the spec's
`protocol_details.first_generation`.

### Firmware update and the link password

Both are described by role only, and both are marked `advanced` in the
spec.

- **Firmware update.** Owners update with Acaia's separate updater apps
  (Pearl Updater for the original Pearl, Acaia Updater for every other
  model), which fetch the image themselves. The app examined carries no
  firmware image and no firmware URL. Newer models switch to update mode
  when the updater asks, which implies an entry command this spec does not
  have; the Lunar 2021 then waits for a tap of Tare on its `Confirm?`
  prompt. Every model also documents a button route (for newer models,
  holding Power while plugging in USB). In update mode the display shows
  `UPdAtE` (`UPDATE` on the Pearl S, `ISP` on Pearl firmware 1.3 and older).
  On the protocol side the framed protocol reserves the ISP command (9),
  the file-transfer command (14) and ISP success/fail ack results, and the
  ISSC module has its air-patch characteristic. Which of these the updaters
  use is not established. A replacement client can only send owners to
  Acaia's updater apps. See [Firmware Update](../protocols/firmware-update.md).
- **Link password.** Command 15 takes a 15-byte payload and is acked with
  "set password ok" or "set password failed". No client examined sends it.
  The manuals' error 904 (900 on the original Pearl's 2.0 firmware) is a
  password error with a default of `0000`. Whether that stored code is the
  link password is not established.

## Troubleshooting

These are defects and quirks found in the vendor app and the open
implementations, plus the vendor's own documented failure modes.

- **Weight streams briefly, then stops or the scale disconnects.**
  - No heartbeat is being written, or the interval is too long. Keep it at
    3 s or less.
  - The identify or event-subscription frame was never written, or was
    written before notifications were enabled.
- **The scale is not found in a scan.**
  - Bluetooth is switched off in the scale's settings menu.
  - Another central, often the vendor app running in the background, is
    already connected.
  - The scale has gone to sleep. The Lunar manual says the sleep timer only
    counts while the scale is disconnected from every phone.
- **A Lunar 2021 connects and streams weight but ignores tare and timer
  commands.** Old firmware. pyacaia's README says the 2021 Lunar needs a
  firmware update, done with the vendor's updater app, before commands
  work.
- **Readings wrap or turn nonsensical above 655.35 g (or 6553.5 g).** Only
  the low two bytes of the magnitude are being read. The field is 32 bits;
  pyacaia, Beanconqueror and AcaiaArduinoBLE all read 16, which breaks at
  0.01 g resolution above 655.35 g.
- **Nothing decodes, or frames look truncated, on the older `2a80` scales.**
  Frames are split across notifications (AcaiaArduinoBLE sees 10-byte
  notifications without the header on pre-2021 Lunars). Buffer and parse
  the byte stream.
- **Weights on a Pyxis or Cinco look ten times off in a port of the vendor
  app's logic.** For names containing `PYXIS` or `CINCO` the vendor app
  ignores the decimal-places byte and divides by 100 in grams and by 10000
  in ounces. The open implementations use the byte on the Pyxis and work, so
  use the byte.
- **Readings the scale sent never show up in a port of the vendor app.** The
  app drops readings of exactly 9999.0, readings beyond ±3000, the first
  reading below −5 and the first near-zero reading after a non-zero one.
  That is display filtering, not protocol; a client need not copy it.
- **The sleep timer reads wrong in pyacaia.** pyacaia multiplies the status
  frame's sleep byte by 5. It is an index (5, 10, 20, 30, 60 min), so the two
  disagree above index 2.
- **The vendor app keeps re-sending identify.** It writes identify every
  second, up to 20 times, after subscribing on the ISSC module; its stop
  condition is never set in the build examined. Harmless, but do not copy
  it as a requirement.
- **The scale shows error 904 (900 on the original Pearl's 2.0 firmware).**
  A wrong password or passcode. The manuals give `0000` as the default. On
  the original Pearl the settings menu itself sits behind the `F.0000`
  passcode prompt, which is the most likely source.
- **After an interrupted firmware update the display stays blank or shows
  `UPdAtE`, and the scale no longer streams weight.** The scale is still in
  update mode. Acaia's help centre says to force-quit the updater, re-enter
  update mode by holding Power while plugging in USB, and run the update
  again. The Pyxis Black manual instead says to hold Power for about 50 s
  until the scale turns off, then enter update mode from its settings menu.
  A generic client can neither finish nor undo an update.

## Open questions

- How long the scale tolerates a missing heartbeat before it stops
  streaming or disconnects.
- What the event-subscription arguments mean.
- Whether the scale checks the identify string at all.
- Whether the Lunar 2021, Pearl S and Pyxis accept every settings write, and
  what the resolution item's values are.
- Whether the scales advertise a service UUID, and which products advertise
  the `INFOS` and `PROCHBT` names.
- Whether the one-to-one link is enforced by the scale or only by the apps.
- Whether the original (non-S) Pearl and the Pearl 2021 speak the framed
  protocol exactly as the Lunar and Pyxis do; no open implementation reports
  testing them.
- Whether the Pyxis Black (APS001) speaks this protocol at all, and whether
  the 2022 Pearl S and later Lunar 2021 firmware keep it unchanged.
- The command the updaters use to enter update mode, the firmware-update
  sequence, image format and signing.
- The set-password payload, and whether Reset to Default clears it.
- The info message (command 7) layout and the setting and countdown event
  layouts.
- Which hardware, if any, still speaks the older obfuscated framing.

## Tools Used

- [x] Static analysis of the delisted Acaia Coffee Android app (2.5.10)
- [x] Cross-check against pyacaia, AcaiaArduinoBLE and Beanconqueror's Acaia driver
- [x] Acaia's user manuals and archived help-centre articles
- [ ] nRF Connect dump and a btsnoop capture of a pour, a tare and a timer start/stop: **still needed**

## References

- [Acaia Lunar user manual, FW 2.6.020 (models AL001 / AL006 / AL007)](https://cdn.acaia.co/web/2026_doc/manual/Lunar/Lunar_MAN_AFBF26001_EN.pdf)
- [Acaia Lunar (2021) user manual, FW 1.0.019 (models AL008 / AL009 / AL010 / AL012 / AL013)](https://cdn.acaia.co/web/2026_doc/manual/Lunar2021/Lunar2021_MAN_AFBF19001_EN.pdf)
- [Acaia Pyxis user manual, FW 1.0.019 (2019 Pyxis, model AC002)](https://cdn.acaia.co/web/2022_doc/manual/Pyxis/Pyxis_MAN_AE9F01901_EN.pdf)
- [Acaia Pyxis Black user manual, FW 1.0.2 (model APS001)](https://cdn.acaia.co/web/2025_doc/manual/pyxis/pyxis_MAM_AECF102005_EN.pdf)
- [Acaia Pearl user manual, FW 2.0.010 (original Pearl, models AP001AT / AP004AT)](https://cdn.acaia.co/web/2026_doc/manual/Pearl/Pearl_MAN_AE10F20003_EN.pdf)
- [Acaia Pearl (2021) user manual, FW 1.0.014 (models AP007 / AP008 / AP009)](https://cdn.acaia.co/web/2026_doc/manual/Pearl_2021/Pearl2021_MAN_AFBF14001_EN.pdf)
- [Acaia Pearl Model S user manual, FW 1.0.057 (models PS001 / PS002)](https://cdn.acaia.co/web/2026_doc/manual/Pearl_S/PearlS_MAN_AFBF57001_EN.pdf)
- [Acaia Pearl Model S (2022) user manual, FW 1.0.009 (models PS003 / PS004)](https://cdn.acaia.co/web/2026_doc/manual/Pearl_S_2022/PearlS2022_MAN_AFBF09001_EN.pdf)
- [Acaia help centre: How to update your scale's firmware (archived)](https://web.archive.org/web/20231129174656/https://help.acaia.co/hc/en-us/articles/207391486-How-to-update-your-scale-s-firmware)
- [Acaia help centre: The firmware update failed, or the scale is stuck in Update mode (archived)](https://web.archive.org/web/20191117151329/https://help.acaia.co/hc/en-us/articles/207727653-The-firmware-update-failed-or-the-scale-is-stuck-in-Update-mode)
- [Acaia help centre: How to turn on and off your scale's Bluetooth capability (archived)](https://web.archive.org/web/20191117151323/https://help.acaia.co/hc/en-us/articles/213995583-How-to-turn-on-off-your-scale-s-Bluetooth-capability)
- [pyacaia (Python client, GPL-3.0)](https://github.com/lucapinello/pyacaia)
- [AcaiaArduinoBLE (ESP32 client)](https://github.com/tatemazer/AcaiaArduinoBLE)
- [Beanconqueror: Acaia decoder](https://github.com/graphefruit/Beanconqueror/blob/52d64e2b91f14dede361d4f903815689dee681ea/src/classes/devices/acaia/decoder.ts)
- [LunarGateway (ESP32 gateway AcaiaArduinoBLE was ported from)](https://github.com/frowin/LunarGateway)
- [btscale (the JavaScript client pyacaia was based on)](https://github.com/bpowers/btscale)
- [Acaia Coffee on Google Play (archived listing of the delisted app)](https://web.archive.org/web/20260106123356/https://play.google.com/store/apps/details?id=com.acaia.coffeescale)
- [BOOKOO official BLE protocols (out of scope; linked only)](https://github.com/BooKooCode/OpenSource)
- [Missing Devices survey](../research/missing-devices.md), which asked for both generations to be covered
- [Pairing, Bonding and Unpairing](../protocols/pairing.md)
- [Firmware Update (DFU / OTA)](../protocols/firmware-update.md)

## Contributors

- Claude Code agent: spec written from the published open-source clients, checked against a static read of the vendor app (no hardware)
