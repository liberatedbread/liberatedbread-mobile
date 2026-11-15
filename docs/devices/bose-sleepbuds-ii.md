# Bose Sleepbuds II

> **Status**: Spec Available (unverified)
> **Protocol**: BLE
> **Manufacturer**: Bose Corporation
> **Manufacturer Status**: Abandoned — product discontinued 2023, Bose Sleep app withdrawn from the stores 2025-07-21

## Overview

In-ear buds that play stored noise-masking sounds all night and stream nothing
from the phone. The phone's only role was the Bose Sleep app, which over BLE
chose the sound, set volume and timer, set alarms, toggled phone-free mode and
uploaded sound files. Bose dropped the product in 2023 and ended the app on
21 July 2025; an installed copy lives until a phone OS update kills it, and
Bose's advice is to switch on phone-free mode first so the buds replay one
preselected sound on their own.

The pair is **two BLE peripherals**. Each bud advertises, accepts one
connection and takes its own writes — the left bud relays nothing to the
right. A client connects to both and sends every command twice, as the vendor
app did.

This page covers choosing a stored sound, volume, start/stop and the sleep
timer, battery, the phone-free flag, and the alarm and synchronised-start
opcodes as far as they are known. **Sound-file upload is out of scope** — it
is documented in the community repo, writes to the buds' storage, and has not
been checked beyond one author's bench. Firmware update is declared as a
`firmware_update` feature so a client keeps generic controls away from it: the
activation opcode is an `advanced` command, and the image transfer itself is
undocumented.

Everything byte-level rests on a single source, chillee151/SleepBuds2Revival
(derived from the Sleep app and tested on firmware 11.9.0, "Kingsley"
hardware). The same app also drove the 2018 first-generation sleepbuds
("Drowsy", 8-byte playback frame, different sound IDs); those are noted but
not covered.

## Initial Setup

| Property | Value |
|----------|-------|
| Setup required | No — a bud out of its case advertises and answers |
| Method | `ble_direct` (per bud) |
| Advertised | Name contains "Bose" / "Sleepbud" (owner-renamable; factory name not recorded) |
| Passphrase protection | not_applicable |
| Confidence | medium (one community client; nothing replayed here) |

After connecting, subscribe to the Control Point, Settings and Audio Data
characteristics and read firmware, serial, Settings, Sounds and Audio Data —
the sequence the vendor app ran. The Audio Data read matters: it carries the
current file ID, which a volume change must send back.

**Factory reset**: none. Bose's support article says so outright. The two
things that get mistaken for one: a paper clip pushed into the pinhole on the
back of the **charging case** (next to the USB-C port) until it clicks reboots
the case only; putting the buds in the case until the lights blink slowly
white and taking them out again power-cycles the buds. To make a bud forget a
phone, forget it on the phone (iOS Bluetooth settings) or disconnect it in the
app (Android), then power-cycle via the case.

**Rebinding**: BLE only, nothing to rejoin. The buds reconnect to the most
recently connected device when powered on within about 2 m of it.

## Pairing

| Property | Value |
|----------|-------|
| Pairing required | Unknown |
| Security mode | `just_works` if anything — no PIN, button or display exists |
| Bonding | Unknown |
| One central at a time | Yes, per bud |
| One bond at a time | Unknown |
| Confidence | low |

The evidence splits. For a bond: Bose tells iPhone owners to forget the
Sleepbuds in the iOS Bluetooth list (iOS lists only paired accessories), the
buds reconnect to the last device on their own, and the control point's
status table has an "already bonded" code. Against a mandatory bond: the
community client wrote playback frames from a Mac that had never run the app
and reports no pairing prompt — though macOS pairs silently when asked.
Implement for both: connect, and accept a Just Works bond if the stack asks.

**Entering pairing mode**: nothing to do; a bud advertises whenever it is out
of the case and unconnected.

**Unpairing**: no bud-side route and no factory reset; phone-side forget only.

**Recovery**: force-stop the Bose Sleep app; on iOS forget the buds and toggle
Bluetooth; case the buds until the lights blink white, take them out, connect.

## Protocol Summary

