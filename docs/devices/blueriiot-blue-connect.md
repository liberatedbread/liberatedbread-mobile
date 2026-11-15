# Blueriiot Blue Connect (Go / Plus) Pool Analyser

> **Status**: Spec Available. The measure-now path is corroborated by an open integration and by community frames posted beside the vendor app's values, but has not been replayed by this project.
> **Protocol**: BLE (plus Sigfox and an optional Wi-Fi bridge, both out of scope)
> **Manufacturer**: Blueriiot (Riiot Labs SA, now part of Fluidra)
> **Manufacturer Status**: Active. The vendor cloud is required for history, advice and Sigfox, but not for a BLE reading.

## Overview

The Blue Connect is a floating (or pipe-mounted, with the Blue Fit50 clamp)
pool and spa analyser. The **Plus** measures water temperature, pH, ORP and
conductivity, from which salinity is estimated. The **Go** drops the
conductivity probe. It has three uplinks:

- **Sigfox**: automatic readings a few times a day, straight to the vendor
  cloud. This needs the Plus pack or a Premium subscription.
- **BLE**: an on-demand "measure now" from a phone within about 10 m.
- **Blue Extender**: an optional mains-powered bridge that collects readings
  over BLE and forwards them over Wi-Fi.

Only the BLE path is local, and it is short. Connect without pairing,
subscribe to one characteristic, write `0x01` to another, and about 8 s later
one notification arrives carrying temperature, pH electrode voltage, ORP,
a conductivity value and battery voltage. That makes the analyser fully
usable from Home Assistant or any BLE client with no account and no
subscription.

The spec is `device-specs/devices/blueriiot-blue-connect.yaml`. Where the two
disagree, the spec wins.

!!! warning "Not the Zodiac Blue Connect"
    Zodiac-branded "Blue Connect" **Gold/Silver** analysers advertise as
    `BC3…`, use different vendor services and require a 9-character access
    code for on-demand measurements. That is a different protocol and is not
    covered here.

## Hardware

