# Pentair ScreenLogic / ScreenLogic2 — Local Protocol Research Notes

## What it is
Pentair pool/spa automation (IntelliTouch, EasyTouch, SunTouch, IntelliCenter)
is bridged to the LAN by the **ScreenLogic2 Protocol Adapter** (P/N 522442),
a small "brick" wired to the outdoor panel's RS-485 COM port. The brick speaks
Ethernet or Wi-Fi to the home network. Pentair is an active manufacturer
(Aug 2026); the ScreenLogic mobile/desktop apps and the Pentair Home cloud
service still work, but neither is needed for local control.

## Local protocol — fully reverse engineered, community libraries in production
Two independent, actively used client libraries implement the local protocol:

- [parnic/node-screenlogic](https://github.com/parnic/node-screenlogic) (Node.js)
- [dieselrabbit/screenlogicpy](https://github.com/dieselrabbit/screenlogicpy) (Python) —
  backs the Home Assistant core integration `pentair_screenlogic`
  (`iot_class: local_polling`).

### Discovery
Client sends an 8-byte UDP broadcast to `255.255.255.255:1444`; every
ScreenLogic adapter on the segment replies with its IP, TCP port, type and
gateway name. Verified in a UniFi VLAN wireshark walkthrough
([UI.com community, 2022](https://community.ui.com/questions/Enabling-UDP-Broadcast-between-VLANs/842a44e1-fc75-4c73-a5d8-862a7a9058e8)):
source port ephemeral, destination port 1444, 8-byte payload.

### Control channel
TCP connection to the adapter (default port **80**). Binary framed messages
with little-endian header (sender id + 16-bit message code + 32-bit length).
Login is a challenge/response against the admin password set on the panel
(SHA-256 based, implemented in both libraries). Message codes for pool/spa
state, circuit on/off, setpoints, schedules, chlorinator, IntelliChem,
pump status are enumerated in the libraries
(`messages/answer codes` in node-screenlogic, `requests/` in screenlogicpy).
Push updates: after login the adapter streams async status messages on the
same socket.

## Cloud dependency
None for local control. Password set on the panel/brick locally; discovery and
control never leave the LAN. Cloud (Pentair Home account) is only used by the
vendor app for remote access.

## APK
Not fetched — protocol fully documented by two community implementations; the
vendor desktop app is a .NET program, not needed.

## Caveats
- One client connection model: heavy parallel clients can wedge the brick;
  libraries serialize and reconnect.
- Firmware updates to the brick historically came via the vendor app; local
  firmware flashing over UDP is possible but niche
  ([Trouble Free Pool, 2020](https://www.troublefreepool.com/threads/pentair-screenlogic-protocol-adapter-issues.213164/)).

## Rating
**Confirmed** — HA core integration + two libraries in wide production use.

## Sources (accessed 2026-08-07)
- github.com/parnic/node-screenlogic
- github.com/dieselrabbit/screenlogicpy; pypi.org/project/screenlogicpy
- home-assistant.io/integrations/screenlogic
- community.ui.com UDP 1444 wireshark walkthrough (2022)
