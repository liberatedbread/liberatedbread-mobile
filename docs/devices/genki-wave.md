# Wave by Genki

> **Status**: Spec available (official source-derived; untested here)
> **Protocol**: Standard BLE-MIDI or Genki BLE API with COBS framing
> **Manufacturer**: Genki Instruments
> **Manufacturer Status**: Active

## Overview

Wave is a gesture-control ring with two distinct local Bluetooth paths:

- **Standalone BLE-MIDI** works with an ordinary MIDI host and does not need
  Genki's cloud or API bridge.
- **Genki API mode** exposes button, motion, battery, device-information and
  spectrogram packages over Genki's own GATT service.

These are different modes on different services. The MIDI characteristic never
accepts Genki's COBS commands, and the API characteristic does not carry
BLE-MIDI timestamps. The machine-readable source of truth is
`device-specs/devices/genki-wave.yaml`.

No hardware was driven for this spec. All protocol facts are reported from
Genki's official API source at commit
`08addce0ea5377bfa48bbb8debae20f19c4df725` and the `genki-wave` 0.5.3 source
release. The writes below are synthetic constructions from that source, not
captured owner traffic.

## Setup, discovery and pairing

Press the middle button to turn Wave on. The official API scanner looks for the
case-sensitive substring `Wave` in the advertised local name. That is only a
heuristic: confirm the intended peripheral and its service after connection,
especially when similarly named devices are present. Whether each service UUID
appears in advertisements has not been established.

| Property | Value |
|----------|-------|
| Setup / account | None for either local path |
| API service | `65e9296c-8dfb-11ea-bc55-0242ac130003` |
| API request/stream characteristic | `65e92bb1-8dfb-11ea-bc55-0242ac130003`, write + notify |
| Standard MIDI service | `03b80e5a-ede8-4b33-a751-6ce34ec4c700` |
| Standard MIDI characteristic | `7772e5db-3868-4112-a1a9-f2669d106bf3` |
| Pairing / bonding | Not established universally; no PIN is documented by the API |
| Factory reset | Unknown; power-off is not a reset |

The official API connects directly but also notes that Linux may aggressively
auto-connect a previously paired Wave. Close or disconnect the other client
before opening the direct API connection. This is not evidence for a universal
bonding rule. Stop notifications and disconnect cleanly when finished; the
README warns that killing an API session can leave the ring connected in an
invalid state.

To turn Wave off, hold the top and bottom buttons for one second. No factory
reset or the state it would clear is documented in the pinned source.

## Standalone standard BLE-MIDI

Connect Wave through the host's normal BLE-MIDI interface and subscribe to MIDI
input. Do not send an API-mode request in this mode. Genki's example receives
MIDI CC status `B0` and associates controller 16 with pitch, 17 with yaw and 18
with roll. Those are the example's mappings, not a claim that every standalone
configuration uses them or that they cannot be changed.

The standard MIDI service is shared by many instruments, so it is deliberately
not an automatic identification signal for Wave.

## Genki API connection sequence

1. Connect to the user-confirmed peripheral and locate the Genki API service.
2. Subscribe to the API characteristic.
3. Send `enter_api_mode`.
4. Send **one** suitable configuration: the original 8-byte form or the
   distinct extended 12-byte form.
5. Reassemble COBS frames across notification boundaries and decode payloads by
   package id.
6. Stop notifications and disconnect cleanly at the end.

The fixed commands are complete writes, including the trailing zero delimiter.
Do not COBS-encode them again.

| Command | Exact synthetic write |
|---|---|
| Enter API mode | `04 01 05 01 02 67 00` |
| Original motion config, 400 Hz | `04 01 0b 08 02 01 01 01 01 01 03 c8 43 00` |
| Original spectrogram config, 2000 Hz | `04 01 0b 08 01 02 01 01 01 01 03 fa 44 00` |
| Extended motion config, 400 Hz, sensitivity 0.7 | `04 01 0b 0c 02 01 01 01 01 01 07 c8 43 33 33 33 3f 00` |
| Request battery status | `03 01 02 01 01 00` |
| Request device information | `03 01 03 01 01 00` |

### API frame and COBS stream

Before COBS encoding, every package is:

```text
type:u8 | id:u8 | payload_size:u16le | payload...
```

The header is four bytes (`<BBH`). **The package id is one byte**, not a
16-bit little-endian value. `payload_size` counts only payload bytes, excluding
the header, COBS expansion and delimiter. Types are request 1, response 2 and
stream 3. Relevant ids include motion 1, battery 2, device information 3,
button 4, device mode 5, raw motion 9, spectrogram 10 and configuration 11.
API mode is value 103.

COBS-encode the complete header and payload, then append one `00` delimiter.
Incoming BLE notifications do not preserve package boundaries:

- a frame may be split over several notifications;
- several complete frames and a trailing partial frame may arrive together;
- a partial final fragment must remain buffered until more bytes arrive.

