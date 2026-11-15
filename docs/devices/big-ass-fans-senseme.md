# Big Ass Fans Haiku with SenseME (legacy firmware)

> **Status**: Spec Available
> **Protocol**: WiFi (ASCII "SenseME" protocol on UDP and TCP port 31415)
> **Manufacturer**: Big Ass Fans (Delta T LLC)
> **Manufacturer Status**: Active. The vendor has replaced this protocol, but the products are still supported.

## Overview

This page covers Big Ass Fans' residential Haiku ceiling fans with SenseME,
the Haiku L with its Wi-Fi module, the standalone Haiku Light and the Haiku
Wall Control, **while they still run the legacy firmware below 3.0**. Every
published parameter dump comes from firmware 2.5.x or 2.6.0. That firmware
speaks a small ASCII protocol on port 31415. Anyone on the LAN can use it,
with no account, no cloud and no authentication. It covers:

- fan power, speed 0–7, direction, Whoosh and sleep mode
- Smart Mode (the vendor's "Auto Comfort"), with its temperature target and
  speed bounds
- light level, and colour temperature on the Haiku Light
- the motion (occupancy) sensor
- the room grouping

The protocol is worth writing down because it is disappearing. Firmware 3.0,
from April 2022, replaced it with a protobuf protocol (see the
big-ass-fans-i6 spec and [aiobafi6](https://github.com/jfroy/aiobafi6)).
Accepting the firmware update offered by the current Big Ass Fans app moves a
legacy device to 3.x. aiosenseme, the library Home Assistant used, was
archived in 2023 for that reason. The protocol now lives only in half a dozen
archived hobby clients. The spec gathers it in one place, per key, with
units.

**Out of scope:**

- firmware 3.x, i6 and es6 (the protobuf protocol)
- the vendor cloud (account claim, Alexa, remote access)
- firmware upload framing
- the Bluetooth wall-remote pairing, a 3.x-era accessory

!!! warning "The current app will take the device off this protocol"
    Opening a legacy fan in the current **Big Ass Fans** app leads to a
    firmware update. After that update the fan speaks only the 3.x protocol,
    and every SenseME integration stops working. Owners' reviews and the
    openHAB and aiosenseme projects all record this. The app does have a
    support-only "downgrade" path, which factory-resets the device back onto
    legacy firmware. To stay on SenseME, decline the update.

Nothing here has been run against hardware by this project, and no capture of
real traffic is held. The protocol facts come from open-source clients that
were written against real fans. The rest comes from a static reading of the
current vendor Android app (3.3.4, cross-checked against 3.4.0), which still
has a legacy-device handler. Everything is marked `reported`.

Select this profile only after observing a legacy UDP discovery reply such as
`FAN,HAIKU,SENSEME`, or an established owner firmware history. A usable
`_api._tcp.local.` record selects the [i6 / firmware 3.x profile](big-ass-fans-i6.md).
Do not broadcast both protocol formats as a capability test: Haiku is a family
name, not a reliable protocol selector.

## Hardware

| Property | Value |
|----------|-------|
| Model Number | Identified on the wire by model string, not part number: `FAN,HAIKU,SENSEME` (Haiku with SenseME), `FAN,HAIKU,HSERIES` (Haiku H), `FAN,LSERIES` (Haiku L with Wi-Fi module; the current guide lists FR112C-U1H, FR127C-U1H/J, FR150C-U1H/J), `LIGHT,HAIKU` (Haiku Light, discontinued), `SWITCH,SENSEME` (Haiku Wall Control) |
| Firmware | Legacy SenseME 2.x. Families `FW000003` (Haiku fan), `FW000004` (wall control), `FW000005` (Haiku L), `FW000006` (Haiku Light) in the published dumps |
| Chipset | Not identified. Published device MACs sit in `20:F8:5E`, a block registered to Delta Electronics, most likely the Wi-Fi module's maker |
| Radio | Wi-Fi (band not established). Legacy fans shipped with an infrared remote |
| Sensors | Occupancy (motion) on the Haiku fan and the wall control; optional on the Haiku L (`DEVICE;OPTION;SENSORS`). The fan uses a temperature reading internally for Smart Mode, but no legacy client reads it |
| FCC ID | Not found. No Big Ass Fans or Delta T grantee turned up, and none is printed in the held manuals |

## Initial Setup

| Property | Value |
|----------|-------|
| Setup required | Yes |
| Method | `softap_udp`: the device's own setup access point, then a join request over the SenseME protocol |
| Setup AP / advertised name | Not established |
| Passphrase protection | plaintext |
| Confidence | low (inferred from the protocol keys and the vendor app; not replayed) |

A legacy device joins Wi-Fi from its own access point. `GETALL` reports
`NW;AP;STATUS` and `NW;DHCP`, and both read `OFF` once the device is
provisioned. The current vendor app's legacy handler can ask the device to
scan and can send it a join request. Onboarding runs over the same protocol
and port as normal control:

1. Power a device with no network stored and join its setup access point.
   Its name and security are not established.
2. Broadcast `<ALL;DEVICE;ID;GET>` to UDP 31415. The device answers
   `(name;DEVICE;ID;mac;model)`.
3. Optionally send `<mac;NW;SCAN>`. The reply format is not established.
4. Send `<mac;NW;JOIN;ssid;passphrase>`, backslash-escaping `< > ; ( ) + ,`
   and `\` in both fields. The passphrase travels in plain text.
5. Move the client back to the home network and broadcast the probe again.

The alternative is the vendor's older **Haiku by BAF** app (earlier **Haiku
Home**). The current app names it as the app legacy products are designed
for. Whether it can still be installed is not established.

**Factory reset**: no reset procedure specific to legacy firmware is held.
The candidate is the current app's remote-control reset:

1. Hold **Fan Power** for about 5 s, until the LEDs blink and the fan beeps.
2. Tap **Speed Minus** or **Speed Plus**. The app shows one or the other,
   depending on the product.
3. The reset is done when the LEDs stop blinking. A fitted light comes on.

That sequence was written for current-firmware fans and the Bluetooth remote,
so it may not apply to a legacy fan with an IR remote (`verified: false`). A
reset loses the network connection. The i6 manual says a reset erases names
and Wi-Fi settings, but that is for the i6. Whether room membership, schedules
and Smart Mode settings survive is not established. Do not confuse the reset
with the Haiku L guide's **reboot** (hold fan On/Off until the LEDs blink,
then press it again within 30 s), which clears nothing. No protocol message
that resets the device is known.

**Rebinding to a new network**: in place, while the old network is still
up. Send `NW;JOIN` with the new credentials and the device moves; the current
app does exactly this. Once the old router is gone, the only route is a
factory reset and the setup-access-point flow.

## Pairing

| Property | Value |
|----------|-------|
| Pairing required | No |
| Security mode | `none` |
| Bonding | `none` |
| PIN source | not applicable |
| One central at a time | No. Several TCP clients can be connected at once |
| One bond at a time | No |
| Confidence | medium (several independent clients; not replayed) |

Nothing pairs. There is no key, token or client registration, and every
command works for anything on the LAN. aiosenseme keeps a TCP connection open
while the vendor app and the remote are in use and receives their changes as
pushes, so clients coexist.

**Entering pairing mode**: not applicable.

**Unpairing**: there is nothing to unpair. To stop a client, take it (or the
device) off the network.

**Recovery**: nothing holds the device exclusively. If a client sees no
state, it has probably missed the initial `GETALL`. Reconnect and read again.

## Protocol Summary

### Transport

| Property | Value |
|----------|-------|
| Discovery | UDP broadcast to port 31415; one reply datagram per device |
| Control | TCP port 31415, one long-lived connection; also accepted as UDP datagrams (Indigo plugin) |
| Framing | Request `<target;TOKEN;…>`; reply and push `(name;KEY…;VALUE…)`. No length, checksum or terminator |
| Encoding | ASCII. Free text escapes `< > ; ( ) + ,` and `\` with a backslash |
| Target | The device's MAC as it reports it (upper-case, colon-separated). Some clients use the name; the probe uses `ALL` |
| Authentication | None |
| Push | Yes, on an open TCP connection: every change, from any source |

The legacy protocol and firmware 3.x share port numbers. Per the current
vendor app, 3.x devices also accept TCP on 31415 (protobuf) and advertise
mDNS `_api._tcp`. An open TCP port therefore proves nothing. A reply to the
UDP probe is the legacy signal.

### Discovery

Send the 19 ASCII bytes `<ALL;DEVICE;ID;GET>`
(`3c414c4c3b4445564943453b49443b4745543e`) to UDP 31415. The published
clients and the vendor app all send from local port 31415 with
`SO_REUSEADDR`. aiosenseme sends to 255.255.255.255 once a second for 5 s.
The vendor app sends to the subnet-directed broadcast every 5 s.

| Field | Example | Meaning |
|-------|---------|---------|
| 0 | `Living Room Fan` | Device name (user-assigned, escaped) |
| 1–2 | `DEVICE`, `ID` | Fixed |
| 3 | `20:F8:5E:AA:BB:CC` | MAC: the stable identity and the target for every request |
| 4 | `FAN,HAIKU,SENSEME` | Model family, comma-separated |

aiosenseme drops a reply unless it has exactly five fields and is 31–200
characters long.

### Request forms

| Form | Example | Meaning |
|------|---------|---------|
| `<T;CAT;ATTR;ON>` / `…;OFF>` | `<mac;FAN;PWR;ON>` | Switch a boolean |
| `<T;CAT;ATTR;SET;V[;V]>` | `<mac;FAN;SPD;SET;3>` | Write a value |
| `<T;CAT;ATTR;GET[;QUAL]>` | `<mac;FAN;SPD;GET;ACTUAL>` | Read one value. The qualifier goes after `GET` in the request and before the value in the reply |
| `<T;GETALL>` | `<mac;GETALL>` | Dump every setting (40–55 replies). **Leaves out the occupancy status** |

### Replies

A reply ends at the first `)` that is not preceded by a backslash. A TCP read
can hold several replies or part of one, so buffer and split. Token 0 is the
device name, followed by the key and then the value or values. Most keys
carry one value, but `DEVICE;ID` carries two (mac;model),
`FAN;BOOKENDS`/`LIGHT;BOOKENDS` two (min;max) and `NW;PARAMS;ACTUAL` three
(address;netmask;gateway). A parser therefore has to know the key to split
it. aiosenseme's own accessors swap the netmask and gateway fields; the
published dumps show the order above.

### Main keys

| Key | Values | Command |
|-----|--------|---------|
| `FAN;PWR` | `ON`/`OFF` | `fan_turn_on` / `fan_turn_off` |
| `FAN;SPD;ACTUAL` | 0–7 (0 = stopped; bounded by `FAN;SPD;MIN`/`MAX`, 1 and 7) | `fan_set_speed` |
| `FAN;DIR` | `FWD`/`REV` (REV = winter / Heat Assist) | `fan_set_direction` |
| `FAN;WHOOSH;STATUS` | `ON`/`OFF` (write `FAN;WHOOSH;ON`) | `fan_whoosh_on` / `_off` |
| `FAN;AUTO`, `LIGHT;AUTO` | `ON`/`OFF`, switch on with motion | `fan_motion_auto_*`, `light_motion_auto_*` |
| `FAN;BOOKENDS` | room speed limits `min;max` | `fan_set_room_speed_limits` |
| `LIGHT;PWR` | `ON`/`OFF` | `light_turn_on` / `_off` |
| `LIGHT;LEVEL;ACTUAL` | 0–16 (bounded by `LIGHT;LEVEL;MIN`/`MAX`, 1 and 16) | `light_set_level` |
| `LIGHT;COLOR;TEMP;VALUE` | 2200–5000 K, Haiku Light only | `light_set_color_temp` |
| `SMARTMODE;STATE` | `OFF`/`COOLING`/`HEATING`/`FOLLOWTSTAT` (`SMARTMODE;ACTUAL` = in effect) | `smartmode_set` |
| `LEARN;ZEROTEMP` | Smart cooling target, **hundredths of °C** (2111 = 21.11 °C) | `cooling_set_ideal_temp` |
| `LEARN;MINSPEED` / `MAXSPEED` | 0–6 (0 = no min) / 1–7 (7 = no max) | `cooling_set_min_speed` / `_max_speed` |
| `SLEEP;STATE` | `ON`/`OFF` | `sleep_on` / `sleep_off` |
| `SMARTSLEEP;IDEALTEMP` | sleep target, hundredths of °C | `sleep_set_ideal_temp` |
| `SMARTSLEEP;MINSPEED` / `MAXSPEED` | 0–7 | `sleep_set_min_speed` / `_max_speed` |
| `SNSROCC;STATUS` | `OCCUPIED`/`UNOCCUPIED`, **not in GETALL** | read with `get_occupancy` |
| `SNSROCC;TIMEOUT;CURR` | ms, 60000–86400000 | `occupancy_set_timeout` |
| `WINTERMODE;HEIGHT` | fan height, cm (274 ≈ 9 ft) | not declared |
| `GROUP;LIST`, `GROUP;ROOM;TYPE` | room name (`EMPTY` = none), room category 0–28 | read only |
| `DEVICE;BEEPER`, `DEVICE;INDICATORS` | `ON`/`OFF` | `beeper_*`, `indicators_*` |
| `DEVICE;LIGHT` | `PRESENT` / `NOT PRESENT` / `PRESENT;COLOR` | draw light controls only when present |
| `NW;SSID`, `NW;TOKEN`, `FW;NAME`, `TIME;VALUE` | network, per-device UUID, firmware family, ISO-8601 UTC clock | read only |

The full table, with the less-understood keys (`FAN;TIMER`, `SLEEP;EVENT`,
`SCHEDULE;*`, `LIGHT;COLOR;LEVEL`, `ERRORLOG;*`), is in the spec's
`protocol_details.senseme.state_keys`.

### Messages only the vendor app sends

| Message | Role |
|---------|------|
| `<mac;DEVICE;SIGNAL;SET;10000>` | Identify. The unit of 10000 is not established |
| `<mac;NW;SCAN>` | Wi-Fi scan (reply not established) |
| `<mac;NW;JOIN;ssid;passphrase>` | Join a network (the spec marks it `advanced`) |
| `<mac;NAME;VALUE;SET;name>` | Rename |

### Connection lifecycle

1. Open TCP 31415.
2. Send `<mac;DEVICE;ID;GET>`, `<mac;SNSROCC;STATUS;GET>` and `<mac;GETALL>`.
3. Keep the connection open. Changes arrive as pushes.
4. Re-send those three reads about once a minute (aiosenseme adds jitter).
   Treat about 90 s of silence as a dead connection and reconnect.

### Firmware update

The vendor app downloads a token-gated image from its cloud. For a legacy
device it requests a "-GEN3" image, meaning firmware 3.x. It then uploads the
image to the device over plain HTTP on port 31416. The spec records the
direction and consequence only, never the upload format. For this protocol
the update is effectively one-way.

## Troubleshooting

- **Integration stopped working after using the new app.** The fan was
  updated to firmware 3.x. A Play Store review describes exactly this for a
  Hubitat driver, and openHAB and aiosenseme record the same break. Either move the
  integration to the 3.x protocol (aiobafi6, Home Assistant's `baf`
  integration) or ask vendor support about the downgrade path, which
  factory-resets the device.
- **Occupancy never shows.** `GETALL` does not include it. Send
  `SNSROCC;STATUS;GET` after connecting.
- **Gateway and netmask look swapped.** aiosenseme's accessors read
  `NW;PARAMS;ACTUAL` in the wrong order. The order is
  address;netmask;gateway.
- **Whoosh turned itself off.** Setting a speed switches Whoosh off
  (observed by aiosenseme).
- **TCP 31415 is open but nothing answers the ASCII.** It is probably a 3.x
  device, which uses the same port for protobuf. Check for a UDP probe reply.
- **Setup fails at the join step.** Owners of the vendor app report having to
  take the phone off Wi-Fi by hand while the fan joins the network. A phone OS
  that holds on to the setup network, or prefers mobile data, can hide the
  device on either side of the move. No join result is established on the
  wire.
- **Two clients fight over state.** Any client can change anything. Always
  render from pushes, not from what you last sent.

## Tools Used

- [x] Published clients: bdraco/aiosenseme (discovery.py, device.py, data/),
  bpennypacker/SenseME-Indigo-Plugin (plugin.py), TomFaulkner/SenseMe,
  sean9keenan/BigAssFansAPI, forty2/haiku-senseme, openHAB bigassfan binding
- [x] Static reading of the current vendor Android app (3.3.4) for the legacy
  handler's messages, escaping, discovery and firmware path
- [x] Vendor manuals held in the research store (current-generation Haiku,
  Haiku L, i6 and SenseME board guides) for the remote reboot sequence and
  hardware context
- [ ] Wireshark on a legacy fan's port 31415, setup access point and join:
  **still needed**

## References

- [bdraco/aiosenseme](https://github.com/bdraco/aiosenseme), and its [GETALL dumps per model](https://github.com/bdraco/aiosenseme/tree/master/data)
- [bpennypacker/SenseME-Indigo-Plugin](https://github.com/bpennypacker/SenseME-Indigo-Plugin)
- [Bruce Pennypacker: Indigo Plugin for SenseME Fans](http://bruce.pennypacker.org/tag/senseme-plugin/)
- [TomFaulkner/SenseMe](https://github.com/TomFaulkner/SenseMe)
- [sean9keenan/BigAssFansAPI](https://github.com/sean9keenan/BigAssFansAPI)
- [forty2/haiku-senseme](https://github.com/forty2/haiku-senseme)
- [openHAB Big Ass Fan binding](https://www.openhab.org/addons/bindings/bigassfan/)
- [Big Ass Fans Haiku L installation guide (PDF, current edition)](https://bigassfans.widen.net/view/pdf/zq0muwn7zn/haiku-l-install-guide.pdf)
- [jfroy/aiobafi6](https://github.com/jfroy/aiobafi6): the 3.x protocol, out of scope here
- [Missing Devices](../research/missing-devices.md)
- [Initial Device Setup](../protocols/device-setup.md)
- [Pairing, Bonding and Unpairing](../protocols/pairing.md)

## Contributors

- Claude Code agent: spec written from published clients and a static reading of the vendor app (desk research; no hardware)
