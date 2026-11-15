# Beddit Sleep Tracker (Bluetooth Classic generation)

> **Status**: Spec Available (static analysis of the last Android app; no capture, no hardware)
> **Protocol**: Bluetooth Classic (SPP over RFCOMM, insecure socket)
> **Manufacturer**: Beddit (Apple)
> **Manufacturer Status**: Shutdown: cloud off since 2018-11-15, hardware discontinued, apps pulled

## Overview

Beddit made thin sensor strips that lie under the bed sheet and record
**ballistocardiography** (BCG): the tiny mechanical forces that the
heartbeat, breathing and body movement put into a mattress. Apple bought
Beddit in 2017, shut Beddit Cloud down on 2018-11-15, stopped selling the
hardware in 2022 and pulled the apps in 2024.

The last Android app (2.3.12) drives three sensor generations. This page
covers the one it reaches over **Bluetooth Classic**, which the app tags
with the hardware type `BT2`. The two BLE generations (`BTLE` and `BTLEv3`)
are documented separately in
[Beddit Sleep Monitor 3 / 3.5](beddit-sleep-monitor.md).

The protocol is small: an insecure SPP socket, a two-line ASCII handshake
(`OK`, `INFO`), then `START 5` and a stream of CRC-32-checked binary frames
of raw 16-bit force samples. While streaming, the host sends `CONT` about
every ten frames (first after frame 10, then before every 11th frame), and
it sends `STOP` at the end.

The sensor sends **only the raw waveform**. The app computes sleep stages,
heart rate, respiration and the sleep score on the phone, in a native
signal-processing library it bundles. So a client built from this spec gets
a live BCG signal, and deriving heart rate or sleep stages from it is a
separate job. The app has no command that downloads a stored night.

!!! warning "Which product is this?"
    The research this page started from calls this sensor the "Beddit 2
    (Smart)", and the spec file keeps that name
    (`beddit-2-sleep-tracker`). The evidence points elsewhere:

    - Beddit Smart, which retail listings titled "Beddit 2.0 Smart Sleep
      Tracker" (2015), connected over **Bluetooth Smart**, which is BLE
      (Sleep Review, 2015).
    - Beddit's November 2015 Android announcement names two supported
      products: **Beddit Smart** and **Beddit Classic**.
    - In October 2015 a commenter who said he worked for Beddit in the US
      described them as "Classic (the original) and Smart", with Bluetooth
      Smart and automatic tracking only on the Smart (9to5Mac, reader
      comment; a weak source).
    - The app has exactly two pre-Beddit-3 hardware types: `BT2`, reached
      over Classic SPP, and `BTLE`, the GATT service
      `f82fd8a8-329d-4c44-a178-e82f91ec9fe6` in the BLE spec. Beddit 3 is
      `BTLEv3`. The three labels name radios, not products.
    - Wolfram's device catalogue lists the original Beddit Sleep Tracker as
      **Bluetooth 2.0**.
    - The app's server-side replacement check covers `BT2` and `BTLE` and
      exempts only Beddit 3. In April 2017 Beddit told owners of every
      pre-Beddit-3 sensor that it would stop working with the app, and
      offered a free Beddit 3 in exchange (Wareable).

    So `BT2` is most likely the **first-generation Beddit (2013, later sold
    as "Beddit Classic")**, and "BT2" most likely stands for Bluetooth 2.x
    rather than "Beddit 2". Beddit Smart 2.0 is most likely the app's `BTLE`
    type. One fact strains this: the first generation launched with an
    iPhone app (Cult of Mac, 2013), the 2015 comment says the Classic still
    worked with the iOS app of the day, and an SPP-only sensor reaches an
    iPhone only through Apple's MFi accessory channel. This is a hypothesis.
    A Classic inquiry of a labelled unit would settle it.

## Hardware

| Property | Value |
|----------|-------|
| Product | Beddit sensor strip, Bluetooth Classic generation (most likely the 2013 first generation / "Beddit Classic"; see above) |
| Sensor | Thin-film force sensor under the sheet (ballistocardiography) |
| Radio | Bluetooth Classic (BR/EDR), SPP. Bluetooth 2.0 per Wolfram's catalogue (weak source). Classic-only: no BLE side |
| Bluetooth module | Bluegiga: the app treats the Bluegiga OUI `00:07:80` as the mark of this generation. The module model is unknown |
| Power | Mains power adapter, per the app's setup text |
| Companion apps | Beddit for Android (last version 2.3.12, delisted). An iPhone app from the 2013 launch on, which reached the sensor by a route nobody has analysed (see the Bluetooth Classic profile table) |
| FCC ID | None found. No Beddit filing covers this generation; the module's own grant is unidentified |
| Manual | None found |

## Initial Setup

