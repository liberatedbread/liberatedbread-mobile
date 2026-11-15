# BlueDriver Bluetooth Pro OBD-II Scan Tool (Bluetooth LE)

> **Status**: Spec Available (third-party capture-derived; not replayed against hardware here)
> **Protocol**: BLE (Silicon Labs BGX13P Xpress Streaming profile, XOR-encoded ELM327-style stream)
> **Manufacturer**: Lemur Vehicle Monitors (BlueDriver)
> **Manufacturer Status**: Active

## Overview

BlueDriver is a plug-in OBD-II scanner that ships with a vendor phone app.
This page covers the **Bluetooth LE** units, which advertise a local name
starting `BlueDriv` or `LSB2-`. The vendor marks these with an engraved **LE**
on the side, and the **BlueDriver Pro Next-Gen** is always LE. The original
Bluetooth Classic BlueDriver (no "LE" marking, paired from the phone's
Bluetooth settings) is a different radio path and has not been researched.

The radio side is a stock Silicon Labs **BGX13P** "Bluetooth Xpress" module.
Behind it sits an **ELM327-style OBD core**. Four vendor-specific rules sit on
top of the module's standard streaming profile, and a client that misses any
one of them gets nothing back:

1. Every stream byte is **XORed with `0x26`**, except CR (`0x0d`) and `>`
   (`0x3e`), which pass through unchanged.
2. The client announces a receive window on DATA (`00 ff 7f`) and then must
   **acknowledge every DATA notification** with `01 <len> 00`. Without the
   acknowledgements the scanner stops after the first fragment.
3. A fixed nine-command **LM init** must run before any PID query works.
4. After the init, **standard AT commands are forbidden**. `ATZ`, `ATE0` and
   the rest corrupt the firmware state, and every later query answers `NO DATA`.

