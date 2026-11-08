# Beddit Sleep Monitor 3 / 3.5

> **Status**: Spec Available (read from the last Android app; not yet replayed against hardware)
> **Protocol**: BLE (vendor GATT service, two layouts)
> **Manufacturer**: Beddit Oy, acquired by Apple in 2017
> **Manufacturer Status**: Shutdown (cloud off 2018-11-15, hardware discontinued 2022, apps removed 2024)

## Overview

Beddit made thin under-mattress sensor strips that measure
**ballistocardiography** (BCG): the tiny body movements caused by each
heartbeat and breath. Apple bought the company in May 2017, shut down
Beddit Cloud on 2018-11-15 and launched a model 3.5 a few weeks later, in
December 2018. It stopped selling the hardware in January 2022 and removed
the iOS apps for models 3.0 and 3.5 from the App Store in September 2024.
Android support had been dropped earlier. Owners are left with working
sensors and no app.

The main finding is what the strip actually sends: **a raw force waveform,
nothing else**. Sleep stages, heart rate, respiration, efficiency and the
sleep score were all computed on the phone, by a native analysis library
bundled with the app, from that live stream. Snoring came from the phone's
own microphone. The protocol itself is small and open: no pairing, no
authentication, no stored history. A client can collect the waveform after
a few reads and a one-byte write. Getting the numbers the app showed means
reimplementing BCG analysis, which is outside this spec.

Every protocol fact here comes from a static read of `com.beddit.beddit`
2.3.12, the last Android build available to us, so it is
`verification: reported`. There are no captures. The FCC listings for both
models and the model 3.5's user guide and radio test report (Internet
Archive copies) add hardware and setup facts, and none of them describes
the protocol.

## Hardware

| Property | Value |
|----------|-------|
| Model Number | Beddit 3 (model 3.0, 2016) and Beddit 3.5 (model 3.5, December 2018). Apple part numbers MR9P2LL/A (3.0) and MUFM2LL/A (3.5), from the store links in MacRumors' coverage |
| Form | Flexible strip about 2 mm thick, laid on the mattress under the sheet |
| Power | USB cable to the supplied USB power adapter. No battery ("nothing to charge"). The 3.5 guide warns against powering it from a computer's USB port |
| Chipset | Unknown. The 3.5's schematic, block diagram and parts list were filed as confidential |
| Radio | Bluetooth Low Energy only. Both filings list one 2402–2480 MHz line, equipment class DTS, and no Classic (DSS) line |
| FCC ID | **2AI4U-B3**: Beddit 3, filed by Beddit Oy (application dated 2016-08-12), about 1.5 mW. Only the listing summary was seen; its exhibits were not reachable. **BCG-B35**: model 3.5, filed by Apple, granted December 2018, 5.02 dBm peak conducted output, integrated antenna, test firmware v004ef1 |

