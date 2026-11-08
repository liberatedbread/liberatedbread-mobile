# Big Ass Fans i6 / es6 / Haiku (firmware 3.x)

> **Status**: Spec Available
> **Protocol**: WiFi (plain TCP 31415, SLIP-framed protobuf; BLE for setup)
> **Manufacturer**: Big Ass Fans (Delta T LLC)
> **Manufacturer Status**: Active

## Overview

This spec covers Big Ass Fans' residential ceiling fans, the Haiku H/I and L
series, i6 and es6, plus Haiku lights and wall controls, running firmware 3.x.
In April 2022 Big Ass Fans moved the Haiku line to the protocol the i6 already
spoke, replaced the Haiku app with the Big Ass Fans app, and dropped the legacy
SenseME ASCII protocol from those fans. Integrations built on the old protocol
stopped working overnight. The legacy protocol has its own spec,
`big-ass-fans-senseme`.

The protocol is local and needs no account:

- The fan announces `_api._tcp` over mDNS.
- It accepts a plain TCP connection on port **31415**, with no TLS, no key and
  no login.
- Every message in both directions is one protobuf message inside a SLIP frame.
- A client **queries** a group of properties or **commits** one property.
- The fan answers queries and **pushes** changes to connected clients. A
  commit is acknowledged only by the fan pushing the new value back.

