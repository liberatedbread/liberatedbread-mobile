# Elgato Key Light classic HTTP family

> **Status**: Spec Available (not replayed by this project)
> **Protocol**: Wi-Fi — local HTTP/JSON on TCP 9123
> **Manufacturer**: Elgato / Corsair
> **Manufacturer Status**: Active

## Overview

Classic Elgato lights can be controlled directly on the LAN without an account
or cloud connection. The local API covers power, brightness, white-point
temperature on CCT models, hue/saturation on Light Strips, identification, and
battery telemetry on the Key Light Mini.

The **Key Light Air MK.2 is different** and is not covered by this guide. It
uses mutual-TLS WebSocket JSON-RPC on the same port. Do not send it plain HTTP
commands. The machine-readable discovery rule requires `mf=Elgato` and no
`tls` TXT key, which keeps the two transports apart even after a rename.

See `device-specs/devices/elgato-key-light.yaml` for discovery matchers,
command bodies, entity bindings, firmware-update details and remaining
unknowns.

## Covered models and capabilities

| Model / board id | Local surface |
| --- | --- |
| Key Light (53), Key Light Air (200), Key Light MK.2 (205), Key Light Neo (210), Key Light Mini (202), Ring Light (201) | CCT: on/off, brightness, mired white point |
| Light Strip (70), Light Strip Pro (206) | HSV: on/off, brightness, hue/saturation; read-only scene state |
| Key Light Air MK.2 (214) | **Excluded** — mutual-TLS WebSocket, not this API |

Board ids are naming hints, not the capability test. A client should inspect
`GET /elgato/lights`: `temperature` means CCT, `hue` means direct HSV, and
`scene` means a running scene. Probe `GET /elgato/battery-info` once for the
Mini's battery surface; a 404 means no battery.

## Initial Setup

| Property | Value |
| --- | --- |
| Setup required | Yes, once to join Wi-Fi |
| Method | Vendor Control Center onboarding |
| Steady-state pairing or account | None |
| Confidence | Medium — public sources and community live tests, not run by this project |

Power the light, follow its Control Center onboarding flow, and wait for an
`_elg._tcp.local.` advertisement on TCP 9123. Ordinary control then works
without the vendor app or cloud. This spec does not claim an independent
implementation of the classic provisioning payload.

## Factory Reset and Rebinding

The documented route to a new network is a Wi-Fi reset, after which the light
can be onboarded again. Two procedures have vendor citations:

- **Key Light Mini**: power on, hold the recessed Reset button with a small
  tool for 10 seconds, and release when the light flashes three times. Let it
  restart. [Vendor instructions](https://help.elgato.com/hc/en-us/articles/4424711679885-Elgato-Key-Light-Mini-Reset-Wi-Fi-Configurations).
- **Key Light Neo**: power on, hold Reset for at least 10 seconds until the
  light flashes three times, then release and wait for the automatic restart.
  [Vendor instructions](https://help.elgato.com/hc/en-us/articles/25947652898701-Elgato-Key-Light-Neo-Reset-Wi-Fi-Configuration).

Reset procedures for the other models are not asserted here. Do not assume the
same button location or timing across the family.

## Protocol Summary

### Discovery

Browse `_elg._tcp.local.` on TCP 9123. Required TXT conditions for this spec:
`mf=Elgato` and **no `tls` key**. TXT `id` is not always the MAC address;
fetch `/elgato/accessory-info` and use `serialNumber` as the durable identity.
An empty `displayName` should fall back to the mDNS instance name.

The HTTP server is effectively single-threaded. Use one keep-alive connection
per light and serialize requests.

### Endpoints

| Method | Path | Purpose |
| --- | --- | --- |
| GET | `/elgato/accessory-info` | Identity, model, firmware and Wi-Fi metadata |
| GET / PUT | `/elgato/lights` | Read state / apply a partial state update |
| GET | `/elgato/battery-info` | Key Light Mini battery and charging data |
| POST | `/elgato/identify` | Blink the selected light |
| PUT | `/elgato/firmware-update/prepare` | Advanced: start a signed firmware upload |
| PUT | `/elgato/firmware-update/data?offset=n` | Advanced: write a 4096-byte image chunk |
| POST | `/elgato/firmware-update/execute` | Advanced: validate, select and restart |

The classic API is unauthenticated. Anything that can reach the light may be
able to control it, rewrite configuration or upload firmware. Keep it on a
trusted LAN and do not expose TCP 9123 to the internet.

### State and control examples

CCT reply:

```json
{"numberOfLights": 1, "lights": [{"on": 1, "brightness": 43, "temperature": 221}]}
```

Direct HSV reply:

```json
{"numberOfLights": 1, "lights": [{"on": 1, "hue": 200.0, "saturation": 100.0, "brightness": 50}]}
```

A successful `PUT /elgato/lights` returns the full new state. Partial bodies
are intentional; do not replay fields the user did not change.

| Action | JSON body |
| --- | --- |
| On | `{"lights":[{"on":1}]}` |
| Off | `{"lights":[{"on":0}]}` |
| Brightness 50% | `{"lights":[{"brightness":50}]}` |
| White point 221 mired | `{"lights":[{"temperature":221}]}` |
| Hue 200°, saturation 100% | `{"lights":[{"hue":200,"saturation":100}]}` |

Use brightness 3–100 and temperature 143–344 mired. `on` is an integer 0/1,
not a JSON boolean. Brightness zero does not switch the light off; it leaves
`on=1` with no visible output. Clamp client-side because range handling is not
consistent across models.

A running Light Strip scene needs special care: a bare power, brightness or
colour write discards it, and there is no scene-list endpoint. The scene entity
is therefore read-only in this spec. Cache the complete observed scene before
implementing any scene-preserving write or restore flow.

## Firmware Update

Classic models accept a complete, board-specific vendor image through the
three advanced update endpoints. Images carry a 128-byte header and an Ed25519
signature. The community firmware analysis describes an inactive-slot update
whose previous image remains available until successful activation. This
project has not exercised an upload or power-loss recovery; do not treat that
recovery claim as verified for every model or interruption point.

## References

- [Live-characterised local HTTP + mDNS protocol](https://github.com/passtas/matterbridge-elgato/blob/main/docs/elgato-protocol.md)
- [frenck/python-elgato](https://github.com/frenck/python-elgato)
- [Key Light Mini firmware reverse engineering](https://github.com/schlarpc/elgato-key-light-mini-firmware-re)
- [Original Key Light quick-start guide (PDF)](https://help.elgato.com/hc/en-us/articles/360055262831-Key-Light-Quick-Start-Guide-PDF)