| UUID | Name | Description |
|------|------|-------------|
| `0000180a-0000-1000-8000-00805f9b34fb` | Device Information | Manufacturer `2a29`, firmware `2a26` (e.g. 11.9.0), serial `2a25` (suffix `-Kde` = Sleepbuds II) |
| `0000180f-0000-1000-8000-00805f9b34fb` | Battery | `00002a19-0000-1000-8000-00805f9b34fb`, percent |
| `fdc34961-888e-4a93-abf1-b3490d8b231b` | Audio service | |
| `1cbd5f8f-6c18-4309-9354-703e7d42a74e` | Audio Data | 12-byte playback frame, read/write/notify |
| `12a3d434-c7de-4760-88c0-4f743ea55e98` | Sounds | 4-byte header, uint16 LE file IDs, `a0 ff` terminator |
| `1cbe5f90-6c19-430a-9355-703f7d43a74f` | Sync | 8-byte bud clock for synchronised start |
| `0000fe21-0000-1000-8000-00805f9b34fb` | Settings service (Bose SIG UUID) | |
| `5e500c28-33db-4d0a-afc8-c9b6df4269bf` | Settings | 4 bytes: flags (bit 0 phone-free, bit 1 renamed, bit 4 in case, bit 5 new logs), battery % |
| `00002a00-0000-1000-8000-00805f9b34fb` | Device Name | Writable name |
| `c76e1666-e7c3-4432-a995-049d09cb9e90` | Update / control service | |
| `e81359e0-9f35-483a-a46f-7c6d686daa06` | Control Point | `[opcode][sub-module][payload]`, replies `[status][opcode][sub-module]` |
| `86d60053-6f4a-409c-9a81-93f16c4e15a0` | Binary Packet | Firmware data — the update path (`firmware_update` feature); transfer format undocumented |
| `4b25c5ad-978d-467c-b598-155247b9e774` | Legacy OTA service | Update path (`firmware_update` feature); not exercised by any source |

**Audio Data frame** (little-endian): `state` (bit 0 playing) | `volume`
(0–255, app uses 0–100) | `file_id` u16 | `masking_timeout` u16 s |
`time_remaining` u16 s | `fade_in` u16 s | `fade_out` u16 s. Firmware 11.x
rejects the old 8-byte frame (ATT 0x42). Sounds are addressed by **file ID**
(the big numbers the Sounds list returns, e.g. 31567 = Warm Static), never by
the app's small track number, which the firmware ignores.

| Frame | Meaning |
|-------|---------|
| `01 32 4f 7b 00 00 00 00 00 00 00 00` | Play Warm Static (31567) at volume 50, untimed |
| `00 00 a0 ff 00 00 00 00 00 00 00 00` | Stop (`ffa0` = no sound) |
| Settings `01 00 00 00` / `00 00 00 00` | Phone-free on / off |

**Write type differs per bud** on the pair tested: the left bud wanted
write-without-response (with-response → ATT 0x42), the right bud acted only
on write-with-response (without-response silently ignored). Try with-response,
fall back to without-response.

**Control Point** sub-modules: `0x00` system queries (`3d`/`3a`/`3b`/`3c`)
and connection parameters (`d0`); `0x02` alarm (`00` read, `01` write, `02`
cancel — write payload is a hypothesis); `0xbb` audio (`01` play-in-future,
`02` cancel); `0x01` firmware activation and `0x03` file transfer are out of
scope. Play-in-future is 18 bytes: `01 bb`, then the Sync clock's minutes,
seconds, ms u16, µs u16 (hours dropped, +~750 ms with carry), a zero pad,
file ID u16, volume, duration i16, fade-in i16, fade-out i16. Status `0x09`
means zero timing, `0x03` mis-indexed timing.

**Phone-free mode** (Settings bit 0) makes the bud play its stored sound at
its stored volume whenever it leaves the case. On the bench that was an
unknown sound at volume 100 — warn before enabling.

`scripts/test_bose_sleepbuds_ii_spec.py` holds the spec's frames and examples
to its own layout and timing rule.

See `device-specs/devices/bose-sleepbuds-ii.yaml` for the full machine-readable
spec.

## References

- [chillee151/SleepBuds2Revival](https://github.com/chillee151/SleepBuds2Revival) — the community client and protocol reference (no licence; facts only)
- [Bose: Sleep App Availability | Sleepbuds II](https://support.bose.co.uk/article/sleepbuds-ii-sleep-app-availability)
- [Bose: Resetting your product (Sleepbuds II)](https://support.bose.co.uk/article/sbdii-sleepbuds-resetting-your-product---ka08c000001bufcaaa)
- [Bose: Setting up your product (Sleepbuds II)](https://support.bose.com.au/article/sbdii-sleepbuds-setting-up-your-product---ka08c000001brexaai)
- [Bose Sleepbuds II owner's guide, model 432893 (manualslib)](https://www.manualslib.com/manual/1998307/Bose-Sleepbuds-Ii.html)
- [bosefirmware/eb](https://github.com/bosefirmware/eb) — first-generation ("drowsy") firmware index
