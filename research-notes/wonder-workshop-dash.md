# Wonder Workshop Dash / Dot / Cue — Research Notes

## What it is
**Dash & Dot** (2014) and **Cue** (2017): BLE-controlled educational robots for kids. Companion apps: Go, Path, Xylo, **Blockly**, Wonder. Control is direct phone↔robot BLE — no hub.

## Why it is at-risk (not fully dead — rated honestly)
- Wonder Workshop was **acquired by Makeblock in 2018**; robot production was discontinued and the company now operates as **"Make Wonder"**, selling a Class Connect **subscription** to schools.
- Hardware is orphaned (no new units, accessories drying up), and the consumer free apps' future is uncertain as the business pivots to subscriptions — classic at-risk profile.
- BUT: the Blockly app is still listed and received builds recently (APKPure history runs to **4.2.5**), so this is "at-risk", not "shut down". Local BLE control works today without any account.

## Local BLE feasibility: VERY GOOD
- Official Wonder Workshop Python API existed (Python 2 / macOS only) — per [Hackaday 2026-02-14](https://hackaday.com/2026/02/14/reverse-engineering-a-dash-robot-with-ghidra/).
- Active community RE:
  - [mewmix/bleak-dash](https://github.com/mewmix/bleak-dash) (2024) — cross-platform Python (bleak) Dash control.
  - [Robopenguins Dash RE writeup](https://www.robopenguins.com/reverse-dash/) (2026-02) — Ghidra-based firmware + protocol RE; covered by [Adafruit blog 2026-02-16](https://blog.adafruit.com/2026/02/16/reverse-engineering-the-dash-learning-robot/).
- GATT recovered from `com.makewonder.blockly` DEX (2026-08):
  - Service family base `af230000-879d-6186-1f49-deca0e85d9c1`, chars `af230001`–`af230006` (command/notify set)
  - OTA/update family `af237777`/`af237778`/`af237779` (same base) — app ships `DashUpdate.json`, `DotUpdate.json`, `CueUpdate.json` firmware manifests.
- Advertising: robots advertise as "Dash"/"Dot"/"Cue" names (strings confirmed in app).

## APK provenance
- **Package**: `com.makewonder.blockly` ("Blockly for Dash & Dot robots").
- **Source**: apkeep `-d apk-pure` (bare APK, ~latest 4.2.x per APKPure listing).
- **SHA-256**: `34e29b50cbf216aeb09b36aff000f6cafe80deaed4a350c1e75f20c97062a207`
- `com.makewonder.go` ("Go for Dash & Dot robots") **failed** on APKPure via apkeep — try other mirrors or adb pull if the Go app matters (Blockly is the superset for control RE).

## What needs cloud
- Basic drive/sensor/program control: nothing — local BLE.
- Class Connect curriculum/accounts: cloud, subscription — irrelevant to local control.

## Open questions
- Opcode table consolidation: bleak-dash + Robopenguins writeup cover drive/LED/sound/sensors; a full opcode map needs one decompile pass of the Blockly APK's `WW*Command` classes (visible in strings: `WW_POSE_DIRECTION_*`, pose/event system).
- Dot (smaller, no wheels) command subset.
- Whether robot firmware updates require the app update channel (af23777x) — i.e., is stock firmware recoverable if Make Wonder vanishes? Firmware blobs appear to ship inside the APK (DashUpdate.json) — worth preserving that fact in the spec.

## Verdict
Document, but tag as AT-RISK rather than dead: hardware discontinued, software maintained under a subscription pivot. Strong prior art makes the spec cheap; the urgency is capturing firmware/opcode details before the business model swallows the free apps.
