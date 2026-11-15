# PAX Vaporizer

> **Status**: Complete
> **Protocol**: BLE
> **Manufacturer**: PAX Labs
> **Manufacturer Status**: Server-dependent (BLE control works locally)

## Overview

Temperature-controlled vaporizer (PAX 3, Era, Era Pro). Uses AES-128 OFB encryption with a per-device key derived from the serial number. PAX is explicitly allowed by project policy.

## Hardware

| Property | Value |
|----------|-------|
| Models | PAX 3, PAX Era, PAX Era Pro |
| Chipset | Nordic Semiconductor (likely nRF5x) |
| Radio | BLE 4.x |
| FCC ID | 2AJWD-PAX3 |

## Protocol Summary

### BLE Services

| UUID | Name | Description |
|------|------|-------------|
| `8e320200-64d2-11e6-bdf4-0800200c9a66` | PAX Service | Primary service |

### Characteristics

| UUID (short) | Properties | Purpose |
|-------------|------------|---------|
| `...0201` | Read | Read encrypted data packets |
| `...0202` | Write | Send encrypted command packets |
| `...0203` | Read, Notify | Notification trigger (data ready to read) |
| `...0210` | -- | Internal service (pairing/enrollment) |
| `...0212` | Write | Internal write (AES-CTR encrypted) |

### Encryption

- **Algorithm**: AES-128 OFB (NoPadding)
- **Master key** (hex): `f7c866c38f78753086293bd57dd32540`
- **Master key** (bytes): `{0xF7, 0xC8, 0x66, 0xC3, 0x8F, 0x78, 0x75, 0x30, 0x86, 0x29, 0x3B, 0xD5, 0x7D, 0xD3, 0x25, 0x40}`
- **Key derivation**: Read 8-char serial -> duplicate to 16 bytes -> AES-128-ECB encrypt with master key -> per-device key
- **Write flow**: Generate random 16-byte IV from UUID -> AES-OFB encrypt payload -> prepend IV -> write `[IV (16)] + [ciphertext]`
- **Read flow**: First 16 bytes = IV, remaining = ciphertext -> AES-OFB decrypt with per-device key and extracted IV
- **Default IV**: `deadbeefdeadbeefdeadbeefdeadbeef` (fallback, not normally used)
- **Secondary mode**: AES-128 CTR (NoPadding) for initial pairing via internal service `...0210`

### Message Types

| Byte | Name | Direction | Payload |
|------|------|-----------|---------|
| `0x01` | ActualTemp | Device->Host | uint16 LE, value/10 = degrees C |
| `0x02` | HeaterSetPoint | Bidirectional | uint16 LE, value/10 = degrees C |
| `0x03` | Battery | Device->Host | uint8, 0-100% |
| `0x06` | LockStatus | Bidirectional | uint8, 0=unlocked, 1=locked |
| `0x08` | PodInserted | Device->Host | uint8 (Era/Era Pro only) |
| `0x0A` | DisplayName | Bidirectional | Length-prefixed UTF-8 |
| `0x13` | DynamicMode | Bidirectional | uint8 heating profile |
| `0x18` | SupportedAttributes | Device->Host | uint64 LE bitfield |
| `0xFE` | StatusUpdate | Host->Device | Request full status |

### Next Steps

- Validate message types with HCI snoop capture
- Document remaining attributes (ColorTheme, HapticMode, Brightness)

## Tools Used

- [x] Community blog posts and source code
- [x] APK decompilation (jadx) -- master key extracted from `com.pax.peace.encryption.b`

## References

- [Reverse Engineering Bluetooth Vapes -- Part 1](https://blraaz.me/reverse-engineering/2021/08/29/bluetooth-reverse-engineering.html)
- [Part 2: Electric Boogaloo](https://blraaz.me/reverse-engineering/2021/10/04/pax-protocol-electric-boogaloo.html)
- [tristanseifert/pax-controller-test](https://github.com/tristanseifert/pax-controller-test) (ISC license)

## Contributors

- Tristan Seifert (blraaz.me) -- original reverse engineering
