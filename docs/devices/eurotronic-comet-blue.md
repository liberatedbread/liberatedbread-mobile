# Eurotronic Comet Blue Bluetooth Radiator Thermostat

> **Status**: Spec Available (static analysis of the vendor apps, cross-checked against two open implementations; no capture, not run against hardware)
> **Protocol**: BLE
> **Manufacturer**: Eurotronic Technology GmbH (rebadged as Sygonix HT100 BT, Xavax (Hama) and Lidl Silvercrest RT2000BT)
> **Manufacturer Status**: Active

## Overview

The Comet Blue is a battery-powered radiator thermostat (TRV) head sold in
Europe since 2014. It runs the valve from a weekly schedule stored on the
device. The phone only reads and writes settings. The only radio is BLE, and
the phone talks to the valve directly. There is no bonding, no hub and no
cloud. EUROprog 2 goes online only to download firmware, and ET Blue's only
links are to the vendor's help pages. If the vendor disappeared tomorrow, a
client would lose nothing it needs.

Access control is an **application-layer PIN**, not Bluetooth pairing. After
connecting, a client writes the PIN to one characteristic. The valve refuses
every other write until that one succeeds. Each setting is a fixed-length
value on its own characteristic, with no framing, checksum or encryption.

The machine-readable spec is
[`device-specs/devices/eurotronic-comet-blue.yaml`](https://github.com/liberatedbread/liberatedbread-protocol-specs/blob/main/device-specs/devices/eurotronic-comet-blue.yaml).
Everything in it is `verification: reported`. The byte layouts come from
static analysis of the two vendor Android apps (2026-09-27), and they agree
with [im-0/cometblue](https://github.com/im-0/cometblue) and
[rikroe/eurotronic-cometblue](https://github.com/rikroe/eurotronic-cometblue).
The authors of those two projects ran them against real units. This project
has not.

**In scope:** the Comet Blue and its rebadges.

**Out of scope:**

- **Progmatic Blue** (a programming stick) and **Progtime Blue** (a socket
  timer). The same EUROprog 2 app drives both, and they use the same UUID
  base, but the protocol is not the same. See
  [Telling the siblings apart](#telling-the-siblings-apart).
- **Comet Zero Blue.** It is in neither vendor app's device list. Do not
  assume it speaks this protocol.
- **Genius BLE100.** ET Blue drives it with the same Comet Blue UUIDs, so it
  probably shares this table. That is unverified.

## Hardware

| Property | Value |
|----------|-------|
| Model Number | Eurotronic Comet Blue. Rebadges: Sygonix HT100 BT, Xavax (Hama), Silvercrest RT2000BT (Home Assistant and rikroe's list) |
| Chipset | Not recorded. The app's name for the radio image points to Dialog's SUOTA lineage, so a Dialog DA1458x radio is possible (inferred only) |
| Radio | Bluetooth 4.0 LE (vendor flyer) |
| Power | Replaceable batteries. The manual forbids rechargeable cells. Schedules survive a battery change |
| Valve fit | M30 × 1.5 directly. Danfoss RA, RAV and RAVL through the bundled adapters (manual) |
| FCC ID | None. The product is sold only in the EU and carries a CE Declaration of Conformity |

## Initial Setup

| Property | Value |
|----------|-------|
| Setup required | No (nothing to provision over the air) |
| Method | `ble_direct` |
| Advertised name | `Comet Blue` (exact, per EUROprog 2). The rebadges' names are not recorded |
| Advertised service | `47e9ee00-47e9-11e4-8939-164230d1df67` (the Home Assistant / rikroe filter; needs active scanning) |
| Passphrase protection | not_applicable |
| Confidence | high (two working open implementations; not replayed here) |

The valve has to be commissioned on its own buttons first. After the first
battery insertion it asks for the date and time on its display. It then
drives the motor to the install position. Mount it only while the display
shows the install prompt. After mounting it runs an **adaptation**, opening
and closing the valve to learn its stroke. A unit that has not finished
adapting still answers over BLE but does not regulate.

After that, a client does the following on every connection:

1. Scan for the advertised service `47e9ee00-47e9-11e4-8939-164230d1df67`,
   or for the exact local name `Comet Blue`.
2. Connect. No bonding is requested.
3. Optionally read the revision strings
   (`00002a26-0000-1000-8000-00805f9b34fb`,
   `00002a28-0000-1000-8000-00805f9b34fb`). They are readable before the PIN.
4. Write the PIN to `47e9ee30-47e9-11e4-8939-164230d1df67` as a **uint32
   little-endian**, with a write request. The factory PIN is `00 00 00 00`.
   Write status 0 means it was accepted; any other status means a wrong PIN.
5. Write the clock (`47e9ee01-47e9-11e4-8939-164230d1df67`), then read and
   write settings.
6. Disconnect. rikroe's library documents that the valve applies writes when
   the link closes.

EUROprog 2 waits 1 s before the PIN write on units whose firmware revision
sorts below a reference revision. Waiting 1 s every time is harmless.

**Factory reset**: use **All reset** in the valve's own menu. Press MENU, turn
the wheel to the reset item, press OK, and press OK again when it flashes. Per
the manual, the valve returns to factory settings: comfort 21 °C, eco 16 °C,
and one heating period from 07:00 to 22:00. It then restarts the
initial-operation flow. **Whether it also restores PIN 0 is not established.**
That question decides whether a second-hand unit with an unknown PIN can be
recovered at all. Pulling the batteries for a few seconds is a different
operation. It is the manual's fix for an error code, and it keeps the
schedule. (Source: manual; not performed here.)

**Rebinding**: the valve has no network membership and no bond. A new phone
or controller needs only the current PIN.

## Pairing

| Property | Value |
|----------|-------|
| Pairing required | Yes, but at the application layer (the PIN write). Nothing pairs at the link layer |
| Security mode | `app_layer` |
| Bonding | `none` |
| PIN source | `fixed_default` = 0. The manual prints it as "000 000"; on the wire it is `00 00 00 00` |
| One central at a time | Unknown (the vendor apps hold one connection per valve) |
| One bond at a time | No (nothing is bonded) |
| Confidence | medium |

**Entering pairing mode**: not needed. The valve accepts a connection and a
PIN write whenever it is powered.

**The PIN**:

- It is 0–999999, at most six digits.
- Owners change it in EUROprog 2. Writing a new value to the PIN
  characteristic, in a connection already authenticated with the old one,
  sets the new PIN. im-0's `set pin` works the same way.
- ET Blue makes the owner choose a per-room PIN and refuses 0. **A valve set
  up with ET Blue no longer answers to 0.**
- The PIN crosses the air in cleartext on an unencrypted link. Anyone who
  sniffs one session learns it.

**Unpairing**: there is no bond to drop. The only way to revoke a client is
to change the PIN, and every other client then has to be given the new one.

**Recovery**: close EUROprog 2, ET Blue, Home Assistant or any other
controller that holds a connection, then connect.

## Protocol Summary

All vendor UUIDs share the base `47e9xxxx-47e9-11e4-8939-164230d1df67`, and
only the four hex digits after `47e9` change. The tables below give the full
UUID for each. Temperatures are one byte of **°C × 2** everywhere. The only
multi-byte field is the PIN, a uint32 little-endian.

### BLE Services

| UUID | Name | Description |
|------|------|-------------|
| `47e9ee00-47e9-11e4-8939-164230d1df67` | Comet Blue service | Every setting, the PIN gate and the firmware-update channel |
| `0000180a-0000-1000-8000-00805f9b34fb` | Device Information (assumed) | Model, firmware, software and manufacturer strings, readable without the PIN. Both clients find these characteristics by UUID alone, so the parent service is assumed rather than dumped |

### Characteristics

The properties are inferred from how the apps use each value. Nobody has
published a GATT dump. Match characteristics by UUID, not by handle.

| UUID | Len | Access | Meaning |
|------|-----|--------|---------|
| `47e9ee01-47e9-11e4-8939-164230d1df67` | 5 | R/W | Clock: `minute, hour, day, month, year − 2000` (local time; the valve handles summer time itself) |
| `47e9ee10-47e9-11e4-8939-164230d1df67` … `47e9ee16-47e9-11e4-8939-164230d1df67` | 8 | R/W | Monday … Sunday: four (start, end) comfort periods, minutes since midnight ÷ 10, `0xff` = unused |
| `47e9ee20-47e9-11e4-8939-164230d1df67` … `47e9ee27-47e9-11e4-8939-164230d1df67` | 9 | R/W | Holiday slots 1–8: start hour/day/month/year, end hour/day/month/year, temperature |
| `47e9ee2a-47e9-11e4-8939-164230d1df67` | 3 | R/W | Flags. Byte 0 bit 7 = child lock (vendor app); byte 0 bit 0 = manual mode (rikroe). The other bits are unknown |
| `47e9ee2b-47e9-11e4-8939-164230d1df67` | 7 | R/W | Temperature block (below) |
| `47e9ee2c-47e9-11e4-8939-164230d1df67` | 1 | R | Battery %, `0xff` = not yet measured |
| `47e9ee2d-47e9-11e4-8939-164230d1df67` | ? | R | A string im-0 calls "firmware revision #2". The apps never read it |
| `47e9ee2e-47e9-11e4-8939-164230d1df67` | 2 | R/W | Read and ignored by the vendor app. im-0 calls it an LCD timer (preload, current) |
| `47e9ee30-47e9-11e4-8939-164230d1df67` | 4 | W | **PIN**, uint32 LE: authenticates, and once authenticated, sets a new PIN |
| `47e9ee40-47e9-11e4-8939-164230d1df67` | 20 | W/N | Firmware-update channel. **Leave it alone** (see below) |
| `00002a24-0000-1000-8000-00805f9b34fb` | str | R | Model number ("comet blue" when lower-cased) |
| `00002a26-0000-1000-8000-00805f9b34fb` | str | R | Controller firmware revision |
| `00002a28-0000-1000-8000-00805f9b34fb` | str | R | Radio software revision. im-0's example unit shows a Sygonix suffix here |
| `00002a29-0000-1000-8000-00805f9b34fb` | str | R | Manufacturer ("eurotronic gmbh" when lower-cased) |

### The PIN gate

- The vendor app sends nothing to the valve except the PIN write and reads
  of the two revision strings until the PIN write returns status 0. im-0 also
  treats every vendor read as needing the PIN.
- A non-zero write status is a wrong PIN.
- Whether a wrong PIN produces an ATT error, a disconnect or both is not
  established. Nor is whether repeated wrong PINs lock the valve out.

### Temperature block (`47e9ee2b-47e9-11e4-8939-164230d1df67`)

| Offset | Field | Encoding |
|--------|-------|----------|
| 0 | Measured temperature | °C × 2, read-only. Always write `0x80` |
| 1 | Active setpoint | °C × 2. Writing it overrides the schedule until the next switch point, like turning the wheel |
| 2 | Eco setpoint | °C × 2, factory 16 °C (`0x20`) |
| 3 | Comfort setpoint | °C × 2, factory 21 °C (`0x2a`) |
| 4 | Offset | int8 °C × 2, −10…+10 (−5.0…+5.0 °C) |
| 5 | Open-window sensitivity | `4` high, `8` medium, `12` low |
| 6 | Open-window close time | minutes: 10, 20, … 60 |

- **Setpoint codes**: `15` (7.5 °C) = **OFF**, which closes the valve (frost
  protection stays active). `57` (28.5 °C) = **ON**, which opens it fully.
  `16`–`56` = 8.0–28.0 °C in 0.5 °C steps. That is exactly the range of the
  vendor app's pickers and the valve's wheel. The spec documents nothing
  wider.
- **`0x80` means "leave this field unchanged"** (im-0, rikroe). Send it in
  every byte you are not changing. For example, comfort 21.0 °C is
  `80 80 80 2a 80 80 80`.
- The vendor app does something different. It reads the block, edits its own
  fields and writes all seven bytes back.

### Flags (`47e9ee2a-47e9-11e4-8939-164230d1df67`)

This is a read-modify-write. Read the three bytes, change only the bit you
mean, and write them all back.

- Byte 0 bit 7 (`0x80`) is the child lock. It is the only bit the vendor app
  touches. It is the same lock the OK + timer key chord sets on the valve.
- rikroe reads byte 0 bit 0 as manual mode.
- **`0x80` is not an "unchanged" filler here**, because it is the child-lock
  bit. The spec marks the flags write `advanced` for this reason.

### Schedules and holidays

**Schedules:**

- Each day carries up to four comfort periods. Outside them the valve holds
  the eco setpoint.
- A time byte is minutes since midnight ÷ 10. So 07:30 is `45`, and `144` is
  24:00.
- The factory schedule is `2a 84 ff ff ff ff ff ff`, one period from 07:00 to
  22:00.
- Unused pairs are handled three ways:
  - The vendor app writes `0xff` in its "2 periods a day" mode and `0x00` in
    its "4 periods" mode.
  - rikroe writes `0x00`.
  - im-0 writes `0xff`.

  All of them treat start == end as empty.

**Holidays:**

- The holiday temperature uses the same codes as the setpoints.
- The vendor app's empty slot is `80 01 01 ff 80 01 01 ff 0f`. im-0 clears a
  slot with nine `0x80` bytes.
- rikroe reports that a holiday in progress reads back hour `128` in its
  start. The manual mentions six vacation profiles, but the valve exposes
  eight slots and every client addresses all eight.

### Firmware update (role level only)

Characteristic `47e9ee40-47e9-11e4-8939-164230d1df67` carries EUROprog 2's
update. The app opens notifications and writes a 20-byte header naming the
image and its length. It then streams 20-byte blocks, each with a block
number, 16 image bytes and a CRC-16. The valve paces the transfer with
notifications carrying a block number and a status code:

| Status | Meaning |
|--------|---------|
| `0xaa` | Header accepted, send the first block |
| `0x01` | Block received, send the next |
| `0xbb` | Busy. The app waits 3 s and resends |
| `0x02` | Restart. The app begins again with the header |

The image is **unsigned** and checked only by the per-block CRC. The vendor's
image downloads now return 404, and nothing is known about recovering from
an interrupted or malformed transfer. The spec therefore flags this path
`advanced` and does not document the header bytes, the image names or an
upload recipe. The status table is here so an owner who sees these
notifications knows what they are, and so a client knows to leave `ee40`
alone.

### Telling the siblings apart

EUROprog 2 sorts a characteristic into a product by the four hex digits
after `47e9` in its UUID:

| Range | Product | Notes |
|-------|---------|-------|
| below `ee50` | Comet Blue (this page) | Advertised name `Comet Blue` |
| `ee50`–`ef4f` | Progmatic Blue | Characteristics `47e9ef01-47e9-11e4-8939-164230d1df67` to `47e9ef41-47e9-11e4-8939-164230d1df67` |
| `ef50` and up | Progtime Blue | Characteristics `47e9ef51-47e9-11e4-8939-164230d1df67` to `47e9ef62-47e9-11e4-8939-164230d1df67`; its PIN is `47e9ef62-47e9-11e4-8939-164230d1df67` |

If a connected device shows `ef..` characteristics and no `ee..` ones, it is
not a Comet Blue.

### Test vectors

These were built from the layouts above, not captured. The temperature read
reproduces the values im-0's README prints for its unit.

| What | Bytes |
|------|-------|
| PIN 0 | `00 00 00 00` |
| PIN 123456 (rikroe's test) | `40 e2 01 00` |
| Clock 2026-09-28 14:05 | `05 0e 1c 09 1a` |
| Factory schedule, 07:00–22:00 | `2a 84 ff ff ff ff ff ff` |
| Set comfort 21.0 °C | `80 80 80 2a 80 80 80` |
| Set active setpoint OFF | `80 0f 80 80 80 80 80` |
| Set offset −1.5 °C | `80 80 80 80 fd 80 80` |
| Temperature read: 23.0 / 16.0 / 16.0 / 21.0 / 0.0 / high / 10 min | `2e 20 20 2a 00 04 0a` |
| Holiday 2026-12-24 18:00 → 2027-01-02 12:00 at 16.5 °C | `12 18 0c 1a 0c 02 01 1b 21` |

## Troubleshooting

These are defects and quirks found in the vendor apps and the open
implementations.

- **Every write fails straight after connecting.**
  - No PIN has been written in this connection yet.
  - The PIN is wrong. A unit set up with ET Blue has a room PIN and refuses
    0. A second-hand unit carries its previous owner's PIN.
  - On older firmware the PIN write went out too soon after connecting. Wait
    1 s and retry.
- **A name-filtered scanner does not find the valve.** EUROprog 2 matches
  only the exact name `Comet Blue` and applies no UUID filter, and a rebadge
  may advertise another name. Filter on service
  `47e9ee00-47e9-11e4-8939-164230d1df67` instead, with active scanning on.
- **The valve turns OFF after a third-party client changed only comfort or
  eco.** This is a defect in rikroe's library. When the setpoint is not
  supplied, it leaves `0x00` instead of `0x80` in byte 1 of the temperature
  block. rikroe's Home Assistant component says in a code comment that the
  valve turns OFF otherwise, and its climate entity works around the defect
  by always resending the setpoint. Send `0x80` in every field you are not
  changing.
- **Switching to manual or auto mode also clears the child lock.** rikroe's
  mode switch writes flags byte 0 as `0x01` or `0x00` without reading it
  first, which drops bit 7. Do a read-modify-write instead.
- **A value reads back unchanged in the same connection.** The valve applies
  writes when the link closes (rikroe). Disconnect, reconnect and read again.
- **The setpoint does not stick.** In AUTO the valve returns to its schedule
  at the next switch point, by design. If a holiday slot is running, the
  valve holds the holiday temperature. Home Assistant's documentation says
  holiday mode can only be ended from the valve's MENU button.
- **The battery shows 255, or stops updating at 100 %.** `0xff` means the
  valve has not measured the battery yet, so re-read after a second. The
  vendor app's parser accepts only −1…99. It silently drops a reading of
  exactly 100 and keeps showing the previous value. Home Assistant's
  documentation also warns the reading may not be very accurate.

## Open questions

- The real GATT table: handles, properties, and whether the Device
  Information strings sit in a standard `0000180a-0000-1000-8000-00805f9b34fb`
  service.
- What a wrong PIN looks like on the air, and whether the menu reset restores
  PIN 0.
- The flag bits beyond child lock and manual mode.
- What the valve does with a temperature byte outside 15–57 that is not
  `0x80`.
- The advertised names of the Sygonix, Xavax and Silvercrest rebadges, and
  whether every unit advertises the `47e9ee00` service.
- Whether Genius BLE100 shares this table.
- The meaning of `ee2d` and `ee2e`.
- Why im-0's example unit reports open-window sensitivity 4 when the manual
  says medium is the default.

## Tools Used

- [x] Static analysis of EUROprog 2 (`com.delan.app.germanybluetooth` 11.09.2026, versionCode 20)
- [x] String-table read of ET Blue (`org.eurotronic.etblue` 1.0.2, versionCode 3); the Dart code was not decompiled
- [x] Cross-check against im-0/cometblue, rikroe/eurotronic-cometblue and rikroe/cometblue-custom-component
- [ ] nRF Connect dump and a capture against a real valve: **still needed**

## References

- [Eurotronic Comet Blue user manual, English, 2015/06 (Internet Archive copy of the vendor PDF)](https://web.archive.org/web/20160221215014/http://www.eurotronic.org/fileadmin/user_upload/eurotronic.org/Download-BAL-WB/Comet_Blue/Comet-Blue-BAL-en-A4.pdf)
- [Eurotronic Comet Blue product flyer, English (Internet Archive copy)](https://web.archive.org/web/20150329082331/http://www.eurotronic.org/fileadmin/user_upload/eurotronic.org/Download-BAL-WB/Comet_Blue/CometBlue-WB-en.pdf)
- [Eurotronic downloads](https://eurotronic.org/downloads/)
- [im-0/cometblue (Python library and CLI, GPL-3.0)](https://github.com/im-0/cometblue)
- [rikroe/eurotronic-cometblue (bleak library, MIT)](https://github.com/rikroe/eurotronic-cometblue)
- [rikroe/cometblue-custom-component (Home Assistant custom component)](https://github.com/rikroe/cometblue-custom-component)
- [Home Assistant: Eurotronic Comet Blue integration](https://www.home-assistant.io/integrations/eurotronic_cometblue/)
- [EUROprog 2 on Google Play](https://play.google.com/store/apps/details?id=com.delan.app.germanybluetooth)
- [ET Blue on Google Play](https://play.google.com/store/apps/details?id=org.eurotronic.etblue)
- [eQ-3 Eqiva Radiator Thermostat](eqiva-eq3-ble-trv.md), the closest sibling spec
- [Pairing, Bonding and Unpairing](../protocols/pairing.md)

## Contributors

- Claude Code agent: spec written from static analysis of the vendor apps and published open-source clients (no hardware)
