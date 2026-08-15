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

## References

- <https://github.com/argilo/secplus>
- <https://github.com/ratgdo/esphome-ratgdo>
- <https://konnected.io/products/smart-garage-door-opener-blaq-myq-alternative>
