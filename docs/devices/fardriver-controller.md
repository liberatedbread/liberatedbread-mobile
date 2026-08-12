# Fardriver ND-series Motor Controller

> **Status**: Research
> **Protocol**: BLE
> **Manufacturer**: Nanjing Fardriver Controller Co.
> **Manufacturer Status**: Active (app-tethered; no documented local API)

## Overview

Fardriver ND-series controllers are sine-wave (FOC) brushless motor controllers used
throughout the Chinese light-EV supply chain — QS Motor hub-motor kits, e-motorcycle
builds, and classic-scooter EV conversions. The controller carries a BLE bridge and is
driven by the vendor "FarDriver" Android app, which shows live speed, pack voltage,
current, RPM, temperatures and state of charge, and writes tunable parameters
(gear-mode curves, speed limiting, regen, throttle response).

We document it because it is the **app layer behind app-connected classic-scooter EV
conversions**. Kits such as Retrospective Classic's "Project:E" Vespa/Lambretta
conversion (72 V, 4 kW hub motor, keyless ignition) are advertised as
"connected by app", where the app reports speed, battery status, range and the
selected riding mode, and where the speed limit can be restricted or derestricted.
That is a rider-facing dashboard bound to a proprietary app — exactly the dependency
OpenGreenIoT exists to remove.

