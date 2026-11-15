# KING JIM TEPRA Lite LR30

> **Status**: Spec Available (untested; public capture reviewed)
> **Protocol**: BLE GATT
> **Manufacturer**: KING JIM CO., LTD. (active)

## Overview

The LR30 is a monochrome label printer that can be driven directly from a
phone or computer over BLE. Two independent open clients establish a local
print path with no Wi-Fi, cloud account, PIN or application credential. The
machine-readable spec is
`device-specs/devices/king-jim-tepra-lite.yaml`.

This document covers **LR30 only**. The vendor app also accepts `LR30SG`, but
that alias is not wire-verified. Although its name matches the `LR30` discovery
prefix, do not assume that it accepts this print sequence. **LR5 is excluded.**
No firmware-update route is established or declared.

No LR30 was driven by this project. The sources are two pinned open
implementations, static analysis of the vendor app, and a public BLE capture.
The capture corroborates the command sequence, but it is third-party evidence,
so protocol facts in the YAML remain `reported`.

## Hardware and discovery

| Property | Value |
|----------|-------|
| Model | TEPRA Lite LR30 |
| Radio | BLE GATT |
| Advertised-name prefixes | `LR30`, `TepraBLE` |
| Examples accepted by the clients | `LR30`, `LR30 #1`, `TepraBLE Demo` |
| Companion app | TEPRA Lite (`jp.co.kingjim.TEPRALite`) |
| Category | `printer` / label printer |

The sources establish the custom service after connection, not that every
advertisement contains its UUID. Match either name prefix, then confirm the
FFF0/FFF1/FFF2 layout before printing.

## Initial setup

No provisioning is required.

1. Power on the LR30.
2. Scan for a local name beginning `LR30` or `TepraBLE` and connect.
3. Discover GATT services and **subscribe to FFF1 notifications before any
   FFF2 write**. Notifications carry command replies, raster flow control and
   busy status; successful Write Without Response calls alone do not mean the
   print path is working.
4. Build a monochrome label and run the print sequence below.

The setup flow is derived from the public clients and has not been replayed by
this project.

## Pairing, reset and moving hosts

| Property | Value |
|----------|-------|
| Pairing required | No |
| Security mode | `none` |
| Bonding | `none` |
| PIN | None used or established |
| Pairing-mode gesture | None needed |
| Confidence | Medium (public clients and capture, not replayed here) |

Both clients use an unpaired connection, and the reviewed capture contains no
SMP exchange. Do not request a bond merely to make printing work. There is no
device-side pairing record to unpair in the documented flow; disconnect and
connect from the new host. Simultaneous-central behavior and acceptance of an
optional host-initiated bond remain unknown.

**Factory reset:** no reset command, button procedure or settings-clearing
effect is established. None is needed to change hosts because the direct flow
creates no bond, network credential or owner binding. A power cycle ends a
connection, but is not claimed to restore factory settings. Do not borrow a
reset sequence from another TEPRA model.

**Rejoining:** there is no Wi-Fi network to rejoin and no factory reset is
required. Disconnect the old central, then scan and connect from the new one.

## BLE services

| UUID | Role |
|------|------|
| `0000180f-0000-1000-8000-00805f9b34fb` | Standard Battery Service |
| `00002a19-0000-1000-8000-00805f9b34fb` | Battery Level, read |
| `0000fff0-0000-1000-8000-00805f9b34fb` | LR30 print service |
| `0000fff1-0000-1000-8000-00805f9b34fb` | Printer-to-client notifications (RX) |
| `0000fff2-0000-1000-8000-00805f9b34fb` | Client-to-printer Write Without Response (TX) |

Host operations begin `F0`; printer replies begin `F1`. There is no checksum or
length envelope in the recovered message layer. Each operation below is one
GATT write, no more than 18 bytes.

### Commands and replies

