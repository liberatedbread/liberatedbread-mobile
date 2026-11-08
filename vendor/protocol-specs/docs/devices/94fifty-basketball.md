# 94Fifty Smart Sensor Basketball

> **Status**: Spec Available
> **Protocol**: Bluetooth Classic RFCOMM (vendor SDP service; BLE used only to find the ball)
> **Manufacturer**: InfoMotion Sports Technologies Inc.
> **Manufacturer Status**: Shutdown

## Overview

The 94Fifty was the first consumer smart basketball. It is regulation size,
with a sensor puck suspended inside: a nine-axis motion sensor, a magnetometer,
a small microcontroller, a Bluetooth radio, a lithium-polymer cell and a Qi
charging coil. The ball does its own work. It recognises dribbles and shots
on board and sends finished numbers to the phone: shot arc, backspin, release
time, dribble counts, streaks and dribble force. The vendor's app was a
display and coaching shell around those numbers.

InfoMotion Sports Technologies filed for Chapter 11. The website, the account
service and the app are gone. The only build that survives is version 1.4 of
the Android app (December 2014), from a third-party mirror. None of the ball's
function depends on the dead server. Drills, metrics, the ball's clock and
firmware update all run over the local Bluetooth link.

The Android app **finds** the ball with a short BLE scan for a vendor service
UUID. It then **talks** to it over Bluetooth Classic: an insecure RFCOMM socket
to a vendor SDP record, opened to the address the scan returned. There is no
GATT in the Android path. The protocol is a small binary request/reply
protocol with HDLC-style `0x7e` framing, a CRC-32 on every packet, and
unsolicited records streamed during a drill.

