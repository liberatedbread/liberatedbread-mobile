# Canon Ivy 2 / Zoemini 2 / iNSPiC PV-223

> **Status**: Spec Available (untested by this project)
> **Protocol**: Bluetooth Classic SPP / RFCOMM channel 1
> **Manufacturer**: Canon (active)

## Overview

Canon sells this second-generation 2 × 3-inch ZINK printer as **Ivy 2** in the
US, **Zoemini 2** in Europe and **iNSPiC PV-223** in Japan. Its information
reply reports model `PV223`. A phone or computer can pair and print locally;
no Canon account or cloud is required by the public client.

The control surface is **Bluetooth Classic BR/EDR, not BLE GATT**. Commands
and replies are fixed 34-byte, big-endian frames over RFCOMM channel 1. The
machine-readable spec is
`device-specs/devices/canon-ivy-zoemini.yaml`; it includes the full command
and reply fields, image recipe, completion state machine and padded test
vectors.

**Scope is limited to Ivy 2, Zoemini 2 and iNSPiC PV-223.** PV-123, ZV-123 and
ZV-223 are not covered. An SPP-only first-generation printer uses a different
protocol and must not receive these frames. Similar-looking camera-printers
must not be assumed compatible.

The pinned public client reports successful Zoemini 2 hardware tests. This
project has not repeated them, has no new capture, and keeps every protocol
fact at `reported` confidence rather than claiming its own hardware
verification.

## Setup and pairing

| Property | Value |
|----------|-------|
| Setup required | Classic pairing before the documented control flow |
| Method | `bt_classic_pairing` |
| Advertised name | `Canon (XX:XX) Mini Printer`; `XX:XX` represents the last two address bytes |
| Security | Secure Simple Pairing, Just Works; no PIN |
| Connections | One host at a time |
| Cloud/account | Not needed for local status or printing |
| Confidence | Medium: public protocol and client, not replayed here |

1. Switch the printer on. Close Canon Mini Print and any other client that may
   hold the single connection.
2. Run a Bluetooth **Classic inquiry** (not a BLE-only scan) and select the
   exact `Canon (XX:XX) Mini Printer` name shape.
3. **Check SDP before assigning this spec.** The record must contain all four
   services below. The name alone does not establish the generation.
4. Pair from the host's Bluetooth settings using Just Works. There is no PIN to
   enter. The public client pairs once and trusts the printer for later use.
5. Open RFCOMM channel 1 for SPP UUID
   `00001101-0000-1000-8000-00805f9b34fb`.
6. Send `START_SESSION`, read its 34-byte response, then send `STATUS` before
   printing. Require READY, no error and queue-flag bits 0–4 clear; wait while
   the blue Smart Sheet is being read.

On BlueZ, the public client uses an RFCOMM socket directly. Its author reports
successful printing with BlueZ 5.82; that is upstream's result, not this
project's. The documented flow uses a paired, secure socket. Acceptance of an
unpaired insecure connection is unknown and is not a substitute for pairing.

### SDP generation boundary

| RFCOMM channel | UUID | SDP name | Role here |
|---|---|---|---|
| **1** | `00001101-0000-1000-8000-00805f9b34fb` | `SerialPort` | Print/status protocol |
| 22 | `00000000-deca-fade-deca-deafdecacaff` | `Apple Inc.` | Required in the second-generation SDP set; payload undocumented |
| 23 | `e5b152ed-6b46-09e9-4678-665e9a972cbc` | `WeChat` | Advertised service; payload undocumented |
| 25 | `00500056-0223-0000-0000-000000000000` | `FSK` | Second-generation identification; not a print channel |

The channel-22 UUID can also occur in inquiry data. Some hosts display it
byte-reversed as `ffcacade-afde-cade-defa-cade00000000`; that is the same UUID,
not a fifth service. An emulator must publish all four records for the official
app to select the second-generation protocol. **SPP alone means first
generation and is a reject condition for this spec.**

