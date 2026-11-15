# AM43 / A-OK / Zemismart Blind Motor

> **Status**: Spec Available (unverified)
> **Protocol**: BLE
> **Manufacturer**: A-OK (Shenzhen); rebadged as Zemismart AM43 and others
> **Manufacturer Status**: Unsupported — vendor app status unclear, best-known Homebridge plugin archived 2025

## Overview

A battery or solar-charged tubular motor that drops into a roller blind. The
vendor app ("Blind Engine") talks straight to the motor over BLE, with no hub
or cloud, and so can any other client: one GATT characteristic carries short
XOR-checked frames that open, close, stop and position the blind and read back
battery, position and light level.

Some look-alike motors sold under the AM43 name run **Tuya** firmware instead
(service `0x1910`, set up with Smart Life). They speak a different protocol and
are not covered here.

## Initial Setup

| Property | Value |
|----------|-------|
| Setup required | No (travel limits are set once, at the motor or in the vendor app) |
| Method | `ble_direct` |
| Advertised | Service `0000fe50-0000-1000-8000-00805f9b34fb`; the name is owner-set |
| Passphrase protection | not_applicable |
| Confidence | medium (six open-source clients agree) |

**Travel limits** — the fully-up and fully-down stops — must be set before
positions mean anything. No public source documents a BLE command that sets
them; status bits say whether each is set, and command `0x22` resets them.

**Factory reset**: hold **SET** on the motor head. The LED goes solid red after
about 3 s; keep holding until it flashes red (about 10 s in total), then
release. Limits and settings are cleared. From the A-OK manual; not replayed.

## Pairing

| Property | Value |
|----------|-------|
| Pairing required | No |
| Security mode | `app_layer` (optional PIN frame, default 8888) |
| Bonding | `none` |
| One central at a time | Yes — close the vendor app or stop the hub holding it |
| Confidence | medium |

## Protocol Summary

| UUID | Name | Description |
|------|------|-------------|
| `0000fe50-0000-1000-8000-00805f9b34fb` | Service | |
| `0000fe51-0000-1000-8000-00805f9b34fb` | Command / reply | Write requests; replies arrive as notifications |

**Request**: `00 ff 00 00 | 9a | cmd | len | data | chk`, where `chk` is the XOR
of every byte from `9a` on. **Reply**: `9a | cmd | len | data | chk`, XOR of all
bytes = 0. For acting commands, reply byte 3 is `5a` (accepted) or `a5`
(rejected).

| cmd | Meaning | Example frame |
|-----|---------|---------------|
| `0a` | Move: `dd` open, `ee` close, `cc` stop | `00ff00009a0a01cc5d` (stop) |
| `0d` | Set position, percent **closed** (0 = open) | `00ff00009a0d0132a4` (50 %) |
| `17` | PIN login, big-endian uint16 | `00ff00009a170222b815` (8888) |
| `a7` | Status: flags, rpm, position, length, diameter | `00ff00009aa701013d` |
| `a2` | Battery (% at reply byte 7) | `00ff00009aa2010138` |
| `aa` | Light level (raw step at reply byte 4) | `00ff00009aaa010130` |

`scripts/test_am43_spec.py` checks every frame in the spec against the XOR rule
and against the literal frames in am43-ctrl.

See `device-specs/devices/am43-blind-motor.yaml` for the full machine-readable
spec.

## References

- [buxtronix/am43](https://github.com/buxtronix/am43)
- [ESPHome AM43 component](https://esphome.io/components/cover/am43/)
- [openHAB AM43 binding](https://www.openhab.org/addons/bindings/bluetooth.am43/)
- [binsentsu/am43-ctrl](https://github.com/binsentsu/am43-ctrl)
- [A-OK AM43 manual (multilingual)](https://www.manualslib.mx/manual/676327/A-Ok-Am43.html)
