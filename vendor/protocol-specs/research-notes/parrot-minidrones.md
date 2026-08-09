# Parrot BLE Minidrones — Research Notes

## What it is
Parrot's toy "Minidrones" line (2015–2017): **Rolling Spider**, **Airborne Night**, **Airborne Cargo**, **Hydrofoil**, **Mambo**, **Swing**. Small quad/VTOL drones controlled from a phone over **BLE** (Wi-Fi used only for the camera on Mambo FPV variants). Distinct from Bebop/ANAFI (Wi-Fi).

## Why it is abandoned / at-risk
- Parrot laid off a third of its drone staff in **2017** and exited the consumer toy-drone segment; minidrones were delisted and by **2019** the line was dead (Parrot pivoted to ANAFI professional/military).
- **FreeFlight 3** (handled Rolling Spider + Bebop) was pulled from Google Play — owners' threads from 2021-11: "Cannot find freeflight 3 app anymore on google store" (parrotpilots.com). The dedicated **FreeFlight Mini** app is likewise gone from Play (Aptoide/mirror only).
- Parrot the company still exists, so this is "product-line abandoned", not "company dead". Flight control itself was always local — the cloud (Parrot Academy/flight-log sync) was optional.

## Local BLE feasibility: EXCELLENT
- Flight control is local BLE GATT with a handshake over fixed characteristics; no account needed.
- Prior art (protocol RE'd years ago):
  - [voodootikigod/node-rolling-spider](https://github.com/voodootikigod/node-rolling-spider) — BLE protocol for Rolling Spider / Airborne Night (noble).
  - [amymcgovern/pyparrot](https://github.com/amymcgovern/pyparrot) — Python, covers Mambo/Swing/Airborne over BLE (+ Wi-Fi video).
  - Parrot published its **libARCommands** XML command definitions (SDK 3) covering minidrone command IDs.
- Known GATT layout from prior art (base `9a66xxxx-0800-9191-11e4-012d1540cb8e`): service `9a66fa00-…`; chars `fa0a`/`fa0b` (send no-ack/with-ack), `fa0c` (receive), `fa1b`/`fa1c`/`fa1d` (PCMD + camera), `fa21` (handshake counter). Advertising name prefixes `RS_` (Rolling Spider), `Mars`/`Marshall`, `SWING`, etc.
- APK confirmation: FreeFlight 3 v5.2.7 binary contains minidrone product strings (Mambo, Swing, Hydrofoil, Airborne Night/Cargo, "Mars (RS space) model", "Marshall (JS fire) model", "Delos EVO Hydrofoil/Light/Brick product"), plus a legacy `00001010..00001019-d102-11e1-9b23-00025b00a5a5` profile family in DEX. The 9a66faXX constants are built in native code (libARController) — not visible in a cheap string sweep.

## APK provenance
- **Package**: `com.parrot.freeflight3` ("FreeFlight 3"), version **5.2.7** (versionCode 50207201, released 2019-10) — final.
- **Source**: apkeep `-d apk-pure` (XAPK).
- **SHA-256 (XAPK)**: `af098b8e37d3e43c799131abc223fd2349f00823d949fafa649f19c2cf2c2519`
- FreeFlight Mini (dedicated minidrone app) was **not fetchable via APKPure** under `com.parrot.freeflightmini`; Aptoide mirror exists. FreeFlight 3 fully covers the BLE minidrones, so this is not blocking.

## What needs cloud
- Nothing for flight. Optional Parrot account (Academy, flight-log sync) is dead/dying and irrelevant.

## Safety
- Spinning propellers; toy-class (<100 g). `safety_class: LOW`. PCMD watchdog behavior (drone cuts motors on link loss) should be preserved in any re-implementation.

## Open questions
- Per-model capability matrix (which commands Mambo cannon/grabber accessories use) — in libARCommands XML; needs extraction into the spec.
- Swing VTOL mode-switch command IDs — pyparrot has them.
- Confirm whether Mambo FPV camera stream works without the app (Wi-Fi RTP) — secondary to BLE control.

## Verdict
Document. Local BLE flight control is proven by multiple maintained libraries; spec work is consolidation of node-rolling-spider + pyparrot + libARCommands XML, plus naming the per-model quirks.