The vendor app's broader name rule also recognises `Instant Camera`. This spec
deliberately does not: that name and the camera-printer models do not establish
PV-223 compatibility.

### Factory reset, unpairing and rebinding

**Factory reset is unknown.** The public protocol and reviewed research provide
no model-matched factory-reset procedure or reset command. Do not borrow a
button sequence from another Canon generation. Whether any reset clears the
persistent auto-off value or pairing records is also unknown. Power-cycling
and removing a host bond are not factory resets.

To move to a new host, close the old client and pair the new host directly; no
factory reset or cloud account is needed. If a bond has gone stale, remove the
printer in that host's OS Bluetooth settings and pair again. The public client
reports that pairing with other devices can make a printer forget an earlier
host, but bond capacity and eviction rules are unknown. No printer-side way to
delete just one bond is documented.

The printer normally closes the link about **20 seconds after a print**.
Reconnect and run `START_SESSION` for the next operation; multiple prints in
one uninterrupted session have not been established.

## Protocol summary

### Frame format

Every command and response is **34 bytes**: an 8-byte header and a 26-byte
payload. All multi-byte integers are **big-endian**. Unused payload bytes are
zero and no application checksum covers a frame.

| Bytes | Command (host → printer) | Response (printer → host) |
|---|---|---|
| 0–1 | Start `43 0F` | Start `43 F0` |
| 2–3 | Device type `00 01`; `FF FF` for START_SESSION | `00 01` |
| 4 | Device code `20`; `FF` for START_SESSION | Product code: `20`, `21` or `22` for the PV-223 family; Zoemini 2 reports `21` |
| 5–6 | Command code, big-endian | Echoed command code, or `03 02` for receive ACK |
| 7 | Access: `00` read, `01` write | Error status; zero is success |
| 8–33 | 26-byte payload | 26-byte payload |

RFCOMM is a byte stream, so one read is not necessarily one frame. Buffer
across reads, resynchronise on `43 F0`, and emit a response only after all 34
bytes arrive. Keep a trailing `43` while waiting to see whether `F0` follows.
Commands are strictly one at a time: send a request, read its response, then
send the next. Responses normally take 0.1–0.7 seconds; the public client uses
a five-second timeout.

The raw JPEG transfer after accepted `PRINT_READY` is the exception: image
bytes have no `43 0F` envelope. Read the single 34-byte `0x0302`
acknowledgement after exactly the announced number of bytes.

### Commands

| Command | Code | Purpose |
|---|---:|---|
| `start_session` | `0x0000` | Open a session; returns an uncertain protocol byte, power word and maximum image-chunk size |
| `get_status` | `0x0101` | Battery, errors, queue state, media flags and progress |
| `get_info` | `0x0102` | Product code, Bluetooth address, length-prefixed serial and `PV223` model |
| `get_settings` | `0x0103`, read | Auto-off, firmware/TMD versions, print counter and uncertain fields |
| `set_auto_power_off` | `0x0103`, write | Set persistent auto-off to 3, 5 or 10 minutes; response reads the setting back |
| `print_ready` | `0x0301` | Announce exact JPEG byte length and two observed `01` constants |
| `send_jpeg` | raw bytes after `0x0301` | Send the announced JPEG with no per-chunk framing or ACK |
| receive ACK | `0x0302` | Printer acknowledges image receipt, **not** mechanical completion |
| `reboot` | `0xFFFF` | Advanced restart request; response and timing are undocumented |

Examples, with all 34 bytes shown in the spec's vector block:

```text
START_SESSION  43 0F FF FF FF 00 00 00  00 … 00
response       43 F0 00 01 21 00 00 00  01 82 64 FF FF 00 … 00
               battery 100%, on battery, chunk size 0xFFFF

STATUS         43 0F 00 01 20 01 01 00  00 … 00
response       43 F0 00 01 21 01 01 00  81 E4 00 00 00 00 00 … 00
               mains/charging, battery 100%, READY, no flags

PRINT_READY    43 0F 00 01 20 03 01 00  00 11 AA 0C 01 01 00 … 00
               announce 1,157,644 JPEG bytes
```