| Property | Value |
|----------|-------|
| Setup required | No |
| Method | `none` (insecure RFCOMM socket, nothing to provision) |
| Inquiry name | Starts with `beddit`, compared case-insensitively. Real name unrecorded; probably includes the device number printed on the back |
| Passphrase protection | not_applicable |
| Confidence | low (static analysis only) |

1. Lay the strip on the bed under the bottom sheet and plug its power
   adapter into the wall. The app's instructions say no more than this.
   Exact placement on the mattress is not recorded.
2. Run a Bluetooth Classic inquiry and pick the device whose name starts
   with `beddit`. A household with several strips tells them apart by the
   device number on the back of each one.
3. Open an **insecure** RFCOMM socket to SPP
   `00001101-0000-1000-8000-00805f9b34fb`. If that fails, wait about 2 s
   and connect straight to RFCOMM channel 1, as the app does.
4. Send `OK`, then `INFO`. Save the address, the channel order, the sample
   rate and the version.

That is the whole of the vendor app's "setup". It closes the socket after
`INFO` and reconnects by address for each night, and never scans again.

**Factory reset**: none known, and nothing known to clear. The app writes
nothing to the sensor except the five session lines, and it never bonds.
For a wedged sensor, unplug the adapter for a few seconds. That is a power
cycle, not a reset.

**Rebinding**: nothing is bound. A new phone or client just connects.

## Pairing

| Property | Value |
|----------|-------|
| Pairing required | No (reported) |
| Security mode | `none`: insecure RFCOMM socket |
| Bonding | `none`: the app never bonds |
| PIN source | n/a (no PIN known) |
| One central at a time | Unknown (probably: serial modules usually carry one SPP link) |
| One bond at a time | n/a |
| Confidence | low |

The app opens the socket insecure and has **no** code that bonds, sets a
PIN or reacts to a pairing request. It never tells the user to pair in the
OS settings either. A module that demanded authentication would make
Android show a PIN dialog the app never mentions, so the firmware almost
certainly accepts an unauthenticated link. Bonding is recorded as `none`,
the catalogue's rule for a device whose only profile is opened insecure.
The one doubt is a module with Bluetooth 2.1 or later: the phone's stack
might run Secure Simple Pairing Just Works on its own and keep a key. That
would not change what a client does.

**Entering pairing mode**: no button and no window are known. The app asks
only for power and a phone nearby.

**Unpairing**: nothing to unpair.

**Recovery**: close the vendor app, which holds the socket all night while
recording, then power-cycle the strip.

## Protocol Summary

### Bluetooth Classic profile

