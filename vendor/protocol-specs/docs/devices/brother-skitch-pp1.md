# Brother Skitch PP1

> **Status**: Research — narrow reported protocol, untested on hardware
> **Protocol**: Bluetooth LE / GATT
> **Manufacturer**: Brother Industries, Ltd. (active)

## Overview and scope

The Skitch PP1 is an app-controlled embroidery machine whose operation manual
lists Bluetooth LE with GATT. This specification currently supports only
**identification, connection, information, service-count and status reads**.
It does not declare an embroidery motion/job-start control or a usable design
upload feature.

The machine-readable source is
`device-specs/devices/brother-skitch-pp1.yaml`. All protocol facts are
`reported` from Brother's manual and static analysis of the public companion
app; `device.testing` is `untested`. No hardware or live packet capture was
used.

**PP1 only.** The same manual names PP1E, but shared manual coverage does not
prove its advertised name, model identifier or wire behavior. PP1E is left as
an open research item, not a supported variant.

## Identification

Require both of these before sending a command:

- an advertised name matching `^Brother PP1-[0-9]{4}$`;
- service `a76eb9e0-f3ac-4990-84cf-3a94d2426b2b`, with the read and write
  characteristics below.

The manual illustrates `Brother PP1-****` and describes the suffix as four
digits from the machine's serial number. The app accepts the broader
`Brother PP1` prefix, but this spec intentionally uses the manual's narrower
shape and does not extend it to PP1E.

The service is shared with other Brother products. It is therefore **not** a
stand-alone PP1 identifier and is deliberately not an independent scan
matcher: the scan schema ORs a name and service within one matcher. Match the
name first, then confirm the service and characteristics after connecting.

| Role | UUID |
|------|------|
| Service | `a76eb9e0-f3ac-4990-84cf-3a94d2426b2b` |
| Response, explicit read | `a76eb9e1-f3ac-4990-84cf-3a94d2426b2b` |
| Command, write-with-response | `a76eb9e2-f3ac-4990-84cf-3a94d2426b2b` |

BLE address type and stability are unknown. The documented local name is the
only reported stable discovery key; its four-digit suffix is not asserted to
be globally unique.

## Pairing and rebinding

The manual's first-pairing and new-host procedure is:

1. Power on the machine.
2. Hold the **Bluetooth button** until the machine beeps and the adjacent LED
   blinks at 1.5-second intervals.
3. Select the PP1-named machine from the host's pairing UI. The Bluetooth LED
   becomes steady when pairing finishes.

The app pairs with one embroidery machine at a time. That is an app-side
selection limit, not proof that the machine permits only one central or one
bond. The actual GATT bond requirement, security mode and bonding behavior
remain unknown: the app checks for an OS bond in its UI, but static analysis
does not establish which operation enforces it.

To rebind or recover a failed connection, delete the machine in the app and
in the host's Bluetooth settings, then hold the Bluetooth button and pair
again. This does **not** require a factory reset.

## App-mediated factory reset

Brother's **Reset to default** operation deletes all saved data, customized
settings and connection information. It is not a button-only reset.

1. In the app's home screen, open the connected machine's settings.
2. Choose **Reset to default** and acknowledge the deletion warning.
3. Leave the machine powered while the app communicates with it. The manual
   explicitly warns against turning it off during the process.
4. Pair again before further use.

This procedure is `verified: false` with the manual as its basis. Static
analysis separately reports reset opcode `0c 00`; the spec marks that command
`advanced`. It has not been tested as a replacement for the app procedure.

## Connection and request semantics

Every request starts with a **two-byte big-endian opcode**, followed by its
payload. This corrects an earlier research-summary statement that called the
command opcode little-endian. Multi-byte fields inside design/firmware
payloads have their own, usually little-endian, encoding.

For information, service-count, status, reset and firmware-begin:

1. Write the request to the write characteristic **with response**.
2. Explicitly **read** the read characteristic.
3. Require the matching big-endian opcode echo and decode the response.
   GATT write completion alone is not the command result.

Serialize one ordinary request/read transaction at a time. No notification or
indication property is asserted for the response characteristic.

### Reported MTU behavior