Split at zero bytes, COBS-decode each nonempty body, then require exactly
`4 + payload_size` decoded bytes before parsing the payload. There is no
additional fragment header or BLE-MIDI timestamp in this API stream.

### The two configuration widths are different

The original **8-byte** configuration payload is:

```text
u8 datastream | u8 spectrogram_enabled | 2 reserved zero bytes |
f32le sample_rate
```

It has no tap-sensitivity field. The fixed motion example uses datastream 1,
spectrogram off and 400.0 Hz. The fixed spectrogram example uses datastream 0,
spectrogram on and 2000.0 Hz.

The extended **12-byte** configuration has the same first eight bytes followed
by `f32le tap_sensitivity`. The synthetic extended example uses motion,
spectrogram off, 400.0 Hz and sensitivity 0.7. Its header declares payload size
12. Do not treat the 8-byte form as a truncated extended form, and do not send
both configurations as though they were sequential setup steps.

## Payload layouts

All floating-point fields below are little-endian IEEE-754 binary32 values.
Offsets are packed unless explicitly noted.

### Motion data — 105 bytes

| Offset | Value |
|---:|---|
| 0, 12, 24 | gyro x/y/z, acceleration x/y/z, magnetometer x/y/z (three floats each) |
| 36 | raw quaternion w/x/y/z (four floats) |
| 52 | current quaternion w/x/y/z (four floats) |
| 68 | Euler roll/pitch/yaw (three floats) |
| 80 | linear acceleration x/y/z (three floats) |
| 92 | peak flag, one-byte boolean |
| 93 | peak normalized velocity, float32; intentionally unaligned |
| 97 | timestamp, unsigned 64-bit little-endian microseconds |

The source does not establish physical units or calibration for the gyro,
acceleration, magnetometer, Euler, linear-acceleration or peak-velocity values.
Leave them raw rather than assuming degrees, radians, `g`, `m/s²` or `µT`.
Quaternions are dimensionless. The timestamp epoch and wrap behavior are also
unknown.

Raw motion (package id 9) is shorter: six floats for gyro x/y/z and acceleration
x/y/z at offsets 0–23, then the unsigned 64-bit microsecond counter at offset
24, for exactly 32 bytes. Its sensor units are likewise unresolved.

### Battery — 9 meaningful field bytes

| Offset | Type | Meaning |
|---:|---|---|
| 0 | float32 | voltage in V |
| 4 | float32 | percentage in % |
| 8 | boolean byte | charging; zero false, nonzero true |

The example `00 00 80 40 00 00 af 42 01` decodes to 4.0 V, 87.5%, charging.
The Android decoder reads these nine bytes without checking total length. The
official C++ value type commonly has three trailing native-alignment bytes,
so a 12-byte payload may also be encountered; preserve those trailing bytes
rather than decoding them as fields. The actual on-wire length and padding are
unconfirmed and remain a capture target.

### Spectrogram — 392 bytes

Ninety-six floats occupy offsets 0–383, followed by the unsigned 64-bit
microsecond counter at offset 384. There are six consecutive 16-bin channels:

1. acceleration x at float indexes 0–15;
2. acceleration y at 16–31;
3. acceleration z at 32–47;
4. gyro x at 48–63;
5. gyro y at 64–79;
6. gyro z at 80–95.

Bin-center frequencies, FFT/window details and magnitude or power units are not
established. Do not label the bins Hz or the values dB without new evidence.

### Device information — 35 bytes

The layout is three firmware bytes, a nine-byte board-version field, six address
bytes and a seventeen-byte serial field. Text fields are NUL-padded UTF-8. No
owner address or serial is included here. The official adapters disagree on
address display order, so neither order is promoted to a product identity rule.

## Firmware and remaining gaps

The source constant `1.7.4` is an API compatibility value, **not a claim that
1.7.4 is the latest firmware**. No update path was exercised or asserted.

Still needed: an owner advertisement/GATT dump; motion, battery and spectrogram
captures; sensor and bin calibration; timestamp semantics; a standalone-MIDI
mapping check; a clean-disconnect test; and bonding/reset documentation. Button
timestamp semantics and operations outside the minimal command set are left
out rather than guessed.

`scripts/test_genki_wave.py` independently implements COBS and stream
reassembly with the Python standard library, checks every fixed write against
its pre-COBS bytes, and exercises the motion, raw-motion, battery, spectrogram
and device-information structures. These are synthetic checks, not hardware
verification.

## References

- [Official Genki Wave API, pinned commit](https://github.com/genkiinstruments/genki-wave/tree/08addce0ea5377bfa48bbb8debae20f19c4df725) — framing, requests, configurations and payload structures
- [Official standalone MIDI example, pinned commit](https://github.com/genkiinstruments/genki-wave/blob/08addce0ea5377bfa48bbb8debae20f19c4df725/examples/run_midi.py) — standard BLE-MIDI path
- [genki-wave 0.5.3 on PyPI](https://pypi.org/project/genki-wave/0.5.3/) — pinned source release
- [Wave product page](https://genki.is/wave) — vendor product overview
