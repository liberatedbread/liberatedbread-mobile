# Kamigami (Dash Robotics) — Research Notes

## What it is
**Kamigami**: build-it-yourself origami-style hexapod robot (2015 Kickstarter by **Dash Robotics**, UC Berkeley spinout; Mattel distributed a retail line from 2017). Fast (~5 body lengths/s) six-legged bug bots with IR "battle" between robots, light sensor, gyro/accel, RGB LED. Phone control is **BLE**; drag-and-drop coding in the app.

## Why it is abandoned
- Dash Robotics folded after the Mattel deal wound down (~2019); website gone, apps removed from Google Play and the App Store. Kamigami Controller v1.4.0 is the final build, mirrors only.
- No cloud was ever needed — control is direct BLE — but with the app delisted, the robots ship as display pieces unless a mirror APK or third-party controller is used.

## Local BLE feasibility: GOOD (greenfield but friendly hardware)
- No pairing/auth observed; standard GATT.
- Recovered from `com.dashrobotics.kamigami2` v1.4.0 static sweep (2026-08):
  - Custom service family `708a96f0-f200-4e2f-96f0-9bc43c3a31c8` with characteristics `…f1` and `…f2` (command/notify — role TBD)
  - TI OAD service `f000ffc0-0451-4000-b000-000000000000` → robot MCU is a TI CC25xx (firmware updates over air)
  - Nordic legacy DFU UUID `00001530-1212-efde-1523-785feabcd123` also present (maybe dev-board legacy)
  - Standard DIS/battery strings present.
- Prior art: UC Berkeley's BML lab ran multi-robot Kamigami experiments — [BML-MultiRobot/kamigami_common](https://github.com/BML-MultiRobot/kamigami_common) (ROS; mostly sim, but the group drove real Kamigami hardware via BLE in papers). No published opcode map found — this is the RE opportunity.
- App is plain Android Java (`com.dashrobotics.kamigami2.models.Instruction`, `Game` views, unobfuscated-looking class names in strings) — a jadx pass should yield the command table quickly.

## APK provenance
- **Package**: `com.dashrobotics.kamigami2` ("Kamigami Controller"), version **1.4.0** — final.
- **Source**: apkeep `-d apk-pure` (bare APK).
- **SHA-256**: `1e6cc823f6503c3033a147e2ca2631a2ff158613efa39d3b2b68d58f24cc21d1`
- APKPure history 1.1.1 → 1.4.0. Original "Kamigami" app (older `com.dashrobotics…` package) also on mirrors.

## What needs cloud
- Nothing. Local BLE only.

## Open questions
1. Opcode map for drive/LED/sound/IR-fire + program-download format (the app compiles block programs into `Instruction` sequences sent to the robot).
2. Role split of the two `708a96f1/f2` characteristics (write vs notify).
3. Whether TI OAD images are recoverable from the APK (firmware preservation angle).

## Verdict
Document as easy-greenfield: dead company, zero cloud, GATT anchors already recovered, unobfuscated app — one focused jadx session + one HCI snoop away from a full spec.