The session power word is at payload `p[1–2]`; the STATUS power word is at
`p[0–1]`. In both, `w & 0x7f` is battery percent and `w & 0x80` means
mains/charging. The high byte is only an uncertain raw value, not a decoded
voltage. Zoemini 2 reports chunk size `0xFFFF`; whether that literally means
unlimited is unknown. The public client caps writes at 4096 bytes for progress,
and uses 650 bytes if no chunk size is known.

### STATUS decoding

Offsets below are payload offsets, so frame offset is `8 + p`.

| Payload | Type | Meaning |
|---|---|---|
| `p[0–1]` | `uint16` big-endian | Power word described above |
| `p[2]` | `uint8` | Error code; idle cover/paper conditions can leave this zero and appear only as flags |
| `p[3]` | `uint8` | Queue state |
| `p[4–5]` | `uint16` big-endian | Queue flags |
| `p[6]` | `int8` | Print progress percent; observed values 25, 50, 75, 100 |

Queue states:

| Value | State | Client action |
|---:|---|---|
| `0x00` | READY | Idle; after observed print activity, the print has finished |
| `0x01` | PRINT_PREPARATION | In progress; can also appear briefly after printing |
| `0x04` | PRINT_PRINTING | In progress |
| `0x10` | PAPER_JAM | Fail the job; there is no separate jam error code |
| `0xF0` | TRANSIENT_ERROR | Inspect the error code |
| `0xF1` | RECOVERABLE_ERROR | Inspect the error code |

Queue-flag bits are cover open (0), out of paper (1), wrong paper (2), blue
Smart Sheet being read (3), and Smart Sheet error (4). Bits 5–15 are unknown.
After loading a new pack, bit 3 can remain set for about **35 seconds**. Wait
for it to clear; do not announce a print while any of bits 0–4 is set.

Error codes `0x11`–`0x17` respectively mean busy, high temperature, low
temperature, battery too low, cover open, paper empty and wrong Smart Sheet.
Codes `0x21`–`0x24` are print-data error, cover opened during print, paper
exhausted during print and wrong Smart Sheet during print. The public table
also lists a camera-write error, but that applies to out-of-scope
camera-printers and is not a PV-223 capability claim.

### Information and settings

`GET_INFO` puts six address octets at `p[0–5]`, serial length `n` at `p[6]`,
the UTF-8 serial at `p[7 … 6+n]`, model length `m` at `p[7+n]`, and the model
at `p[8+n … 7+n+m]`. Require `n + m <= 18` and do not search for NUL
terminators. The observed model is `PV223`. Owner addresses and serials should
stay in local client logs; the spec's vector uses a documentation address and
invented serial. The serial's third character is reported to select a body
colour icon, not a protocol capability.

`SETTING` responses contain auto-off minutes at `p[0]`, three firmware-version
bytes at `p[1–3]` (displayed decimal `a.b.c`), TMD version at `p[5]`
(displayed `0.0.x`), and the photo counter as big-endian `uint16` at `p[6–7]`.
Calibration sheets do not increment that counter. The remaining fields are
recorded but uncertain in the spec. A successful auto-off write returns the
full settings with the new value already applied; no commit command follows.

## JPEG transfer and completion

Prepare the image exactly; the printer does not scale, rotate or colour-manage
it for you.

1. Centre-crop the upright source to the content's physical ratio,
   `634 : (1596 / 1.675)`, approximately 2:3.
2. Resize to **634 × 1596**, without preserving source pixel aspect ratio.
3. Paste at `(3, 6)` on a white **640 × 1608** canvas. This gives 3-pixel side
   margins and 6-pixel top/bottom margins.