Big Ass Fans documents none of this. The protocol was worked out by
[aiobafi6](https://github.com/jfroy/aiobafi6), which Home Assistant's `baf`
integration has shipped since 2022.6, and by oogje's
[Homebridge plugin](https://github.com/oogje/homebridge-i6-bigassfans). The
field numbers exist only in aiobafi6's hobbyist `.proto`. This page and the
spec restate them in our own tables and do not reproduce that file. A static
check of the vendor Android app (v3.3.4, cross-checked against v3.4.0)
confirmed the transport, framing, mDNS browse, BLE setup channel, colour
presets and firmware-upload port. Everything taken from it is marked
*reported*. Nothing here has been run against a fan by this project.

**Choose the protocol from the advertisement, not the product name.** A usable
`_api._tcp.local.` record and API version select this SLIP/protobuf profile.
Legacy UDP replies select the [SenseME profile](big-ass-fans-senseme.md). Do
not send both formats to discover which one a fan accepts. Haiku firmware 3.0
was the migration boundary, but API versions vary independently: a public
SmartThings implementation reports H/I firmware 3.3.7 with API version 8.

**Out of scope:**

- the legacy SenseME firmware
- the vendor cloud, beyond what it is for
- firmware image bytes
- the Bluetooth remote's own pairing, beyond how to do it
- Matter, which current smart boards also support (they ship with a Matter QR
  sticker)

## Hardware

| Property | Value |
|----------|-------|
| Model Number | i6: MK-i61-* (051806, 061806, 071806, 051800, 061800, 051906, 061906, 071906 …). es6: MK-ES62-052306/062306/072306. Haiku: MK-HK4-*. Haiku i: K3127-*, K3150-*. Haiku L: FR112C-U1H, FR127C-U1H/J, FR150C-U1H/J. Model strings on the wire: `i6`, `es6`, `Haiku H/I Series`, `Haiku L Series`, `Haiku Light`, `Haiku Switch`. The app also knows `Turbo6`, `Mammoth`, `Bison`, `Speakeasy` |
| Chipset | Not identified. One published example MAC carries OUI `20:F8:5E` (Delta Electronics), which suggests a Delta Wi-Fi module (low confidence) |
| Radio | Wi-Fi (control) and BLE (setup, plus a fallback channel for the same messages). The smart board is a replaceable part: "SenseME board" on Haiku, "smart board" on i6/es6. Haiku L needs its optional Wi-Fi module for any app control |
| FCC ID | Not found. None is printed in the manuals held, and fccid.co lists no Big Ass Fans or Delta T grantee |

!!! note "Where the temperature comes from"
    On some models the temperature and humidity readings, and so Auto Comfort,
    come from the Bluetooth remote or wall control, not the fan. Home
    Assistant's documentation says so, and oogje says it for the i6. If the fan
    loses its remote, those values stop updating while the fan stays reachable.

## Initial Setup

| Property | Value |
|----------|-------|
| Setup required | Yes |
| Method | `ble_provisioning` (the Big Ass Fans app) |
| Setup AP / advertised name | No AP. The app scans for BLE service `e0fc1000-1fb1-4168-96df-b3f057a86e01` |
| Passphrase protection | unknown (sent over an unbonded BLE channel; the message is not documented) |
| Confidence | low (vendor help page plus a static read of the app; not replayed) |

The vendor's help page and the app agree on the flow:

1. Install and power the fan. It beeps once on power-up unless beeps are
   turned off.
2. In the app, choose **Add Product**. The app searches over Bluetooth.
3. Press **Identify**. The chosen fan beeps and flashes its LEDs.
4. Choose the home network and enter its passphrase. The app sends it over
   BLE.
5. Name the fan.
6. The fan then appears as `_api._tcp` on the LAN.

The BLE channel is known at the transport level: a vendor service with a write
characteristic and a notify characteristic, carrying the same SLIP-framed
protobuf as the LAN socket. The message that carries the Wi-Fi credentials is
not, so onboarding still needs the vendor app. It is also not established
whether the app lets you finish onboarding without signing in. There is a
cloud claim step, and one reviewer describes backing out of sign-up to reach
local devices. Haiku L fans bought before 2023 join over Wi-Fi rather than
Bluetooth (the app offers a "Wi-Fi (before 2023)" route). That route is not
documented here.

**Factory reset**: the i6 manual gives two routes. Neither has been tried here.

- **From the paired remote:** hold **fan power** for 5 s until the remote's
  LEDs blink and the fan beeps, then press **fan minus**. The fan beeps and
  its LED blinks slowly. The reset is complete when the LED blinks **green**.
- **Without the remote:** switch the fan off at the wall switch or breaker for
  about 5 s, then on for about 5 s. Do this **four times** in all. The reset is
  complete when the fan's LED turns **green**.

A reset **erases all settings, including the fan's name and its Wi-Fi
network**. The Haiku board instructions only point at the support site, so
whether the same steps apply to Haiku and es6 is not established.

**Rebinding to a new network**: physical reset only, as far as is known. The
app's advice is to reset the product's network settings and then Add Product
again. No way to change Wi-Fi over the LAN socket is known.

## Pairing

| Property | Value |
|----------|-------|
| Pairing required | No |
| Security mode | `none` |
| Bonding | `none` |
| PIN source | not applicable |
| One central at a time | Unknown (Home Assistant and the vendor app are routinely used side by side) |
| One bond at a time | not applicable |
| Confidence | medium (three independent clients connect with nothing but a socket) |

Nothing pairs on the control path. Anything on the LAN can open 31415 and drive
the fan. The app also uses the BLE setup channel without bonding (reported).

**The Bluetooth remote and wall control** pair with the fan itself. This is
separate from anything a client does:

- **To pair:** hold the remote close to the fan and press any button. The
  remote's LEDs cycle while it searches, and the fan plays a jingle when
  pairing completes.
- **To move a remote to another fan:** hold **fan power** and **fan minus**
  until the LEDs flash, which clears all of the remote's pairings. Then press
  any button near the new fan.

**Recovery**: none needed for LAN clients. If a remote stops working, power
cycle the fan and pair the remote again (i6 manual).

## Protocol Summary

### Discovery

| Signal | Value |
|--------|-------|
| mDNS service | `_api._tcp.local.`, SRV port 31415 |
| TXT keys | `name`, `model`, `uuid`, `api version` (with a space) |
| Match | `api version` present **and** `model` starting with `i6`, `es6`, `Haiku`, `Turbo6`, `Mammoth`, `Bison` or `Speakeasy` (case-insensitive) |
| Identity | TXT `uuid`, which equals the fan's own property field 10 |
| BLE (setup only) | service `e0fc1000-1fb1-4168-96df-b3f057a86e01` |

aiobafi6 ignores fans whose `api version` is below 4. Occupancy readings need
API version 5, which is firmware 3.1. Home Assistant's zeroconf matcher only
accepts `haiku*` and `i6*`, so it misses es6. The vendor app also browses
`_http._tcp`, for a reason not established; do not use that as a fan signal.

### Transport and framing

- **Socket:** plain TCP to the SRV port (31415). The vendor app uses a 10 s
  connect timeout and TCP keepalive.
- **Frames:** RFC 1055 SLIP. Each message is `c0`, then the message, then
  `c0`. Inside a message, `c0` is sent as `db dc` and `db` as `db dd`. There is
  no length field and no checksum.
- **Empty frames:** a `c0 c0` pair can occur. Skip it, as the vendor app does.
  aiobafi6 drops the connection instead.
- **Messages:** protobuf (proto2). Every number and boolean is a varint
  (base-128, least-significant group first). Strings and nested messages are
  length-delimited. Temperatures are int32, so a value below 0 °C is a 10-byte
  varint.
- **Size:** aiobafi6 caps a message at 4096 bytes and says none is expected to
  be larger.

Every frame in either direction uses the same message tree. The names below
are ours:

| Message | Field | Carries |
|---------|-------|---------|
| outer | 2 | envelope |
| envelope | 2 | commit (client → fan) |
| envelope | 3 | query (client → fan) |
| envelope | 4 | query result (fan → client, answers and pushes) |
| commit | 3 | one property set |
| query | 1 | group (varint) |
| query result | 2 (repeated) | property sets: merge each one, later values win |
| query result | 3 (repeated) | schedules (group 5); format unknown |

| Query group | Meaning |
|-------------|---------|
| 0 | Everything. Send it on connect |
| 1 / 2 | Fan / light properties |
| 3 | Firmware, clock and API properties. The vendor app repeats this one on a timer (about every 15 s, per oogje) |
| 4 | Network |
| 5 | Schedules |
| 6 | Sensors (oogje sends it first and calls it capabilities) |
| 7, 8 | Present in the app's enum; meaning unknown |

### Client rules

1. Connect, then send query group 0 at once. Merge every property set in the
   replies into one running copy.
2. Keep the socket open. The fan pushes every change, and that push is the
   only confirmation a commit gets.
3. Re-query now and then for values the fan does not push, such as RPM and the
   clock. aiobafi6 defaults to every 60 s and Home Assistant uses 300 s.
4. Put **one property per commit**. Every known client does, and whether the
   fan accepts more is unknown.
5. To run at a chosen speed, commit fan mode = 1 (on), then commit speed. This
   is what Home Assistant does.
6. Skip unknown fields, and leave the volatile ones (clock, uptime, RPM) out of
   change detection.
7. The fan occasionally drops the connection (oogje). Reconnect, and resend a
   command that was in flight.

### Properties

These are the fields a client needs. The spec's
`protocol_details.baf_i6_api.properties` has the full table, including fields
only oogje names, which are marked hypothesis.

| Field | Name (ours) | Access | Values / units |
|-------|-------------|--------|----------------|
| 1 | name | r | string |
| 2 | model | r | string, as TXT `model` |
| 7 | firmware_version | r | string |
| 10 | service_uuid | r | equals TXT `uuid` |
| 13 | api_version | r | decimal string |
| 17 | capabilities | r | sub-message of flags (below) |
| 43 | fan_mode | rw | 0 off, 1 on, 2 auto |
| 44 | reverse | rw | 0 forward, 1 reverse. The app offers it but advises against it |
| 45 | speed_percent | r | 0–100 % |
| 46 | speed | rw | 0–7. 1–7 are the app's seven speeds; 0 stops rotation |
| 47 | comfort_enabled | rw | Auto Comfort on/off |
| 48 | comfort_ideal_temperature | rw | int32, 0.01 °C (2350 = 23.50 °C) |
| 50 / 51 | comfort_min_speed / comfort_max_speed | rw | 0–7. Min 0 = no minimum, max 7 = no maximum |
| 52 / 53 | fan_motion_sense / timeout | rw | bool / seconds |
| 54 / 55 | fan_return_to_auto / timeout | rw | bool / seconds |
| 58 | whoosh | rw | bool |
| 60 / 61 / 62 | heat_assist / speed / reverse | rw | bool / 1–7 / bool |
| 63 / 64 | target_rpm / current_rpm | r | rpm. Current RPM is not pushed |
| 65 | eco | rw | bool (Haiku) |
| 66 | fan_occupancy | r | bool. API 5+; clears about 4.5–5 min after the last motion |
| 68 | light_mode | rw | 0 off, 1 on, 2 auto |
| 69 | light_brightness | rw | 0–100 % (0 = off) |
| 70 | light_brightness_level | rw | 0–16. Home Assistant uses this one |
| 71 | light_color_temperature | rw | kelvin, not mireds |
| 73 / 74 / 75 | light motion timeout / return to auto / timeout | rw | seconds / bool / seconds |
| 77 | light_dim_to_warm | rw | bool |
| 78 / 79 | warmest / coolest colour temperature | r | kelvin: the light's range |
| 82 | light_target | rw | 0 both, 1 downlight, 2 uplight (oogje, hypothesis) |
| 85 | light_occupancy | r | bool. API 5+; clears about 9.5 min after the last motion |
| 86 | temperature | r | int32, 0.01 °C |
| 87 | humidity | r | % (aiobafi6: whole percent; oogje divides by 100, unresolved) |
| 120 | ip_address | r | string |
| 124 | wifi | r | sub-field 1 SSID |
| 134 / 135 / 136 | LED indicators / beep / legacy IR remote | rw | bool |

The **capability flags** (field 17) say which controls to draw. aiobafi6 and
oogje disagree on one of them:

| Flag | oogje | aiobafi6 |
|------|-------|----------|
| 1 | temperature sensor | comfort flag 1 |
| 3 | occupancy sensor | comfort flag 3 |
| 4 | downlight | has light |
| 6 | colour-temperature control | **has uplight** (conflict) |
| 11 | uplight | — |
| 14 | eco mode | — |

Home Assistant offers Auto Comfort only when flags 1 and 3 are both set.

**Light colour.** The app's picker offers the presets below, hiding any that
fall outside the light's range in fields 78–79. Picking one commits field 71.

| Kelvin | App label |
|--------|-----------|
| 2200 | Warm |
| 2700 | Warm White |
| 3000 | Soft White |
| 3500 | Natural White |
| 4000 | Bright White |
| 5000 | Cool White |
| 6500 | Daylight |

### Commands

A commit is `c0 12 <len> 12 <len> 1a <len> <tag> <varint> c0`. The tag is
`varint(field << 3)`. Each frame below was produced by an independent encoder
and matches aiobafi6's serializer byte for byte.

| Command | Field | Example | Frame (hex) |
|---------|-------|---------|-------------|
| Query everything | — | group 0 | `c0 12 04 1a 02 08 00 c0` |
| Query group | — | group 3 | `c0 12 04 1a 02 08 03 c0` |
| Fan mode | 43 | auto (2) | `c0 12 07 12 05 1a 03 d8 02 02 c0` |
| Speed | 46 | 3 | `c0 12 07 12 05 1a 03 f0 02 03 c0` |
| Reverse | 44 | on | `c0 12 07 12 05 1a 03 e0 02 01 c0` |
| Whoosh | 58 | on | `c0 12 07 12 05 1a 03 d0 03 01 c0` |
| Auto Comfort | 47 | on | `c0 12 07 12 05 1a 03 f8 02 01 c0` |
| Ideal temperature | 48 | 23.5 °C (2350) | `c0 12 08 12 06 1a 04 80 03 ae 12 c0` |
| Comfort min speed | 50 | 2 | `c0 12 07 12 05 1a 03 90 03 02 c0` |
| Comfort max speed | 51 | 7 | `c0 12 07 12 05 1a 03 98 03 07 c0` |
| Heat Assist | 60 | on | `c0 12 07 12 05 1a 03 e0 03 01 c0` |
| Heat Assist speed | 61 | 1 | `c0 12 07 12 05 1a 03 e8 03 01 c0` |
| Light mode | 68 | on | `c0 12 07 12 05 1a 03 a0 04 01 c0` |
| Light brightness | 69 | 50 % | `c0 12 07 12 05 1a 03 a8 04 32 c0` |
| Light colour | 71 | 4000 K | `c0 12 08 12 06 1a 04 b8 04 a0 1f c0` |

**A push from the fan, with an escape.** This frame reports speed 3 and a
temperature of 22.40 °C:

```
c0 12 0d 22 0b 12 03 f0 02 03 12 04 b0 05 db dc 11 c0
```

The raw temperature 2240 encodes as the varint `c0 11`, so its `c0` goes out as
`db dc`. After un-escaping, the query result holds two property sets: field 46
= 3, then field 86 = 2240.

### BLE setup channel (reported)

| UUID | Role |
|------|------|
| `e0fc1000-1fb1-4168-96df-b3f057a86e01` | Vendor service. The app's Add Product scan filters on it |
| `e0fc1003-1fb1-4168-96df-b3f057a86e01` | Write with response. SLIP frames are split into 20-byte pieces |
| `e0fc1004-1fb1-4168-96df-b3f057a86e01` | Notify. Carries SLIP frames from the fan |

The app requests a 250-byte MTU, enables notifications through the standard
`00002902-0000-1000-8000-00805f9b34fb` descriptor, and reads Model Number and
Serial Number from the Device Information service. Earlier research notes
listed three "vendor BLE UUIDs" as the wall remote's pairing channel. Those
strings are not GATT UUIDs at all: in the app they identify thermostat
integrations. They are deliberately left out of the spec.

### Firmware update

This is reported from the app and is only here so a reader knows what the
port is. Do not drive it from anything but the vendor app.

1. The app asks the cloud for a firmware token, which requires an account.
2. It downloads the image.
3. It uploads the image to the fan's HTTP server on TCP **31416**.

The request path and body are left out on purpose, and whether the fan is
prepared for the upload by a message on 31415 is not established. The app can
also downgrade a Haiku to the legacy firmware, but only when support asks for
it. A downgrade factory resets the fan, which must then be added again with
the old Haiku app.

### Cloud

`api.bigassfans.com` uses OAuth and a versioned vendor media type. It handles:

- claiming a device to an account
- control from outside the home network
- Alexa and Google Assistant
- thermostat links
- firmware tokens

The LAN protocol never touches it, and fans keep working locally without
internet access.

## Troubleshooting

Collected from store reviews, the app's own messages and the open-source
projects:

- **The app cannot find the fan over Bluetooth on Android.** One reviewer
  could only add the fan from an iPhone; Android control worked after that. A
  fan that is already on a network will not re-enter setup until its network
  settings are reset.
- **"Could not find the device on the network" after setup.** The app detects
  VPNs and asks for them to be turned off. mDNS and the LAN socket do not cross
  a VPN, and they do not cross an AP with client isolation either. One reviewer
  had to switch phone Wi-Fi off while the fan joined.
- **The Wi-Fi password is rejected.** The product does not support a double
  quote in the passphrase.
- **Firmware update fails with "preparation failed".** One reviewer saw this
  on Android 15 on three of four fans; the same update succeeded from an
  Android 9 phone.
- **The integration stopped working after the April 2022 update.** The fan is
  now on firmware 3.x and no longer speaks SenseME. Switch to an i6-protocol
  client such as aiobafi6 or Home Assistant's `baf` integration.
- **Temperature and Auto Comfort go unavailable while the fan stays online.**
  On those models the readings come from the remote. Restore the remote's
  pairing.
- **A command is ignored now and then.** The fan occasionally resets the
  connection (oogje). Reconnect and resend.

## Tools Used

- [x] Static read of the vendor Android app (jadx), targeted at transport, framing, mDNS, BLE and firmware-upload paths
- [x] aiobafi6, Home Assistant `baf` and homebridge-i6-bigassfans source review
- [x] Independent protobuf/SLIP encoder cross-checked against aiobafi6's serializer
- [ ] Packet capture or bench test against a real fan

## References

- [aiobafi6](https://github.com/jfroy/aiobafi6): Apache-2.0 Python client; `wireutils.py`, `device.py`, `discovery.py`, `proto/aiobafi6.proto`
- [Home Assistant Big Ass Fans integration](https://www.home-assistant.io/integrations/baf/) and [its source](https://github.com/home-assistant/core/tree/dev/homeassistant/components/baf)
- [homebridge-i6-bigassfans](https://github.com/oogje/homebridge-i6-bigassfans): MIT; `src/platformAccessory.ts`
- [aiosenseme](https://github.com/bdraco/aiosenseme): the legacy SenseME client, archived
- [i6 operation and maintenance manual (PDF)](https://bigassfans.widen.net/view/pdf/aex819i2mz/i6-operation-maintenance-manual.pdf): remote pairing and factory reset
- [i6 installation guide (PDF)](https://bigassfans.widen.net/view/pdf/cwocvvmrju/i6-install-guide.pdf)
- [es6 installation guide (PDF)](https://bigassfans.widen.net/view/pdf/qddmwtqbbr/es6-install-guide.pdf)
- [Haiku installation guide (PDF)](https://bigassfans.widen.net/view/pdf/3id7cxbxkj/haiku-install-guide.pdf)
- [Haiku L installation guide (PDF)](https://bigassfans.widen.net/view/pdf/zq0muwn7zn/haiku-l-install-guide.pdf)
- [Haiku i installation guide (PDF)](https://bigassfans.widen.net/view/pdf/xkq3irtwao/haiku-i-install-guide.pdf)
- [BAF app: how to add a fan to Wi-Fi](https://bigassfans.com/support/baf-app/how-to-add-fan-to-wifi/)
- [Bluetooth remote setup and pairing](https://bigassfans.com/support/controls/bluetooth-remote/set-up-and-pairing/) and [disconnecting](https://bigassfans.com/support/controls/bluetooth-remote/disconnecting/)
- [Initial Device Setup](../protocols/device-setup.md), [Pairing, Bonding and Unpairing](../protocols/pairing.md), [Firmware Update](../protocols/firmware-update.md)
- [Missing Devices survey](../research/missing-devices.md): the entry this spec answers

## Contributors

- Liberated Bread contributors: spec from open-source clients plus a targeted static check of the vendor app