Everything here comes from the open project
[sjalkote/bluedriver-reverse-engineering](https://github.com/sjalkote/bluedriver-reverse-engineering).
Its author decoded iOS PacketLogger HCI logs of the vendor app pairing and
streaming live data, then replayed the session in a Python Bleak client. Two
further sources fill in around it. Silicon Labs' public BGX documentation
supplies the service UUID and the meaning of the flow-control bytes (both
**inferred**, and marked so). Vendor support articles supply the pairing
window, the LED meanings and the existence of firmware updates. This project
holds no capture of its own and has driven no hardware. Every fact is
`reported`, and the spec's `device.testing` is `untested`.

Generic ELM327 behaviour lives in
[OBD-II Bluetooth Adapters](obd2-bluetooth-adapter.md). PID formulas live in
the `obd2-pid-reference` spec (`device-specs/devices/obd2-pid-reference.yaml`).
Also see [Common OBD-II Patterns](../protocols/obd2-common.md).

**Out of scope:** the vendor app's enhanced and manufacturer diagnostics
(ABS/SRS/TPMS and similar), repair reports, cloud features, firmware update
(only its existence is recorded) and DTC clearing (mode 04). The source never
exercised mode 04. It erases stored codes and resets readiness monitors, so any
client that adds it should treat it as an advanced, confirm-first action.

## Hardware

| Property | Value |
|----------|-------|
| Model code | LSB2 (the CERT note and the owner's guide both use it; the `LSB2-` name prefix matches). Neither source says whether it names the LE unit, the Classic one or both |
| Models covered | BlueDriver Pro with "LE" engraved; BlueDriver Pro Next-Gen (always LE, per vendor). Which unit the upstream author had is not stated |
| Not covered | Bluetooth Classic BlueDriver (no "LE" marking) |
| Radio module | Silicon Labs BGX13P (upstream); its GATT profile matches the stock BGX Xpress Streaming service |
| OBD core | ELM327-style; reached only through the vendor's LM commands and raw mode-01 requests |
| Advertised name | Prefix `BlueDriv` or `LSB2-` |
| Firmware string | LMI replies carry an "OSAPI" version, e.g. `OSAPI v2.60` |
| Power | OBD connector pin 16 (usually unswitched, so unplug the scanner when you are done) |
| FCC ID | Not harvested |

LED meanings, per the vendor:

| LED | Meaning |
|-----|---------|
| Solid blue at plug-in | Starting up |
| Flashing red (Pro) / green (Next-Gen) | Powered and talking to the vehicle; no app connected |
| Flashing blue | Talking to a phone; stops flashing after a while |
| Solid red at plug-in | Firmware recovery mode after an interrupted update; only the vendor app's update flow recovers it |

## Initial Setup

| Property | Value |
|----------|-------|
| Setup required | No provisioning. A one-time LE bond is made on first connect (see Pairing) |
| Method | `ble_direct` (pairing required) |
| Advertised name | `BlueDriv*`, `LSB2-*` |
| Passphrase protection | `not_applicable` |
| Confidence | medium (working open client plus vendor articles; not replayed here) |

1. Turn the ignition on (engine running, or key-on/engine-off), then plug the
   scanner in.
2. **Within 60 seconds**, scan for the name prefix and connect.
3. Run the connection handshake below. Its read of the encrypted
   characteristic makes the host pair on first contact.
4. Poll mode-01 PIDs one request at a time.

The documented path needs no account. Per the vendor, codes, freeze frame and
live data all work offline in its own app. Only repair reports, VIN decoding
and firmware downloads need the vendor's servers.

**Factory reset**: none documented. Unplugging the scanner is a power cycle,
not a reset. It restarts the 60 s pairing window, but no source says it drops
bonds. A stock BGX13P keeps up to 14 bonds and evicts the least recently used
one when a new host bonds. Whether this product keeps that default is not
confirmed.

**Rebinding**: pair the new phone or client inside the 60 s window. A phone
that bonded earlier may reconnect first and take the only connection. Turn
Bluetooth off on it, or forget the scanner there, before pairing the new one.

## Pairing

See [Pairing, Bonding and Unpairing](../protocols/pairing.md).

| Property | Value |
|----------|-------|
| Pairing required | Yes |
| Security mode | `just_works`: the scanner answers SMP with IO capability NoInputNoOutput, forcing LE Secure Connections Just Works, with no PIN and no dialog |
| Bonding | `required`: the bond persists (macOS lists the scanner afterwards), and an unbonded host can only pair inside the window |
| PIN source | none |
| One central at a time | Yes (BGX13P limit; vendor troubleshooting assumes another phone can take the connection) |
| One bond at a time | No. Several phones stay paired (vendor); the stock module keeps 14 bonds |
| Confidence | medium |

**How pairing is triggered**: CoreBluetooth has no pairing call, so the vendor
app reads the encrypted characteristic `12e868e7-c926-4906-96c8-a7ee81d4b1b3`
and the stack pairs on the resulting security requirement. Upstream does the
same. On later connections the read runs over the encrypted link, or fails
harmlessly when the bond is cached. That characteristic's service is not
recorded, so look it up by UUID.

**Entering pairing mode**: there is no button. The scanner is pairable for
about **60 seconds after it powers up** from the connector (vendor). To reopen
the window, unplug it and plug it back in. No source says whether an
already-bonded host can reconnect outside the window.

**Why the window exists**: CERT/CC
[VU#615456](https://www.kb.cert.org/vuls/id/615456) (CVE-2016-2354, April
2016) found that the "BlueDriver LSB2" accepted Bluetooth connections with no
PIN, so anyone in range could reach the vehicle's diagnostic bus. The vendor's
fix was firmware that limits discoverability to one minute after plug-in (not
at every ignition-on). The LE units covered here ship with that window, so the
spec records the note as history rather than as an active `security_advisory`.
Just Works still means that anyone who can plug the scanner in can pair with
it. The note's word "discoverability" leaves open whether the scanner stops
advertising after the minute or only stops accepting new pairings. A stock
BGX13P can do the latter: with pairing turned off, bonded hosts still connect.

**Unpairing**: no scanner-side route is documented. On the host, forget the
scanner in the OS Bluetooth settings. The vendor gives exactly this remedy when
a bonded iPhone will not reconnect.

**Recovery**: fully close the vendor app, including in the background. Turn
Bluetooth off on every other phone or tablet that has paired with the scanner.
Then unplug, replug and connect within 60 s.

## Protocol Summary

### BLE services

The three streaming characteristics are the stock Silicon Labs BGX Xpress
Streaming characteristics. Upstream lists them by UUID without naming their
service. The service UUID below is **inferred** from the
[BGX documentation](https://docs.silabs.com/gecko-os/1/bgx/latest/ble-services)
and has not been seen in a BlueDriver GATT dump. Look the characteristics up by
UUID.

| UUID | Name (upstream / BGX) | Properties | Use |
|------|------------------------|------------|-----|
| `331a36f5-2459-45ea-9d95-6142f0c4b307` | BGX Xpress Streaming service | (service) | Inferred |
| `a9da6040-0823-4995-94ec-9ce41ca28833` | CMD / Peripheral Receive (Rx) | write, write-without-response, notify | XOR-encoded ASCII commands in; stream control messages out |
| `a73e9a10-628f-4494-a099-12efaf72258f` | DATA / Peripheral Transmit (Tx) | write-without-response, notify, indicate | XOR-encoded reply fragments out; window and acknowledgement messages in |
| `75a9f022-af03-4e41-b4bc-9de90a47d50b` | STATUS / Stream Mode (Mode) | read, write, notify, indicate | Status bursts, not decoded. **Never write it**: on a BGX module a Mode write takes the module out of streaming |
| `12e868e7-c926-4906-96c8-a7ee81d4b1b3` | ENCRYPTED | read (encryption required) | Pairing trigger; service not recorded |
| `0000180a-0000-1000-8000-00805f9b34fb` | Device Information | (service) | Standard |
| `00002a24-0000-1000-8000-00805f9b34fb` | Model Number String | read | Display only |
| `00002a26-0000-1000-8000-00805f9b34fb` | Firmware Revision String | read | Display only |

### Wire encoding

`wire = plain ^ 0x26` for every stream byte, except `0x0d` (CR) and `0x3e`
(`>`), which are sent as-is. Decoding applies the same rule. The three-byte
stream control messages are **not** encoded.

A consequence of the rule, worked out here rather than observed: plaintext `+`
(`0x2b`) and `0x18` would encode to `0x0d` and `0x3e` and so cannot be
represented. Neither appears in ELM327 command or reply text.

| Plain | Wire |
|-------|------|
| `LMI` CR | `6a 6b 6f 0d` |
| `LMX0` CR | `6a 6b 7e 16 0d` |
| `010C` CR | `16 17 16 65 0d` |
| `0F 80 ` CR `>` (upstream's reply to `010C`: 0x0f80 / 4 = 992 rpm) | `16 60 06 1e 16 06 0d 3e` |
| `OK` CR `>` | `69 6d 0d 3e` |
| `NO DATA` CR `>` | `68 69 06 62 67 72 67 0d 3e` |

### Flow control

The bytes are upstream's. The field names come from the BGX "Fast-Ack"
streaming control message, a 3-byte message of the form `opcode`,
`count (u16 little-endian)`. Opcode `0x00` is Initial Buffer Size and `0x01`
is Buffer Bytes Freed.

| Bytes | Direction | Upstream says | BGX reading |
|-------|-----------|---------------|-------------|
| `00 ff 07` | scanner → client, CMD notify, on connect | status message | Initial Buffer Size = 2047 bytes |
| `00 ff 7f` | client → scanner, DATA write, before the first command | opens a 255-byte credit window | Initial Buffer Size = 32767 bytes |
| `01 01 00` | scanner → client, CMD notify, after each command | ACK | Buffer Bytes Freed = 1 |
| `01 <len> 00` | client → scanner, DATA write, **for every DATA notification** | per-fragment ACK | Buffer Bytes Freed = `<len>` |

Open question: under the BGX reading the scanner has 32767 bytes of credit and
should not need a per-fragment acknowledgement, yet upstream saw it stall after
one fragment without them. Acknowledge every fragment, as the vendor app does.

### Connection sequence

| # | Characteristic | Action |
|---|----------------|--------|
| 1 | CMD | Subscribe (the scanner sends `00 ff 07`) |
| 2 | DATA | Subscribe |
| 3 | STATUS | Subscribe |
| 4 | ENCRYPTED | Read. This pairs on first contact (inside the 60 s window); upstream allows 20 s |
| 5 | Device Information | Optionally read the firmware and model strings |
| 6 | DATA | Write `00 ff 7f`, then wait about 100 ms |
| 7 | DATA | From now on, write `01 <len> 00` for every notification, then XOR-decode it and append it to the reply buffer until `>` |
| 8 | CMD | LM init (below), waiting for `>` after each command |

Upstream subscribed before pairing and ran only on macOS, which pairs on its
own when a subscription needs encryption. On a stack that instead refuses the
subscriptions, doing step 4 first is the untested fallback.

### LM init

Each command is sent XOR-encoded with a trailing CR over CMD. Wait for `>`
before sending the next one (upstream allows 3 s, then pauses 50 ms).

| # | Command | Expected reply | Role |
|---|---------|----------------|------|
| 1 | `LMI` | `?`, or `OSAPI v2.60` CR `OK` | Firmware identity probe |
| 2 | `LMD` | `OK` | Unknown |
| 3 | `LML0` | `?` | Unknown; the `?` is expected |
| 4 | `LMI` | `OSAPI v2.60` CR `OK` | Firmware identity probe |
| 5 | `LMD` | `OK` | Unknown |
| 6 | `LMDP` | protocol number CR `OK` | Auto-detected OBD protocol |
| 7 | `LMI` | `OSAPI v2.60` CR `OK` | Firmware identity probe |
| 8 | `LMX1` | `OK` | Exhaustive timing, ~200 ms per query |
| 9 | `LMX0` | `OK` | Fast timing, ~45 ms per query; ready for live polling |

After the init the ELM core runs with echo off, headers off, linefeeds off,
spaces on and automatic protocol selection. The vendor app switches to `LMX1`
only for its one-time monitor and freeze-frame scans, and uses `LMX0` for live
data.

`LMDP` returns the ELM327 protocol numbers: `1` J1850 PWM, `2` J1850 VPW,
`3` ISO 9141-2, `4`/`5` ISO 14230-4 KWP (5-baud / fast init), `6`–`9` ISO
15765-4 CAN (11/29-bit at 500/250 kbit/s), `A` SAE J1939.

### Reading PIDs

Mode-01 PIDs are sent raw (e.g. `010C` CR). A single-PID reply carries **only
the data bytes**, with no `41` and no PID echo (`0F 80` CR `>`). Strip a
leading `41 <pid>` defensively anyway. `NO DATA`, `UNABLE`, `ERROR`, `STOPPED`,
`SEARCHING` or `?` mean no value.

The PIDs upstream tested, with J1979 formulas (A, B are data bytes in reply
order; multi-byte values are big-endian):

| PID | Parameter | Formula |
|-----|-----------|---------|
| `010C` | Engine RPM | (A·256 + B) / 4 rpm |
| `010D` | Vehicle speed | A km/h |
| `0105` | Coolant temperature | A − 40 °C |
| `010F` | Intake air temperature | A − 40 °C |
| `0104` | Engine load | A·100/255 % |
| `0111` | Throttle position | A·100/255 % |
| `012F` | Fuel level | A·100/255 % |
| `010B` | Intake manifold pressure | A kPa |
| `0142` | Control module voltage | (A·256 + B) / 1000 V |

**Multi-PID**: on CAN vehicles only, one mode-01 request may carry up to six
PIDs (e.g. `010C0D0504110B`). Each PID number comes back ahead of its data,
with no leading `41`. Drop any `0:`/`1:` frame markers. If fewer PIDs come
back, the vehicle does not support combined requests, so fall back to one PID
per request.

**No pipelining**: any write while a query is in flight aborts that query.

**Timing (upstream)**: serial polling takes about 40–50 ms per PID, so a
six-PID refresh takes about 0.25–0.3 s, matching the vendor app. The
connection interval is about 15 ms.

## Troubleshooting

| Symptom | Cause |
|---------|-------|
| First fragment arrives, then nothing | A DATA notification was not acknowledged (`01 <len> 00`), or `00 ff 7f` was never written |
| Every query answers `NO DATA` | An AT command was sent after the LM init, which breaks the firmware state. No recovery is documented; unplugging and re-initialising is the obvious (untested) remedy. The init may also have been skipped |
| `ATRV` / `ATDP` answer `NO DATA` | By design. Use PID `0142` and `LMDP` |
| Random timeouts, truncated replies | A command was written before the previous `>` arrived |
| Live data updates about once a second | The scanner is in `LMX1`; send `LMX0` |
| Scanner not found, or the pairing read times out | More than 60 s since plug-in on an unbonded host; another bonded phone or the vendor app holds the connection; ignition off; stale bond on the host (forget it and re-pair) |
| Solid red LED at plug-in | Firmware recovery mode. Only the vendor app's update flow recovers it |

The vendor also notes that many aftermarket Android head units run a ROM that
blocks the scanner from pairing, and knows of no workaround.

## Tools Used

- Upstream: Apple Bluetooth logging profile + sysdiagnose + PacketLogger (iOS
  HCI capture), and a Python Bleak client on macOS.
- This project: documentation review only (the upstream repository, Silicon
  Labs BGX documentation and data sheet, vendor support articles, the LSB2
  owner's guide, the CERT/CC note). No capture, no hardware.

## References

- [sjalkote/bluedriver-reverse-engineering](https://github.com/sjalkote/bluedriver-reverse-engineering):
  the primary source. See its
  [README.md](https://github.com/sjalkote/bluedriver-reverse-engineering/blob/b4d1bc1aa693c213dcd08bb4dffb3bb9e66e2a74/README.md)
  and [main.py](https://github.com/sjalkote/bluedriver-reverse-engineering/blob/b4d1bc1aa693c213dcd08bb4dffb3bb9e66e2a74/main.py),
  pinned. The repository has no licence, so this page restates its findings
  and copies none of its code.
- [BlueDriver LSB2 Bluetooth Pro OBDII Scan Tool instruction guide](https://manuals.plus/bluedriver/bluedriver-lsb2-bluetooth-pro-obdii-scan-tool)
  (manuals.plus, which refuses non-browser clients with a 403): the owner's
  guide for model LSB2. It covers the app's features, including the sensor
  firmware update, but has no pairing steps and does not say which radio it
  describes.
- [CERT/CC VU#615456](https://www.kb.cert.org/vuls/id/615456)
  (CVE-2016-2354): the 2016 no-PIN finding and the one-minute
  discoverability fix behind the 60-second pairing window.
- [Silicon Labs BGX: BLE Services](https://docs.silabs.com/gecko-os/1/bgx/latest/ble-services)
  and [Security](https://docs.silabs.com/gecko-os/1/bgx/latest/security):
  the streaming profile, Fast-Ack messages, Mode values and bonding defaults.
  The [BGX13P data sheet](https://web.archive.org/web/20240419150258/https://www.silabs.com/documents/public/data-sheets/bgx13p-datasheet.pdf)
  (archived) adds that the module's own OTA accepts only images Silicon Labs
  has signed.
- BlueDriver support:
  [Device Not Pairing (LE)](https://support.bluedriver.com/en/articles/15108496-device-not-pairing-device-type-le-engraved-on-device),
  [Understanding LED Colors](https://support.bluedriver.com/en/articles/15108475-understanding-led-colors),
  [iPhone and iPad Troubleshooting](https://support.bluedriver.com/en/articles/15108480-iphone-and-ipad-troubleshooting),
  [Android Troubleshooting](https://support.bluedriver.com/en/articles/15108483-android-troubleshooting),
  [Update Failure - Solid Red Light](https://support.bluedriver.com/en/articles/15108486-update-failure-solid-red-light),
  [Do I need an Internet Connection?](https://support.bluedriver.com/en/articles/15108454-do-i-need-an-internet-connection)
- Product pages:
  [BlueDriver Pro](https://us.bluedriver.com/products/bluedriver-scan-tool),
  [BlueDriver Pro Next-Gen](https://us.bluedriver.com/products/bluedriver-pro-scan-tool-next-gen)
- Machine-readable spec: `device-specs/devices/bluedriver-obd2.yaml`

## Contributors

- Spec compiled from the sources above; no hardware session yet.
