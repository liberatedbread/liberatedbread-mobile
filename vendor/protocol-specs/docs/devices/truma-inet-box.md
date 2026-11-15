# Truma iNet Box (Legacy)

> **Status**: Spec available; source-derived, untested
> **Protocol**: BLE Nordic UART, ASCII `TRBT:` messages
> **Manufacturer**: Truma Gerätetechnik GmbH & Co. KG

## Overview and family boundary

The legacy iNet Box bridges Bluetooth to vehicle systems. Its local ASCII
protocol remains independent of the retired `inet.truma.com` service, which
was dead when checked on 2026-09-01. The legacy app is superseded and no live
box replay was performed by this project.

The newer **iNet X / iNet X Pro** uses
[framed CBOR on another GATT service](truma-inet-x.md). Never send `TRBT:`
frames to iNet X or CBOR to an iNet Box. The standalone LevelControl sensor
and older Bluetooth hardware generations are separate follow-ups.

This guide covers status reads. Heating/cooling controls, switches,
configuration, pairing changes, SMS/USSD and firmware are not ordinary commands.

## BLE transport and identification

| Role | UUID |
|---|---|
| Nordic UART service | `6e400001-b5a3-f393-e0a9-e50e24dcca9e` |
| Write | `6e400002-b5a3-f393-e0a9-e50e24dcca9e` |
| Notify | `6e400003-b5a3-f393-e0a9-e50e24dcca9e` |

No dependable advertised-name prefix was established. Nordic UART is shared by
many serial modules, so treat it only as a candidate signal and confirm the
TRBT dialect read-only.

Subscribe to notifications and concatenate them before parsing. A notification
can contain a partial message or several messages. Setup requires no Wi-Fi
provisioning, but bonding/first-run behavior is **unknown**; do not clear owner
pairing state. Reconnect after closing the old central. No factory reset or
standalone-unpair procedure is established.

## `TRBT:` framing

```text
TRBT:<LEN>:<MSGID>:<FLAGS>:<payload fields>
```

- Header is 20 ASCII bytes. LEN, MSGID and FLAGS are four uppercase,
  zero-padded hexadecimal digits.
- **LEN counts payload bytes only**, excluding the 20-byte header.
- Payload fields are colon-separated fixed-width hexadecimal values with a
  trailing colon.
- Wait for the declared payload length, parse, then continue with the next
  buffered message.

Flag bits include `0001` empty request, `0002` more/array transfer,
`0004` response, `0008` accept, `0010` reject and `0020` info.

### Vehicle status (`0x0017`)

The source-derived query uses a 13-segment zero template with MORE (`0002`),
not an empty request. Its payload is 62 bytes, so its complete 82-byte frame is:

```text
TRBT:003E:0017:0002:0D:0000:0000:0000:0000:0000:0000:0000:00:00:00:00:00:00:00:00:
```

Expect message `0017` with RESPONSE (`0004`). The spec's command array and
`scripts/test_truma_inet_specs.py` reproduce this vector exactly.

Payload fields after splitting on `:` are:

| Index | Meaning | Decode |
|---:|---|---|
| 0 | Segment count | u8 hex |
| 1 | Switching capabilities | u16 bit field; capability, not actuation permission |
| 2 / 3 / 4 | Inside / outside / water temperature | u16 in 0.1 K steps; Celsius = raw × 0.1 − 273.15 |
| 5 / 6 | Starter / leisure battery voltage | u16 × 0.1 V |
| 7 | Leisure battery current | u16 × 0.01 A |
| 8 | Leisure battery state of charge | u8 × 0.5 percent |
| 9–13 | Mains, EisEx, gas reserve, 12 V, pump | Bit 0 is on; preserve other bits |
| 14 / 15 | Fresh / waste water | Raw; unit unresolved |
| 16 | Ambient light, newer format only | Raw; unit unresolved |

Older replies stop at index 15; newer replies add ambient light at index 16.
For every numeric/switch field, low byte `FD` means invalid, `FE` no value,
`FF` device unavailable; `FB`/`FC` are reserved. Check these **before** scaling
so a sentinel never becomes a plausible reading.

## Message vocabulary and cloud

Other IDs cover device/box status, errors, configuration, Alde heater,
consolidated switches, LevelControl, pairing and firmware. Their presence is a
vocabulary, not permission to send them to a vehicle. Most layouts and live
behavior remain unverified.

The dead cloud historically supplied firmware manifests/images and the
LevelControl bottle database. Local TRBT status traffic does not depend on it.
The app also had telemetry and SMS/USSD paths; no vendor credential is
reproduced or needed for local reads.

Firmware uses advanced START (`0008`), DATA (`0009`) and END (`000a`) messages
on the same BLE link; sub-device update (`000f`) is separate. The historical
image host is dead, and signature, model compatibility and interrupted recovery
are unknown. Do not probe update entry from this documentary block.

## Remaining questions

- Advertised name, bonding and live Nordic UART/status verification.
- Tank/ambient-light units and other message layouts across firmware versions.
- Factory reset, standalone unpairing and safe firmware recovery.
- Standalone LevelControl and older Bluetooth generations.

## References

- [Truma iNet Box operating instructions (FCC exhibit)](https://fccid.co/api/files/s1/2adpz_inetboxa_usersmanual_2609813_19ecf17cb3.pdf)
- [Truma iNet Box FCC record](https://fccid.co/fcc/2ADPZ-INETBOXA)
