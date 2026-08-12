# PowerTap P1/P2 Pedals (and C1/G3) — Research Notes

## What it is
- PowerTap BLE/ANT+ power meters: P1/P1S/P2 pedal-based units and the C1 chainring
  (the G3 hub is ANT+-centric with BLE caps). The P1 line was the first major
  pedal power meter with dual ANT+ + Bluetooth Smart broadcast (2015).

## Why abandoned (dated sources)
- 2019: SRAM/Quarq acquired the PowerTap brand from Saris.
- 2021-02: **SRAM discontinued all PowerTap products** (G3 hubs, P2 pedals); support
  commitments made for existing owners
  ([DC Rainmaker](https://www.dcrainmaker.com/2021/02/tidbits-powertap-discontinued.html), 2021-02;
  [Velo](https://velo.outsideonline.com/road/road-racing/heres-what-the-disappearance-of-powertap-might-mean/), 2021-02-17).
- 2022-07: original parent Saris filed for bankruptcy (context for C1/G3-era owners).
- The original "PowerTap Mobile" app era ended; firmware/config was folded into the
  **SRAM AXS app** (alive, on Play) — see
  [TrainerRoad forum PSA](https://www.trainerroad.com/forum/t/powertap-p1-s-psa-use-the-sram-axs-app/31304), 2020-03-11.

## Local BLE feasibility — mostly a non-problem, by design
- Telemetry uses the standard Bluetooth SIG **Cycling Power Service (0x1818)** with
  the Cycling Power Measurement characteristic — any head unit, watch, or phone app
  reads it locally with no account and no cloud. Zero-offset calibration is the
  standard CPS Control Point (0x2A66) write, supported by virtually all head units.
- There is **no cloud dependency anywhere** in normal operation: the units are pure
  broadcast/config sensors.
- The only proprietary surface is firmware update + advanced diagnostics, currently
  via the SRAM AXS app (alive). If SRAM ever drops P1/P2 support there, an HCI snoop
  of one firmware-update session would preserve that path.

## APK
- Not fetched: no abandoned vendor app is load-bearing. `com.sram.axs` is current and
  maintained; grabbing it now is optional future-proofing (apkeep/apk-pure has it).
  Legacy "PowerTap Mobile" was iOS-only for the P1 era (DC Rainmaker P1 review,
  2015-08) — nothing Android-side to rescue.

## Open questions
- Whether the P2's extended metrics (left/right balance detail beyond standard CPS)
  use a proprietary characteristic — check with nRF Connect on a live unit.
- G3 hub BLE firmware-update channel (legacy PowerTap iOS app) — undocumented.
- safety_class: LOW (fitness telemetry).
