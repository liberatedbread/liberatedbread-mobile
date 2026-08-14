# Cue Health Monitoring System (Cue Reader) — Research Notes

## What it is
The Cue Reader is a battery-powered, BLE-connected cartridge processor for Cue Health's
at-home molecular tests (COVID-19 NAAT, later mpox/flu/RSV). It runs a single-use test
cartridge and reports results to the Cue Health app over Bluetooth (Protobuf framing).
First molecular COVID test with FDA home/OTC emergency authorization (2021-03).

## Why it's abandoned (dated sources)
- FDA warned consumers not to use Cue's COVID tests, 2024-05-14
  ([Medical Device Network](https://www.medicaldevice-network.com/news/fda-warns-users-not-to-use-cue-healths-at-home-covid-19-tests/)).
- Cue Health shut down and laid off all remaining staff, 2024-05-22
  ([STAT](https://www.statnews.com/2024/05/22/cue-health-covid-19-test-maker-layoffs/),
  [MassDevice](https://www.massdevice.com/cue-health-layoffs-all-employees-fda-warning-letter-covid-19-tests/)).
- Recall classified Class II and EUAs revoked, 2024-10-17; **Cue remotely disabled the
  mobile app so remaining cartridges cannot be run at all**
  ([MedTech Dive](https://www.medtechdive.com/news/fda-cue-health-recall-covid-19-tests/730116/)).
- `com.cuehealth.healthapp` returns 404 on Google Play (checked 2026-08-03).

## Local BLE feasibility
- Reader ↔ app link is plain BLE with Protobuf messages — **the link itself is local**;
  cloud was only used for accounts, telehealth proctoring, and (post-2022) server-side
  result-tamper checks.
- Prior art (security RE): Ken Gannon / WithSecure reverse-engineered the BLE+Protobuf
  result block — a result field ending `10 02` = positive, `10 03` = negative — and
  demonstrated a bit-flip result forgery, 2022-04
  ([TechCrunch, 2022-04-21](https://techcrunch.com/2022/04/21/cue-health-covid-security-false-results/)).
  Cue's fix was server-side checks (now dead), so the on-device protocol is the pre-fix
  local protocol.
- Realistic value: archival/protocol documentation and hardware reuse (motorized/optical
  cartridge platform). The consumable cartridges are recalled and unobtainable, so the
  device can never run a real assay again.

## APK provenance
- **Package**: `com.cuehealth.healthapp` (delisted from Play; on APKPure)
- **Source**: apkeep `-d apk-pure`, downloaded 2026-08-03
- **Latest version listed**: 2.2.0 (1.7.2 → 2.2.0 available)
- **APK SHA-256**: `263335717f7efadca85021417537aa76fcc3db437c02c3bc0e99d841724991a4` (~152 MB)
- DEX strings triage: custom 128-bit service family `4FCB0001/2/3-890C-46A3-AB5E-1E1F3ED3D352`
  (probable Reader GATT service), Nordic-Thingy-style UUID `EF68xxxx-9B35-4933-9B10-52FFA9740042`
  family absent, `5434483e-c6a2-11ea-87d0-0242ac130003` (unknown proprietary), CSR/Qualcomm
  OTA UUIDs (`0002a5d5c51b` suffix family), Google Fast Pair (`9a04f079-…`). Full mapping
  needs a jadx pass.

## Safety
- safety_class: HIGH. Diagnostic device: results were used for travel/treatment decisions,
  and a result-falsification exploit is publicly documented. Any local client must never
  present readings as valid medical results — this is a preservation effort, not a way to
  keep testing (cartridges are recalled and chemically dead).

## Open questions
- Full GATT table + Protobuf message set (jadx on the APK; WithSecure's writeup has field details).
- Does the Reader require an app-side unlock that Cue's app-disable broke, or is the
  disable purely app-side (in which case a local client could still drive the Reader)?
- Firmware/DFU path (CSR-family OTA UUIDs suggest a Qualcomm/CSR module).