The Android app requests MTU 512 and starts with a 500-byte application
payload limit. After MTU negotiation, if `limit + 12` exceeds the negotiated
MTU, it sets `limit = MTU - 12`. During its connection routine it probes the
information command with a zero-filled payload of `limit + 10` bytes,
reducing the limit by 50 after a failed write and restoring 500 if the limit
reaches zero.

Those are reported app behaviors, not hardware-verified requirements. A
client issuing only the short requests below need not reproduce the padded
probe. The app's 10-second read/write timeout, 30-second connect timeout and
roughly three-second status polling interval are likewise implementation
choices, not device limits.

## Initial usable commands

| Operation | Numeric opcode | Wire bytes | Response |
|-----------|---------------:|------------|----------|
| Information | `0x0000` | `00 00` | Information layout below |
| Status | `0x0001` | `00 01` | Status layout below |
| Service count | `0x0100` | `01 00` | Two little-endian counters |
| Reset settings — **advanced** | `0x0c00` | `0c 00` | Byte 2 = `00` reported as success |
| Begin firmware update — **advanced** | `0x0b00` | `0b 00 <target>` | Byte 2 = `00` reported as acceptance |

The firmware target is one byte: `1` main controller image, `2` Bluetooth
image, or `3` when both reported targets are present. It is derived from the
uploaded image metadata and has no default. Begin is the **final** operation
after transfer, not a pre-upload bootloader command.

### Information response

The reported parser expects at least 52 bytes. Only fields with useful,
source-supported meanings are decoded; unit-specific serial, address and
product identifiers are intentionally not exemplified.

| Absolute offset | Width | Encoding | Meaning |
|----------------:|------:|----------|---------|
| 0 | 2 | `uint16` BE | Opcode echo `00 00` |
| 2 | 2 | `int16` BE / 100 | Leading software version; raw 104 represents 1.04 |
| 26 | 2 | `int16` BE | Bluetooth-version raw value; scaling/unit open |
| 28 | 1 | `uint8` | Model ID; 61 is reported for PP1 |
| 29 | 1 | `uint8` | OEM ID; the public PP1 manifest uses 1 |
| 30 | 1 | `uint8` | Monitor-capability raw value; semantics open |
| 31 | 2 | `int16` LE | Maximum-width raw value; **unit not established** |
| 33 | 2 | `int16` LE | Maximum-height raw value; **unit not established** |
| 37 | 2 | `int16` BE | Software-version suffix; padding semantics open |
| 41 | 11 | ASCII | Model code; padding rules open |

Do not infer millimetres or another physical unit for the raw dimensions.
Other offsets remain opaque in this narrow spec.

### Service-count response

| Absolute offset | Width | Encoding | Meaning |
|----------------:|------:|----------|---------|
| 0 | 2 | `uint16` BE | Opcode echo `01 00` |
| 2 | 4 | `uint32` LE | Service counter; what it counts is open |
| 6 | 4 | `uint32` LE | Total counter; its relationship to the first is open |

### Status response and error offset

Bytes 0–2 are required. Byte 3 has no established meaning. The **error code
is absolute byte 4**, decoded only when the response is longer than four
bytes. The app substitutes 221 when byte 4 is absent, so preserve the
response-length distinction rather than silently turning absence into a real
error value.

Reported machine-state values are:

| Value | State | Value | State |
|------:|-------|------:|-------|
| 0 | Initial | 48 | Embroidering |
| 1 | Lower thread | 49 | Embroidery finished |
| 16 | Waiting; no design data | 50 | Embroidery interrupted |
| 17 | Waiting with design data | 64 | Thread change |
| 18 | Receiving design data | 65 | Paused |
| 32 | Mask-trace lock wait | 66 | Stopped |
| 33 | Mask tracing | 80 | Hoop avoidance |
| 34 | Mask trace finished | 81 | Hoop avoidance in progress |
| 96 | Update data receiving | 97 | Update data received |

App-only connection placeholders are not added to the wire enum. Unknown
numeric states must remain unknown rather than being coerced to idle.

The spec also records the reported error-byte labels. They are not the
manual's `#1001`-style display numbers. Notable values include 0 needle
position, 1 safety, 2 lower-thread safety, 3 lower-thread free, 32 needle
plate, 33 thread lever, 96 upper thread, 97 lower thread, 112 hoop, 113 no
hoop, 114 initial hoop, 128 regular inspection, 152 setting, 221 none and 255
other; restart reasons occupy 16–28. Value 238 is an app-side unknown
placeholder, not asserted as an on-wire error.