| Property | Value |
|----------|-------|
| Models | Blue Connect Plus (EU ref. 71663; AU ref. 73661), Blue Connect Go (ref. 73014), earlier plain "Blue Connect", first-generation "blue by Riiot" (2017) |
| Chipset | Cypress (Infineon) PSoC 4 BLE: inferred from the Cypress bootloader service, the Cypress address block `00:A0:50` and company ID `0x0131` |
| Radio | BLE, 10 dBm, plus Sigfox (EU 868 MHz; US and AU 902/920 MHz editions) |
| Battery | 3.6 V lithium thionyl chloride primary cell, about two years' life, reported on the wire in mV |
| Advertised name | `B` + generation digit + 8 hex digits (vendor app's filter `^B[12][0-9A-Fa-f]{8}$`; not yet seen on air) |
| FCC ID | None found. The manual carries an FCC Part 15 statement for serial numbers beginning with 4, but prints no FCC ID, and fccid.co has no Blueriiot, Riiot Labs or Fluidra grantee. |
| Rated ranges | pH 0–14, temperature 5–50 °C, ORP 0–999 mV, conductivity 250–15 000 µS/cm (Plus) |

## Initial Setup

| Property | Value |
|----------|-------|
| Setup required | No (for a local BLE reading) |
| Method | `ble_direct` |
| Setup AP / advertised name | `^B[12][0-9A-Fa-f]{8}$` (update mode: `blue v2 - OTA`) |
| Passphrase protection | not_applicable |
| Confidence | medium (open integration and community scripts, not replayed here) |

Cloud activation happens in the vendor app, which scans the QR code on the
storage cap or takes the printed key and the last three serial digits. It
links the unit to an account and to Sigfox, and a local BLE reading does not
need it. The one physical step is waking a new unit (or one coming out of
winter standby): **shake it with one sharp movement, and two beeps confirm
activation.** Keep the top of the analyser out of the water, since the
antenna lives there.

**Factory reset**: none is documented for the analyser. The account link
lives in the cloud and BLE stores no bond, so nothing local needs clearing.
The vendor's fix for an unresponsive unit is a **forced restart**: take it
out of the water, unscrew the top (left-hand thread, so turn it clockwise),
unplug the white battery connector for about 10 seconds, reconnect it, reseat
the seal and screw it back anticlockwise.

**Rebinding**: nothing binds the BLE surface. Any client in range can
measure. Moving the unit to a different vendor account is a cloud operation.

## Pairing

| Property | Value |
|----------|-------|
| Pairing required | No |
| Security mode | `none` |
| Bonding | `none` |
| PIN source | n/a |
| One central at a time | Unknown |
| One bond at a time | No (nothing bonds) |
| Confidence | medium (vendor help centre plus the open integration) |

The vendor's own help centre explains that the analyser uses Bluetooth
without pairing, which is why it never shows up in the phone's Bluetooth
list.

**Entering pairing mode**: not applicable. The analyser advertises whenever
it is awake.

**Unpairing**: nothing to unpair.

**Recovery**: if a connection or measurement fails, close the vendor app and
unplug any Blue Extender, since the Extender is itself a BLE central that
connects to the analyser. Then retry. If the analyser still does not answer,
do the forced restart above.

## Protocol Summary

All UUIDs share the vendor base `-f0a2-9b06-0c59-1bc4763b5c00`. iopool's
probes use the same base, so never identify on it alone.

### BLE Services

| UUID | Name | Description |
|------|------|-------------|
| `f3300001-f0a2-9b06-0c59-1bc4763b5c00` | Analyser service | Main vendor service |
| `f3300002-f0a2-9b06-0c59-1bc4763b5c00` | Measure request | Write `0x01` (with response) to start a measurement |
| `f3300003-f0a2-9b06-0c59-1bc4763b5c00` | Measurement notification | One frame per request, about 8 s later |
| `f3300020-f0a2-9b06-0c59-1bc4763b5c00` | Command | One-byte opcodes (below) |
| `f3300008-f0a2-9b06-0c59-1bc4763b5c00` | Flash settings (older firmware) | Configuration record. Layout not decoded, so treat it as read-only |
| `f3300012-f0a2-9b06-0c59-1bc4763b5c00` | Flash settings (2.3.0+) | Same record on current firmware |
| `f3320001-f0a2-9b06-0c59-1bc4763b5c00` | Production info service | |
| `f3320011-f0a2-9b06-0c59-1bc4763b5c00` | BLE firmware version | Read. Layout below |
| `00060000-f8ce-11e4-abf4-0002a5d5c51b` | Cypress bootloader service | Update mode only |
| `00060001-f8ce-11e4-abf4-0002a5d5c51b` | Bootloader command | Write plus notify, Cypress bootloader packets |
| `f3380001-f0a2-9b06-0c59-1bc4763b5c00` | Blue Extender service | On the Extender, not the analyser. Command write `f3380002`, notify `f3380003`; command set not documented |

### Command: Measure now

**Request**: enable notifications on `f3300003`, then write to `f3300002`:

| Offset | Length | Description |
|--------|--------|-------------|
| 0 | 1 | `0x01` |

**Response**: one notification on `f3300003`. All multi-byte fields are
little-endian u16.

| Offset | Length | Field | Decode |
|--------|--------|-------|--------|
| 0 | 1 | Header | low nibble = message type (3), high nibble = format version: `0x23` on firmware ≤ 2.2.x (11 bytes), `0x33` on 2.3.0 (12 bytes) |
| 1 | 2 | Water temperature | raw × 0.01 °C |
| 3 | 2 | pH electrode | mV = raw × 0.25 − 512; uncalibrated pH = (2048 − raw) / 232 + 7 = 7 − mV / 58 |
| 5 | 2 | ORP | raw × 0.25 mV |
| 7 | 2 | Conductivity (raw) | µS/cm ≈ 1 061 500 / raw (community fit). Reads 0 or 1 on a Go (no probe) |
| 9 | 2 | Battery | mV (about 3620 on a healthy cell) |
| 11 | 1 | (version-3 frames only) | Meaning unknown |

The vendor app applies the temperature, pH-electrode and ORP scalings above
itself. The pH figure is the ideal-electrode formula the community fitted, and
the app shows a calibrated value that can differ by a few hundredths.

**Test vectors** (raw frames posted in the Home Assistant community thread,
beside what the vendor app or cloud showed):

| Frame | Decoded here | Vendor showed |
|-------|--------------|---------------|
| `23 ab 09 32 07 ab 0a 78 00 24 0e` | 24.75 °C, pH 7.888, ORP 682.75 mV, 8846 µS/cm, 3.620 V | 24.8 °C, pH 7.93, 685 mV, 8742 µS/cm, salinity 4.9 g/L |
| `23 a9 0b ff 07 aa 08 01 00 25 0e` | 29.85 °C, pH 7.004, 554.5 mV, no probe, 3.621 V | 29.8 °C, pH 7.0, 554 mV |
| `23 18 0b 7f 07 0d 0a 00 00 2b 0e` | 28.40 °C, pH 7.556, 643.25 mV, no probe, 3.627 V | 28.4 °C, pH 7.6, 645 mV |
| `33 a5 0a b0 07 bc 0a 01 00 2c 0e 22` | 27.25 °C, pH 7.345, 687.0 mV, no probe, 3.628 V, trailing byte 34 | (firmware 2.3.0 frame) |

### Command characteristic opcodes

Each is one byte written with response to `f3300020`.

| Opcode | Role | Advanced |
|--------|------|----------|
| `0x31` | Software reset (the app's "restart my analyser") | No |
| `0x20` | Select the US Sigfox radio zone | **Yes**: radio-regulatory |
| `0x21` | Select the AU Sigfox radio zone | **Yes**: radio-regulatory |
| `0x50` | Reboot into the Cypress bootloader (firmware update) | **Yes**: the unit cannot measure until an image is delivered |

### Firmware version (`f3320011`)

| Offset | Length | Field |
|--------|--------|-------|
| 0 | 1 | Major |
| 1 | 1 | Minor |
| 2 | 2 | Build year (LE) |
| 4 | 1 | Build day |
| 5 | 1 | Build month |
| 6 | 1 | Build minute |
| 7 | 1 | Build hour (UTC) |
| 8 | 8 | Source-revision hash (shown as hex) |

This is the BLE part's own version. One user's app showed `v0.2 2019-11-12`
beside product firmware 2.2.1.

### Advertisement

The vendor app also reads measurements from the advertisement. The
manufacturer data is company ID `0x0131` (Cypress's), then one message with the
same header byte as above, then two trailing bytes. The message types that
arrive there (compressed status records) are not decoded in this spec.

### Firmware update

The analyser is a Cypress PSoC 4 BLE part. After opcode `0x50` it reboots
into Cypress's stock BLE bootloader, advertises as `blue v2 - OTA` and serves
the bootloader service. There the app writes the `.cyacd` image row by row
using the standard Cypress bootloader host protocol. The app bundles firmware
2.3.0. An interrupted update leaves the unit in the bootloader, and the app
offers to finish it. The spec documents the transport by role only and
contains no flashing sequence. See [Firmware Update](../protocols/firmware-update.md).

## Troubleshooting

- **The write succeeds but nothing arrives.** Subscribe to `f3300003`
  *before* writing `0x01`. Otherwise another central (the vendor app, an
  Extender) may hold the link, the top of the analyser may be under water,
  or you may be out of the short BLE range. The vendor's last resort is the
  battery-disconnect restart. A forum user needed it after a firmware
  update left the unit unreachable.
- **Conductivity of about a million µS/cm.** You have a Go. It reports 1
  (sometimes 0) where the Plus reports its conductivity reading. The open
  integration only guards against 0.
- **Battery always 100 %.** The open integration multiplies its battery
  percentage by 100 twice before clamping. Use the voltage instead. With this
  cell chemistry a percentage derived from voltage says little until the very
  end.
- **Battery drains fast.** Every BLE measurement powers the probe. Poll
  every 30 minutes or less often, as the integration does by default and as
  the vendor's help centre advises.
- **The vendor app will not take a Bluetooth measurement on Android.**
  Older builds required location services to be on before a BLE scan. That
  is an Android permission requirement, not a device one.
- **pH or ORP is slightly off from the app.** This spec's values are
  uncalibrated. The app applies a per-unit calibration from its pH 7/pH 4/ORP
  reference-solution routine. Check a test strip before dosing chemicals.

## Tools Used

- Static analysis of the vendor Android app (v4.17.0), described by role only
- Home Assistant community captures (gatttool on a Raspberry Pi, and an iPhone BLE scanner app)
- adamantivm/BlueConnect source review

## References

- Vendor user manual (Blue Connect, Plus and Go, EN, Dec 2019): <https://s3-eu-west-1.amazonaws.com/riiotlabs-manuals/RIIOT_BlueConnect-UserManual-A4-EN.pdf>
- Blue Extender manual: <https://s3-eu-west-1.amazonaws.com/riiotlabs-manuals/RIIOT_BlueExtender_UserManual-A4-EN.pdf>
- Vendor help centre, "Bluetooth without pairing": <https://support-blueriiot.helpshift.com/hc/en/3-blueriiot/faq/80-my-analyzer-does-not-appear-in-the-list-of-bluetooth-connected-devices-what-should-i-do/>
- Vendor help centre, forced restart: <https://support-blueriiot.helpshift.com/hc/en/3-blueriiot/faq/138-i-cannot-connect-to-my-analyzer-via-bluetooth/>
- adamantivm/BlueConnect (MIT Home Assistant integration): <https://github.com/adamantivm/BlueConnect>
- Home Assistant community thread (frames and decode): <https://community.home-assistant.io/t/blue-connect-pool-measurements/118901?page=9>
- Infineon BLE component datasheet (bootloader service UUIDs): <https://www.infineon.com/assets/row/public/documents/cross-divisions/396/infineon-component-bluetooth-low-energy-ble-pdl-2.20-software-module-datasheets-en.pdf>
- Zodiac Gold/Silver (a different protocol, GPLv3, cited only for the contrast): <https://github.com/Adrien40/ha-blue-connect-local-test>
- [Pairing, Bonding and Unpairing](../protocols/pairing.md)

## Contributors

- Initial spec from app static analysis plus community and open-source prior art
