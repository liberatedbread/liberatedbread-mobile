# Chamberlain/LiftMaster Garage Opener — Security+ (via bridge)

> **Status**: Complete (documented from prior art; requires a hardware bridge)
> **Protocol**: Security+ 1.0 / 2.0 wired UART
> **Manufacturer**: The Chamberlain Group (Chamberlain / LiftMaster / Craftsman)
> **Manufacturer Status**: Active — local control only via an aftermarket bridge

## Overview

Chamberlain's **MyQ cloud** product has no local control (documented in the
`research-notes/myq-cloud-hub` dud note: the hub is outbound-cloud-only,
verified 2026-08-14 with all local ports closed). The
garage **opener itself** is locally controllable by wiring an aftermarket
bridge board (**ratgdo**, GPL-2.0, or **Konnected blaQ**) to its wall-control
terminals; the board impersonates a wall panel and speaks the opener's native
Security+ protocol, exposing local control + door status over ESPHome/MQTT with
no cloud.

## Generation gate (check the learn-button color first)

| Generation | Learn button | Wired UART | Local control |
|-----------|--------------|-----------|---------------|
| Security+ 1.0 | purple / orange / red | 1200 baud, 8E1 | Yes (experimental, limited status) |
| Security+ 2.0 | yellow | 9600 baud, 8N1, 19-byte packets | **Yes** (mature, full status) |
| Security+ 3.0 | white (Nov 2025+) | — (encrypted BLE, no data on wires) | **No** — uncracked |

Security+ 2.0 carries a 40-bit fixed + 28-bit rolling code, obfuscated
(bit-reverse → base-3 → 2-bit remap + permutation) — the "obfuscated serial
signal" that defeats a plain relay. The rolling-code codec is fully implemented
in `argilo/secplus` and the ratgdo firmware; this spec points at those rather
than restating the bit math.

## Install / pair

Wire the bridge to Ground / Control / Obstruction (LiftMaster Sec+ 2.0:
red/white/common), in parallel with the wall button, then press the opener's
learn button to pair the emulated panel (it seeds the rolling-code counter).

## Sibling device verified live: MyQ Smart Garage Control MYQ-G0401

A 2026-08-19 LAN sweep found a second Chamberlain-family device next to the
closed-port hub from the `research-notes/myq-cloud-hub` dud: a **MyQ Smart
Garage Control hub, model MYQ-G0401** (Gen 3, BLE-linked to the opener,
firmware 1.10) at `192.168.1.104`. Unlike the earlier hub, this unit answers
on port 80:

- `GET /jabout` — **unauthenticated** JSON identity: product string
  `SMART GARAGE CONTROL,GEN3,BLE,CH`, brand, MyQ serial, AP name, firmware,
  MAC, joined SSID, RSSI, uptime.
- `GET /` — Wi-Fi setup web UI (`/myq.js`, `/brand.js`, provisioning URL
  setup.myqdevice.com). `HEAD /` returns 404 (HEAD not implemented), which
  explains an earlier "404 on /" observation.
- All other `/j*` paths 404. The LAN surface is **read-only identification +
  setup** — there is no local door control; control stays MyQ cloud + the
  hub's BLE link to the opener. The wired ratgdo/Konnected bridge remains the
  only local control path.

Captured responses (`myq_jabout.json`, `myq_index.html`, with checksums) are
archived in the maintainers' private research workspace, not committed here.

## References

- <https://github.com/argilo/secplus>
- <https://github.com/ratgdo/esphome-ratgdo>
- <https://konnected.io/products/smart-garage-door-opener-blaq-myq-alternative>
