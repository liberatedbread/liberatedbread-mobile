# Chamberlain/LiftMaster MyQ Wi-Fi Hub — DUD: cloud-locked, rejected

## Verdict
**Rejected — no local control.** The MyQ Wi-Fi hub / built-in MyQ opener radio
is outbound-cloud-only: it makes MQTT-over-TLS connections to Chamberlain's
cloud (port 8883, some setups 2165) and exposes NOTHING on the LAN — no local
HTTP/REST, no mDNS, no open port. Chamberlain blocked all third-party API
access in Nov 2023 (Home Assistant dropped its MyQ integration in 2023.12,
killing `pymyq`), has refused to reopen it since, and in Nov/Dec 2025 escalated
with Security+ 3.0 (see below). MyQ-the-cloud-product is not locally
controllable.

## Live observation (2026-08-14)
The MyQ hub on the LAN (MAC CC:6A:10:2A:11:F4, The Chamberlain Group,
10.69.198.170) had ports 80/443/8080 all CLOSED to probes — consistent with an
outbound-cloud-only device that accepts nothing locally.

## BUT the opener itself IS locally controllable — via a wired bridge
The garage OPENER (as opposed to the MyQ cloud radio) speaks its own Security+
1.0 / 2.0 protocol on the wall-control terminals, and a wired bridge board
(ratgdo, GPL-2.0; or Konnected blaQ) impersonates a wall panel to drive it
fully locally over MQTT/ESPHome — no cloud, no MyQ. That path is documented as
a real spec: see `device-specs/devices/chamberlain-garage-opener-secplus.yaml`
(`local_access: bridge_hardware`). This dud note is specifically about the
MyQ **cloud radio/hub**, which the bridge ignores entirely.

## Generation gate
- Security+ 1.0 (purple/orange/red learn button) and 2.0 (yellow) — locally
  bridgeable (ratgdo/Konnected).
- Security+ 3.0 (white learn button, Nov 2025+) — accessory comms moved to
  encrypted BLE, the wall-button wires carry power only, uncracked. No local
  path today.

## Sources
- Home Assistant MyQ removal blog (2023-11-06); Slashdot API-shutoff (2023-11-08)
- Konnected blaQ CEDIA 2024 PR ("local integration myQ says you can't have")
- SmartThings community "Chamberlain blocks again with Security+ 3.0" (Dec 2025)
- Netgate/Sophos forum threads: MyQ hub uses outbound TLS/MQTT 8883 only
