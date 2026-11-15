# Yogasleep Dohm Connect White-Noise Machine

> **Status**: Spec Available (unverified)
> **Protocol**: BLE (one vendor characteristic, ASCII commands)
> **Manufacturer**: Yogasleep (formerly Marpac)
> **Manufacturer Status**: Active. Still sold, but the Marpac Connect app looks neglected

## Overview

The Dohm is a fan-based white-noise machine. It has a real fan motor and ten
speed settings, and the speed is the volume. The Connect model (SKU 4000900)
adds Bluetooth LE, so a phone can:

- switch it on and off
- set the speed
- give it a name
- set its clock
- store up to three on-device on/off schedules

Store reviewers describe the vendor's Marpac Connect app as abandoned. That
claim is unverified and undated, and the machine is still on sale.

This spec is read from
[martinemde/dohm-ble](https://github.com/martinemde/dohm-ble), an MIT Home
Assistant integration and standalone client. Its author worked the protocol
out from three sources:

- a capture of the vendor's Apple-platform app (2026-06-02)
- their own hardware, driven from Home Assistant
- a static reading of the Android app (1.0.7.0)

The spec keeps those three apart. Each command says whether it was seen on
the wire (`observed`), and the two commands that were only inferred are
marked `hypothesis`.

## Hardware

| Property | Value |
|----------|-------|
| Model | Dohm Connect, SKU / model ID 4000900 |
| Chipset | Unconfirmed: upstream says a TI BLE module, but the UUID base is the CSR/Qualcomm style |
| Radio | Bluetooth LE |
| Power | Mains adapter |
| Category | `appliance` |
| Aliases | Marpac Dohm Connect, Dohm Connect; advertises `MARPAC_DOHM…` when a name is present |
| Companion apps | Marpac Connect (Android `com.marpac`, 1.0.7.0 analysed upstream; Apple-platform app captured) |

## Initial Setup

| Property | Value |
|----------|-------|
| Setup required | No provisioning. A new controller bonds once and learns the device ID once |
| Method | `ble_direct`: bond, enable notifications, send `i$` |
| Advertised | Service `00005600-d102-11e1-9b23-00025b005aa5`; name prefix `MARPAC_DOHM` when one is present |
| Passphrase protection | not_applicable |
| Confidence | medium (one working open client; not replayed here) |

1. Close the phone app. The tested unit takes one controller at a time.
2. For a new controller, hold the top button for about five seconds, then
   pair.
3. Enable notifications on `00005601-d102-11e1-9b23-00025b005aa5`.
4. Send `i$`. The reply `I,<id>$` gives the device ID that every other
   command carries. The first reply on a fresh link can take about 15 s, so
   allow 30 s and up to three tries.
5. Optionally set the clock. The vendor app does this on every reconnect.

**Factory reset**: unknown. No source describes one. The five-second hold
opens pairing and can replace the stored bond. Nobody has shown that it
clears the name, clock or schedules.

**Rebinding to a new controller**: hold the button and pair the new
controller. On the tested unit, that can invalidate the old controller's
bond.

## Pairing

| Property | Value |
|----------|-------|
| Pairing required | Yes. Upstream reports that a bond is required on its hardware |
| Security mode | Unknown. No PIN or passkey is mentioned anywhere |
| Bonding | `required` |
| PIN source | None known |
| One central at a time | Yes |
| One bond at a time | Yes on the tested unit (an observation, not a guarantee) |
| Confidence | medium |

**Entering pairing mode**: hold the top button for about five seconds. No
indicator and no window length are documented.

**Unpairing**: there is no known device-side unpair. Pairing a new
controller replaces the old bond.

**Recovery**: close the vendor app and any other client. Clear a bond only
deliberately. A slow first reply, a wrong device ID and notifications that
are not enabled all look like a dead bond.

## Protocol Summary

### BLE Services

| UUID | Name | Properties | Description |
|------|------|-----------|-------------|
| `00005600-d102-11e1-9b23-00025b005aa5` | Dohm command service | | Vendor service |
| `00005601-d102-11e1-9b23-00025b005aa5` | Command and reply | write, notify | All commands and all replies. Not readable |
| `0000180a-0000-1000-8000-00805f9b34fb` | Device Information | | The Android app reads firmware revision `00002a26-…` |
| `0000180f-0000-1000-8000-00805f9b34fb` | Battery | | Level `00002a19-…`, read and notify; unused by any open client |

### Grammar

```
LETTER[,ID[,VALUE...]]$
```

Commands are plain ASCII with no length or checksum. A lowercase letter is
a query and an uppercase letter is a set. Every command except `i$` carries
the device ID. There is no escaping, so `,` and `$` never appear inside a
value.

Replies arrive as notifications, in one of four kinds:

- `OK$` for an accepted set
- a typed report without the ID, for a query
- `Failed NN$` for an out-of-range value (a space, not a comma)
- the input echoed back, for a letter the device does not know

### Commands

The examples use the invented device ID `00532A`:

| Command | Frame | Reply | Seen on the wire |
|---------|-------|-------|------------------|
| Get device ID | `i$` | `I,00532A$` | yes |
| Get power | `m,00532A$` | `M,1$` / `M,0$` | yes |
| Power on / off | `M,00532A,1$` / `M,00532A,0$` | `OK$` | yes |
| Get speed | `s,00532A$` | `S,02$` (two digits) | yes |
| Set speed 1–10 | `S,00532A,3$` | `OK$`; `S,…,11$` gives `Failed 03$` | yes |
| Get name | `n,00532A$` | `N,Bedroom$` | app-derived |
| Set name | `N,00532A,Bedroom$` | `OK$` | app-derived |
| Set clock | `T,00532A,2133,2$` (21:33, Tuesday) | `OK$` | yes |
| Get schedule slot | `p,00532A,1$` | `P,1,2030,0730,7F,02$` | yes |
| Schedule start | `P,00532A,1,1,2030$` | `OK$` | yes |
| Schedule stop | `P,00532A,2,1,0730$` | `OK$` | yes |
| Schedule days + speed | `P,00532A,3,1,7F,02$` | `OK$` | yes |
| Get clock (**unproven**) | `t,00532A$` | unknown | no |
| Set device ID (**unproven**) | `I,00532A,<new>$` | unknown | no |

Some value encodings need care:

- **Clock**: local `HHMM` and an ISO weekday, Monday = 1 to Sunday = 7. No
  date, seconds or time zone is sent.
- **Schedule writes**: the field selector (1 start, 2 stop, 3 days and
  speed) comes before the slot number.
- **Day mask**: two uppercase hex digits. Monday is `01` and Sunday is `40`,
  so weekdays are `1F` and every day is `7F`.
- **Schedule speed**: two decimal digits. In the app's model, days `00`
  disables a slot and speed `00` deletes it.
- **Slot updates**: three separate writes with no transaction, so read the
  slot back afterwards.

`t` and `I` exist only as letters in the Android app, which never sends
them. The frames above are upstream's guesses.

### Session behaviour

- **No request IDs.** Send one command at a time and wait for its reply type.
  After a write, read the state back. A timeout does not prove a write
  failed.
- **Polling.** The characteristic cannot be read. The vendor apps poll power
  and speed every 1–5 s, and Home Assistant polls every 30 s.
- **Notifications can stop.** Upstream saw them stop on a long-lived link.
  Its client rewrites `01 00` to the CCCD before each command, as the
  captured Apple-platform app did.
- **Slow replies on BlueZ.** The unit asks for a slow connection interval,
  and replies drain about every 5 s. Upstream allows 15 s per reply.

The spec binds one entity, a power switch. Speed is not bound. Its wire
value is ASCII decimal text, which no entity role can fill from a number.
That is recorded as a schema gap in `protocol_details.schema_gaps`.

`scripts/test_yogasleep_dohm_connect_spec.py` checks every example frame
against the grammar and renders each command's template from the example's
parameters. It also pins the frames from upstream's command table, with the
ID swapped.

See `device-specs/devices/yogasleep-dohm-connect.yaml` for the full
machine-readable spec.

## References

- [martinemde/dohm-ble (Home Assistant integration and standalone client, MIT)](https://github.com/martinemde/dohm-ble)
- [dohm-ble protocol reference (docs/protocol.md)](https://github.com/martinemde/dohm-ble/blob/main/docs/protocol.md)
- [Yogasleep Dohm Connect product page](https://yogasleep.com/products/dohm-connect)
- [Dohm Connect 4000900 user manual (manuals.plus, third-party copy)](https://manuals.plus/asin/B07QD182JV)
