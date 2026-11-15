# Ninebot/Segway E-Scooters (ES/E/F/D/G30 Max + Ninebot S/mini) — Research Notes

## What it is
Segway-Ninebot's consumer BLE scooter family: ES1–ES4, E22/E25/E45, F-series, D-series,
Max G30/G30L, plus the self-balancing Ninebot S / miniPRO (hoverboard-form-factor,
same app and BLE stack). Companion app: "Segway-Ninebot".

## Cloud status — vendor alive, account-dependent (at-risk, not dead)
- Ninebot/Segway is alive and shipping new models (as of Aug 2026), so this is an
  *at-risk* target, not an abandoned one.
- The app pushes account creation; new scooters must be **activated in-app** before
  reaching full speed, and activation rides on Segway's servers. If that service dies,
  unactivated scooters stay speed-limited — the classic cloud-brick risk.
- Firmware updates are server-hosted.

## Local BLE feasibility — HIGH (proven by third-party tooling)
- [ScooterHacking Utility](https://wiki.scooterhacking.org/doku.php?id=shutility) pairs
  with these scooters directly over BLE to read/change settings and flash BLE/ESC/BMS
  firmware — no Segway account involved. There is even a browser build
  (utility.cfw.sh) using Web Bluetooth. Supported list: ESx, E, F, F2, D, G30, T15,
  and more ([joeybabcock.me/wiki](https://joeybabcock.me/wiki/ScooterHacking_Utility)).
- Pairing involves a per-session exchange (SHU issue tracker references the "BLE random
  (0x5B)" handshake on G30). Firmware encryption is documented by the NinebotCrypto
  implementation (github.com/scooterhacking org, "implementation of the NinebotCrypto
  protocol by majsi") and firmware mirrors exist at firmware.scooterhacking.org.
- SHFW custom firmware ([lekrsu/shfw-walkthrough](https://github.com/lekrsu/shfw-walkthrough))
  runs on G30 and removes dependency on vendor servers entirely.

## APK provenance
- Package `com.ninebot.segway` ("Segway-Ninebot", v6.9.x as of 2026)
- apkeep (apk-pure), XAPK 287,720,576 bytes
- XAPK SHA-256: `00fe6167ad4facc95d933d44a33c8220b5d218046ff7c1d4ab148d89abfde63e`
- Old versions archived by the community: files.scooterhacking.org/apps/ninebot/v5/
- **Static pass inconclusive**: base APK ships only a ~208 KB `classes.dex` loader stub;
  bulk code is elsewhere (heavy native libs in the abi split, `assets/platform.zip`,
  `assets/nedata.db`). No BLE UUIDs recoverable with a cheap strings pass — needs real
  unpacking or an HCI snoop. Prior art (SHU/NinebotCrypto) already fills the gap.

## BLE transport (from prior art, not from APK)
- Nordic UART Service family is the standard transport across Ninebot/Xiaomi scooters
  ([irmo.de e-scooter BLE teardown](https://www.irmo.de/2023/11/08/e-scooter-bluetooth-hacking/)):
  service `6e400001-b5a3-f393-e0a9-e50e24dcca9e`, write `6e400002`, notify `6e400003`.
- Commands are the shared Ninebot/Xiaomi serial protocol (register read/write frames,
  CRC16) tunneled over the UART characteristics; exact per-model register maps live in
  the ScooterHacking wiki and firmware patcher sources.
- Treat these UUIDs as prior-art-reported; confirm on hardware per model.

## What needs cloud
- Initial activation of a brand-new scooter (server round-trip) — open question whether
  SHU can activate offline; community reports suggest activation bypass exists for some models.
- Firmware image downloads (mirror exists at firmware.scooterhacking.org).
- Everything else (lock, speed modes, lights, cruise, regen, telemetry) is local BLE.

## Open questions
- Offline activation path for never-activated scooters (biggest cloud-brick risk).
- Which newer models (2024+) changed the BLE handshake (SHU issue #235 shows drift).
- Ninebot S/miniPRO hoverboard-mode control frames (lean-to-steer telemetry over BLE).

## Safety
Vehicle. Speed-limit and motor-control writes are safety-relevant; firmware flashing can
brick controllers. safety_class: HIGH.