| Operation | Host write | Printer reply / use |
|-----------|------------|---------------------|
| Prepare | `F0 5A` | Wait for `F1 5A`; the capture contains `F1 5A 00 02 00 54 45 50 52 41` |
| Set depth | `F0 5B <depth> 06` | Wait for `F1 5B`; captured depth +1 answers `F1 5B 00 06` |
| Raster pair | `F0 5C <16 bytes>` | Send six writes, then wait for six-byte `F1 5C …` |
| End raster | `F0 5D 00` | Wait for `F1 5D 00` |
| Poll status | `F0 5E` | Four-byte `F1 5E`; byte 2 is `01` while busy and `00` on completion |

The four variable bytes in an `F1 5C` reply are not decoded. The last `F1 5E`
byte is `00` in the public capture but has no established meaning. Treat poll
values other than the documented busy/complete pair as unknown rather than
reporting success.

The older written reverse-engineering note calls the poll replies `F1 5D 01
00` and `F1 5D 00 00`. Its own capture instead consistently carries **`F1 5E
01 00` while busy and `F1 5E 00 00` when complete**. This spec follows the
capture.

### Print depth

Depth ranges from **-3 through +3** and uses sign/magnitude, not two's
complement:

- for `d >= 0`, the depth byte is `d`;
- for `d < 0`, it is `0x10 + abs(d)` (equivalently `0x10 - d`).

| Signed depth | Depth byte | Complete write |
|--------------|------------|----------------|
| -3 | `13` | `F0 5B 13 06` |
| -2 | `12` | `F0 5B 12 06` |
| -1 | `11` | `F0 5B 11 06` |
| 0 | `00` | `F0 5B 00 06` |
| +1 | `01` | `F0 5B 01 06` |
| +2 | `02` | `F0 5B 02 06` |
| +3 | `03` | `F0 5B 03 06` |

The final `06` is present in both clients. Its meaning is unknown; it is not a
checksum.

## Raster encoding

### Canvas and padding

1. Render an upright monochrome canvas **64 pixels high**, with one meaning
   black and zero white. Width runs along the feed direction.
2. Set the padded width to `max(84, source_width)`, then add one if it is odd.
   The result is always at least 84 pixels and even.
3. Create a white canvas at that width and paste the source at horizontal
   offset:

   ```text
   left = padded_width // 2 - source_width // 2
   ```

   This centers the content; when there is an extra odd padding pixel, it is
   on the left.

The maximum feed-direction width, physical DPI and tape-media table are not
established. The spec therefore does not invent `max_height`, DPI or media
codes.

### Rotation and row packing

Rotate the padded canvas **clockwise 90 degrees**, expanding its dimensions
from `width × 64` to `64 × width`. Rotated rows from top to bottom correspond
to source columns from left to right.

For each rotated row:

1. Visit rotated x coordinates from 63 down to 0.
2. For visit number `s = 0..63`, add `1 << s` if that pixel is black.
3. Write the resulting unsigned 64-bit integer as **eight big-endian bytes**.

An imaging library is not required. The equivalent direct mapping from an
upright source column `x` is:

```text
source pixel (x, y) -> row byte 7 - (y // 8), bit (y % 8)
```

Thus byte 0 contains source y=56..63, byte 7 contains y=0..7, and the lower
source y within each group has the lower bit number. Black sets the bit;
white clears it. An even padded width produces pairs of eight-byte rows, so
the encoded raster length is always a multiple of 16 bytes.

### Sixteen-byte pair permutation

For two consecutive encoded rows `A0..A7` and `B0..B7`, reorder their 16 bytes
as follows:

```text
source: A0 A1 A2 A3 A4 A5 A6 A7 B0 B1 B2 B3 B4 B5 B6 B7
wire:   A6 A7 A4 A5 A2 A3 A0 A1 B6 B7 B4 B5 B2 B3 B0 B1
```

Equivalently, select source indexes
`[6, 7, 4, 5, 2, 3, 0, 1, 14, 15, 12, 13, 10, 11, 8, 9]`.
Prefix `F0 5C`. **The raster payload is 16 bytes; the complete GATT write is
18 bytes.**

A synthetic two-column example in the YAML and test suite produces:

```text
row A:       01 02 04 08 10 20 40 80
row B:       80 40 20 10 08 04 02 01
GATT write:  F0 5C 40 80 10 20 04 08 01 02 02 01 08 04 20 10 80 40
```

