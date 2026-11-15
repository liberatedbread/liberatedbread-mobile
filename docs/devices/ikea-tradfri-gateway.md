# IKEA TRÅDFRI Gateway (E1526)

> **Status**: Spec Available (unverified)
> **Protocol**: LAN (CoAP over DTLS-PSK, UDP 5684)
> **Manufacturer**: IKEA of Sweden
> **Manufacturer Status**: Unsupported — no new products or features since April 2024; support promised until at least June 2026

## Overview

The TRÅDFRI gateway is IKEA's first Zigbee hub. It is a small box with only an
Ethernet connection, and it runs TRÅDFRI bulbs, control outlets, blinds,
STARKVIND air purifiers and remotes. Its local API needs no cloud: CoAP secured
with DTLS in pre-shared-key mode on UDP 5684. A client enrols once using the
security code printed on the label. After that it reads, writes and observes
JSON resources whose keys are numbers.

IKEA says it will release no new products or features for the gateway after
April 2024, because the gateway has run out of memory. It promises the system
will keep working at least until June 2026. Gateway firmware has still come out
since then: 1.21.44 in July 2025, 1.21.51 in February 2026 and 1.21.57 in
May 2026. The successor is the DIRIGERA hub. The new IKEA Home smart app cannot
control this gateway.

## Initial Setup

| Property | Value |
|----------|-------|
| Setup required | Yes — enrol a client with the label security code |
| Method | `wired`, then a security-code enrolment stage |
| Discovery | mDNS `_coap._udp`, instance `gw-<12 hex mac>`, TXT `version`; also HomeKit `_hap._tcp` (model TRADFRI) |
| Passphrase protection | not_applicable — Ethernet only |
| Confidence | medium |

**Enrolment**:

1. Open a DTLS-PSK session to UDP 5684. Use the identity `Client_identity` and
   the 16-character security code as the key.
2. POST `{"9090":"<identity>"}` to `/15011/9063`. Pick an identity that is
   unique to your install.
3. The gateway replies `2.01` with `{"9091":"<psk>","9029":"<firmware>"}`.
4. Reconnect using `<identity>` and `<psk>`. Store both, and do not store the
   security code.

One community write-up reports that a PSK expires after six weeks without use.

**Factory reset**: lift off the lid and push a pin into the pinhole on top for
at least 5 seconds. This erases every paired device, group, scene and issued
PSK. A lost PSK never needs a reset: enrol again instead.

## Protocol Summary

| Path | Method | Meaning |
|------|--------|---------|
| `/15001` | GET | Device ids (array) |
| `/15001/<id>` | GET / PUT / observe | One device |
| `/15004`, `/15004/<id>` | GET / PUT / observe | Groups |
| `/15005/<group>/<scene>` | GET | Scenes (moods) |
| `/15011/15012` | GET / PUT | Gateway info; `9061` opens accessory pairing |
| `/15011/9063` | POST | PSK enrolment |
| `/15011/9030`, `/15011/9031` | POST | Reboot, factory reset |

A device write puts the state inside a one-element array keyed by the kind of
device. A group write uses a flat object.

| Write | Payload |
|-------|---------|
| Light on / off | `{"3311":[{"5850":1}]}` |
| Light brightness (0–254) | `{"3311":[{"5851":127}]}` |
| Colour temperature (250–454 mired) | `{"3311":[{"5711":370}]}` |
| Colour xy (0–65535 each) | `{"3311":[{"5709":30138,"5710":26909}]}` |
| Outlet on | `{"3312":[{"5850":1}]}` |
| Blind position (% closed) | `{"15015":[{"5536":50}]}` |
| Group on / scene | `{"5850":1}` / `{"5850":1,"9039":196608}` |

To subscribe to a resource, GET it with the CoAP Observe option set to 0. Each
notification carries the whole object. Remotes and motion sensors report their
battery level and nothing else useful.

Still unknown: the DTLS cipher suite the gateway picks, the rules for
identities, whether a PSK really expires, and which value stops a blind.

See `device-specs/devices/ikea-tradfri-gateway.yaml` for the full spec.

## References

- [home-assistant-libs/pytradfri](https://github.com/home-assistant-libs/pytradfri)
- [AlCalzone/node-tradfri-client](https://github.com/AlCalzone/node-tradfri-client)
- [glenndehaan/ikea-tradfri-coap-docs](https://github.com/glenndehaan/ikea-tradfri-coap-docs)
- [Home Assistant TRÅDFRI integration](https://www.home-assistant.io/integrations/tradfri/)
- [openHAB TRÅDFRI binding](https://www.openhab.org/addons/bindings/tradfri/)
- [IKEA: end of TRÅDFRI support FAQ](https://www.ikea.com/ie/en/customer-service/knowledge/articles/893bggb1-5065-40fb-gef4-21be418f18dg.html)
- [IKEA Home smart release notes](https://ww8.ikea.com/ikeahomesmart/releasenotes/releasenotes.html)
- [TRÅDFRI gateway manual (E1526, PDF)](https://www.ikea.com/us/en/manuals/tradfri-gateway__AA-1954428-1_pub.pdf)
