# Bosch Performance Line CX (Gen4) eBike System

> **Status**: Research — early
> **Protocol**: CAN bus (500 kbit/s)
> **Manufacturer**: Bosch eBike Systems
> **Manufacturer Status**: Active, tightly closed (dealer-tool gated)

## Overview

Bosch is the most closed mainstream e-bike system, and the one that most often stops a
repair café dead. Diagnostics, error-code detail, component pairing and firmware updates
run through Bosch's dealer tooling and the **eBike Flow** app; an independent workshop
without dealer access can frequently see *that* a bike has faulted but not *why*, and
cannot re-pair a replaced component. That is precisely the dependency this project exists
to document.

!!! warning "This one is genuinely hard — set expectations before starting"
    Unlike every other motor in this registry, there is **no BLE or serial link to scan**.
    The system is CAN, so getting on the bus needs a CAN interface and physical access to
    the harness, not a phone. Community reverse engineering
    ([bosch-nerds/ebike](https://git.cccfr.de/bosch-nerds/ebike)) is at an early stage — it
    documents how to get on the bus and a couple of frames, not a message catalogue.
    Treat this page as a starting kit, not a protocol spec.

## Hardware

| Property | Value |
|----------|-------|
| System | Performance Line CX, Gen4 |
| Display | Kiox (also Nyon, Purion, Intuvia across the range) |
| App | eBike Flow (also Bosch's dealer diagnostic tooling) |
| Bus | CAN, 500 kbit/s |

### Kiox display internals

| Part | Component |
|------|-----------|
| CPU | STM32F469IIH6 |
| Flash | W25M512JV (512 Mbit SPI) |
| RAM | W9864G6KH (64 Mbit SDRAM) |

## Protocol Summary

### Bus and wiring

CAN at **500 kbit/s**:

```
ip link set can0 type can bitrate 500000
```

Breakout via a D-Sub 9 connector following **CiA DS-102**:

| Pin | Signal | Wire |
|-----|--------|------|
| 1 | RTL | |
| 2 | CAN_L | yellow |
| 3 | Ground | black |
| 7 | CAN_H | green |
| 8 | RTH | |
| — | +12 V, max 1 A | red |

### Known frames

Only one is documented so far:

| Frame | Meaning |
|-------|---------|
| `061#00` | Start/stop command (`cansend can0 061#00`) |

That is the honest extent of the public message catalogue. There is no decoded field
mapping for speed, assist level, battery state or error codes yet — building one is the
work.

### Verification

`hypothesis` throughout. The bitrate, pinout and tooling are `reported` and reproducible;
the single frame above is `reported` from one source and unconfirmed by us. Nothing on this
page has been observed on our own bus.

!!! danger "Advanced, and unusually consequential here"
    Anything that transmits on this bus should be treated as `advanced`:

    - **Bosch actively detects tampering.** Speed-tuning dongles are detected, and the
      system records it. A flagged unit can be refused service and lose its warranty —
      a consequence that outlives whatever change caused it.
    - **Derestriction changes legal class**, moving the bike out of EAPC/pedelec status
      and changing licence, insurance and road-access requirements.
    - **Component pairing is the legitimate case** and the reason this matters: a salvaged
      or replaced motor, battery or display has to be paired to the bike, which is exactly
      what dealer gating blocks. It is also exactly the operation that leaves a bike
      unusable if it goes wrong halfway.

    Know the recovery path before writing a frame, and do it with the wheel off the ground.

## Device spec

[`device-specs/devices/bosch-ebike-cx-gen4.yaml`](https://github.com/PigsCanFlyLabs/opengreeniot-protocol-docs/blob/main/device-specs/devices/bosch-ebike-cx-gen4.yaml)
carries what is known as a machine-readable `bus` spec (`protocol: can`,
`style: broadcast`): bitrate, the full D-Sub 9 breakout as `wiring` entries, and a message
catalogue containing exactly one frame, marked `hypothesis` and `advanced`.

A one-entry catalogue is the honest output here. The spec exists so that captured frames
have somewhere to land as they are confirmed, not because the protocol is understood.

## First steps

1. Build the D-Sub 9 breakout above and confirm 500 kbit/s with `candump`.
2. Capture a full session passively: power-on, assist level changes, walk mode, a fault.
   Passive capture first — do not transmit until the bus is understood.
3. Diff captures across single-variable changes (one assist level step at a time) to
   isolate candidate IDs.
4. Only then consider replaying a known-safe frame, on a stand.

## Tools Used

- [ ] CAN interface — SocketCAN-compatible, or SuperCAN firmware on an Adafruit Feather M4 CAN Express
- [ ] `can-utils` (`candump`, `cansend`)
- [ ] `python-can` viewer for live monitoring
- [ ] `cannelloni` for UDP-over-CAN streaming to a workstation

## References

- [bosch-nerds/ebike — CAN bus reverse engineering (git.cccfr.de)](https://git.cccfr.de/bosch-nerds/ebike)
- [Hackaday — an open-source ebike motor controller](https://hackaday.com/2023/11/08/an-open-source-ebike-motor-controller/)
- Pedelecforum.de — additional community findings, largely undocumented in repo form

## Contributors

- Initial research — bus parameters, pinout and tooling transcribed from public community
  work; no capture taken from a physical system.