The two-column example isolates the bit ordering. A real job pads that canvas
to 84 pixels before applying the same transform.

## Print sequence and flow control

1. Send `F0 5A` and wait for the `F1 5A` reply.
2. Send `F0 5B <depth> 06` and wait for `F1 5B`.
3. For each 16-byte source block, apply the pair permutation and send one
   18-byte `F0 5C` write.
4. After **every six** raster writes, wait for a six-byte `F1 5C` notification.
   The open clients pause about 20 ms between other raster writes; this is
   client pacing, not a measured firmware minimum.
5. If the image ends with one through five writes after the last full batch,
   do not add a separate `F1 5C` wait for that partial group. Proceed to the
   end operation, as the clients and capture do.
6. Send `F0 5D 00` and wait for `F1 5D 00`.
7. Send `F0 5E` and wait for the four-byte `F1 5E` reply. Repeat while byte 2
   is `01`. Byte 2 `00` is the captured completion state. Keep the connection
   and FFF1 subscription open until then.

At the minimum width of 84 pixels there are 672 encoded raster bytes, 42 data
writes and seven full-batch acknowledgements. An 86-pixel image has 688 bytes,
43 writes, seven full-batch acknowledgements and one trailing write before the
end operation.

The open clients use a 10-second notification timeout. That is an
implementation choice, not a guaranteed printer timeout.

## Battery status

Battery Service characteristic `00002a19-0000-1000-8000-00805f9b34fb` uses the
standard one-byte Battery Level percentage encoding. Its **LR30 calibration is
not established**: the bridge README reports a persistent 99% reading. Expose
it only as a raw, uncalibrated value. Do not derive charge health, runtime or a
low-battery threshold from it.

## BlueZ compatibility

The direct client's README reports that stock Linux bluetoothd/BlueZ hides
the FFF1 descriptor, preventing its normal Bleak backend from enabling
notifications. This is a **host-stack issue, not printer authentication**.
Windows 10 and 11 are reported to work with the ordinary Bleak path. On Linux,
the same project reports success with a Bumble host stack over an HCI
controller.

Use that documented alternate host path rather than sending blind FFF2 writes.
Without FFF1 there are no prepare/depth replies, batch flow control, end
acknowledgement or busy status. The project has not reproduced either host
result, and no BlueZ-version-specific fix is claimed.

## References

- [ekspla/tepra-lite-bleak, pinned implementation](https://github.com/ekspla/tepra-lite-bleak/tree/e794c799b20ec7b2a8673a1279f264048ffe6ad7) —
  direct client, renderer and BlueZ/Windows notes.
- [puhitaku/tepra-lite-esp32, pinned implementation](https://github.com/puhitaku/tepra-lite-esp32/tree/bfa7dd1d2d4e496319edaa43be32730f95c33905) —
  independent client, bridge and battery caveat.
- [Written reverse-engineering note, pinned](https://github.com/puhitaku/tepra-lite-esp32/blob/bfa7dd1d2d4e496319edaa43be32730f95c33905/doc/reverse_engineering.md) —
  GATT layout and packet sequence, with the poll-id discrepancy noted above.
- [Public LR30 BLE capture, pinned pcapng](https://github.com/puhitaku/tepra-lite-esp32/blob/bfa7dd1d2d4e496319edaa43be32730f95c33905/doc/sniffed_packets.pcapng) —
  evidence for the operations, batching, partial final groups and `F1 5E`
  busy/completion replies.

## Remaining gaps

- A current-firmware owner GATT/CCC dump and end-to-end print are still needed.
- LR30SG compatibility is unverified; LR5 needs separate evidence.
- Battery accuracy, all non-prefix `F1 5A`/`F1 5B` fields, `F1 5C` payload
  semantics, and unusual `F1 5E` values remain unresolved.
- Maximum label length, physical DPI, media details, reset behavior and
  simultaneous-central behavior are unknown.
- No firmware-update surface or vendor credential mechanism was established;
  none is invented here.
