# MekaMon (Reach Robotics) — Research Notes

## What it is
**MekaMon** (Berserker V1 2016 / V2 2017): four-legged app-controlled battle robot with augmented-reality gameplay, from UK startup **Reach Robotics**. Phone↔robot link is **BLE**; the Unity-based app adds AR overlays and a visual-programming mode.

## Why it is abandoned
- Reach Robotics **shut down in Sept 2019** (founder Silas Adekunle's announcement; widely covered, e.g. The Robot Report/TechCrunch 2019-09). "The consumer robotics space is an inherently challenging market."
- Apps pulled from app stores; company dissolved. Note: the github.com/Reach-Robotics org still online is a **different** Australian company (subsea manipulators) — do not confuse.
- The robot is a brick without BLE control; no cloud account was ever required for basic drive, but the dead app is the only shipped controller.

## Local BLE feasibility: GOOD (proven, thin docs)
- No cloud dependency in the control path — BLE GATT direct to the robot.
- Prior art: [Hackaday 2021-11-03, "Hacking The Mekamon Robot To Add New Capabilities"](https://hackaday.com/2021/11/03/hacking-the-mekamon-robot-to-add-new-capabilities/) → [hackaday.io project 159212](https://hackaday.io/project/159212/instructions): Raspberry Pi talks to the robot over BLE and drives it autonomously (custom camera head). Confirms the BLE channel is unauthenticated and scriptable.
- Static triage of `com.reachrobotics.mekamon` v2.3.0 (Unity app, 169 MB XAPK): no GATT UUIDs surfaced in a cheap string sweep — the BLE layer is a Unity plugin/native lib; needs either jadx on the plugin or one nRF Connect scan + HCI snoop. Strings confirm VisProg block system and `mekaId` identifiers.

## APK provenance
- **Package**: `com.reachrobotics.mekamon` ("MekaMon"), version **2.3.0** (versionCode 54) — final.
- **Source**: apkeep `-d apk-pure` (XAPK, 168.9 MB; APK Info says "XAPKOBB").
- **SHA-256 (XAPK)**: `5b96ff7f0a745cc2668d2e7853c57a5e1364c43c5b2bd793983c207ca46a943f`
- APKPure history 1.0.1 → 2.3.0.

## What needs cloud
- Nothing confirmed for basic control; AR battle content/leaderboards presumably had server bits, all dead.

## Open questions (this is the greenfield part)
1. GATT service/characteristic map — needs nRF Connect scan of a live robot (V1 vs V2 may differ).
2. Command framing (drive gait, leg servos, IR "weapon" fire/hit) — the hackaday.io project is the best lead; author documented enough to drive it.
3. Whether the Unity app's BLE plugin code is decompilable to a command table (jadx pass on the managed DLLs in `assets/bin/Data/Managed/`).

## Verdict
Document as medium-difficulty: company dead, local BLE confirmed feasible with working prior art, but no published UUID/opcode map — requires either a targeted decompile of the Unity BLE plugin or one live HCI snoop. APK is safely mirrored.
