# Nissan Leaf (ZE0 / AZE0 / ZE1) — battery data over OBD-II

> **Status**: In Progress (read-only decode transcribed from open-source clients; not yet run against a car)
> **Protocol**: OBD-II connector: ISO 15765-4 CAN (11-bit, 500 kbit/s) with ISO-TP, KWP-style `21` group reads and UDS `22`/`19` reads
> **Manufacturer**: Nissan
> **Manufacturer Status**: Active. The NissanConnect EV cloud service for Leafs built up to May 2019 ended on 30 March 2026.

Machine-readable spec: [`device-specs/devices/nissan-leaf-obd2.yaml`](https://github.com/liberatedbread/liberatedbread-protocol-specs/blob/main/device-specs/devices/nissan-leaf-obd2.yaml).

## Overview

On 30 March 2026 Nissan switched off the **NissanConnect EV** app for Leafs built up to
May 2019 and for e-NV200 vans, in the UK and in at least Ireland and Cyprus. Owners lost
remote charge status, remote charging and pre-conditioning. Nissan still exists and so
does the car. Only the cloud path is gone.

The battery data the app showed is still available locally. A phone or a home server
connects to a plug-in **ELM327-class OBD-II adapter** (usually a BLE one, such as the
LeLink2). Through it, the client polls the **Li-ion Battery Controller (LBC)**: requests
go to CAN ID `0x79B` and replies come back on `0x7BB`. Nothing here requires a session or
security access, and this page documents **reads only**.

!!! warning "Read-only, on purpose"
    The open sources this is drawn from also implement LBC writes: clearing DTCs, and a
    seed/key-gated routine that resets the pack's degradation history. They are left out
    deliberately and listed in the spec under `protocol_details.excluded_services`. A
    tool that can rewrite a battery's reported health has no place in a spec that people
    use to judge a used car.

!!! note "Polling etiquette"
    The open clients poll gently. The Home Assistant integration polls every 10 s with
    the car on and every 5 minutes with it off, because on some cars each poll of a
    sleeping car clicks a relay. OVMS does not poll the LBC at all while the car is
    off. Battery-Emulator stops polling while another tester is using `0x79B`, because
    the LBC drops a request that arrives mid-reply. Run one poller at a time.

## Hardware

| Property | Value |
|----------|-------|
| Model Number | ZE0 (2010–2012, 24 kWh), AZE0 (2013–2017, 24/30 kWh), ZE1 (2018+, 40/62 kWh) |
| Chipset | n/a (vehicle); the adapter is ELM327-class, see [OBD-II Bluetooth adapter](obd2-bluetooth-adapter.md) |
| Radio | None on the car side; BLE or Classic on the adapter |
| FCC ID | n/a |
| Category / hierarchy | `vehicle` |
| Aliases | Nissan LEAF; Leaf 24/30 kWh; Leaf 40 kWh / 62 kWh e+ |
| Companion apps | NissanConnect EV (discontinued 2026-03-30 for pre-May-2019 cars) |

**ZE1 port isolation.** On 2018+ cars a CAN gateway sits between the OBD-II port and the
vehicle buses, and it powers down when the ignition is off. With the car off, polls go
unanswered, so the car has to be switched on. ZE0/AZE0 ports stay reachable with the car
off.

## Initial Setup

| Property | Value |
|----------|-------|
| Setup required | No (on the car) |
| Method | `wired` |
| Passphrase protection | not_applicable |
| Confidence | medium (public open-source clients) |

Plug in the adapter, wake the car (switch it on for ZE1), connect to the adapter and run
the ELM327 initialisation below.

**Factory reset**: not applicable. The car stores no client pairing or credentials.

**Rebinding**: physical swap of adapter or host. The car keeps no record of the last tool.

## Pairing

Nothing pairs with the car. Any pairing belongs to the adapter. See
[OBD-II Bluetooth adapter](obd2-bluetooth-adapter.md).

## Protocol Summary

### ECU addressing

From the [community CAN database README](https://github.com/dalathegreat/leaf_can_bus_messages):

| ECU | Request | Response | Used here for |
|-----|---------|----------|---------------|
| LBC (battery controller / BMS) | `0x79B` | `0x7BB` | SOC, SOH/Hx, Ah, pack V/A, cells, temperatures |
| VCM | `0x797` | `0x79A` | 12 V battery, charge counts, gear, plug state, VIN |
| M&A (meter) | `0x743` | `0x763` | odometer, tyre pressures |
| CHARGER | `0x792` | `0x793` | — |
| INVERTER/MC | `0x784` | `0x78C` | — |
| BCM / HVAC / ABS | `0x745` / `0x744` / `0x740` | `0x765` / `0x764` / `0x760` | — |
| SHIFT (ZE0 only) | `0x79D` | `0x7BD` | — |

### ELM327 session (py-nissan-leaf-obd-ble)

```text
ATZ            reset; wait 1 s, ignore the reply
ATE0           echo off
ATSP6          ISO 15765-4 CAN, 11-bit, 500 kbit/s
ATH1           print CAN IDs
ATL0 / ATS0    no linefeeds, no spaces
ATCAF0         auto-formatting off: client writes the PCI byte and reassembles
AT RV          optional: < 6 V means no live socket

# whenever the target ECU changes (<hdr> = 79B, 797 or 743)
ATSH <hdr>
ATFCSH <hdr>
ATFCSD 30 00 00     flow control: ContinueToSend, block size 0, STmin 0
ATFCSM 1            use that user-defined flow-control frame

022101         LBC group 0x01 (PCI 02 + 21 01)
03221156       VCM DID 0x1156 (PCI 03 + 22 11 56)
```

Over BLE the library defaults to the LeLink GATT layout: service
`0000ffe0-0000-1000-8000-00805f9b34fb`, with `0000ffe1-0000-1000-8000-00805f9b34fb` used
for both notify and write.

A client on a native CAN interface (Battery-Emulator) answers each LBC frame itself with
`30 01 00 FF FF FF FF FF` on `0x79B`, a block size of 1. The community spreadsheet says
that frame must follow within 15 ms.

### ISO-TP reassembly

- `0x` single frame: low nibble = length.
- `1L LL` first frame: 12-bit length, then 6 data bytes. Group `0x61` is 331 bytes, so its
  first frame is `11 4B`.
- `2n` consecutive frame: sequence 1..F, wrapping to 0, then 7 data bytes. Group `0x02`
  wraps the counter more than once, so count frames.
- Truncate to the announced length. A single frame `03 7F <svc> <NRC>` is a negative
  response, not group data.

All offsets below index the **reassembled payload**, where `payload[0] = 0x61` and
`payload[1]` is the group number. OVMS offsets are 2 lower.

### LBC groups (service `0x21`)

| Group | Contents | Reply length |
|-------|----------|--------------|
| `01` | current, pack V, 12 V, insulation, Hx/health, SOC, Ah | 41 (ZE0) / 43 (AZE0) / 53 (ZE1) |
| `02` | 96 cell voltages + pack and bus voltage | 198 |
| `04` | pack temperatures | 16 (ZE0/AZE0) / 31 (ZE1) |
| `06` | balancing shunts (layout disputed) | 26 |
| `61` | health block: Hx, SOH, bars, capacity (ZE1) | 331 |
| `62` | L1/L2 and quick-charge counts, usage histograms | 118 / 120 (ZE1) |
| `83` / `84` | battery part number / pack serial (ASCII) | — |

The group `0x01` reply length identifies the generation. A ZE1 that has just woken
sometimes answers with `0x2C` (44 bytes), a layout no source maps; poll again.

#### Group `0x01` — ZE0 (41 bytes)

| Field | Offset | Len | Decode | Unit | Confidence |
|-------|--------|-----|--------|------|------------|
| HV current 1 | 2 | 4 | signed / 1024 | A | hypothesis |
| HV current 2 | 8 | 4 | signed / 1024 | A | hypothesis |
| HV pack voltage | 20 | 2 | / 100 | V | hypothesis |
| 12 V supply | 22 | 2 | / 1000 | V | reported |
| Insulation resistance | 24 | 2 | ×1 | kΩ | reported |
| Hx | 28 | 2 | / 100 | % | reported |
| State of charge | 31 | 3 | / 10000 | % | reported |
| Capacity | 34 | 4 | / 10000 | Ah | reported |

#### Group `0x01` — AZE0 (43 bytes)

| Field | Offset | Len | Decode | Unit | Confidence |
|-------|--------|-----|--------|------|------------|
| HV current 1 / 2 | 2 / 8 | 4 | signed / 1024 | A | hypothesis |
| HV pack voltage | 20 | 2 | / 100 | V | hypothesis |
| 12 V supply | 22 | 2 | / 1000 | V | reported |
| Insulation resistance | 24 | 2 | ×1 | kΩ | reported |
| Hx | 28 | 2 | / 100 | % | reported |
| State of charge | 31 | 3 | / 10000 | % | **hypothesis** (ZE0 offset assumed) |
| Capacity | 34 | 4 | / 10000 | Ah | reported |

#### Group `0x01` — ZE1 (53 bytes)

| Field | Offset | Len | Decode | Unit | Confidence |
|-------|--------|-----|--------|------|------------|
| HV current 1 / 2 | 2 / 8 | 4 | signed / 1024 | A | reported |
| HV pack voltage | 20 | 2 | / 100 | V | reported |
| 12 V supply | 22 | 2 | / 1000 | V | reported |
| Insulation resistance | 24 | 2 | ×1 | kΩ | reported |
| Health ("Hx") | 30 | 2 | / 102.4 | % | reported, **disputed** |
| State of charge | 33 | 3 | / 10000 | % | reported |
| Capacity | 37 | 3 | / 10000 | Ah | reported |

On ZE1, OVMS and py-nissan-leaf-obd-ble read `payload[30..31] / 102.4` as health.
Battery-Emulator reads no Hx from this layout and takes ZE1 Hx and SOH from group
`0x61` instead.

#### Group `0x02` — cells (all generations)

96 × u16 big-endian millivolts at `payload[2 + 2i]`. `0xFFFF` (or ≥ 5000 mV) means no
reading. Pack voltage is at `payload[194..195] / 100` V and bus voltage at
`payload[196..197] / 100` V.

#### Group `0x04` — temperatures

There are four sensor slots, each a u16 thermistor raw value at `payload[2 + 3i]`
followed by one byte at `payload[4 + 3i]` holding whole °C. The third slot (i = 2) reads `FF FF FF`
on 2013+ packs, which have only three sensors. `payload[14]` is a fifth temperature in
°C. OVMS converts raw to °C as `-0.102 × (raw − 710)`. Only the first 16 bytes of the
ZE1 reply are mapped.

#### Group `0x61` — health block (ZE1)

| Field | Offset | Len | Decode | Unit |
|-------|--------|-----|--------|------|
| Hx | 2 | 2 | / 100 | % |
| SOH | 4 | 2 | / 100 | % |
| Dash capacity bars | 6 | 1 | raw | — |
| SOH, unfiltered | 7 | 2 | / 100 | % |
| SOH, filtered | 9 | 2 | / 100 | % |
| Capacity | 14 | 4 | / 10000 | Ah |

### VCM and meter (UDS `0x22`)

Request `03 22 <DID>` to `0x797` (VCM) or `0x743` (meter). The reply is
`0L 62 <DID> <data>`, and the single-frame length gives the data width.

| ECU | DID | Meaning | Decode |
|-----|-----|---------|--------|
| VCM | `1103` | 12 V battery voltage | × 0.08 V |
| VCM | `1183` | 12 V battery current | signed16 / 256 A |
| VCM | `1203` / `1205` | quick / L1-L2 charge count | u16, `FFFF` = none |
| VCM | `1156` | gear | 1 P, 2 R, 3 N, 4 D (Eco: 5 or 7, sources differ) |
| VCM | `1304` | power switch | bit 7 set = on |
| VCM | `1234` / `114E` | plug state / charge mode | enums |
| VCM | `115D` | ambient temperature | x / 2 − 40 °C (disputed) |
| VCM | `121A` | speed | signed16 / 10 km/h |
| Meter | `0E01` | odometer | 24-bit km |
| Meter | `0E25`–`0E28` | tyre pressures FR, FL, RR, RL | × 1.7236894 kPa (0.25 psi) |

The VIN comes from `21 81` on the VCM: a 19-byte reply holding 17 ASCII characters and
2 zero bytes. Never publish a real one.

### Worked example (invented values)

A ZE1 group `0x01` reply:

```text
7BB 10 35 61 01 FF FF F8 00     current_1 = 0xFFFFF800 / 1024 = -2.0 A
7BB 21 00 00 FF FF F8 00 FF
7BB 22 FF FF FF FF FF FF FF
7BB 23 94 70 32 00 03 E8 FF     pack 0x9470/100 = 380.00 V, 12 V 0x3200 = 12.8 V, 1000 kΩ
7BB 24 FF FF FF 25 80 00 0B     health 0x2580/102.4 = 93.75 %
7BB 25 71 B0 00 0F 42 40 FF     SOC 0x0B71B0/10000 = 75.0 %, 0x0F4240/10000 = 100.0 Ah
7BB 26 FF FF FF FF FF FF FF
7BB 27 FF FF FF FF FF FF FF
```

`scripts/test_nissan_leaf_obd2_spec.py` decodes this and the other vectors in the spec
(ZE0, AZE0, group `0x02`, `0x04`, `0x61`, VCM and meter frames) from the spec's own
tables.

## What is still unknown

1. The AZE0 SOC offset, which is assumed from ZE0.
2. Which ZE1 health figure is the "real" SOH: group `0x01` health / 102.4, or group
   `0x61`.
3. The group `0x06` balancing-bit layout, where OVMS and Battery-Emulator disagree.
4. Whether ZE0/AZE0 answer group `0x61`.
5. Whether the ELM327 needs `ATCRA 7BB` with these headers, and how its flow control
   behaves under `ATCAF0`.
6. Which J1962 pins reach the LBC on each generation.

The full list is in the spec's `remaining_unknowns`.

## Tools Used

- [x] Read (not executed) OVMS `vehicle_nissanleaf`, Battery-Emulator's Nissan Leaf
      driver, py-nissan-leaf-obd-ble and the community CAN spreadsheet
- [ ] Capture against a ZE0, AZE0 and ZE1 car

## References

- [dalathegreat/leaf_can_bus_messages](https://github.com/dalathegreat/leaf_can_bus_messages): CAN spreadsheet, DBCs, ECU ID table
- [pbutterworth/nissan-leaf-obd-ble](https://github.com/pbutterworth/nissan-leaf-obd-ble) and [py-nissan-leaf-obd-ble](https://github.com/pbutterworth/py-nissan-leaf-obd-ble)
- [OVMS Nissan Leaf module](https://github.com/openvehicles/Open-Vehicle-Monitoring-System-3/tree/master/vehicle/OVMS.V3/components/vehicle_nissanleaf)
- [dalathegreat/Battery-Emulator](https://github.com/dalathegreat/Battery-Emulator)
- [Nissan UK: NissanConnect EV maintenance notice](https://www.nissan.co.uk/ownership/maintenance-page.html)

## Contributors

- Initial write-up from public open-source clients (weekly device sweep, backlog #24)
