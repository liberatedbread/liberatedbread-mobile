# Target: FOREO Peach 2 (IPL)

## Target metadata
- target_id: foreo-peach-2
- app package_id(s): com.foreo.foreoapp (FOREO For You 4.4.1/559 analyzed)
- device class: IPL hair removal (BLE)
- transport(s): BLE
- local-only viability: **confirmed by static analysis — high**

## Known facts (verified from RE sources)
- Device ships LOCKED; vendor manual requires app "registration" to unlock.
- VERIFIED (static, app 4.4.1): unlock write = `01 02 <8-byte chipId>` to
  characteristic `0x0A20`; chipId = keyless nibble permutation of the device
  BLE MAC → **offline unlock possible, no FOREO server needed by firmware**.
- VERIFIED (static): session handshake `01 A1 <MAC[3..5]>` to `0x0A10` after
  every connect; no bonding.
- VERIFIED (static): command channel `FFF1`, opcode bytes `0A`=write/`0B`=read;
  intensity levels 0–5 via `0A01`; removal mode Basic `0AD0 01` / Pro `0AD0 06`.
- VERIFIED (static): Pro mode is paywalled via server subscription but
  enforced app-side only — firmware accepts `0AD0 06` unconditionally.
- Full details: research-notes/foreo-peach-2.md (+ .yaml)

## Device discovery signals
- BLE advertised names: `PEACH2`, `PEACH 2`, `PEACH™ 2`, `PEACH2GO`,
  `PEACH2ProMAX`
- TBD — hardware: service UUID containing `FFF1` (hypothesis `FFF0`)

## Threat model + guardrails
- IPL device: eye/skin safety interlocks are firmware-side (skin-contact
  sensor); replacement app must NOT attempt to defeat interlocks — only
  reproduce unlock/settings the stock app already performs.

## First experiments (when hardware arrives)
1) ./scripts/detect_devices.sh with a factory-locked unit; capture adv name/MAC.
2) HCI snoop of stock-app first-run registration → confirm `0A20`/`0A30` writes
   match static analysis.
3) Replacement-app MVP: connect → security-access write → activate → wake →
   set intensity 0–5 → set Pro mode without any network.

## Evidence checklist
- APK: FOREO For You 4.4.1 (559), sha256
  90a4ec8f5c22c1085d1500f6bf1954c28edcd81531f0eed94bf8a13aa494ae79
- HCI snoop log: TBD (hardware not yet acquired)

## Spec output (clean-room)
- device-specs/devices/foreo-peach-2.yaml — after hardware verification