Beddit 3 was also sold as measuring room temperature and humidity. The
Android app's BLE session reads no characteristic for either (see
[Open questions](#open-questions)).

## Initial Setup

| Property | Value |
|----------|-------|
| Setup required | No |
| Method | `ble_direct` |
| Setup AP / advertised name | Name starting with `beddit`, compared case-insensitively (the app's filter; the real name has never been seen in a scan) |
| Passphrase protection | not_applicable |
| Confidence | low (read from the app only) |

The app's onboarding: lay the strip on the mattress under the sheet, plug
its power adapter into the wall, then connect. The model 3.5 user guide
adds the placement: across the mattress, dark rubber side down, at chest
level and clear of the pillows, on top of any mattress protector and under
the fitted sheet, on your own side of a shared bed. There is no button and
no pairing-mode step.

With several sensors in range, the Android app tells the owner to find the
device number on the back of the strip, and the 3.5 guide says the ID
number is printed on the cable close to the sensor. Both suggest that each
unit's advertised name carries that number. Nobody has confirmed it with a
scan.

**Factory reset**: none is known, and none seems needed. As far as the app
shows, the sensor holds no bond, credential or owner binding. The only
candidate procedure is generic: unplug the adapter for about ten seconds.
It is not from any Beddit document and has not been tried.

**Rebinding**: nothing ties the strip to a phone at the BLE layer. Connect
from the new client once the old one has let go of the link.

## Pairing

| Property | Value |
|----------|-------|
| Pairing required | No (inferred) |
| Security mode | `none` |
| Bonding | `none` |
| PIN source | not applicable |
| One central at a time | Unknown |
| One bond at a time | not applicable |
| Confidence | low |

The app opens a plain GATT connection (no autoConnect) and never requests a
bond. That fits open GATT but does not prove it. Android pairs
automatically when a characteristic answers "insufficient authentication",
so the app's code would look the same if the sensor asked for Just Works
pairing somewhere.

**Entering pairing mode**: not needed. There is no button and the app has
no pairing-mode step.

**Unpairing**: nothing is bonded, so there is nothing to clear.

**Recovery**: if the sensor cannot be found or connected to, close or
uninstall the vendor app on any phone that used it, then power-cycle the
strip.

## Protocol Summary

The app connects, discovers services and walks them in discovery order. It
uses whichever of the two Beddit services it meets first and aborts if it
finds neither.

| Layout | Service | App's hardware-type label | Channels |
|--------|---------|---------------------------|----------|
| BTLEv3 | `e6807d20-b90a-11e5-a837-0800200c9a66` | `BTLEv3/<hw rev>` | 2, self-describing |
| BTLE | `f82fd8a8-329d-4c44-a178-e82f91ec9fe6` | `BTLE/<hw rev>` | 1, "force" |

`e6807d20-…` is a time-based UUID minted on 2016-01-12, seven months
before Beddit Oy filed the Beddit 3 radio with the FCC (2AI4U-B3) and nine
months before Beddit 3 reached shops. So the BTLEv3 layout is very likely Beddit 3.
Whether the Beddit 3.5 uses it too is assumed but not shown: this Android
app may predate the 3.5.

Two things point to the BTLE layout being an earlier generation. Its label
has no "v3". And the app sends BTLE sensors, like the classic-Bluetooth
ones, through a server-side replacement check that BTLEv3 sensors skip.
The [Bluetooth Classic spec](beddit-2-sleep-tracker.md) argues from 2015
press coverage that it is the Beddit Smart (2015). That has not been
verified here, and which retail models used the BTLE layout is not
established.

### BLE Services: BTLEv3 layout

| UUID | Name | Properties | Description |
|------|------|------------|-------------|
| `e6807d20-b90a-11e5-a837-0800200c9a66` | Sensor service | | Selects this layout |
| `e6807d21-b90a-11e5-a837-0800200c9a66` | Control point | read, write | Write `01` to start streaming. Read once at connect (value unused) |
| `e6807d22-b90a-11e5-a837-0800200c9a66` | Status | read, notify | Subscribed to but never acted on. Byte 0 is a bitfield; the app's code tests bit `0x02` |
| `e6807e21-b90a-11e5-a837-0800200c9a66` | Channel 1 description | read | See below |
| `e6807e20-b90a-11e5-a837-0800200c9a66` | Channel 1 data | notify | Sample packets |
| `e6807e25-b90a-11e5-a837-0800200c9a66` | Channel 2 description | read | See below |
| `e6807e24-b90a-11e5-a837-0800200c9a66` | Channel 2 data | notify | Sample packets |

!!! warning "Earlier write-ups have these roles wrong"
    One gave the service as `e6807e20-…`. Another paired the descriptions
    with `e6807e20`/`e6807e24` and the data with `e6807e21`/`e6807e25`. The
    app's session code **reads** `e6807e21` and `e6807e25` and parses them
    as descriptions. It **subscribes** to `e6807e20` and `e6807e24` and
    parses their notifications as samples. To check on a real unit without
    trusting either version: the description is the readable one with
    ASCII `u2` at bytes 2–3.

### BLE Services: BTLE layout

| UUID | Name | Properties | Description |
|------|------|------------|-------------|
| `f82fd8a8-329d-4c44-a178-e82f91ec9fe6` | Sensor service | | Selects this layout |
| `f82fd8aa-329d-4c44-a178-e82f91ec9fe6` | Sample rate | read | uint16 LE, whole Hz |
| `f82fd8a9-329d-4c44-a178-e82f91ec9fe6` | Control and force data | write, notify | Write `01` to start; force packets arrive as notifications |

### Device Information (both layouts)

| UUID | Name | App's use |
|------|------|-----------|
| `00002a25-0000-1000-8000-00805f9b34fb` | Serial Number String | Sensor serial |
| `00002a27-0000-1000-8000-00805f9b34fb` | Hardware Revision String | Appended to the hardware-type label |
| `00002a26-0000-1000-8000-00805f9b34fb` | Firmware Revision String | Labelled the **bootloader** version |
| `00002a28-0000-1000-8000-00805f9b34fb` | Software Revision String | Main firmware version |

All four are read at connect under service
`0000180a-0000-1000-8000-00805f9b34fb`. The app aborts the session if any
of them is missing.

### Session sequence

1. Connect. Do not bond.
2. Discover services and pick the layout.
3. Read the four Device Information strings, then:
    - BTLEv3: `e6807d21`, `e6807d22`, `e6807e21`, `e6807e25`
    - BTLE: `f82fd8aa`

    Do one read at a time.
4. Enable notifications (CCCD `01 00`), one descriptor write at a time:
    - BTLEv3: `e6807d22`, `e6807e20`, `e6807e24`
    - BTLE: `f82fd8a9`
5. To start recording, write `01` to `e6807d21` (BTLEv3) or `f82fd8a9`
   (BTLE).
6. Decode notifications until done, then **disconnect**. No stop command
   exists.

### Command: Start streaming

**Request**: write one byte to the control characteristic.

| Offset | Length | Description |
|--------|--------|-------------|
| 0 | 1 | `0x01` |

**Response**: no acknowledgement is documented. Sample notifications
simply begin.

### Channel description (BTLEv3, read)

| Offset | Length | Description |
|--------|--------|-------------|
| 0 | 2 | Sample rate × 100, uint16 little-endian (`raw / 100.0` Hz) |
| 2 | 2 | ASCII type code. Must be `u2` (`75 32`) = uint16 samples. Anything else aborts the app |
| 4 | to end | Channel name, UTF-8, at least 1 byte |

The value must be at least 5 bytes. The app's analysis needs one channel
named exactly `force`, and processes samples in 0.2-second frames, so a
real sample rate is a multiple of 5 Hz. The actual rates and the second
channel's name are unknown.

Example (constructed, not a capture): `10 27 75 32 66 6f 72 63 65` →
100.00 Hz, uint16, `force`.

### Sample packet (BTLEv3, notify on `e6807e20` / `e6807e24`)

| Offset | Length | Description |
|--------|--------|-------------|
| 0 | 1 | Sequence counter, uint8, per channel, wraps 255 → 0 |
| 1 | 2 × n | n ≥ 1 samples, uint16 little-endian, raw sensor counts |

The length is odd and at least 3. Example (constructed):
`00 10 27 11 27 12 27` → sequence 0, samples 10000, 10001, 10002.

### Force packet (BTLE, notify on `f82fd8a9`)

| Offset | Length | Description |
|--------|--------|-------------|
| 0 | 1 | Packet type, `0x80` or `0x90`. Anything else aborts the app. The difference between the two is unknown |
| 1 | 1 | Sequence counter, uint8, wraps 255 → 0 |
| 2 | 2 × n | n ≥ 1 force samples, uint16 little-endian |

The length is even and at least 4. Example (constructed):
`80 00 e8 03 e9 03 ea 03` → type 0x80, sequence 0, samples 1000, 1001,
1002.

### Lost packets

The app keeps one expected-sequence counter per channel. It starts at 0
when notifications open and becomes `(sequence + 1) mod 256` after each
packet. When a packet's sequence does not match, the app works out
`lost = (sequence − expected) mod 256` packets. It then inserts
`lost × (samples in this packet)` copies of this packet's **second**
sample before the packet's own samples. For example, with 5 expected and
`07 10 27 20 27 30 27` received, the app emits six copies of 10016, then
10000, 10016, 10032. Packets carry no timestamp, so sample `n` of a
channel falls at `n / rate` seconds.

## Troubleshooting

These are defects and quirks found in the app's code. A replacement
client should know about them.

- **The vendor app cannot record a BTLE-layout sensor any more.** After
  connecting to a sensor whose layout is not BTLEv3, the app asks
  `replacements.beddit.com` whether the sensor is blocked. It does this in
  the setup wizard and again before every recording. A network failure is
  fatal: the app shows an error and abandons setup or cancels the night.
  Neither that host nor `cloudapi.beddit.com` resolved on 2026-09-28. The
  sensor takes no part in this check, so a client built from this spec is
  unaffected. BTLEv3 sensors skip the check.
- **Status is ignored.** The app subscribes to `e6807d22` but does not
  route its notifications to the routine that would decode them. That
  routine does nothing anyway. The status bits have never been used, so
  nothing depends on them.
- **Start race on the BTLE layout.** The app reports the session as open
  as soon as it *sends* the notification-enable write on `f82fd8a9`,
  without waiting for it to complete. A client should wait for the CCCD
  write to complete before writing `01`.
- **Padding is crude.** Lost packets are filled with repeats of the next
  packet's second sample, not interpolated. A one-sample packet pads with
  0, and the app assumes the lost packets were the same size. It also
  assumes the counter starts at 0: if the sensor's first packet carries
  any other sequence number, the app pads at the very start of the
  recording. Record the gap instead if your analysis can cope with one.
- **No reconnect.** Any GATT error or disconnect ends the recording. The
  app does not reconnect mid-night.
- **All four Device Information strings are required.** The app aborts if
  one is missing. A client need not.
- **Dual-mode routing.** Once a name has matched, the app uses BLE only
  when Android reports the device as LE. A device that Android reports as
  classic or dual-mode goes to the classic SPP path, which belongs to an
  older sensor generation. So does a device of unknown type whose address
  starts with the Bluegiga OUI `00:07:80`. A client written for this spec
  should connect over LE regardless.
- **One Samsung handset.** On the Galaxy S III (GT-I9300) the app runs a
  2-second LE scan before connecting. This is a quirk of that phone, not
  of the sensor.

## Out of scope

- **Sleep analysis.** Stages, heart rate, respiration and score are
  computed by the app, not sent by the sensor.
- **The classic-Bluetooth sensor generation.** The same app drives it over
  SPP; see [Beddit Sleep Tracker (Bluetooth Classic)](beddit-2-sleep-tracker.md).
- **Beddit Cloud** (`cloudapi.beddit.com`), shut down on 2018-11-15, and
  the replacement service (`replacements.beddit.com`). The sensor never
  needed either to stream.
- **Firmware update.** The Android app has no OTA or DFU code and carries
  no firmware images.

## Open questions

- The advertised name, address type, and any advertised service UUIDs.
- Which retail models use each layout, and whether the 3.5 exposes
  `e6807d20` at all.
- Real sample rates and channel names.
- What the `e6807d22` status bits mean, and what distinguishes packet type
  `0x80` from `0x90`.
- Whether any characteristic indicates rather than notifies.
- Whether the sequence counter restarts on each connection or on each
  start write.
- Whether more than one central can connect, and whether the sensor
  accepts or asks for a bond.
- Where Beddit 3's room temperature and humidity readings travel. They
  might be the second BTLEv3 channel, or they might exist only in the iOS
  app's protocol.
- Whether the sensor stops streaming by itself, for example when the bed
  is empty.
- The chipset, and what the Beddit 3 filing's exhibits (2AI4U-B3) say.

## Tools Used

- [x] jadx static decompile of the Android app (2.3.12), with the
      disassembled bytecode checked where the write-ups disagreed
- [x] FCC listings for 2AI4U-B3 and BCG-B35; the BCG-B35 user guide and
      BLE test report (Internet Archive copies)
- [ ] nRF Connect / BLE sniffer against a real strip, which is the next
      step and would settle most of the open questions

## References

- [Beddit Sleep Monitor user guide, model 3.5 (FCC exhibit, Internet Archive)](https://web.archive.org/web/20250110173852/https://fccid.io/BCG-B35/User-Manual/B35-user-guide-4071459.pdf): placement, power adapter, where the ID number is printed
- [Beddit 3 (B3) user manual, FCC exhibit 3094679 (ManualsLib)](https://www.manualslib.com/manual/1328024/Beddit-B3-3094679.html): quick installation guide for the original Beddit 3; not read for this spec
- [FCC ID 2AI4U-B3](https://fccid.io/2AI4U-B3) (Beddit 3, Beddit Oy; the mirror refuses scripted clients)
- [FCC ID BCG-B35 (Internet Archive)](https://web.archive.org/web/20221024082234/https://fccid.io/BCG-B35) (model 3.5, Apple)
- [FCC BCG-B35 BLE test report (Internet Archive)](https://web.archive.org/web/20250110064920/https://fccid.io/BCG-B35/Test-Report/12289553-E1V2-FCC-IC-Report-BLE-Final-revised-4071460.pdf)
- [Beddit app on Google Play (Internet Archive, 2017-04-13)](https://web.archive.org/web/20170413023340/https://play.google.com/store/apps/details?id=com.beddit.beddit)
- [MacRumors: FCC approval for Beddit 3.5 (2018-12-05)](https://www.macrumors.com/2018/12/05/apple-fcc-approval-sleep-monitor-beddit-3-5/)
- [MacRumors: Apple begins selling Beddit 3.5 (2018-12-07)](https://www.macrumors.com/2018/12/07/apple-selling-new-beddit-sleep-monitor/)
- [MacRumors: Beddit 3 at Apple Stores (2016-09-26)](https://www.macrumors.com/2016/09/26/beddit-3-sleep-tracker-apple-stores/)
- [AppleInsider: Beddit cloud shutdown on Nov. 15 (2018-09-21, Internet Archive)](https://web.archive.org/web/20180927192024/https://appleinsider.com/articles/18/09/21/apple-owned-beddit-to-shut-down-cloud-services-on-nov-15)
- [Gadgets & Wearables: Apple stops selling Beddit (2022-01-12)](https://gadgetsandwearables.com/2022/01/12/beddit-sleep-monitor-buy/)
- [9to5Mac: Apple removes Beddit apps (2024-09-30)](https://9to5mac.com/2024/09/30/apple-removes-beddit-app-store/)
- [MacRumors: Beddit topic page](https://www.macrumors.com/guide/beddit/)
- Machine-readable spec: `device-specs/devices/beddit-sleep-monitor.yaml`

## Contributors

- Initial spec from static analysis of the Android app
