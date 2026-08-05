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

## References

- [pywemo](https://github.com/pywemo/pywemo)
- [Home Assistant Wemo integration](https://www.home-assistant.io/integrations/wemo/)
- [ouimeaux](https://github.com/iancmcc/ouimeaux)
- Local APK analysis: `data/wemo/summary.md`
- Machine-readable spec: `device-specs/devices/wemo-devices.yaml`
- [Wemo Setup, Factory Reset and Rebinding](wemo-setup.md)
