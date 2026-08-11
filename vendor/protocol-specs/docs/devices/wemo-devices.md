# Belkin Wemo Smart Devices

> **Status**: In Progress
> **Protocol**: WiFi (SSDP/UPnP + SOAP 1.1 over HTTP)
> **Manufacturer**: Belkin
> **Manufacturer Status**: Shutdown (cloud-dependent features affected; local UPnP control survives for supported devices)

!!! tip "Setting a device up, or moving it to a new network?"
    This page covers discovery and control of a device that is already on your
    WiFi. For factory reset, first-time provisioning over the device's own
    setup AP, and rebinding a device to a different network without the (now
    defunct) Wemo app, see
    **[Wemo Setup, Factory Reset and Rebinding](wemo-setup.md)**.

## Discovery First

Wemo local control starts with SSDP. Do not require users to enter static IP
addresses.

1. Send `M-SEARCH` to `239.255.255.250:1900`.
2. Use `ST: urn:Belkin:service:basicevent:1` first, then device-specific URNs or `ssdp:all`.
3. Read the `LOCATION` response header.
4. Fetch `http://<ip>:<port>/setup.xml`.
5. Parse `deviceType`, `UDN`, `serialNumber`, `macAddress`, `friendlyName`, and `serviceList`.
6. Match the variant by `deviceType` first, then UDN prefix/model metadata.
7. Send SOAP requests to the `controlURL` from `serviceList`.

Stable device ordering should use `UDN`, then `serialNumber`, then
`macAddress`. `friendlyName` is display text and can be changed by the user.
Ports are connection details only; Wemo devices can move across
`49152-49159`, with pywemo probing:

```text
49153, 49152, 49154, 49151, 49155, 49156, 49157, 49158, 49159
```

