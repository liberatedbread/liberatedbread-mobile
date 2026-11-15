# Anova Precision Cooker (original, Bluetooth)

> **Status**: Spec Available
> **Protocol**: BLE
> **Manufacturer**: Anova Applied Electronics
> **Manufacturer Status**: Active (app subscription-gated for new accounts since 2024-08-21)

## Overview

The original Anova Precision Cooker is a sous-vide immersion circulator sold
in two models. The 2014 **800 W Bluetooth** unit is the A2 generation. The
**900 W Bluetooth + Wi-Fi** unit is the A3 generation. Both speak the same
phone-direct BLE protocol. It needs no account and no cloud. Commands are plain
ASCII strings ending in a carriage return, and they go to one HM-10-style
serial characteristic.

The protocol is worth writing down because of how the vendor app changed.
Anova made its app a subscription for accounts created after 2024-08-21. It
also announced that Bluetooth control of these cookers would end in 2025, then
cancelled that plan on 2025-01-16 (see [Missing Devices](../research/missing-devices.md)).
A second-hand cooker on a new account still hits the paywall. The local
protocol avoids both problems.

Anova has since published a developer page and an MIT-licensed reference
client for this cooker. The community had already worked the protocol out:
neilpa/circulate in 2014 and Aldaviva/SousVide in 2024. The vendor pages leave
out reply formats, status strings and ranges. The spec therefore cites Anova
where it can and uses the community sources for the rest.

**Out of scope:**

- the 900 W model's Wi-Fi and cloud path
- the Precision Cooker Nano, which uses a framed binary protocol on service
  `0e140000-0af1-4582-a242-773e63054c68`
- the first Precision Cooker Mini, which uses JSON + Base64
- the 2022-and-later Precision Cooker 3.0, Pro 3.0, Mini and Lite
- the Precision Oven

None of this has been driven against hardware by this project.

!!! warning "This starts a heater remotely"
    Every temperature on this protocol is in whichever unit the cooker is
    currently set to. Suppose a client means 60 °C but the cooker is set to
    °F: the cooker aims for 15.6 °C, and nothing on the wire flags the mistake.
    Re-read the unit every poll cycle, because anyone can toggle it at the
    cooker. Before a remote start, check that the cooker is clamped in a pot
    and the water sits between its MIN and MAX marks.

## Hardware

| Property | Value |
|----------|-------|
| Model Number | 800 W Bluetooth: A2 generation (also referred to as A2.2; SousVide calls its unit a Precision Cooker 1.0). 900 W Bluetooth + Wi-Fi: A3 generation |
| Chipset | Not identified. The `0000ffe0-0000-1000-8000-00805f9b34fb` / `0000ffe1-0000-1000-8000-00805f9b34fb` layout is the one TI CC254x "HM-10"-style UART modules use, and one community unit's address carries the TI OUI `84:eb:18` (hypothesis) |
| Radio | BLE (GATT server). The 900 W model adds 2.4 GHz Wi-Fi |
| Heater / pump | 800 W (120 V or 220 V), 8.2 L/min (vendor manual, 800 W model) |
| Temperature | Room temperature to 99 °C, stability ±0.01 °C (vendor manual). Over BLE the cooker accepts 5.0–99.9 °C / 41.0–211.8 °F (circulate) |
| FCC ID | 800 W: not found. 900 W: the 2015 manual says it contains FCC ID `AZY-HF-LPB100`, a modular Wi-Fi radio grant (product code matches the High-Flying HF-LPB100). The later FCC IDs `2APBOAN300`/`425`/`525`/`625` are the excluded 2022-and-later generation |

## Initial Setup

