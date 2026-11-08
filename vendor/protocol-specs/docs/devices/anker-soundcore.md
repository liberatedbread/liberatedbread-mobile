# Anker soundcore Earbuds, Headphones and Speakers

> **Status**: Spec Available
> **Protocol**: Bluetooth Classic, RFCOMM to a per-model vendor UUID or SPP (BLE for discovery; a GATT tunnel on some models)
> **Manufacturer**: Anker Innovations Limited (soundcore brand)
> **Manufacturer Status**: Active

## Overview

Anker's soundcore range covers true-wireless earbuds (Liberty, Life, Space),
over-ear headphones (Life Q, Space Q) and portable speakers (Motion and
others). The **soundcore** app changes settings the hardware keeps itself:
noise cancelling, transparency or normal mode, the equaliser, button mapping,
auto power-off, voice prompts and firmware. Audio is ordinary A2DP and HFP
and needs no app at all.

The reason to document it anyway is the app. Recent versions ask for an
account, show full-screen advertising before the device screen and bundle an
AI assistant, and store reviews say so at length. The device needs none of
that. Its control channel is an unauthenticated RFCOMM socket speaking a
small framed binary protocol, which two open-source clients already
implement: [OpenSCQ30](https://github.com/Oppzippy/OpenSCQ30) and
[SoundcoreManager](https://github.com/gmallios/SoundcoreManager).

The protocol is a **family keyed by the SKU** (`A3947`, `A3116`, ...), not one
command set. The frame is shared, but command IDs mean different things on
different models, and the state reply has a different layout on each. This
page and the spec describe the shared frame, a table mapping 60-odd SKUs to
their control channel, and three models in full:

| Model | Evidence |
|---|---|
| **Liberty 4 NC (A3947)**, earbuds | Public HCI capture of the vendor app ([SoundcoreManager #162](https://github.com/gmallios/SoundcoreManager/issues/162)): frames, checksums and SDP records `confirmed` |
| **Motion+ (A3116)**, speaker | Public HCI capture of the vendor app ([OpenSCQ30 #215](https://github.com/Oppzippy/OpenSCQ30/issues/215)): frames, the missing checksum and SDP records `confirmed` |
| **Life Q30 / Life Tune (A3028 / A3029)**, headphones | OpenSCQ30 and SoundcoreManager only: `reported` |

For any other model, take its command set from OpenSCQ30's per-model module
(`lib/src/devices/soundcore/<sku>.rs`) before sending it anything.

Machine-readable spec: `device-specs/devices/anker-soundcore.yaml`. Where this
page and the spec disagree, the spec wins.

## Hardware

| Property | Liberty 4 NC | Motion+ | Life Q30 / Life Tune |
|----------|--------------|---------|----------------------|
| SKU | A3947 | A3116 | A3028 / A3029 |
| Type | True-wireless earbuds, adaptive ANC, LDAC, charging case with a button | 30 W portable speaker, aptX, AUX in, TWS pairing with a second Motion+ | Over-ear ANC headphones, NFC pairing |
| FCC ID | [2AOKB-A3947](https://fccid.co/fcc/2AOKB-A3947) (granted 2023-03-28) | [2AOKB-A3116](https://fccid.io/2AOKB-A3116) | [2AOKB-A3028](https://fccid.co/fcc/2AOKB-A3028) (granted 2020-08-12; both models) |
| Chipset | Bestechnic (BES), going by its SDP records `TOTA` and `BESOTA` | Qualcomm/CSR, going by its SDP record `CSR GAIA` and aptX support | Unknown |
| Classic name | `soundcore Liberty 4 NC` (captured) | `Soundcore Motion+` (manual) | `Soundcore Life Q30` / `Soundcore Life Tune` |
| Control channel | vendor UUID `0cf12d31-fac3-4553-bd80-d6832e7b3947`, channel 15 in the capture | vendor UUID `0cf12d31-fac3-4553-bd80-d6832e7b3116`, channel 1 in the capture | SPP `00001101-0000-1000-8000-00805f9b34fb` (vendor app's table) |
| Checksum byte | yes | **no** | yes |
| Captured firmware | 04.88 (both buds) | 80.01 | n/a |
| Observed OUI | `E8:EE:CC` (Fantasia Trading LLC, Anker's US company) | `7C:96:D2` (Fihonest Communication) | n/a |

The grantee on all three FCC IDs is Anker Innovations Limited (grantee code
`2AOKB`), 2402-2480 MHz. One unit each was seen, so the OUIs are weak
signals. The A3947's BLE advertisements come from a random address with no
OUI at all.

## Initial Setup

| Property | Value |
|----------|-------|
| Setup required | Yes: ordinary Bluetooth pairing from the host's settings |
| Method | `bt_classic_pairing` |
| Advertised name | `soundcore …` (current products) / `Soundcore …` (older) |
| Passphrase protection | not_applicable (no network, no credentials) |
| Confidence | medium (FCC-filed manuals; pairing not observed in the captures) |

The vendor app provisions nothing. It lists bonded devices, recognises the
model, and opens the control socket. Its account is for the vendor cloud,
which the device never contacts. A client does the same:

1. **Pair the device** from the phone or computer's Bluetooth settings (see
   [Pairing](#pairing) for each model's button).
2. **Browse SDP** and pick the control record. Take the vendor UUID
   `0cf12d31-fac3-4553-bd80-d6832e7b<sku>` if it is there; otherwise take SPP
   `00001101-0000-1000-8000-00805f9b34fb`. This is OpenSCQ30's rule, and it
   matters: on a Liberty 4 NC the record with the SPP class is Bestechnic's
   test service `TOTA` (channel 12), not the control channel.
3. **Open an insecure RFCOMM socket** to it. The vendor Android app always
   uses the insecure constructor; the link is already bonded for audio.
4. **Send the model's state request** and read the reply by its length field.

There is no handshake and no authentication in either capture.

**Factory reset**

| Model | Procedure | Source |
|---|---|---|
| Liberty 4 NC (A3947) | Earbuds in the case, lid open. Hold the case button all the way down for **10 s** until the LEDs flash white rapidly three times. | Quick guide, FCC exhibit, panel 13 |
| Life Q30 / Life Tune (A3028 / A3029) | Hold **power + volume up** together for **5 s**. | Manuals, FCC exhibits |
| Motion+ (A3116) | None documented. The manual only says to remove the speaker from the phone's Bluetooth list and pair again. | Vendor manual (2020-11) |

None of these has been tried by this project, and the manuals do not say
what a reset clears.

**Rebinding to a new phone**: pair it like any other host. The earbuds and
headphones remember more than one host. The Motion+ reconnects to the last
host at power-on and re-enters pairing mode from its Bluetooth button.
Nothing in the control protocol is tied to a phone or an account.

## Pairing

| Property | Value |
|----------|-------|
| Pairing required | Yes (it is an audio device; both open clients list only bonded devices) |
| Security mode | `just_works` (inferred: no display or keypad; not observed) |
| Bonding | `required` |
| PIN source | none |
| One central at a time | Unknown for the control channel; the vendor app held it for its whole session in both captures |
| One bond at a time | No: dual connection / dual pairing in the manuals |
| Confidence | medium |

**Entering pairing mode** (from the manuals, not tried):

- **Liberty 4 NC (A3947)**: opening the case the first time powers the buds on
  and makes them pairable. Manually: buds in the case, lid open, hold the case
  button for **3 s** until the LEDs flash white rapidly. To add a second
  host, wear both buds and hold both touchpads for **3 s** at the same time.
- **Life Q30 / Life Tune (A3028 / A3029)**: from off, hold power for **5 s**
  until the LED flashes blue. After the first host connects, press power
  twice to pair a second. Android phones can also tap the right ear cup (NFC).
- **Motion+ (A3116)**: at power-on it reconnects to the last host or becomes
  pairable. Press the Bluetooth button to re-enter pairing mode; the
  indicator fades blue in and out while pairable and is solid blue once
  connected.

**Unpairing**: no button or command removes one host from the device's list.
Forget the device on the host. The factory reset presumably clears the device
side too, but the manuals do not say so.

**Recovery**: close the vendor app, or turn off Bluetooth on its phone, before
connecting from another client. If the device will not show up, remove it
from the host's Bluetooth list and pair again.

## Protocol Summary

### Bluetooth Classic profiles

| Property | Value |
|----------|-------|
| Control profile | vendor RFCOMM UUID `0cf12d31-fac3-4553-bd80-d6832e7b<sku>` on most models; SPP `00001101-0000-1000-8000-00805f9b34fb` on older earbuds and headphones |
| Socket | insecure (the vendor app never opens a secure one); the link is bonded for audio anyway |
| Dual-mode | Yes. BLE role: secondary control on some models (SoundcoreManager's GATT tunnel), discovery elsewhere |
| iOS reachable | Not over RFCOMM (CoreBluetooth has none). The vendor iOS app probably uses the BLE GATT tunnel; not examined |

SDP records seen in the captures:

| Record | A3947 | A3116 | Role |
|---|---|---|---|
| vendor `0cf12d31-fac3-4553-bd80-d6832e7b<sku>` | "Spp1", channel 15 | "CSR GAIA", channel 1 | **Control**: every soundcore frame |
| SPP `00001101-0000-1000-8000-00805f9b34fb` | "TOTA", channel 12 | none | BES test service. Not the control channel |
| `66666666-6666-6666-6666-666666666666` | "BESOTA", channel 13 | none | BES firmware update (out of scope) |
| `df21fe2c-2515-4fdb-8886-f12c4d67927c` | "RFCOMM COM", channel 17 | none | Google Fast Pair Message Stream (opened by Android, not the app) |
| HFP / HSP | channels 3 / 1 | channels 12 / 11 | Telephony |
| A2DP sink, AVRCP | L2CAP 25, 23 | L2CAP 25, 23 | Audio |

The Motion+ has **no** record with the SPP class, so a client that opens "the
serial port" by `00001101-…` finds nothing on it. Its control record is named
"CSR GAIA" (the slot a Qualcomm/CSR SoC reserves for its GAIA protocol) but
carries soundcore frames, not GAIA.

### Frame format

```
phone -> device:  08 ee 00 00 00 | c1 c2 | len_lo len_hi | payload... | [sum]
device -> phone:  09 ff 00 00 01 | c1 c2 | len_lo len_hi | payload... | [sum]
```

| Field | Offset | Size | Notes |
|---|---|---|---|
| Direction | 0 | 5 | `08 ee 00 00 00` out, `09 ff 00 00 01` in |
| Command | 5 | 2 | A reply repeats the command it answers |
| Length | 7 | 2 | u16 **little-endian**, counts the **whole frame**, header to last byte |
| Payload | 9 | len − 9 (− 1) | Per command, per model |
| Checksum | last | 1 | Sum of every preceding byte mod 256. **Absent on the Motion+ (A3116).** |

Split the stream by the length field; that works with or without a checksum.
A set is acknowledged with an empty-payload frame carrying the same command.
The vendor app sent one frame at a time and waited for its answer.

Worked examples, all captured:

```
08 ee 00 00 00 01 01 0a 00 02            A3947 state request: 08+ee+01+01+0a = 0x102 -> 02
09 ff 00 00 01 06 81 0a 00 9a            A3947 acknowledgement of a sound-mode set
08 ee 00 00 00 01 01 09 00               A3116 state request: 9 bytes, no checksum
09 ff 00 00 01 01 10 0a 00 01            A3116 voice-prompt reply (on): payload 01, no checksum
```

OpenSCQ30 treats the checksum as a per-model setting, and the Motion+ is the
only model it knows of without one. A client meeting an unknown model can
check the first reply: if its last byte is the sum of the others, the model
uses checksums.

### Commands

**Liberty 4 NC (A3947)**, checksummed:

| Command | Frame | Reply | Status |
|---|---|---|---|
| State | `08 ee 00 00 00 01 01 0a 00 02` | `09 ff 00 00 01 01 01`, 169 bytes on firmware 04.88 | confirmed |
| LDAC query | `08 ee 00 00 00 01 7f 0a 00 80` | `… 01 7f 0b 00 <ldac> <sum>` | confirmed exchange; meaning from OpenSCQ30 |
| Sound modes | `08 ee 00 00 00 06 81 11 00` + 7 bytes + sum | empty ack | confirmed |

The seven sound-mode bytes are, in order: ambient mode (0 noise cancelling, 1
transparency, 2 normal); ANC strengths (high nibble manual 0-5, low nibble
adaptive 0-5); transparency (0 full, 1 vocal); NC mode (0 manual, 1 adaptive,
2 transportation); wind noise (bit 0 suppression); environment detection
(0/1); transportation type (0 plane, 1 train, 2 bus, 3 car). The same seven
bytes sit at offsets 135-141 of the state reply. To change one, read the
state and send the other six back unchanged, as the vendor app did:

```
08 ee 00 00 00 06 81 11 00 02 50 00 01 00 00 00 e1   normal       (captured)
08 ee 00 00 00 06 81 11 00 01 50 00 01 00 00 00 e0   transparency (captured)
08 ee 00 00 00 06 81 11 00 00 50 00 01 00 00 00 df   noise cancel (captured)
```

State reply fields (offsets from the first byte of the frame): 9 host earbud,
10 buds linked, 11-12 battery left/right (0-5 steps, **not percent**), 13-14
charging left/right, 15-19 and 20-24 firmware left/right (ASCII `NN.NN`),
25-40 serial number (ASCII), 46-47 EQ preset (u16 LE), 48-67 EQ bands, 135-141
sound modes, 148 case battery (0-5), 163-164 auto power-off. The offsets past
the serial number come from OpenSCQ30's A3947 parser, and every one decoded
sensibly on the captured frame. The case battery read 2 while the same
unit's Fast Pair report said 40 %.

**Motion+ (A3116)**, no checksum:

| Command | Frame | Reply | Status |
|---|---|---|---|
| State | `08 ee 00 00 00 01 01 09 00` | 45 bytes: 9 charging, 10 battery (0-5), 11 volume (0-16), 13 auto-off, 14-18 firmware, 19-34 serial, 35 EQ preset, 36-44 EQ bands | confirmed |
| Voice prompt? | `08 ee 00 00 00 01 10 09 00` | `… 01 10 0a 00 <0/1>` | confirmed |
| Voice prompt on/off | `08 ee 00 00 00 01 90 0a 00 <0/1>` | ack | confirmed |
| Volume | `08 ee 00 00 00 01 81 0a 00 <0-16>` | ack | confirmed |
| Auto power-off | `08 ee 00 00 00 01 83 0a 00 <1-4>` (5/10/30/60 min) | ack, then push `01 05 <value>` | confirmed |
| EQ preset | `08 ee 00 00 00 02 81 0a 00 <p>`: 0 BassUp, 1 BassOff, 2 Voice, 3 Heavy, 4 Classic, 5 Original, ff custom | ack, then push `02 01 <p>` | confirmed |
| Custom EQ | `08 ee 00 00 00 02 83 12 00` + 9 bands (dB + 6; 80 Hz … 12 kHz) | ack | confirmed |
| Power off | `08 ee 00 00 00 01 85 09 00` | link drops | reported |
| `05 01` | `08 ee 00 00 00 05 01 09 00` | 41 bytes, 16 × u16 LE, meaning unknown | confirmed exchange |

**Life Q30 / Life Tune (A3028 / A3029)**, checksummed, all from OpenSCQ30:

| Command | Frame | Notes |
|---|---|---|
| State | `08 ee 00 00 00 01 01 0a 00 02` | 70 bytes on older firmware: 9 battery, 10 charging, 11-12 EQ preset, 13-20 bands, 44-47 sound modes, 48-52 firmware, 53-68 serial; newer firmware appends fields |
| Sound modes | `08 ee 00 00 00 06 81 0e 00` + 4 bytes + sum | ambient (0 NC, 1 transparency, 2 normal), NC mode (0 transport, 1 outdoor, 2 indoor), transparency, custom strength |
| Equaliser | `08 ee 00 00 00 02 81 14 00` + preset (u16 LE) + 8 bands + sum | band byte = gain in tenths of a dB + 120; preset `fe fe` = custom |

**Commands mean different things on different models.** `01 81` is volume
on the Motion+ and auto play/pause on earbuds; `01 83` is auto power-off on
the Motion+ and touch tones on earbuds; `01 05` is a Motion+ push but the
serial/firmware reply on earbuds. Never send a command to a model it was not
documented for.

### Unsolicited frames

| Prefix | Model | Payload |
|---|---|---|
| `09 ff 00 00 01 02 01` | A3116 | EQ preset, after every preset set (confirmed) |
| `09 ff 00 00 01 01 05` | A3116 | Auto power-off value, after every set (confirmed; meaning inferred from the echo) |
| `09 ff 00 00 01 01 03` | all | Battery levels (reported) |
| `09 ff 00 00 01 01 04` | all | Charging flags (reported) |
| `09 ff 00 00 01 06 01` | earbuds, headphones | Sound modes changed on the device (reported) |

### BLE

Many models advertise over BLE so the app can find them without an inquiry.
The advertisement carries a model code as a service UUID and the device's
**BR/EDR address in its manufacturer data**. A client reads that address and
opens RFCOMM to it, not to the advertiser's address:

| | A3947 (captured) | Older models (vendor app, reported) |
|---|---|---|
| Service UUID | 32-bit, raw `01 4e f5 da` = `daf54e01-0000-1000-8000-00805f9b34fb` | 128-bit `01XXf5da-0000-1000-8000-00805f9b34fb`, XX per model (`12` for most earbuds, `0a` for the Motion+) |
| Manufacturer data | 8 bytes: BR/EDR address **MSB first**, then `00 00`. No company ID | 7 bytes: BR/EDR address **LSB first**, then one byte |
| Also | Google Fast Pair service data (`0xfe2c`) | |

Some models also tunnel the same frames over a GATT service.
SoundcoreManager drives the A3951, A3027, A3028, A3029 and A3935 that way
(from Windows), picking the first non-generic service with a notify+read and
a write+write-without-response characteristic. That layout is not documented
here.

### Model table

`protocol_details.model_table` in the spec maps each SKU the vendor app
(an older 2.9.9 build) knew to its control channel and BLE code. In short:

- **Vendor UUID** (`0cf12d31-fac3-4553-bd80-d6832e7b<code>`): all the speakers
  (Soundcore 3, Mini 3, Motion+, Motion Boom, Flare, Rave, Trance, Select,
  Icon+, Infini Pro, Boost …), PowerConf, Frames, and newer earbuds (Life A1,
  Life Note 3/3S/3i, Life P3/P3i, Life Dot 3i, Life A3i, Liberty Neo 2,
  Liberty 3 Pro, Life Q20+, Life 2 Neo). The Liberty 4 NC, too new for that
  build, follows the same rule (captured).
- **SPP**: Life Q30, Q35, Tune and Tune Pro; Liberty 2, 2 Pro, 2 Pro+; Liberty
  Air 2 and Air 2 Pro; Life A2 NC; Life Dot 2 NC.

Some speakers also have a per-model OTA UUID with `7c` in place of `7b`.
OpenSCQ30's list of 38 supported SKUs is in the spec too. It covers models
the table lacks, such as the Space Q45 (A3040) and Space A40 (A3936).

### Fast Pair (A3947)

Android itself opens Google's
[Fast Pair Message Stream](https://developers.google.com/nearby/fast-pair/specifications/extensions/messagestream)
on the Liberty 4 NC, next to the soundcore channel. In the capture it
carried the model ID `D1E4E3`, the BLE address, and a battery report for left,
right and case in percent (bit 7 = charging). A client that only wants battery
percentages can read them there without the vendor protocol.

### Firmware update

Out of scope, and deliberately not examined: a failed transfer can leave
earbuds unbootable. What is known: the A3947 publishes a BES OTA channel
(`BESOTA`, captured) and the app bundles a BES updater. The app also bundles a
Qualcomm GAIA BR/EDR service that may serve the Motion+ (unverified), and
some speakers have per-model `7c` OTA UUIDs. Images come from the vendor
cloud.

### Controls a client can offer

| Model | Controls |
|---|---|
| A3947 | Battery (left, right, case, 0-5), charging, sound mode, NC mode, firmware |
| A3116 | Battery (0-5), charging, volume (0-16), EQ preset, auto power-off, voice prompts, power off, firmware |
| A3028 / A3029 | Battery (0-5), charging, sound mode, NC mode, firmware |

EQ curves are declared as commands but not bound to a control, because no
entity type holds an eight- or nine-band curve.

## Troubleshooting: what the evidence says about common complaints

### "The app says not connected, but the earbuds are playing"

A recurring review, including for the Liberty 4 NC. Audio (A2DP) and control
(the RFCOMM channel) are separate links, so one can be up while the other is
down. On the Liberty 4 NC the record with the SPP class is the wrong one
(`TOTA`, channel 12), and only one client may be able to hold the control
channel. **Try**: close every other soundcore client, including the vendor
app's background service, then reconnect. A client of your own should open
the vendor UUID, not SPP.

### A Motion+ that no third-party client can connect to

The Motion+ has no SPP-class SDP record: its only serial record is the vendor
UUID, named "CSR GAIA". A client that asks for `00001101-…` gets nothing.
OpenSCQ30 now pins the vendor UUID for this model, and its changelog lists
several Motion+ connection fixes. The Motion+ also sends and expects frames
**without** a checksum, so a parser that insists on one rejects every reply.

### "Gaming mode shows as on but does nothing" (Liberty 4 NC)

Reported in a 2026-09 review. OpenSCQ30 handles gaming mode on the A3947 with
a model-specific module. Not examined here.

### Forced account, ads, AI

Nothing on the device side needs any of it: both captured sessions are
unauthenticated byte frames on a local socket. OpenSCQ30 (Android, Linux,
Windows) covers most models without an account.

### Capturing a model not covered here

1. On Android, enable Developer options → **Enable Bluetooth HCI snoop log**,
   toggle Bluetooth, then use each control once in the vendor app
   ([Android's guide](https://source.android.com/docs/core/connect/bluetooth/verifying_debugging)).
2. Pull `btsnoop_hci.log` from `adb bugreport` and filter `btrfcomm` in
   Wireshark. Payloads starting `08 ee` and `09 ff` are this protocol.
3. Your unit's address and serial number belong in your notes only. On the
   Liberty 4 NC seen here, the serial number is `3947` followed by the unit's
   own BR/EDR address byte-reversed (a unit at `aa:bb:cc:dd:ee:ff` would read
   `3947FFEEDDCCBBAA`), so treat the state reply as identifying.

From Linux, a first look:

```bash
sdptool browse aa:bb:cc:dd:ee:ff    # find the 0cf12d31-…-d6832e7b<sku> record and its channel
```

```python
import socket
ADDR, CHANNEL = "aa:bb:cc:dd:ee:ff", 15      # channel from sdptool (15 on the captured A3947)
CHECKSUM = True                              # False for the Motion+ (A3116)

def frame(cmd, payload=b""):
    n = 9 + len(payload) + (1 if CHECKSUM else 0)
    b = bytes([0x08, 0xee, 0, 0, 0]) + bytes(cmd) + n.to_bytes(2, "little") + payload
    return b + bytes([sum(b) & 0xff]) if CHECKSUM else b

s = socket.socket(socket.AF_BLUETOOTH, socket.SOCK_STREAM, socket.BTPROTO_RFCOMM)
s.connect((ADDR, CHANNEL))
s.send(frame([0x01, 0x01]))                  # state request
buf = b""
while len(buf) < 9 or len(buf) < int.from_bytes(buf[7:9], "little"):
    buf += s.recv(1024)
print(buf.hex(" "))                          # 09 ff 00 00 01 01 01 …
```

## Tools Used

- [x] Wireshark / tshark: `btrfcomm` and `btsdp` dissectors on the two public captures
- [x] A small SDP continuation reassembler, to recover the full service records
- [x] Static analysis of an older vendor Android build, for the model table and socket flags
- [x] OpenSCQ30 and SoundcoreManager source, for payload meanings
- [ ] A run against real hardware by this project

## References

- [OpenSCQ30](https://github.com/Oppzippy/OpenSCQ30): open-source client, one
  module per model. Framing in `lib/src/devices/soundcore/common/packet.rs`,
  models in `lib/src/devices/soundcore/`
- [SoundcoreManager](https://github.com/gmallios/SoundcoreManager): independent
  client over BLE GATT; framing in `soundcore-lib/src/packets/request.rs`
- [SoundcoreManager #162](https://github.com/gmallios/SoundcoreManager/issues/162):
  Liberty 4 NC HCI capture
- [OpenSCQ30 #215](https://github.com/Oppzippy/OpenSCQ30/issues/215): Motion+
  HCI capture
- [Liberty 4 NC (A3947) quick guide, FCC exhibit (PDF)](https://fccid.co/api/files/s1/2aokb_a3947_usersmanual_6445546_7382539816.pdf)
- [Life Q30 (A3028) manual, FCC exhibit (PDF)](https://fccid.co/api/files/s1/2aokb_a3028_usersmanual_4855093_b44fac2725.pdf)
- [Life Tune (A3029) manual, FCC exhibit (PDF)](https://fccid.co/api/files/s1/2aokb_a3028_usersmanual_4855095_d45c23a20f.pdf)
- [Motion+ (A3116) user manual, vendor-hosted (PDF)](https://dix7fd4yse9rd.cloudfront.net/s/Soundcore/product/6109030547646/files/1608603719981_soundcorea3116manualmulti20201125v02.pdf)
- FCC grants: [2AOKB-A3947](https://fccid.co/fcc/2AOKB-A3947),
  [2AOKB-A3028](https://fccid.co/fcc/2AOKB-A3028),
  [2AOKB-A3116](https://fccid.io/2AOKB-A3116)
- [Google Fast Pair Message Stream](https://developers.google.com/nearby/fast-pair/specifications/extensions/messagestream)
- [Common Bluetooth Classic Patterns](../protocols/bluetooth-classic-common.md)

## Contributors

- @claude - capture analysis (two public HCI logs), open-source cross-check, static analysis of the vendor Android app, spec and page