The full SSDP wire format — the M-SEARCH datagram, response headers,
deduplication, the rule that separates Wemo from every other UPnP responder,
and the description parse rules — is in
`device-specs/devices/wemo-devices.yaml` under `device.discovery`.
[pywemo](https://github.com/pywemo/pywemo) implements it if you want a client
rather than a spec.

## Device Catalog

| Device | deviceType URN | pywemo | Home Assistant | APK widget |
|---|---|---:|---:|---:|
| Mini Plug F7C063 | `urn:Belkin:device:controllee:1` / `socket:1` | Yes | Yes | Yes |
| WiFi Plug WSP080 | `urn:Belkin:device:socket:1` | Yes | Yes | Yes |
| Insight F7C029 | `urn:Belkin:device:insight:1` | Yes | Yes | Yes |
| Light Switch Gen1/2/3-way | `urn:Belkin:device:Lightswitch:1` | Yes | Yes | Yes |
| Dimmer v1 | `urn:Belkin:device:dimmer:1` | Yes | Yes | Yes |
| Dimmer v2 | `urn:Belkin:device:dimmer:1` | Yes | Yes | Yes |
| Maker | `urn:Belkin:device:Maker:1` | Yes | Yes | Yes |
| Outdoor Plug | `urn:Belkin:device:outdoor:1` | Yes | Yes | Yes |
| Bridge / Link | `urn:Belkin:device:bridge:1` | Yes | Yes | Yes |
| Motion | `urn:Belkin:device:motion:1` / `sensor:1` | Yes | Yes | Yes |
| Coffee Maker | `urn:Belkin:device:coffeemaker:1` | Yes | Partial switch class | Yes |
| Crock-Pot | `urn:Belkin:device:crockpot:1` | Yes | Community / legacy | Yes |
| Air Purifier | `urn:Belkin:device:purifier:1` / `airpurifier:1` | Public RE / openHAB | Community / legacy | Yes |
| Heater | `urn:Belkin:device:heater:1` | Public RE / openHAB | Community / legacy | Yes |
| Humidifier | `urn:Belkin:device:humidifier:1` / `humidity:1` | Yes | Yes, fan platform | Yes |
| Humidifier B | `urn:Belkin:device:humidifierb:1` | APK/public RE | Community / legacy | Yes |

Notes:

- APK mocks sometimes reuse generic `socket:1` or `Humidifier:1` fixture data.
  The spec records those ambiguities and prefers pywemo/public library behavior
  for live hardware.
- Dimmer v1 and v2 share `urn:Belkin:device:dimmer:1`; use UDN prefix and model
  metadata to distinguish them.
- Motion appears as `motion:1` in the APK and is often described as `sensor:1`
  in older catalogs.

## SOAP Services

All Wemo SOAP requests are HTTP POSTs with:

```text
Content-Type: text/xml; charset="utf-8"
SOAPACTION: "<serviceType>#<Action>"
```

Common services:

| Service | Service URN | Control URL | Typical actions |
|---|---|---|---|
| basicevent | `urn:Belkin:service:basicevent:1` | `/upnp/control/basicevent1` | `GetBinaryState`, `SetBinaryState` |
| insight | `urn:Belkin:service:insight:1` | `/upnp/control/insight1` | `GetInsightParams`, `GetPowerThreshold`, `SetPowerThreshold` |
| deviceevent | `urn:Belkin:service:deviceevent:1` | `/upnp/control/deviceevent1` | `GetAttributes`, `SetAttributes`, `GetAttributeList` |
| bridge | `urn:Belkin:service:bridge:1` | `/upnp/control/bridge1` | `GetEndDevicesWithStatus`, `GetDeviceStatus`, `SetDeviceStatus` |
| metainfo | `urn:Belkin:service:metainfo:1` | `/upnp/control/metainfo1` | `GetMetaInfo`, `GetExtMetaInfo` |
| WiFiSetup | `urn:Belkin:service:WiFiSetup:1` | `/upnp/control/WiFiSetup1` | `GetApList`, `ConnectHomeNetwork`, `GetNetworkStatus`, `CloseSetup` |

The WiFiSetup control URL spelling varies across firmware generations
(`/upnp/control/WiFiSetup1` and `/upnp/control/wifi1` have both been reported),
so resolve it from the `serviceList` in `setup.xml` rather than hardcoding it.
That service is only exposed while the device is in setup mode — see
[Wemo Setup](wemo-setup.md).

## Controlling a plug, and controlling the Crock-Pot

The spec carries a machine-readable control surface for the two device
families we have hardware for. `entities` says which controls to draw and
where each reads its state, `commands` says what to send for each control's
roles with the arguments already chosen, and `http_endpoints` documents the
actions both of those name. A client substitutes a command's parameters into
its arguments and renders the result through `soap_common.request_format` —
there is no Wemo-specific code in that sentence, which is the point.

A plug is the easy half:

| | |
|---|---|
| State | `basicevent#GetBinaryState` → `BinaryState` |
| On / off | `basicevent#SetBinaryState` with `BinaryState` 1 or 0 |
| The catch | `8` means on with the load idling. Treat non-zero as on, and split the value on `\|` first — some firmware answers with a long pipe-delimited form whose first field is the state |

The Crock-Pot looks like a plug and is not one:

| | |
|---|---|
| State | `basicevent#GetCrockpotState` → `mode`, `time`, `cookedTime` |
| Modes | `0` off, `50` warm, `51` low, `52` high |
| Setting anything | `basicevent#SetCrockpotState` with **both** `mode` and `time` |
| The catch | `GetBinaryState` answers `0` whatever the cooker is doing |

Two things about that table are worth saying out loud, because both are
invisible until a user complains:

- **`BinaryState` is not the Crock-Pot's state.** The universal switch surface
  is present, answers, and lies — bind to it and you ship a cooker that reads
  as permanently off with a toggle that springs back. pywemo overrides its own
  base implementation here for exactly this reason. On/off is `mode != 0`.
- **There is no set-the-mode-alone action.** `SetCrockpotState` carries mode
  and cook time together, so switching to Warm without sending the current
  `time` back also clears the timer. Read `GetCrockpotState` immediately
  before the write and hand back what you did not mean to change; the spec's
  commands say which value that is in each case, as
  `source: state:GetCrockpotState.time`.

Both devices also push changes over UPnP eventing rather than making you poll
— `SUBSCRIBE` to the `eventSubURL` in `setup.xml`, renew on the `TIMEOUT` the
device grants rather than the one you asked for, and read `BinaryState`, or
`mode`/`time`/`cookedTime`, out of the `NOTIFY` property set. That is the
difference between a control that notices somebody pressing the button on the
device and one that only knows what it last wrote. See `soap_common.eventing`.

## Scheduling: can it turn itself on later?

Yes, and the mechanism is stranger than the rest of the protocol. Schedules
live **on the device**, in a SQLite database it hands out and takes back over
SOAP: `rules#FetchRules` answers with a version and a URL, you `GET` the URL
for a ZIP containing the database, edit rows, zip it, base64 it, and post it
back with `rules#StoreRules`. The device then runs the schedule off its own
clock with nothing else on the network — which is the property worth having,
because a phone app that schedules a future action has to still be running
when the time comes, and on iOS it will not be.

Full detail, table by table, is in the spec's `scheduling` block. The four
things worth knowing before you start:

- **Fetch, modify, store.** `StoreRules` replaces the whole database. A client
  that builds a fresh one deletes every rule the user made in the Wemo app —
  and that app is gone, so they cannot make them again.
- **The `ruleDbBody` escaping is not a typo.** The argument's literal text
  begins `&lt;![CDATA[` and ends `]]&gt;` — an XML-escaped CDATA wrapper
  around the base64. Sending a real CDATA section is the obvious correction
  that does not work.
- **A rule's action is a number**: `1.0` on, `0.0` off, `2.0` toggle. Nothing
  in the table carries a cooking mode, so *"start the Crock-Pot on Low at
  five"* does not appear to be expressible — and on the Crock-Pot the binary
  state a rule would set is the surface that reads `0` whatever the device is
  doing. Treat a scheduled cooker as unproven until somebody tries it.
- **The Crock-Pot's cook time is a different thing.** `SetCrockpotState`'s
  `time` is a countdown the appliance runs itself, in minutes, starting when
  you send it. That is a duration, not a start time — but it is the timer that
  certainly works today.

What is *not* established: the `DayID` encoding (one captured schedule uses
`1`, pywemo's long-press rule uses `-1`), the full `RULES.Type` vocabulary
beyond `Time Interval` and `Long Press`, and whether the appliance classes
honour rules at all. The spec lists these as open questions rather than
guessing, because a schedule written from a guessed column fires on the wrong
day.

## References

- [pywemo](https://github.com/pywemo/pywemo)
- [Home Assistant Wemo integration](https://www.home-assistant.io/integrations/wemo/)
- [ouimeaux](https://github.com/iancmcc/ouimeaux)
- Local APK analysis: `data/wemo/summary.md`
- Machine-readable spec: `device-specs/devices/wemo-devices.yaml`
- [Wemo Setup, Factory Reset and Rebinding](wemo-setup.md)