Everything here comes from static analysis of that Android app, whose
protocol layer is unobfuscated, plus the user guide and test report filed
with the FCC grant. No ball has been driven from this spec and no traffic has
been captured, so every byte is `reported`. One HCI snoop session would
confirm most of it; see [Capturing a session](#capturing-a-session).

Scope: both hardware revisions (hw1, hw2) speaking protocol v1, as the Android
app v1.4 drives them. Not covered: the SmartNet instrumented net and the
shooting-machine integration (the only trace of either in the protocol is a
SmartNet-detected flag in shot records), the dead cloud service, firmware
image contents, and the factory and FCC test modes, which are named but not
specified.

Machine-readable spec: `device-specs/devices/94fifty-basketball.yaml`. Where
this page and the spec disagree, the spec wins.

## Hardware

| Property | Value |
|----------|-------|
| Model | 94Fifty Smart Sensor Basketball; FCC test model TBBX001 |
| Hardware revisions | **hw1** and **hw2**, reported in the system-info reply. The app treats them as protocol-identical; the revision only selects the firmware image. |
| Sensors | The app's hardware self-test checks an InvenSense MPU-9150 nine-axis IMU and a Honeywell HMC5983 magnetometer. Launch press quoted nine sensors and 6,000 data points per second in total. |
| MCU | Unknown part. The bundled firmware images are not Cortex-M; their layout points to a 16-bit MCU. |
| Radio controller (hypothesis) | The ball's radio test-mode requests use the same modulation, test-pattern and ACL packet-type values as TI's CC256x vendor-specific tester commands. With the 16-bit host images, that suggests a CC256x-class dual-mode controller beside a separate host MCU. This has not been seen on a board. |
| Radio | Dual-mode Bluetooth 4.0. Launch-era coverage names a Texas Instruments part; the FCC photo markings are illegible. BLE advertising (used only to find the ball) plus BR/EDR RFCOMM (all control). The app assumes one address for both. |
| Power | 3.7 V 240 mAh lithium-polymer cell; Qi charging pad (about 3 h from empty) |
| Range | Earlier research notes say about 30 m. No primary source was found for that figure; the FCC report gives 1.38 mW conducted into a -0.5 dBi chip antenna. |
| FCC ID | [2AARZ-TBBX001](https://fccid.co/fcc/2AARZ-TBBX001) (DTS, 2402-2480 MHz, granted 2013-09-30). The grantee holds no other grant, so the SmartNet and the charging pad are not filed under this code. |
| Vendor app | 94Fifty Basketball, Android package `com.spectrumdt.ist`, last version 1.4. An iOS app existed and was not examined. |
| Firmware | The Android app bundles hw1 OEM 0.73, hw2 OEM 0.130 and hw2 manufacture 0.106 as its newest images |

## Initial Setup

| Property | Value |
|----------|-------|
| Setup required | No |
| Method | `none`. Activate once on the pad, wake by bouncing, scan, open the socket. |
| Advertised name | Classic inquiry name starts `IST-`. What the ball advertises over BLE is not recorded; the app matches its BLE service UUID instead. |
| Passphrase protection | not_applicable (no network, no credentials) |
| Confidence | medium (activation and wake from the user guide, the connect sequence from the app's code; none of it run) |

A client's first contact is the same as the vendor app's:

1. **First use only: activate the ball.** Balls ship in Travel Mode, a locked
   state with the radio off. Plug in the Qi pad (its blue light blinks once),
   then set the ball on it with the ball logo over the pad logo. The light
   turns solid blue when activation is done.
2. **Wake it.** Bounce the ball four or more times in a row. It sleeps again
   after a period of inactivity. How long it stays connectable without a
   connection is not established.
3. **Scan BLE** for an advertisement that carries the 128-bit service UUID
   `b69bc590-59d9-4920-9552-defcc31651fe`, and keep the address. The vendor
   app scans in 5 s windows. A host that cannot scan BLE can use a Classic
   inquiry instead and keep devices whose name starts `IST-`.
4. **Open an insecure RFCOMM socket** to the SDP service
   `32e5fcfc-52ee-41b0-827a-f18929716fef` at that address. The app tries
   twice, 250 ms apart. The RFCOMM channel number is resolved through SDP and
   is not recorded.
5. **Send system info** and wait up to 5 s for the reply (type `0x8001`).
   The app sends nothing else until this arrives. There is no login, no key
   exchange and no clock sync.

On Linux the same steps are `sdptool browse aa:bb:cc:dd:ee:ff` to find the
channel, then `rfcomm connect 0 aa:bb:cc:dd:ee:ff <channel>` or a raw
`AF_BLUETOOTH` RFCOMM socket.

**Factory reset**: none is known, and none is needed to change hands. The
user guide documents no reset, and the app sends no reset-to-defaults
command. Power-control mode 1 is a reboot, not a reset. The ball holds no
bond and no credential. Its clock, stored name and any stored records are
overwritten or ignored by the next client.

**Rebinding**: nothing to rebind. A new phone wakes the ball, scans and
connects. The vendor app kept renames and history in its own storage and its
cloud, not on the ball.

## Pairing

| Property | Value |
|----------|-------|
| Pairing required | No |
| Security mode | `none` (insecure RFCOMM socket) |
| Bonding | `none` |
| PIN source | n/a |
| One central at a time | Unknown (the app keeps one socket; whether the ball takes a second is untested) |
| One bond at a time | n/a: nothing bonds |
| Confidence | medium (static analysis of the vendor app) |

**Entering pairing mode**: there is no pairing mode, but there is a **wake**
step, and the spec records it under `device.pairing.enter_pairing_mode`
because it gates everything the same way. Bounce the ball four or more times
in a row. A ball in Travel Mode will not wake this way; it needs a few seconds
on the charging pad first.

**Unpairing**: nothing to unpair. No bond is created on either side.

**Recovery**: close the vendor app, or turn off Bluetooth on the phone running
it, before connecting from anything else. Before switching to a new ball the
vendor app sends the old one power-control "disconnect", so a client taking
over from it can do the same. Do not open a *secure* socket. That makes the
host start a pairing, and nobody knows whether the ball would complete it or
what PIN it would want.

The app's diagnostic connection test has a switch between secure and insecure
sockets, so its developers tried both. The shipped connect path uses the
insecure one.

## Protocol Summary

### Bluetooth Classic profiles

| Property | Value |
|----------|-------|
| Control profile | Vendor RFCOMM service, SDP UUID `32e5fcfc-52ee-41b0-827a-f18929716fef` (not SPP) |
| Socket | insecure (no bond) |
| Dual-mode | Yes. BLE advertises service `b69bc590-59d9-4920-9552-defcc31651fe`; the Android app uses BLE only to find the ball. `ble_role` is `unknown` because the iOS app may have used GATT. Same address for both assumed, not confirmed. |
| iOS reachable | Not over this spec: CoreBluetooth has no RFCOMM, and nothing suggests MFi. The user guide lists iOS devices "that support Bluetooth 4.0", which points to a GATT surface the iOS app used and nobody has recorded. |
| Stream | binary, `0x7e`-delimited frames with byte stuffing and a CRC-32; frames up to 2048 bytes |

### Frame format

```
wire      7e | packet, with 7d and 7e escaped | 7e
request   type u16 | token u16 | payload           | crc32 u32
reply     type u16 | token u16 | error u16 | payload | crc32 u32
```

- **Escaping:** a packet byte `0x7d` or `0x7e` is sent as `0x7d` followed by
  the byte XOR `0x20`, so `7d` becomes `7d 5d` and `7e` becomes `7d 5e`. No
  other byte is escaped. Everything below, offsets included, is about the
  **de-stuffed packet with the flags removed**. Offset 0 is the high byte of
  the type.
- **Byte order:** big-endian throughout.
- **Length:** every packet, CRC included, is a multiple of 4 bytes and at
  least 8. A request payload is therefore a multiple of 4 and a reply payload
  is 2 more than a multiple of 4. That is why most replies have 2 zero bytes
  of padding at offset 6. A reply with a non-zero error carries a 2-byte zero
  payload, 12 bytes in all.
- **Replies:** the reply type is the request type with bit 15 set
  (`0x0005` → `0x8005`), and the reply echoes the request's token.
- **Tokens:** the requester picks the token. Token 0 marks an unsolicited
  frame (live records, stream data). The app uses 1 for its opening system
  info and otherwise the low 15 bits of the clock in ms, never 0.
- **CRC:** CRC-32/BZIP2 over every packet byte before it, computed before
  stuffing and appended big-endian. Parameters: polynomial `0x04c11db7`, init
  `0xffffffff`, not reflected in or out, final XOR `0xffffffff`, check value
  `0xfc891918` for ASCII `123456789`. This is **not** the zlib/Ethernet CRC-32
  (which gives `0xcbf43926` on the same string); a client that reaches for
  `zlib.crc32` gets every frame rejected.
- **Receiving:** split on `0x7e`, undo the escapes, drop empty frames. Drop a
  frame on `7d 7d` or `7d 7e`, on more than 2048 buffered bytes, on a length
  under 8 or not a multiple of 4, or on a CRC mismatch. The app drops unknown
  types silently.

A quick check of an implementation, using the spec's test vectors:

| Frame | Meaning |
|---|---|
| `7e 00 01 00 01 3d e2 93 b4 7e` | system info, token 1 |
| `7e 00 05 00 7d 5e e2 7b 81 f2 7e` | status with token `0x007e`: the token's `7e` is escaped |
| `7e 00 05 00 0b 15 0a f7 7d 5e 7e` | status with token `0x000b`: the CRC's last byte `7e` is escaped |
| `7e 80 05 00 01 00 00 00 00 00 00 0f 3c 00 00 00 00 00 00 00 00 1c 5e 47 2d 7e` | status reply: idle, 3900 mV |

### Opcodes

Starts are `0x01xx`, ends `0x02xx`, stored-record fetches `0x03xx`, test
modes `0x04xx`, data frames `0x83xx`. Replies are request | `0x8000`.

| Request | Reply | Name | In the spec |
|---|---|---|---|
| `0x0001` | `0x8001` | system info | `get_system_info` |
| `0x0002` | `0x8002` | firmware segment | advanced, role only |
| `0x0003` | `0x8003` | firmware finalize | advanced, role only |
| `0x0004` | `0x8004` | power control: mode u16, delay u16 ms | `power_off`, `power_reset`, `power_disconnect`, `power_travel_mode`, `power_disable_bluetooth` |
| `0x0005` | `0x8005` | status | `get_status` |
| `0x0006` / `0x0007` | `0x8006` / `0x8007` | get / set clock | `get_rtc`; setting is parameterised |
| `0x0008` | `0x8008` | abort activity or stream | `abort_activity` |
| `0x0009` / `0x000a` | `0x8009` / `0x800a` | bandwidth test start / end | advanced, role only |
| `0x000b` / `0x000c` | `0x800b` / `0x800c` | get / set ball name | `get_ball_name`; setting is parameterised |
| `0x000d` | `0x800d` | hardware self-test | `get_hardware_diag` |
| `0x0055` | `0x8055` | echo (dummy payload) | named only |
| `0x0101` / `0x0201` | `0x8101` / `0x8201` | raw sensor stream start / end, data `0x8301` | diagnostic |
| `0x0102` / `0x0202` | `0x8102` / `0x8202` | orientation stream start / end, data `0x8302` | diagnostic |
| `0x0120` / `0x0220` | `0x8120` / `0x8220` | dribbling activity start / end, records `0x8320` | `start_dribbling_drill`, `end_dribbling_activity` |
| `0x0121` / `0x0221` | `0x8121` / `0x8221` | shooting activity start / end, records `0x8321` | `start_shooting_drill_pass`, `start_shooting_drill_solo`, `end_shooting_activity` |
| `0x0320` / `0x0321` | `0x8320` / `0x8321` | fetch a stored dribbling / shooting record | parameterised |
| `0x0401`-`0x0406` | `0x8401`-`0x8406` | factory and FCC test modes | advanced, named only |
| — | `0x8080` | bandwidth-test data | advanced |

Earlier notes on this ball listed decimal 512 as the raw-stream start. There
is no opcode `0x0200`: raw stream starts at `0x0101` (257) and ends at
`0x0201` (513).

The echo opcode `0x0055` is defined by the app's protocol library but never
sent, and nothing in the app uses it as a keepalive. The keepalive the app
actually uses is a status request every 3 s, and only on its diagnostic
raw-stream and bandwidth-test screens.

### Fixed commands

Each is a complete frame with token `0x0001`, flags and CRC included, so it
can be written to the socket as-is:

| Command | Frame |
|---|---|
| `get_system_info` | `7e 00 01 00 01 3d e2 93 b4 7e` |
| `get_status` | `7e 00 05 00 01 3a 80 21 a8 7e` |
| `get_rtc` | `7e 00 06 00 01 38 e9 d4 21 7e` |
| `get_ball_name` | `7e 00 0b 00 01 30 96 ae 82 7e` |
| `get_hardware_diag` | `7e 00 0d 00 01 34 45 45 90 7e` (reply can take several seconds; the app waits 15 s) |
| `abort_activity` | `7e 00 08 00 01 32 ff 5b 0b 7e` |
| `end_dribbling_activity` | `7e 02 20 00 01 bb 35 87 0a 7e` |
| `end_shooting_activity` | `7e 02 21 00 01 ba ed 2b 8d 7e` |
| `power_off` | `7e 00 04 00 01 00 00 00 00 e6 6a 9e d8 7e` |
| `power_reset` | `7e 00 04 00 01 00 01 00 00 e7 b2 32 5f 7e` |
| `power_disconnect` | `7e 00 04 00 01 00 03 00 00 e4 03 6b 51 7e` |
| `power_travel_mode` (**advanced**) | `7e 00 04 00 01 00 02 00 00 e5 db c7 d6 7e` |
| `power_disable_bluetooth` (**advanced**) | `7e 00 04 00 01 00 04 00 00 e1 08 2c c4 7e` |

Power-control modes: 0 off (sleeps until bounced), 1 reboot, 2 Travel Mode
(radio off and locked until the ball sits on its pad), 3 drop the link and stay
awake, 4 Bluetooth off. Travel Mode is `advanced` because a ball without its
pad stays unusable. Bluetooth-off is `advanced` because only the factory
validator uses it and nobody knows how the ball comes back from it. The app
never waits for the `0x8004` reply. Whether it arrives before the link drops
is unknown.

The three drill starts are in the spec as fixed frames: `start_dribbling_drill`
and the two shooting starts (see below).

### Requests that take a value

These need a CRC computed over caller data, which the schema's command
encoder cannot express yet. The spec documents them byte by byte, with worked
frames, under `protocol_details.parameterised_requests`:

| Request | Packet (de-stuffed) | Worked frame (token `0x1234`) |
|---|---|---|
| set clock `0x0007` | `00 07` token, UTC seconds u32, CRC (12 bytes) | 2026-01-01T00:00:00Z: `7e 00 07 12 34 69 55 b9 00 c7 85 c9 90 7e` |
| set ball name `0x000c` | `00 0c` token, name 48 bytes UTF-8 NUL-padded, CRC (56 bytes) | "Court 1": `7e 00 0c 12 34 43 6f 75 72 74 20 31` + 41 × `00` + `c8 e1 b3 73 7e` |
| fetch stored record `0x0320` / `0x0321` | type, token, activity id u32, record id u16, `00 00`, CRC (16 bytes) | shooting record 0 of activity 1: `7e 03 21 12 34 00 00 00 01 00 00 00 00 c8 7b e0 2d 7e` |
| start activity `0x0120` / `0x0121` | see [Starting an activity](#starting-an-activity) | — |

The Android app never sends set ball name, the stored-record fetches or the
echo. Its rename feature changes only its own record and its cloud copy, and
allows 1-20 ASCII characters. Whether the ball keeps records after an
activity ends, or across a power cycle, is not established.

### Starting an activity

The common start payload is 20 bytes, all big-endian:

| Offset | Length | Field | Notes |
|---|---|---|---|
| 4 | 4 | user id | always 0 from the app |
| 8 | 4 | start time | always 0 from the app |
| 12 | 2 | padding | `00 00` |
| 14 | 2 | notify method | bit 0: the limit counts events (1) or ms (0). Bit 1: a record every N events (1) or every N ms (0). |
| 16 | 4 | activity limit | ms or events, minimum 100 ms or 1 event |
| 20 | 4 | notify interval | ms or events, minimum 100 ms or 1 event |

Dribbling (`0x0120`) adds DSP algorithm u16 (0) and dribble window u16 (5): a
32-byte packet. Shooting (`0x0121`) adds player height u16 in inches, shot
distance u16 in inches, shooting algorithm u16 and 2 bytes of padding: a
36-byte packet. The app sends the player's height, or 70 in when it is
unknown. Its distances are 165 (free throw), 180 (15 ft), 216 (18 ft),
240 (20 ft) and 276 (23 ft). Algorithm 1 is for a shot taken off a chest
pass and 2 is solo. The protocol library also names them "with magnetometer"
and "without magnetometer". Values 3 and up are debug values.

The app's presets, which the spec carries as fixed frames:

| Command | Settings |
|---|---|
| `start_dribbling_drill` | time limit and time trigger, 600 000 ms, a record every 200 ms, algorithm 0, window 5 |
| `start_shooting_drill_pass` | event limit and event trigger, 20 shots, a record every shot, 70 in, 180 in, algorithm 1 |
| `start_shooting_drill_solo` | as above with algorithm 2 |

The start reply (`0x8120` / `0x8121`) carries an error and then, at offset 8,
the activity id (u32), which every record repeats. Start errors the app
handles: 2 system busy, 8 low battery, 9 invalid state. The end reply
(`0x8220` / `0x8221`) carries the highest record id at offset 6.

For a shot to register, the user guide says it must follow a chest pass to
the shooter. For a solo shot, spin the ball into the air, catch it and shoot
without letting it bounce.

### Live records

During an activity the ball sends one record per notify interval with token
0. The last one has `is_last` set, and the app ends the activity on it
without using its metrics. The app de-duplicates on the record id.

**Shooting record `0x8321`** (64 bytes):

| Offset | Length | Field | Type | Scaling |
|---|---|---|---|---|
| 6 | 2 | is_last | u16 | non-zero: activity over |
| 8 | 4 | activity id | u32 | from the start reply |
| 12 | 2 | record id | u16 | shot number |
| 16 / 20 / 24 | 4 each | samples to first shot / last shot / buffer end | u32 | sample rate unknown |
| 28 | 2 | shot made | i16 | negative missed, 0 undetermined, positive made |
| 32 / 36 | 4 each | samples to release / to rim | u32 | |
| 40 | 2 | release time | u16 | ms; the app grades 850 ms or less as quick |
| 42 | 2 | average release time | u16 | ms |
| 44 | 2 | shot arc | u16 | binary angle: degrees = raw × 360 / 65536 (`0x2000` is 45°) |
| 46 | 2 | average shot arc | u16 | as above |
| 48 | 2 | shot spin | i16 | the app shows raw / 24.6 as rpm; sign convention unknown |
| 50 | 2 | average shot spin | i16 | as above |
| 52 | 2 | launch height | u16 | unit unknown |
| 54 | 2 | SmartNet detected | u16 | non-zero: true |
| 56 | 2 | shot distance | u16 | unit unknown, probably inches |

Bytes 14-15, 30-31 and 58-59 are padding; 60-63 are the CRC. Without the
SmartNet accessory, most shots are expected to read "undetermined".

**Dribbling record `0x8320`** (56 bytes):

| Offset | Length | Field | Type | Scaling |
|---|---|---|---|---|
| 6 | 2 | is_last | u16 | non-zero: activity over |
| 8 | 4 | activity id | u32 | |
| 12 | 2 | record id | u16 | |
| 16 / 20 / 24 | 4 each | samples to first dribble / last dribble / buffer end | u32 | |
| 28 | 4 | samples in control | u32 | feeds the app's control percentage |
| 32 | 4 | total dribbles | u32 | tenths: the app shows raw / 10 |
| 36 | 2 | best streak | u16 | tenths |
| 38 | 2 | current streak | u16 | tenths |
| 40 | 2 | average streak | u16 | probably tenths; the app prints it raw |
| 42 | 2 | average dribble speed | u16 | unit unknown |
| 44 | 2 | dribble intensity (moving average) | u16 | the app shows raw / 1024 as G |
| 46 | 2 | dribble intensity (activity average) | u16 | as above |
| 48 | 2 | streak restart count | u16 | increments when a streak breaks |

Bytes 14-15 and 50-51 are padding; 52-55 are the CRC. The app's
ball-control percentage formula is in `protocol_details.control_percentage`.

### Status and system info

**Status reply `0x8005`** (24 bytes): offset 8 and 9 each hold an activity
code (0 idle, 1 raw stream, 2 orientation stream, 3 bandwidth test, 32
dribbling, 33 shooting). The app treats the byte at offset 9 as the current
activity. Battery voltage is a u16 at offset 10 in mV. Offsets 12 and 16 are
u32 link byte counters the app ignores. The app's battery gauge maps voltage
to a percentage through a piecewise curve, given in
`protocol_details.battery_percentage`. Its battery icon turns yellow at 30 %
and red at 15 %.

**System info reply `0x8001`** (28 bytes):

| Offset | Length | Field | Notes |
|---|---|---|---|
| 8 | 2 | release type | 1 OEM, 2 Debug, 3 Manufacture |
| 10 / 12 / 14 | 2 each | protocol / bootloader / firmware version | high byte major, low byte minor: `00 82` is 0.130 |
| 16 | 4 | hardware revision | u32: 1 hw1, 2 hw2 |
| 20 | 4 | serial number | u32; the app prints it in decimal |

An older 24-byte form (protocol revision 3 and below) has no release type:
the versions sit at 6, 8 and 10, the hardware revision at 12, the serial at
16. Tell the two apart by length.

**Hardware self-test reply `0x800d`** (12 bytes): a u16 at offset 6 with a bit
set per failed check: `0x01` bounce, `0x02` IMU bus, `0x04` IMU self-test,
`0x08` magnetometer, `0x10` power-off check. 0 means all passed. `0x7fff`
is the app's own "diagnostics unavailable" value. The app substitutes it when
no reply arrives and shows a reply carrying it the same way. Whether a ball
ever sends it is unknown. Read the whole word before testing bits, so that
`0x7fff` is never taken as five failures. Only the app's device-validator
screens run the self-test.

### Error codes

| Code | Meaning |
|---|---|
| 0 | no error |
| 1 | unknown packet type |
| 2 | system busy (retry) |
| 3 | in progress (the firmware updater treats it as success) |
| 4 | firmware segment out of sequence |
| 5 | firmware image corrupted |
| 6 | invalid packet size |
| 7 | invalid packet field |
| 8 | low battery |
| 9 | invalid state |
| 10 | invalid activity id |
| 11 | invalid record id |
| 12 | activity not running |
| 13 | scoring engine failed |
| 14 | out of resources |
| 65535 | unspecified failure (the app maps any unlisted value here) |

### Diagnostic streams

The raw sensor stream (`0x0101`, data `0x8301`, 1344-byte frames carrying
1324 sample bytes) and the orientation stream (`0x0102`, data `0x8302`,
28-byte frames carrying 8 bytes) exist for the app's diagnostic screens. The
app treats the data as opaque and writes it to a file, so neither layout is
known. The end replies carry a notification count at offset 6.

### Firmware update

The ball takes new firmware over the same RFCOMM link, from the running
firmware, with no separate bootloader entry. The spec gives the exchange's
**role only** and marks both opcodes `advanced`. It gives no flashing bytes.

- A firmware-segment request (`0x0002`) carries a sequence number counting from
  0, a length and up to 1012 image bytes. The ball answers `0x8002`. "System
  busy" means send the same segment again after 50 ms. The app allows 2 s per
  reply.
- A firmware-finalize request (`0x0003`) commits the image. Then the app
  reboots the ball with power-control mode 1.
- The images are raw binaries of about 150-250 kB, one per hardware revision
  and release type, bundled in the app. The ball has an "image corrupted"
  error, so it checks something. Whether that is a signature is not known,
  and nor is what an interrupted update leaves behind.

### Factory and FCC test modes

Opcodes `0x0401`-`0x0406` put the radio into certification and production
test modes: an FCC test mode (modulation, pattern, channel, power), an RF
signalling test, a set-maximum-output-power command, an FCC TX/RX mode, and
BLE directed and undirected advertising tests. The bandwidth test (`0x0009`,
`0x000a`, data `0x8080`) floods the link. The spec names these as `advanced`
and gives no payloads. They leave normal operation, may transmit outside the
grant, and nothing documents the way back.

## Why a 94Fifty might misbehave

Findings from the vendor app and user guide. None has been reproduced on a
ball.

### 1. It won't show up after bouncing

The user guide gives three causes, in this order. The battery is flat: charge
it on the pad for at least an hour. The ball is in Travel Mode: a few seconds
on the pad releases it. It hasn't woken yet: keep bouncing until it connects.
A client should also allow for the ball's sleep timer. The ball sleeps after
inactivity, and nobody has measured how long it stays connectable.

### 2. It has to be bounced again after every session

When the vendor app disconnects it sends power-control **off**, not
"disconnect", so the ball goes to sleep. A client that wants the ball to stay
awake for the next connection should send `power_disconnect` (mode 3) instead,
or just close the socket.

### 3. The vendor app reflashes the ball without asking, downgrades included

By default the Android app compares the ball's firmware with the one OEM image
it bundles for that hardware revision (hw1 0.73, hw2 0.130). If the two differ
**in either direction**, it goes straight from its ball-connection screen into
flashing, with no prompt. A ball running newer firmware than the app's image
(for example one updated by a later iOS build) is downgraded the first time
the Android app v1.4 connects to it. A ball whose firmware major version is 72
is exempt. If you care about the firmware on your ball, check its version with
`get_system_info` from your own client first. Don't connect the old app to a
ball whose firmware you have not recorded.

The policy can be switched off. Type `diag` in the sign-in email field to open
the diagnostic screen, then open its settings page. It has a firmware
validation mode selector with four choices: fixed version (the default
described above), upgrade only, downgrade only and disabled. Choose disabled,
or upgrade only, **before** the app connects to the ball. The release build
exposes this selector, and nothing on this path needs an account.

### 4. The app won't sign in

Accounts lived on the dead server. The login screen has a guest path ("Just
Visiting" in the user guide) that runs drills entirely offline, and typing
`diag` in the sign-in email field opens the app's diagnostic screen without an
account. The app targets Android 4-era APIs, and nobody has confirmed it
still runs on a current phone.

The app has four device-validator screens. They are production-line tests
(battery, streams, a short dribbling activity, the hardware self-test,
firmware and the power modes), not an authenticity check, and they never run
in the consumer flow. They open only from the diagnostic screen's test list,
or at launch if the diagnostic settings put the app in factory mode. Leave that
mode alone. Nothing in normal use depends on them.

### 5. A ball name set in the app doesn't follow the ball

The Android app never writes the name to the ball. It keeps the name in its
own storage and its cloud record, which is now gone. The ball has a 48-byte
name slot (`get_ball_name` / set ball name) that the Android app never
touches, so it holds whatever an iOS or factory tool last wrote, possibly
nothing.

### 6. An iPhone can't reach it with this spec

CoreBluetooth has no RFCOMM API. The vendor's iOS app almost certainly used
a BLE GATT surface on the same ball, and nobody has recorded that GATT table.
Until someone does, an iPhone can find the ball but cannot drive it.

### 7. The FCC grant covers only the LE radio

The grant is DTS only, and the report lists 40 channels 2 MHz apart, the LE
channel plan. Yet the Android app can only have reached the ball over BR/EDR,
because RFCOMM does not run over LE. The app's own radio test modes include
BR/EDR modulations, frequency hopping and ACL packet types up to 3-DH5, so the
radio can do BR/EDR whatever the filing says. An inquiry scan or an HCI snoop
log would settle it in minutes. Until then, the BR/EDR side rests entirely on the app's
code.

### Capturing a session

The cheapest confirmation is Android's Bluetooth HCI snoop log (Developer
options) while the vendor app connects to a ball, runs one dribbling drill and
one shooting drill, and disconnects. In Wireshark the `btrfcomm` filter shows
the payloads in the clear. One such session confirms the SDP record, the
framing, the CRC, the handshake and both record layouts, and gives the BLE
advertised name and whether the BR/EDR and BLE addresses match. Keep your own
ball's address and serial number out of anything you commit.

## Tools Used

- [x] Static analysis of the vendor Android app (94Fifty Basketball 1.4)
- [x] FCC exhibits for 2AARZ-TBBX001 (user guide, test report, photos)
- [x] Standard-library transcription of the framing and CRC to recompute every
      fixed frame and test vector in the spec
- [ ] HCI snoop capture
- [ ] Hardware session

## References

- [94Fifty Smart Sensor Basketball user guide (PDF, FCC exhibit)](https://fccid.co/api/files/s1/2aarz_tbbx001_usersmanual_2089328_be3eadb87f.pdf):
  activation, the four-bounce wake, Travel Mode, charging, troubleshooting
- [FCC ID 2AARZ-TBBX001](https://fccid.co/fcc/2AARZ-TBBX001): grant and exhibits
- [FCC test report (PDF)](https://fccid.co/api/files/s1/2aarz_tbbx001_testreport_2089326_7e539edeeb.pdf)
  and [internal photos (PDF)](https://fccid.co/api/files/s1/2aarz_tbbx001_internalphotos_2089321_e4c3575cb8.pdf)
- [Design News: Smart Basketball Analyzes Shooting, Dribbling (2013, archived)](https://web.archive.org/web/20250125061603/https://www.designnews.com/gadget-freak/smart-basketball-analyzes-shooting-dribbling)
- [Engineering.com: 94Fifty Basketball Uses Sensors to Measure Basketball Skills (2013, archived)](https://web.archive.org/web/20250909111054/https://www.engineering.com/fire-the-coach-94fifty-basketball-uses-sensors-to-measure-basketball-skills/)
- [ABI: Maker of 'Smart' Basketball Files for Bankruptcy Protection](https://www.abi.org/feed-item/maker-of-%E2%80%98smart%E2%80%99-basketball-files-for-bankruptcy-protection)
- [CRC RevEng catalogue: CRC-32/BZIP2](https://reveng.sourceforge.io/crc-catalogue/17plus.htm)
- [TI CC256x vendor-specific HCI commands (archived TI wiki)](https://web.archive.org/web/20210114141655/https://processors.wiki.ti.com/index.php/CC256x_VS_HCI_Commands):
  the tester-command tables behind the radio-controller hypothesis
- [Common Bluetooth Classic Patterns](../protocols/bluetooth-classic-common.md)

## Contributors

- Liberated Bread project: spec from static analysis, 2026-09