| Property | Value |
|----------|-------|
| Setup required | No |
| Method | `ble_direct` |
| Setup AP / advertised name | Local name `Anova` (match the name, never the shared `0000ffe0-0000-1000-8000-00805f9b34fb` UUID alone) |
| Passphrase protection | not_applicable (the 900 W model's Wi-Fi onboarding is out of scope and undocumented) |
| Confidence | medium (two open implementations and the vendor docs agree; not replayed here) |

To connect:

1. Plug the cooker in.
2. Scan for `Anova` and connect.
3. If the host asks for a PIN, enter `0000`.
4. Enable notifications on `0000ffe1-0000-1000-8000-00805f9b34fb`.
5. Send `read unit`. The cooker answers `c` or `f`.
6. Optionally send `get id card`. A reply that starts `anova f56-` means the
   900 W Wi-Fi model.

**Factory reset**: none is documented. The cooker stores a pairing, a
temperature unit, a calibration offset and, on the 900 W model, Wi-Fi
credentials. Pressing the Bluetooth symbol clears the pairing (vendor manual).
Writing `cal 0.0` restores the factory calibration offset. No procedure is
known that clears everything at once. That is a finding from reading the
operating manual and Anova's developer pages end to end, not a test.

**Rebinding to a new network**: not applicable on the BLE path. To move the
cooker to a new phone, forget it on the old one, press the cooker's Bluetooth
symbol, and pair again.

## Pairing

| Property | Value |
|----------|-------|
| Pairing required | Unknown |
| Security mode | `legacy_pin` (PIN `0000`, entered as passkey 000000 on an LE link) |
| Bonding | `optional` |
| PIN source | `fixed_default` — `0000` |
| One central at a time | Unknown (likely, as with HM-10-style modules) |
| One bond at a time | Unknown |
| Confidence | low (the sources disagree) |

The sources disagree on whether pairing is needed:

- Aldaviva/SousVide pairs the cooker in the operating system's Bluetooth
  settings with PIN `0000`.
- Anova's own Bleak reference client connects without asking for a bond, and
  so does pycirculate's bluepy connection.

Most likely the cooker answers on an unbonded link and keeps a bond when a
host starts one. Nobody has confirmed that.

**Entering pairing mode**: press the **Bluetooth** symbol on the control panel.
According to SousVide, the indicator turns blue and blinks. The vendor manual
warns that this breaks any existing pairing. Anova's reference client says the
cooker is also connectable right after power-up.

**Unpairing**: press the Bluetooth symbol, which breaks the cooker's existing
pairing, then forget the cooker in the old host's settings. No factory reset is
needed.

**Recovery**: close the vendor app and any other client. If the cooker still
will not pair, the vendor manual says to switch it off for 10 seconds and power
it back on. On Windows 11, set *Bluetooth devices discovery* to **Advanced** or
the cooker stays hidden.

## Protocol Summary

### BLE Services

| UUID | Name | Description |
|------|------|-------------|
| `0000ffe0-0000-1000-8000-00805f9b34fb` | Serial service | The only vendor service. The UUID is shared by every HM-10-style module, so it does not identify the cooker |
| `0000ffe1-0000-1000-8000-00805f9b34fb` | Command/reply | Write requests without response. Replies arrive as notifications on the same characteristic |

### Framing and client rules

- **Requests** are ASCII strings ending in CR (`0x0d`). Each one is 20 bytes
  or less. Send one at a time.
- **Replies** are ASCII strings ending in CR. A reply longer than 20 bytes is
  split across notifications; `power interrupt error` + CR is 22 bytes, for
  example. Accumulate until a CR arrives, then strip CR, NUL and whitespace.
  Anova's own rule ends a reply at a notification shorter than 20 bytes or one
  ending in `0x00`. Keep that rule only as a fallback, because on its own it
  never completes a reply that exactly fills 20 bytes.
- **No request IDs, no unsolicited traffic.** Serialise every request, wait
  for its reply or a timeout (Anova suggests 15 s), and poll for everything.
  SousVide polls `read temp`, `read set temp` and `status` once a second.
- **Unknown command**: the reply is `Invalid Command`. Treat it as the answer
  to the request in flight.
- **Units**: every temperature, in both directions, uses the unit `read unit`
  reports. The calibration offset is the one exception and is always °C.

### Commands

The table gives the command and the reply it gets. Every request ends with CR.

| Request | Reply | Notes |
|---|---|---|
| `read unit` | `c` / `f` | Governs every temperature |
| `set unit c` / `set unit f` | the new letter | Same as holding Start/Stop for 3 s on the cooker |
| `read temp` | e.g. `73.4` | Water temperature, current unit, 0.1 resolution |
| `read set temp` | e.g. `145.0` | Setpoint, current unit |
| `set temp <n>` | the value with one decimal, e.g. `135.0` | Does not start heating. Range 5.0–99.9 °C / 41.0–211.8 °F (circulate) |
| `status` | `stopped`, `running`, `low water`, `heater error`, `power interrupt error` | Only `stopped` is idle. The running string is circulate's and unconfirmed |
| `start` | `start` | Echoes even if the cooker does not start, so confirm with `status` |
| `stop` | `stop` | |
| `set timer <minutes>` | the minutes | Whole minutes. Anova's reference client sends `0` for no timer. Loads the timer but does not start it |
| `start time` | none, or `start time` | Sources disagree. Wait a bounded time and discard any echo |
| `stop time` | `stop time` | |
| `read timer` | `<minutes> running` / `<minutes> stopped` | circulate's format |
| `get id card` | begins `anova f56-` on the 900 W model | The rest is a per-unit ID, so don't publish it |
| `clear alarm` | not documented | 900 W model only |
| `version` | not documented | 900 W model only |
| `read cal` | e.g. `0.0` | Calibration offset, always °C |
| `cal <offset>` | echo | −9.9 to 9.9 °C. Declared **advanced**: a wrong offset silently shifts every cook |

#### Worked example: set the setpoint

Every byte below is ASCII. The number is decimal text in the cooker's current
unit, with one fractional digit, never a binary value.

**Request** (write without response to `0000ffe1-0000-1000-8000-00805f9b34fb`):

| Offset | Length | Bytes | Description |
|--------|--------|-------|-------------|
| 0 | 9 | `73 65 74 20 74 65 6d 70 20` | `set temp ` (with the trailing space) |
| 9 | 4 | `35 37 2e 35` | `57.5`, in whatever unit `read unit` reported |
| 13 | 1 | `0d` | CR terminator |

**Response** (one notification, since it is under 20 bytes):

| Offset | Length | Bytes | Description |
|--------|--------|-------|-------------|
| 0 | 4 | `35 37 2e 35` | The accepted setpoint echoed with one decimal |
| 4 | 1 | `0d` | CR terminator |

To start a cook, Anova's reference client sends these in order:

1. `set temp`
2. `stop time`
3. `set timer`
4. `start`
5. `start time`, if the timer is above 0

circulate also documents more commands: multi-step programs, `set led`,
`set name`, the date and history commands, and `set password`. The spec lists
them under `protocol_details` without declaring them, and says why for each.

## Troubleshooting

- **Readings look shifted by one command.** The client lost request/reply
  alignment, usually because of a late `start time` echo or a reply that
  arrived after a timeout. To resync, stop sending, drain notifications, send
  `read unit`, and wait for `c`/`f`. SousVide's client never waits for a
  `start time` reply, so if the cooker does echo it, every later reply is off
  by one.
- **Client hangs after one command.** The cooker answered `Invalid Command`,
  for example to `version` on the 800 W model, and the client dropped it.
  SousVide's C# client does exactly this, and it waits with no timeout.
- **Temperatures suddenly wrong mid-session.** Someone toggled °C/°F at the
  cooker. SousVide reads the unit only once, when it connects.
- **Timer restarts after a reconnect, or starts before the bath is hot.**
  Store reviews report this about the vendor app. The vendor start sequence
  starts the timer together with the cook, and re-running it on reconnect
  resets the countdown. On reconnect, read `status` and `read timer`. Send
  `start time` only once `read temp` reaches the setpoint if you want the
  timer to count from temperature.
- **Setpoint jumps to about 1 °C after "calibrating".** pycirculate's
  calibration helper sends `set temp <factor>` instead of `cal <factor>`.
- **Can't reconnect after changing phones.** A stale pairing is holding the
  cooker. Press the Bluetooth symbol, forget the cooker on the old phone, and
  pair again with `0000`.

## Tools Used

- [x] Published sources: Anova's A2/A3 developer pages and the
  anova-culinary/developer-project-a2a3 reference client; Aldaviva/SousVide
  (client and wiki); neilpa/circulate; erikcw/pycirculate
- [x] Vendor manuals: the original Bluetooth cooker's operating manual and the
  2015 Wi-Fi-model manual
- [x] Strings-level look at the current vendor Android app (3.6.6), for
  context only
- [x] tshark over the one research-store capture tied to the family, which
  turned out to be a Nano (service `0e140000-0af1-4582-a242-773e63054c68`,
  advertised as `Nano`)
- [ ] nRF Connect / Wireshark against a real A2/A3 cooker: **still needed**

## References

- [Anova Precision Cooker operating manual (original Bluetooth model, ManualsLib)](https://www.manualslib.com/manual/958097/Anova-Precision.html)
- [Anova Precision Cooker WI-FI user manual, 2015 (PDF)](https://www.williams-sonoma.com/netstorage/pdf/Anova-Precision-Cooker-with-WI-FI-User-68921-Manual.pdf)
- [Anova developer docs: A2/A3 overview](https://developer.anovaculinary.com/docs/devices/a2-a3/overview)
- [Anova developer docs: A2/A3 BLE protocol](https://developer.anovaculinary.com/docs/devices/a2-a3/ble-protocol)
- [Anova developer docs: A2/A3 commands](https://developer.anovaculinary.com/docs/devices/a2-a3/commands)
- [anova-culinary/developer-project-a2a3 (MIT reference client)](https://github.com/anova-culinary/developer-project-a2a3)
- [Aldaviva/SousVide](https://github.com/Aldaviva/SousVide)
- [SousVide wiki: Communication Protocol](https://github.com/Aldaviva/SousVide/wiki/Communication-Protocol)
- [SousVide wiki: Bluetooth Low Energy Interception](https://github.com/Aldaviva/SousVide/wiki/Bluetooth-Low-Energy-Interception)
- [neilpa/circulate README](https://github.com/neilpa/circulate/blob/f4187a153f92cb7530a57ee75632593ae117aed1/README.md)
- [erikcw/pycirculate](https://github.com/erikcw/pycirculate)
- [neilpa/circulate issue 7 (Nano captures)](https://github.com/neilpa/circulate/issues/7)
- [Anova support: original Precision Cooker remote connectivity sunsetting](https://support.anovaculinary.com/hc/en-us/articles/27322197681165-The-Original-Anova-Precision-Cooker-Bluetooth-Bluetooth-WIFI-remote-connectivity-sunsetting)
- [Ars Technica on the 2024 subscription change](https://arstechnica.com/gadgets/2024/08/smart-sous-vide-cooker-to-start-charging-2-month-for-10-year-old-companion-app/)
- [Pairing, Bonding and Unpairing](../protocols/pairing.md)

## Contributors

- Claude Code agent: spec written from published sources (desk research; no hardware)