4. Rotate the entire canvas **180 degrees**.
5. Remember rows 6 and 1601, shift the image down four rows, fill rows 0–9
   from the remembered first row and rows 1604–1607 from the remembered last
   row. Keep the three white columns on each side white.
6. Encode baseline JFIF JPEG, quality 90, RGB, **4:4:4 chroma (no
   subsampling)**, with no alpha, ICC profile or EXIF. Progressive JPEG and
   other dimensions are untested. Maximum file size is unknown; files over
   1 MiB are reported accepted.

The horizontal resolution is 320 dpi and feed-axis resolution 536 dpi, giving
the non-square-pixel ratio 1.675. Optional shadow/midtone lifting and light
sharpening can improve ZINK output, but are rendering choices rather than wire
requirements.

Then run this session:

1. `START_SESSION` and retain the chunk size.
2. `STATUS`; require READY, zero errors and clear flags 0–4, waiting through
   calibration if needed.
3. `PRINT_READY` with the exact encoded JPEG length as big-endian `uint32`,
   followed by literal payload bytes `01 01`. Their precise copies/mode
   meanings are uncertain. A non-zero response refuses the job; send no image.
4. Write exactly that many JPEG bytes, back to back in chunks no larger than
   the session value. There is no chunk header, delay or per-chunk ACK; RFCOMM
   supplies flow control.
5. Read one `0x0302` frame. Status zero means the whole image was accepted.
   **It does not mean printing has finished.**
6. Poll `STATUS` every **2–5 seconds**. PREPARATION or PRINTING establishes
   activity; a later READY is successful completion. PAPER_JAM and `0x2x`
   errors fail the job. The public client also accepts READY with progress 100,
   or a link drop after progress 100, as completion. Mechanical printing takes
   about 50 seconds after transfer.

## Host compatibility

- **Android:** compatible with the documented Classic pairing/RFCOMM route.
- **Linux/BlueZ:** compatible according to the public client's upstream
  hardware results.
- **iOS/iPadOS CoreBluetooth:** cannot open RFCOMM, so a third-party app cannot
  use this SPP surface through CoreBluetooth. Canon ships an iOS app and the
  channel-22 service is named `Apple Inc.`, but neither establishes an
  iAP2/MFi route or identical framing. No such workaround is claimed.
- **macOS:** not covered by the CoreBluetooth verdict; its Classic API is
  IOBluetooth, which was not tested for this spec.

## Firmware update: no supported route

**This specification declares no firmware-update feature and no update
commands.** The public protocol labels `0x0201`–`0x0203` as undocumented update
opcodes, warns never to send them, and its emulator refuses them. Do not send
them. No image mapping, file format, signature check, bootloader identity,
entry sequence or interrupted-update recovery is established. File names
present in research are not proof that an image fits or can safely update a
printer.

## Remaining evidence gaps

The highest-value next evidence is one owner-controlled SDP/frame capture per
regional PV-223 alias, plus separate captures for the excluded generations.
Other open items are product-code mapping for `0x20`/`0x22`, exact `0xFFFF`
chunk semantics, the uncertain payload fields, bond/reset behaviour, iOS
transport, alternative JPEG acceptance and multiple prints per session.
Scrub the unit's address and serial from any published capture.

## References

- [Pinned public protocol](https://github.com/m4mmon/canon_zoemini2/blob/ccd2d7a4eed0255157a1a88b26ac5b535f917e75/protocol.md)
- [Pinned public client, CUPS path and emulator](https://github.com/m4mmon/canon_zoemini2/tree/ccd2d7a4eed0255157a1a88b26ac5b535f917e75)
- [Canon Mini Print support overview](https://en.canon-cna.com/apps/canon-mini-print/)
- [Common Bluetooth Classic Patterns](../protocols/bluetooth-classic-common.md)
- [Pairing, Bonding and Unpairing](../protocols/pairing.md)
- [Android HCI snoop logging](https://source.android.com/docs/core/connect/bluetooth/verifying_debugging)
