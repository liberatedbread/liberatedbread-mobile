# Insteon Hub (2245-222 Hub v2 / 2242-222 Hub v1)

> **Status**: Spec Available (unverified)
> **Protocol**: LAN (Hub v2: HTTP 25105 with Basic auth; Hub v1: raw modem bytes on TCP 9761)
> **Manufacturer**: Insteon Technologies (formerly SmartLabs)
> **Manufacturer Status**: Active. SmartLabs turned the servers off in April 2022; a buyer led by Insteon users revived the company in June 2022, and it still sells the Hub 2 in 2026.

## Overview

The Insteon Hub is the Ethernet gateway into an Insteon network: switches,
dimmers, plug-in modules, sensors and keypads that talk over the house wiring
and 915 MHz RF. Each hub contains an Insteon Modem (PLM), and both hub
generations expose that modem's published command set on the LAN. A client
on the LAN can drive every linked device with no cloud, no account and no
app. That local path kept working through the April 2022 shutdown. The
revived company's app now needs a paid subscription, but the LAN API does
not.

Hub v2 wraps the modem in HTTP. You send a frame as hex in a URL and poll a
200-character hex ring buffer for the replies. Hub v1 is the same modem as a
plain binary TCP stream on port 9761.

## Initial Setup

| Property | Value |
|----------|-------|
| Setup required | Yes. Wire it to Ethernet and read the label credentials (v2) |
| Method | `wired`; devices are then linked with Set buttons (`button_pairing`) |
| Discovery | None documented. Find the hub in the router's DHCP list and reserve its address |
| Credentials | Hub v2: username and password printed on the bottom label, sent as HTTP Basic auth in clear text. Hub v1: none |
| Passphrase protection | not_applicable (wired) |
| Confidence | medium |

**Linking a device**: send *start all-linking* (`02 64 01 00`), or press the
hub's Set button. Then hold the device's Set button for about 3 seconds
until it beeps. An `02 53` frame in the buffer gives the new device's
address.

**Factory reset**: unplug the hub, hold Set while plugging it back in, and
release when the long beep ends. Hub v2 double-beeps, then beeps again about
30 s later; unplug and replug it once more. Hub v1 double-beeps and its light
turns blue. The reset erases links, scenes and schedules.

## Protocol Summary

**Hub v2 HTTP wrapper** (port 25105, Basic auth):

| Request | Meaning |
|---------|---------|
| `GET /3?<hex frame>=I=3` | Send one modem frame, e.g. `/3?02621A2B3C0F11FF=I=3`. A successful send zeroes the buffer |
| `GET /buffstatus.xml` | Read the buffer. Its `BS` element holds 200 hex characters of ring, then 2 hex digits for the write position |
| `GET /1?XB=M=1` | Clear the buffer |
| `GET /index.htm` | Hub type, firmware and modem address (HTML) |

Poll the buffer about twice a second. To read it, keep a cursor, take
`ring[cursor:position]`, and handle the wrap at 200. Every reply to a
command arrives in the buffer, not in the HTTP response.

**Modem frames** (the same on both hubs):

| Frame | Layout |
|-------|--------|
| Send standard | `02 62 <addr:3> 0F <cmd1> <cmd2>` → echo + `06` (ACK) / `15` (NAK) |
| Send extended | `02 62 <addr:3> 1F <cmd1> <cmd2> <D1..D13> <D14>`, D14 = `(-(cmd1+cmd2+D1+…+D13)) & 0xFF` |
| Receive standard | `02 50 <from:3> <to:3> <flags> <cmd1> <cmd2>` |
| Receive extended | `02 51 …` plus 14 data bytes |
| Get IM info | `02 60` → `02 60 <addr:3> <cat> <subcat> <fw> 06` |
| All-Link DB | `02 69` (first) / `02 6A` (next) → `06` then an `02 57` record, or `15` at the end |

| cmd1 | Meaning |
|------|---------|
| `11` | On at level cmd2 (00–FF) |
| `12` / `14` | Fast on / fast off |
| `13` | Off |
| `19` | Status request. The device's ACK carries the level in cmd2 |
| `2E` | Extended get/set (settings) |

Flags byte: bits 7–5 are the message type (000 direct, 001 ACK, 101 NAK, 110
all-link broadcast), bit 4 means extended, bits 3–2 are hops left and bits
1–0 are max hops.

The modem's `06` only means the hub accepted the frame. Whether the device
heard it shows up in its own `02 50` ACK. Firmware 1012 on the 2245-222 has
published Talos advisories (2018), and the local API is plain HTTP, so keep
the hub off the internet.

See `device-specs/devices/insteon-hub.yaml` for the full spec. The checksum
rule and the frame layouts are tested in `scripts/test_insteon_hub_spec.py`.

## References

- [KRKeegan: technical inspection of the Insteon Hub2 2245-222](https://krkeegan.com/technical-inspection-of-insteon-hub2-2245-222/)
- [pyinsteon](https://github.com/pyinsteon/pyinsteon)
- [Home Assistant Insteon integration](https://www.home-assistant.io/integrations/insteon/)
- [openHAB Insteon binding](https://www.openhab.org/addons/bindings/insteon/)
- [insteon-mqtt](https://github.com/TD22057/insteon-mqtt)
- [INSTEON Hub Developer's Guide (ManualsLib)](https://www.manualslib.com/manual/2802673/Insteon-Hub.html)
- [Factory Resetting Insteon Hub (Insteon support)](https://support.insteon.com/support-knowledgebase/2016/2/24/factory-resetting-insteon-hub)
- [Talos TALOS-2017-0483](https://talosintelligence.com/vulnerability_reports/TALOS-2017-0483)