## Design transfer envelope — reported, not an upload feature

The app first converts its own intermediate representation into a
PP1-specific design stream using a proprietary converter. This repository
does not have a clean-room converter and claims no general design-container
compatibility. The envelope below is documented for future capture analysis;
there is deliberately **no `image_upload` feature**.

**Destructive ordering:** the reported flow sends `07 08` to delete current
embroidery data **before every upload**. That delete operation is not exposed
as an executable command in this spec. Do not experiment with this sequence
on a machine containing work that must be preserved.

After deletion, the reported sequence is:

1. Send data-info with an ordinary write/read transaction.
2. Send consecutive chunks with write-with-response but no per-chunk
   application read.
3. Explicitly read after the final chunk and poll completion.

### Data-info

```text
12 00 | data_type:u8 = 03 | total_length:u32le | sum16:u16le
```

- `total_length` counts design-stream bytes only.
- `sum16` is the sum of all design-stream bytes modulo 65,536, serialized
  little-endian. It is an additive checksum, not a CRC or a signature.
- In the data-info response, byte 2 = `00` is reported as acceptance.

### Chunks and completion

```text
12 01 | offset:u32le | chunk bytes | sum8:u8
```

- `offset` is the zero-based offset into the complete design stream.
- `sum8` is the sum of this chunk's payload bytes only, modulo 256. Opcode
  and offset are excluded.
- Chunk payload follows the reported negotiated application write limit; no
  fixed safe size is hardware-confirmed.
- On explicit completion reads, byte 2 = `00` complete, `01` error and `02`
  busy. The app waits one second on busy; other values and timeout policy are
  open.

### Synthetic envelope vector

For invented bytes `01 02 03 04 05 06 07 08`, total length 8 and sum16
`0x0024`:

```text
12 00 03 08 00 00 00 24 00
12 01 00 00 00 00 01 02 03 04 05 0f
12 01 05 00 00 00 06 07 08 15
```

The two chunks use an artificially small five-byte payload to exercise offset
and checksum behavior. A wrapping vector in the YAML/test verifies sum16
`0x01ff` and sum8 wraparound. `scripts/test_brother_skitch_pp1.py` rebuilds
all vectors using only the standard library for the protocol algorithms.

## Firmware — reported and advanced only

The firmware path reuses the data-info/chunk envelope with data type `04`.
After a successful transfer, the app sends advanced begin command `0b 00`
with the target selected from image metadata. The public PP1 manifest names
model 61, OEM 1, version 1.04.00 and an MD5 used to verify the downloaded
file. That MD5 is download integrity, **not** evidence of device-enforced
signing.

The manual says the machine reboots automatically near the end of the update
and then reconnects to the app. It warns not to power off during the update.
No bootloader name/address, signature verdict, rollback behavior, interrupted
update outcome or recovery procedure is claimed. A production firmware
uploader remains out of scope.

## Open gaps

- PP1E naming, identity and wire compatibility.
- Actual GATT properties, advertised-service presence, bond/security
  requirements, central/bond limits, address stability and non-Android hosts.
- Dimension/counter units, version-suffix semantics, unmapped information
  bytes and uncommon response/error values.
- Live MTU behavior, response timing, result variants and completion state
  machines.
- A clean-room design-stream converter and a safe, verified transfer flow
  that accounts for destructive delete-before-upload.
- Firmware container validation, device-enforced signing and recovery.

## References

- [Brother PP1/PP1E Operation Manual](https://download.brother.com/welcome/doch102864/888r000_om03en.pdf) — pairing page 13, re-pairing page 33, reset/update page 38, BLE/GATT page 39.
- [Brother Skitch PP1 product page](https://www.brother-usa.com/p/sewing-embroidery/PP1)
- [Brother Artspira for Android](https://play.google.com/store/apps/details?id=com.brother.ph.mobile.craftsewing) — public implementation reviewed at 2.9.10 (1150).
- [Public PP1 firmware update manifest](https://download.brother.com/pub/com/phc_pcs_oneclickupdate/frm/pp1/SewingMachine_upf.json)