!!! warning "Vendor attribution is inferred, not confirmed"
    Retrospective publishes **no app name and no controller brand** — their product
    pages, the kit listings, their FAQ, and every press piece covering the kits say
    only "sinusoidal motor controller", "keyless ignition/remote" and "connected by
    app". The Fardriver identification here is inferred from the published bill of
    materials (sine-wave controller, QS-style 4 kW 72 V hub motor, app-adjustable
    speed restriction) matching the ND-series feature set, and from QS Motor shipping
    its 4 kW hub kits paired with Fardriver ND72xxx controllers.
    **Confidence: MEDIUM.** Confirm on your own scooter before relying on it — see
    [Confirming what your scooter actually runs](#confirming-what-your-scooter-actually-runs).
    The main alternative is the Votol EM-series; see [If it's not Fardriver](#if-its-not-fardriver).

## Hardware

| Property | Value |
|----------|-------|
| Family | ND-series (e.g. ND72200, ND72260, ND72680, ND84530) |
| Typical pack voltage | 60–84 V nominal (72 V common; ND72xxx tolerate ~88 V) |
| Commutation | Sine wave / FOC, with regenerative braking |
| MCU (ND84530_24_ABH64) | GigaDevice GD32F303 |
| Radio | BLE via a bolt-on bridge module (varies per unit) |
| Companion app | "FarDriver" (Android; distributed as a direct APK, not via Play) |

## Protocol Summary

### BLE Services

!!! danger "UUIDs are per-unit — verify before use"
    Fardriver controllers ship with **different BLE bridge modules**, so transport
    UUIDs vary between units even when the framing below is identical. The pair below
    is the commonly observed HM-10-style set and is a **starting point only**.
    Scan your own controller with nRF Connect and record what you find.

| UUID | Name | Description |
|------|------|-------------|
| `0000FFE0-0000-1000-8000-00805f9b34fb` | BLE Bridge Service | HM-10-style serial bridge service |

### Characteristics

| UUID | Name | Properties | Description |
|------|------|------------|-------------|
| `0000FFEC-0000-1000-8000-00805f9b34fb` | Telemetry Notify | Notify | Free-running 16-byte status frames |
| `0000FFE1-0000-1000-8000-00805f9b34fb` | Serial Data | Read, Write, Write Without Response, Notify | Bidirectional serial channel on HM-10-style modules |

### Discovery

- **Autodetection: not provided, deliberately.** The spec declares no `identification`
  or `discovery` block — see the warning below.
- **Selection**: manual. Pick the controller by address after confirming it with a scan.
- **CCCD**: standard `0x2902` to enable notifications
- **Pairing**: no bonding on HM-10-style bridges ("Just Works" or none)
- **Keep-alive**: none required — the controller pushes telemetry unprompted once
  notifications are enabled

!!! warning "`0xFFE0` is not a Fardriver signature — do not match on it"
    `0xFFE0` is the generic HM-10/HM-19 BLE-UART service. The MoTool Slacker spec already
    uses it as its sole identification signal, and SP107E LED controllers advertise it as
    well. A registry matcher keyed on that UUID would classify a single advertisement as
    several different devices — and could then point Fardriver telemetry, or an
    **advanced write**, at unrelated hardware. Combined with this device's own
    per-unit UUID variation, it is not a safe auto-match signal.

    Automatic identification can be restored once a discriminating signal exists: a
    unique local-name prefix, manufacturer-specific advertisement data, or a read-only
    framing probe (subscribe, confirm 16-byte `0xAA` frames).

### Status frame format

The controller free-runs status frames as BLE notifications. Each is 16 bytes:

| Offset | Length | Description |
|--------|--------|-------------|
| 0 | 1 | Magic — always `0xAA` |
| 1 | 1 | 6-bit block ID + 2-bit flags |
| 2 | 12 | Payload (mirror of a controller memory block) |
| 14 | 2 | CRC16 |

When the ID field is `< 0x37`, it indexes a 55-entry table of flash addresses spanning
`0x00`–`0xFA`, and the payload is the mirror of that region. Frames rotate through
nearly all addresses, with hot blocks repeated roughly every 3–4 frames.

**Reassembly**: collect frames until the addressed blocks cover the range, and you
have a 512-byte (`0x200`) image of controller memory. The field table below is decoded
from **offsets into that reassembled image** — these are *not* offsets into any single
frame.

### CRC16

| Parameter | Value |
|-----------|-------|
| Polynomial | `0x8005` |
| Init | `0x7F3C` |
| RefIn | true |
| RefOut | true |
| XorOut | false |

Implemented vendor-side as a dual hi/lo lookup table seeded `a = 0x3C`, `b = 0x7F`.

### Decoded telemetry fields

Offsets are into the reassembled 512-byte image.

| Field | Offset | Type | Scaling |
|-------|--------|------|---------|
| Pack voltage | `0x1D0` | int16 | ÷ 10 → volts |
| Line current | `0x1D4` | int16 | ÷ 4 → amps |
| Measured speed | `0x1C8` | uint16 | via configured wheel parameters |
| Throttle depth | `0x1DE` | int16 | relative to low-speed threshold |
| Motor torque | `0x1CC`, `0x1CE` | int16 | `((unkE6² + unkE7²) << 9) / TorqueCoeff` |
| Phase A current | `0x1E0` | 24-bit | `1.953125 × √value` |
| Phase C current | `0x1E6` | 24-bit | `1.953125 × √value` |
| MOSFET (controller) temperature | `0x1AC` | int16 | °C |
| Motor temperature | `0x1E8` | int16 | °C |
| Battery SOC | `0x1EA` | int8 | percent |

### Configuration registers

These are the register addresses the write path below targets. Reading them is ordinary;
writing them is `advanced` — see the write path.

| Setting | Offset | Bits |
|---------|--------|------|
| Brake config | `0x0C` | 0–3 |
| Temp sensor type | `0x0C` | 4–6 |
| Throttle response (Line / Sport / ECO) | `0x32` | 2–3 |
| Gear config (ride mode) | `0x33` | 5–7 |
| CAN baud (250K / 500K / 1M) | `0x178` | 0–1 |
| Speed limit mode | `0x196` | 0–3 |

### Write path

Parameter writes use a shorter variable-length frame (typically 8 bytes) with `flags = 1`:

| Offset | Length | Description |
|--------|--------|-------------|
| 0 | 1 | Magic — `0xAA` |
| 1 | 1 | Computed length (flags = 1) |
| 2 | 2 | Register address (hi, lo) |
| 4 | n | Payload, little-endian |
| 4+n | 2 | CRC16 (same parameters as above, computed over the frame) |

System commands write `0x88 XX` to address `0xA0` — self-balance/calibration, data
gather, and controller reset.

Both write commands are declared in the spec with `advanced: true`:

| Command | Effect |
|---------|--------|
| `write_parameter` | Generic register write — current limits, regen, speed limiting |
| `system_command` | Controller-level operations: calibration, data gather, reset |

!!! warning "Advanced — read this before writing anything"
    These opcodes are documented and meant to be usable. They also retune a **road-going
    vehicle**, so here is what you are taking on:

    - **Confirm before trusting.** The frame *shape* is MEDIUM confidence (derived from
      community RE). Exact per-parameter payload encodings and **CRC byte order are
      unverified** — capture the vendor app writing a known value on your own unit first.
    - **Validate on a stand**, wheel off the ground, never while moving.
    - **Wrong values can overheat** the motor or controller; a mistimed self-balance or
      reset can leave the controller unable to drive until reconfigured.
    - **Derestricting a speed limit may change the vehicle's legal classification and
      invalidate insurance.** Documented because it is your vehicle and your call —
      but make it knowingly.

    Writes are excluded from autodetection: discovery stays scan-and-read only. Consumers
    should keep these available behind a deliberate action — a signpost, not a gate.

## Confirming what your scooter actually runs

Five minutes with a phone, before writing any code:

1. **Scan.** Power the scooter on, open nRF Connect (Android/iOS), and scan next to the
   controller. Note every advertised device name, its address, and its service UUIDs.
   Fardriver bridges often advertise a short generic name and a `0xFFE0`-family service.
2. **Record the real UUIDs.** Connect and enumerate. Write down the service plus the
   characteristic that carries `notify`. This is the per-unit value that matters — the
   UUIDs in this doc are a starting point, not a guarantee.
3. **Check the framing.** Subscribe to the notify characteristic and watch raw bytes with
   the ignition on. If you see a steady stream of 16-byte frames each starting `AA`,
   that is the Fardriver framing above and this spec applies.
4. **Check the phone.** Whatever app the installer put on your phone at handover is the
   ground truth. Grab its package ID (Android: Settings → Apps → App info) and add it to
   `targets/targets.csv`.
5. **Capture, don't guess.** Enable *Developer options → Enable Bluetooth HCI snoop log*,
   drive one connect + one mode change in the vendor app, and pull `btsnoop_hci.log`.
   That single capture resolves the write path far more reliably than inference.

If step 3 shows 16-byte `0xAA` frames, the vendor attribution above is confirmed for your
unit and this page's status can move from Research to In Progress.

## Where else this spec applies

Scooter conversions are not the only place these controllers turn up. The ND/NS-series is
a common upgrade on light electric off-road bikes — **Sur-Ron Light Bee**, **Talaria**
(MX3/MX4/Sting R) and **Segway X260** — typically as the ND96680/NS96680 at 48–96 V, sold
alongside Sabvoton, Kelly and Nucular as the competing options. The framing, CRC and write
path documented here are the same family; only the voltage class and per-unit BLE bridge
differ. If you are working on one of those bikes, start here rather than from scratch, but
re-confirm the UUIDs and register values on your own unit exactly as below.

## If it's not Fardriver

The main alternative in this class is the **Votol EM-series** (EM50/EM100/EM150/EM200),
also sine-wave, also common in 72 V conversions, and also supporting keyless "one-key
start". Distinguishing signs:

- Votol's official tooling is a Windows configurator plus a **WeChat mini-program**, with
  per-unit Bluetooth-ID binding performed by the seller — noticeably clunkier onboarding
  than a plain APK.
- Votol needs battery voltage wired to the lock signal to power up for programming.
- Community BLE access typically goes through a **CAN-to-BT bridge**, not a serial bridge,
  so you would see CAN-shaped traffic rather than 16-byte `0xAA` frames.

If your scan shows a CAN bridge or the framing does not match, open a separate target
sheet rather than stretching this spec.

## Battery telemetry is probably a separate device

Kits of this type usually pair the controller with a smart BMS in the removable pack
(JBD/Xiaoxiang and ANT are the common ones), each with its **own** BLE service and its own
app. If "battery status" in your app is richer than the controller's single SOC byte —
per-cell voltages, cycle count, balance state — it is coming from the BMS, not the
controller, and needs its own spec. Scan with the pack in and the pack out to tell the two
radios apart.

## Tools Used

- [ ] nRF Connect — service/characteristic enumeration, per-unit UUID capture
- [ ] Android HCI snoop log (`btsnoop_hci.log`) — connect + mode change capture
- [ ] Wireshark — frame reassembly and CRC verification
- [ ] `scripts/detect_devices.sh` — BLE discovery sweep

## References

- [Retrospective Classic — Project:E conversion](https://www.retrospectivescooters.com/for-sale/project-e-electric-vespa-conversion)
- [ScooterLab — Retrospective electric conversions feature](https://scooterlab.uk/electric-scooter-conversons-vespa-lambretta/)
- [Motorcycle News — Retrospective electric conversion](https://www.motorcyclenews.com/news/new-tech/retrospective-scooter-electric-conversion-vespa-lambretta/)
- [jackhumbert/fardriver-controllers — protocol and hardware notes (MIT)](https://github.com/jackhumbert/fardriver-controllers)
- [bobecek79/ESP32-Fardriver-BLE-Reader — BLE decode reference (MIT)](https://github.com/bobecek79/ESP32-Fardriver-BLE-Reader)
- [Endless Sphere — Fardriver BLE communication](https://endless-sphere.com/sphere/threads/fardriver-ble-communication.128344/)
- [Endless Sphere — Fardriver serial protocol reverse engineering](https://endless-sphere.com/sphere/threads/fardriver-controller-serial-protocol-reverse-engineering.121825/)
- [QS Motor — QS273 4 kW hub kit with Fardriver ND72680](https://www.cnqsmotor.com/product/electric-car-motor-conversion-kits-qs273-4000w-hub-motor-with-fardriver-nd72680/)
- [Endless Sphere — Votol EM-100/EM-150 controllers](https://endless-sphere.com/sphere/threads/votol-em-100-em-150-controllers.95969/)

## Contributors

- Initial research — protocol framing and field offsets derived from public community
  reverse-engineering work (MIT-licensed), vendor attribution inferred from published
  kit specifications and pending owner confirmation.
