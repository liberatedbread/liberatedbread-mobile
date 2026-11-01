# LIVISI SmartHome Controller (SHC 1 / SHC 2)

> **Status**: Spec Available (from public sources; not replayed against hardware)
> **Protocol**: LAN: HTTP on port 8080 (OAuth2 bearer token) plus a WebSocket event stream
> **Manufacturer**: LIVISI GmbH (formerly innogy SmartHome / RWE SmartHome)
> **Manufacturer Status**: Shutdown. Cloud services retired 2024-03-01

## Overview

The LIVISI SmartHome Controller (SHC) is the hub of the German smart-home
system first sold as RWE SmartHome and then as innogy SmartHome. It drives
LIVISI's own 868 MHz radio devices: plugs, in-wall switches, dimmers and
shutter actuators, radiator and wall thermostats, contacts, motion and smoke
detectors, remotes and sirens.

[heise reported on 2022-03-01](https://www.heise.de/news/Abschaltung-im-Maerz-2024-Smart-Home-Plattform-Livsi-wird-eingestellt-6529050.html)
that LIVISI would end its services on **2024-03-01**, and
[the servers went off that day](https://www.digitalzimmer.de/artikel/news/livisi-stellt-betrieb-seiner-server-endgueltig-ein/).
Before then LIVISI shipped **Local SmartHome**, available for every controller
from 2022-09-26. It is a local web app plus a local copy of the cloud API that
runs on the controller. It is now the only way in.

Unlike the [devolo](devolo-home-control.md) estate, the child devices are
proprietary radio, not Z-Wave or Zigbee, so they cannot move to another
controller. The rescue is keeping the SHC itself usable, and its local API
already makes that possible.

## What died, what still works

| Function | State after 2024-03-01 |
|---|---|
| LIVISI account, app login, cloud backup | Gone; LIVISI said the data was deleted |
| Remote access, push notifications, Alexa / Google / IFTTT | Gone |
| Local web app on the controller (`http://<controller>/`) | **Works**. Device teaching, rules and settings |
| Rules and schedules on the controller | **Run locally** |
| Local SmartHome API (port 8080 + WebSocket) | **Works**. openHAB, Home Assistant and ioBroker use it |

## Generations

| | SHC 1 ("Classic") | SHC 2 |
|---|---|---|
| Device type in `GET /device` | `SHC` | `SHCA` |
| `controllerType` in `GET /status` | `Classic` | `Avatar` |
| Local SmartHome minimum firmware | 1.914-3.1.1043.0 (via 1.913-3.0.1008.0) | 8.17-1.2.39.443 (via 8.17-1.1.36.426) |
| Default local-web-app password | Digits after "SN" on the underside label | Characters after "PIN:" on the label |
| Host name (vendor how-to) | `SMARTHOME01` | `SHCONTROLLER01` |
| Event WebSocket | `ws://<host>:8080/events?token=…` | `ws://<host>:9090/events?token=…` |
| `GET /status` shape | flat | gateway facts under `gateway` |
| `GET /device/{id}/state` | wrapped in `{"state": …}` | bare map |
| Room setpoint property | `pointTemperature` | `setpointTemperature` |
| Button confirmation at first setup | From software 3.1.1056.0 | Not stated |

## Initial Setup

| Property | Value |
|----------|-------|
| Setup required | Yes |
| Method | `wired`: Ethernet, then the controller's local web app |
| Passphrase protection | not_applicable (Ethernet) |
| Confidence | medium (vendor community posts + two open-source clients) |

1. Wire the controller to the router and reserve its DHCP address.
2. Open `http://<address>/`, log in with the label default (see the table),
   set a new **local password** and accept the terms. Password rules: at
   least 10 characters, with upper case, lower case, a digit and a special
   character, and no `?`. An SHC 1 on software 3.1.1056.0 or later asks for
   a button press on the controller.
3. A client logs in as the fixed user **`admin`**:

```http
POST /auth/token HTTP/1.1
Host: 192.168.1.50:8080
Authorization: Basic Y2xpZW50SWQ6Y2xpZW50UGFzcw==
Content-Type: application/json

{"username":"admin","password":"<local password>","grant_type":"password"}
```

The Basic header is the fixed OAuth client `clientId:clientPass`. It appears
in both openHAB's binding and the planbnet library and is not a secret. The
reply's `access_token` (a JWT) goes into `Authorization: Bearer …` on every
later request. It expires: on `errorcode` 2007, log in again and retry once.

**Everything is plain HTTP.** The password and the token cross the LAN in
clear. Keep the controller on a trusted network, and use a VPN rather than a
port forward for remote access.

**Factory reset**: not established from any source read. Treat a lost local
password as an open question rather than resetting blind (see Remaining
unknowns).

## Control

Every write is `POST /action` with an action object. The target is a
**capability** id, found by listing `GET /capability` and joining on
`device: "/device/<id>"`:

```json
{"type":"SetState","namespace":"core.RWE",
 "target":"/capability/0123456789abcdef0123456789abcdef",
 "params":{"onState":{"type":"Constant","value":true}}}
```

| Capability type | Property / action | Values |
|---|---|---|
| SwitchActuator | `onState` | true / false |
| DimmerActuator | `dimLevel` | 0–100 % |
| RollerShutterActuator | `shutterLevel`; `StartRamp` (`rampDirection` RampUp/RampDown), `StopRamp`, namespace `CosipDevices.RWE` | 0–100 % |
| ThermostatActuator | `pointTemperature`; `operationMode` | 6–30 °C; `Auto` / `Manu` |
| RoomSetpoint (VRCC) | `setpointTemperature` (SHC 2) / `pointTemperature` (SHC 1) | 6–30 °C |
| BooleanStateActuator | `value` | true / false |
| SirenActuator | `activeChannel` | None / Alarm / Notification / Feedback |

A successful write answers `{"resultCode":"Success"}`. The new state arrives
on the WebSocket as a `StateChanged` event whose `properties` carry the same
names, flat. Reading one capability (`GET /capability/{id}/state`) returns
`{"<property>": {"value": …, "lastChanged": …}}`.

The device and capability lists are JSON **arrays**, so the spec's
`instances` mechanism cannot enumerate them yet. The spec declares the full
command set but binds entities only for controller-level readings.

## Remaining unknowns

- The token lifetime and the reply fields beyond `access_token`.
- Whether SHC 2 puts `controllerType` at the top level of `/status`. The
  planbnet library reads it there, while openHAB's fixture shows only
  `gateway`. Fall back to the `SHC`/`SHCA` device type.
- The namespace for a shutter `SetState`: `CosipDevices.RWE` (planbnet) or
  `core.RWE` (openHAB).
- Factory reset, local-password recovery, and which button confirms setup on
  SHC 1.
- Discovery. No mDNS/SSDP announcement is documented, and clients take the
  host by hand.
- LIVISI GmbH's status. It was registered 2018-12-11 at Amtsgericht Essen
  (HRB 29622). A register aggregator shows that entry deleted with a later
  Munich record, which looks like a seat move but is unconfirmed. No source
  was found for an insolvency or liquidation.

## References

- [openHAB LIVISI SmartHome binding](https://www.openhab.org/addons/bindings/livisismarthome/) and [its source](https://github.com/openhab/openhab-addons/tree/main/bundles/org.openhab.binding.livisismarthome)
- [planbnet/livisi (Python library)](https://github.com/planbnet/livisi) and [planbnet/livisi_unofficial (HA custom integration)](https://github.com/planbnet/livisi_unofficial)
- [Home Assistant LIVISI integration](https://www.home-assistant.io/integrations/livisi/). Still in core as of 2026-10-25
- [Local SmartHome info thread, official post of 2022-09-30 (preserved)](https://lsh.community/forum/thread/4551-infos-zum-lokalen-smarthome/)
- [Local SmartHome how-to / FAQ (preserved)](https://lsh.community/lsh-howto-en/)
- [heise, 2022-03-01: shutdown announced for 2024-03-01](https://www.heise.de/news/Abschaltung-im-Maerz-2024-Smart-Home-Plattform-Livsi-wird-eingestellt-6529050.html)
- [digitalzimmer, 2024-03-01: servers switched off](https://www.digitalzimmer.de/artikel/news/livisi-stellt-betrieb-seiner-server-endgueltig-ein/)

Machine-readable spec: `device-specs/devices/livisi-smarthome.yaml`