| Property | Value |
|----------|-------|
| Control profile | SPP `00001101-0000-1000-8000-00805f9b34fb`, RFCOMM channel 1 (the app's fallback; SDP not browsed) |
| Socket | Insecure (no bond) |
| Dual-mode | No |
| iOS reachable | No, not through CoreBluetooth, which has no RFCOMM. The vendor's iPhone app (2013 onwards) implies an MFi (iAP) route that nobody has analysed, and that app is gone from the App Store |
| Android | Yes: the vendor app's own path, Android 4.0 and up |
| Linux | Should work: a plain BlueZ RFCOMM socket, no agent (hypothesis, untested) |
| macOS | IOBluetooth exposes RFCOMM; untested |

The app decides at scan time whether a `beddit…` device is BLE or Classic:

| Android reports | App uses |
|---|---|
| LE | BLE path (the other spec) |
| Classic or dual-mode | **This SPP path** |
| Unknown type, address starts `00:07:80` | **This SPP path** |
| Unknown type, any other address | BLE path |
| (Android older than 4.3) | Always this SPP path |

### Session

All text is US-ASCII, and each line ends in a single LF (`0x0a`), with no CR.

| Step | Host sends | Bytes | Sensor answers | App's limits |
|---|---|---|---|---|
| 1 | `OK` | `4f 4b 0a` | `OK` + LF, exactly | 5 s, LF within the first 10 bytes |
| 2 | `INFO` | `49 4e 46 4f 0a` | one line: `INFO` + `KEY:VALUE;…` | 5 s, 999 bytes before the LF |
| 3 | nothing | | | Idle until a recording starts. No keep-alive, no timeout |
| 4 | `START 5` | `53 54 41 52 54 20 35 0a` | binary frames, no text ack | each read 5 s |
| 5 | `CONT` | `43 4f 4e 54 0a` | nothing | once 10 frames have arrived, then before every 11th |
| 6 | `STOP` | `53 54 4f 50 0a` | unknown (the app reads nothing) | only on an orderly stop |

The meaning of the `5` in `START 5` is not visible in the app, which always
sends that literal. What the sensor does without `CONT` is unknown, so copy
the app's cadence.

### `INFO` reply

`INFO`, then pairs separated by `;`. Each pair splits at its first `:`.
Keys are trimmed and case-insensitive, and values are trimmed. A value
containing `,` is a list.

| Key | Required | Meaning |
|---|---|---|
| `CHANNELS` | yes | Channel names, comma-separated, **in the order their samples are interleaved**. The app renames `normal` to `force` and keeps only that channel |
| `SAMPLERATE` | yes | Samples per second per channel, in Hz. Decimal; the app parses it as a float |
| `VERSION` | no | Firmware version string (the app records `undefined` when absent) |

No real `INFO` line has been recorded. The shape is
`INFO CHANNELS:<name1>,<name2>;SAMPLERATE:<hz>;VERSION:<fw>`, and every
value in it is a placeholder.

### Stream frame

| Offset | Length | Field | Type | Notes |
|---|---|---|---|---|
| 0 | 4 | counter | uint32 LE | 0 for the first frame after `START`, then +1 per frame |
| 4 | 2 | payload length `L` | uint16 LE, bytes | The app rejects anything over 65000 |
| 6 | `L` | payload | bytes | Interleaved samples `ch0[0], ch1[0], …, ch0[1], …`. Each sample is a uint16 LE. `L / (2 × N)` samples per channel for N channels |
| 6 + `L` | 4 | CRC-32 | uint32 LE | Over bytes `0 … 6+L−1` (header and payload) |

- **Samples** are raw, uncalibrated force counts. The app declares the
  force channel to its analysis as unsigned 16-bit. Sample `n` was taken
  `n / SAMPLERATE` s after the first sample following `START`.
- **CRC** is the standard zlib / IEEE 802.3 CRC-32 (CRC-32/ISO-HDLC):
  reflected polynomial `0xedb88320`, init `0xffffffff`, final XOR
  `0xffffffff`, check value `0xcbf43926`. The app verifies with the
  platform's standard CRC-32, so this is the variant it accepted.
- **Errors**: a counter gap, an oversize length or a CRC mismatch ends the
  session. There is no resync. Close the socket, reconnect and handshake
  again.
- **Timing**: each of a frame's three reads (header, payload, CRC) must
  complete within 5 s, or the app drops the link.

Test vectors (invented values):

| Frame bytes | Decodes to |
|---|---|
| `00 00 00 00 08 00 02 01 04 03 06 05 08 07 a0 8f 12 8f` | counter 0, L 8, two channels: ch0 = 258, 1286; ch1 = 772, 1800; CRC `0x8f128fa0` |
| `01 00 00 00 04 00 00 80 ff 7f 01 cb 72 25` | counter 1, L 4: ch0 = 32768, ch1 = 32767; CRC `0x2572cb01` |

```python
import socket, struct, zlib

s = socket.socket(socket.AF_BLUETOOTH, socket.SOCK_STREAM, socket.BTPROTO_RFCOMM)
s.connect(("aa:bb:cc:dd:ee:ff", 1))           # your strip's address, RFCOMM channel 1
f = s.makefile("rb")

def line():
    return f.readline().rstrip(b"\n").decode("ascii")

s.sendall(b"OK\n")
assert line() == "OK"
s.sendall(b"INFO\n")
info = line()
fields = {}
for part in info[len("INFO"):].split(";"):     # same rules as the app's parser
    if ":" in part:
        key, value = part.split(":", 1)
        fields[key.strip().upper()] = value.strip()
chans = [c.strip() for c in fields["CHANNELS"].split(",")]
rate_hz = float(fields["SAMPLERATE"])
force = chans.index("normal")                  # the app's "force" channel

s.sendall(b"START 5\n")
expected, since_cont = 0, 0
while True:
    since_cont += 1
    if since_cont > 10:                        # the app's CONT cadence
        s.sendall(b"CONT\n")
        since_cont = 0
    hdr = f.read(6)
    counter, length = struct.unpack("<IH", hdr)
    payload = f.read(length)
    (crc,) = struct.unpack("<I", f.read(4))
    assert counter == expected and zlib.crc32(hdr + payload) == crc
    expected += 1
    per_chan = length // (2 * len(chans))      # the app ignores any remainder
    samples = struct.unpack(f"<{per_chan * len(chans)}H", payload[:per_chan * len(chans) * 2])
    force_samples = samples[force::len(chans)]
```

The sketch is untested and has no timeouts. The app gives up on any read
that takes more than 5 s.

## Troubleshooting

These are defects in the vendor app, found in the static read. They explain
failures an owner still running the old app will see, and they are traps a
new client should not copy.

| Symptom | Cause |
|---|---|
| The old Android app fails setup, or cancels every recording, with an error saying the server could not be reached | After each connection to a `BT2` (or `BTLE`) sensor, the app asks Beddit's replacement service (`replacements.beddit.com`) whether the sensor is blocked, and it treats a network error as fatal. The host returns NXDOMAIN (checked 2026-09-28). **The vendor app cannot be used with this sensor any more.** A client built from this spec needs no server |
| Session ends right after `INFO` | The app's parser cannot take a `CHANNELS` value with no comma (one channel), or a `VERSION` that contains a comma |
| Session ends on a large frame | The app reads the payload length sign-extended, so 32768–65535 ends the session. Read it unsigned |
| Recording dies on one bad frame | No resync: any counter gap or CRC error is fatal |
| Handshake fails on a reconnect | The app sends `STOP` only on an orderly stop. After a crash the sensor may still be streaming (unconfirmed). Close, wait and retry |
| An iPhone never sees the strip | CoreBluetooth has no RFCOMM. No workaround is known; the only other iOS route is MFi, which needs the vendor's own app |

## Cloud (dead)

| Host | Role |
|---|---|
| `cloudapi.beddit.com` | Account sign-in and history sync (Beddit Cloud, shut down 2018-11-15) |
| `replacements.beddit.com` | Sensor blocking and replacement check (`GET /blocking_status/<address without colons>?hardware_type=BT2`), which blocks the old app today |

Neither is part of the sensor protocol.

## Open questions

- Which product this is (see the warning above).
- The inquiry name, the Class of Device and the SDP record.
- What `5` in `START 5` means, and what `CONT` does.
- A real `INFO` line: channel names beyond `normal`, the sample rate and
  the version format.
- Whether the module ever asks for a PIN, and whether it stores a bond.
- How the 2013 iPhone app reached the sensor. An MFi (iAP) channel beside
  SPP would explain it. Finding none would cast doubt on the
  first-generation mapping.
- Buttons, LEDs, and whether a reset exists.

An Android Bluetooth HCI snoop log of the old app would answer most of
these. Its setup wizard runs `OK` and `INFO` before the dead-server check
fails, so even a failed setup attempt captures the handshake and a real
`INFO` line. See
[Common Bluetooth Classic Patterns](../protocols/bluetooth-classic-common.md#capturing-one).

## Tools Used

- [x] Static analysis of the vendor Android app (com.beddit.beddit 2.3.12)
- [ ] Bluetooth HCI snoop capture: not yet
- [ ] Hardware session: not yet

## References

- [Beddit launches new Android app (press release, 2015-11-25)](https://www.prweb.com/releases/beddit_launches_new_android_app_making_it_easier_to_understand_and_improve_sleep/prweb13101182.htm):
  the app supports Beddit Smart and Beddit Classic
- [Beddit Smart is the "first ambient" sleep monitor (Sleep Review, 2015)](https://sleepreviewmag.com/curated/beddit-smart-is-first-ambient-sleep-monitor/):
  Smart uses Bluetooth Low Energy
- [Beddit Sleep Tracker (Wolfram Connected Devices)](https://devices.wolfram.com/devices/beddit-sleep-tracker.html):
  lists the original as Bluetooth 2.0 (other details on that page are wrong)
- [Beddit launches Apple Watch app as Smart Sleep Tracker comes to Apple Stores (9to5Mac, 2015)](https://9to5mac.com/2015/10/06/beddit-apple-watch-retail-stores/):
  see the reader comments, where a Beddit employee sets out Classic versus Smart
- [Beddit is phasing out its old devices (Wareable, 2017, Internet Archive copy)](https://web.archive.org/web/20200928092349/https://www.wareable.com/health-and-wellbeing/beddit-3-upgrade-phase-out-3893):
  the phase-out and free-upgrade program behind the replacement check
- [Beddit (Wikipedia)](https://en.wikipedia.org/wiki/Beddit): company
  history, the April 2017 phase-out of older trackers, the acquisition and
  the cloud shutdown
- [Beddit, a permanent sleep tracker that stays in bed (Cult of Mac, 2013)](https://www.cultofmac.com/news/beddit-a-permanent-sleep-tracker-that-stays-in-bed):
  first-generation launch coverage, with the companion iPhone app
- [Archived Google Play listing (2017-04-13)](https://web.archive.org/web/20170413023340/https://play.google.com/store/apps/details?id=com.beddit.beddit)
- [Common Bluetooth Classic Patterns](../protocols/bluetooth-classic-common.md)
  · [Pairing, Bonding and Unpairing](../protocols/pairing.md)
- [Beddit Sleep Monitor 3 / 3.5](beddit-sleep-monitor.md): the BLE generations
- Machine-readable spec: `device-specs/devices/beddit-2-sleep-tracker.yaml`

## Contributors

- Liberated Bread project: static analysis and spec
