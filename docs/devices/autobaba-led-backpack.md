# AUTOBABA LED Backpack

> **Status**: Spec Available (display commands untested)
> **Protocol**: BLE; Wi-Fi on some related LOY SPACE products
> **Manufacturer**: LOY SPACE / popled.cn (active)

## Overview

A programmable full-color LED backpack using the LOY SPACE protocol family,
also seen in NYAN GEAR and other panels. The detailed spec is
`device-specs/devices/autobaba-led-backpack.yaml`.

A 2026-11-07 owner-authorized live GATT session confirmed the display service
and characteristic properties, then disconnected without reading, subscribing,
writing, pairing or updating anything. This establishes the connection map,
not display-command compatibility. Matrix geometry, firmware and upload
behavior remain unknown until a read-only information response is captured.

## Hardware and identity

- Advertised names begin `YS` or `TL` and include a device serial. This is a
  **platform** match, not proof of an AUTOBABA controller revision.
- Main display service: `0000fff0-0000-1000-8000-00805f9b34fb`.
- Display writes: `0000fff2-0000-1000-8000-00805f9b34fb`,
  **write-without-response only** in live discovery.
- Display notifications: `0000fff1-0000-1000-8000-00805f9b34fb`, notify.
- A separate `5833ff01-9b8b-5191-6142-22a4536ef123` service has **no
  established role on this backpack**. It is an SBH OTA candidate, while
  BanlanX research describes authenticated/ELS control on other firmware.
  Neither role is established here. Its `5833ff02…` write and `5833ff03…`
  notify properties were observed, but the analyzed LOY display path does not
  use them, and no compatible command, image or recovery path is known.

Rediscover by exact advertised name plus FFF0 rather than persisting an old
MAC. During the live investigation, an address-based connection failed while
the same name was found at a different random-format address; passing the
freshly discovered device to the client worked. That does not prove how often
one unit rotates addresses, but it is enough reason not to cache a stale one.

## Setup and pairing

Power the backpack and connect directly. No account or network provisioning
is established for the BLE display path. Do not infer that this particular
unit has Wi-Fi merely because the generic app supports it. An optional
password capability exists in the wider codec; if enabled, use the owner's
normal app flow rather than guessing or bypassing it.

Subscribe to FFF1 before querying or sending a command. Use FFF2 with
`response=False`. No factory reset is established; power-cycling only drops
the connection and is not a factory wipe.

## Read-only information query

The vendor-derived example below asks for device information, panel
parameters, power state and brightness configuration. Sequence 1 is only a
worked example; a real client increments its sequence counter.

```text
aa 55 ff ff 0e 00 01 00 c1 03 0a 00 1b 00 04 00 06 00 ff 03
```

**It was not sent during the live test.** A future owner-authorized capture
should first enable FFF1, then use FFF2 without response and retain the raw
reply. Panel TLV `0x1b` contains big-endian width and height. The app's
initial 64×64 state is only a default, not proof of the backpack's geometry.

## Frame and TLV format

The inner frame begins `AA 55 FF FF`, followed by little-endian length,
sequence, flags/mode, TLV records and a little-endian additive checksum. A
stream builder can add an outer 16-bit record length, but do not blindly
prepend it to every GATT write.

| Encoding | Value length |
|---|---|
| `LL` below `0x80` | `LL` bytes |
| `81 LL` | `LL` bytes, for 128–255 |
| `82 LL LH` | Little-endian 16-bit length, for 256 and above |

Therefore `13 81 c4` means TLV type `0x13` with 196 bytes of value. Logical
resource chunks are separate from GATT writes: the official builder normally
uses 960-byte resource chunks, a 997-byte TLV ceiling and a big-endian 16-bit
chunk count. Initial transport writes are around 180 bytes, with larger
MTU-dependent paths.

The app has power, brightness, rotation, mirroring, playback and resource
operations. Their presence in the generic codec does not prove that this
firmware implements them or which ranges it accepts.

## Upload and maintenance boundaries

A third-party project reports raw-GIF transfer on another YS-family backpack,
but has contradictory geometry notes and no retained capture. Its 196-byte
chunks and 8-bit count are not universal vendor limits. Prefer the official
TLV/resource framing until a capture establishes the simpler route.

Do not send display, authentication or firmware commands through `5833ff…`.
That UUID family appears on unrelated devices, with both a public SBH OTA
profile and authenticated/ELS control described elsewhere. Neither establishes
the backpack's role, accepted commands or images, or a recovery path.

## References

- [LOY SPACE on Google Play](https://play.google.com/store/apps/details?id=com.yskd.loywf)
- [Official LOY SPACE download page](https://app.popled.cn/loy/loyspace/index.html)
- [stared/nyan-led-skills](https://github.com/stared/nyan-led-skills), related
  hardware only; not AUTOBABA verification
- [DCloud `phy-ble-ota` profile](https://ext.dcloud.net.cn/plugin?id=27776),
  evidence for the secondary UUID family's possible role only
