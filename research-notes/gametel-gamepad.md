# Gametel Bluetooth Gamepad (Fructel) — Research Notes

## What This Is
Gametel wireless gamepad by **Fructel AB** (Sweden), launched Dec 2011 for
Android/iOS/PC. Clip-on phone clamp, d-pad + 4 face buttons + 2 shoulder +
dual analog... (mini-joysticks). Fructel went silent after ~2013; website
dead, app unmaintained for a decade, firmware-update and game-catalog
endpoints in the APK point at dead infrastructure. Company defunct (no
registry confirmation pulled — last press 2013, domain gone).

## Transport
- Bluetooth Classic (BR/EDR), dual personality:
  1. **Standard HID** (SDP UUID `00001124`) — gamepad pairs as a plain HID
     gamepad/keyboard; also had an iCade-compat mode on iOS. This mode needs
     no app at all.
  2. **Vendor RFCOMM channel** for app↔pad management:
     UUID `6ae94aad-1f69-4499-9791-e5bc1dbfbbd3` (`BtService.GAMETEL_UUID`,
     service name "Gametel").
- App checks SDP records and branches on HID vs GAMETEL UUID
  (`BtOutConnectHandler.handleUuidsFetched`).

## Vendor Protocol (from com.fructel.gametel v1.5.3 DEX)
Framing (`bluetooth/protocol/Parser.java`):
- `STX 0x02` ... payload ... `ETX 0x03`
- Escape: `0x1B` followed by `byte XOR 0x20` (escapes 0x02, 0x03, 0x1B)
- RX buffer 100 bytes.
Packet structure: first payload byte = packet type:
| Type | Meaning |
|------|---------|
| 1 | Command (host → pad) |
| 2 | Response |
| 3 | Report (pad → host) |

Commands (2nd byte = command id):
| ID | Command |
|----|---------|
| 16 | RemoveLinkKey (payload: 1 byte) |
| 17 | Ping |
| 19 | SendReport (payload: report id, e.g. feature-report readback) |
| 20 | GetMac |

Reports (`Reports/Report.java`): 16=FeatureReport, 17=ButtonReport,
18=StatusReport (1 byte status; bit 1 = battery low).

## What the app did (and what is lost)
- IME service (`IMEService`) injected gamepad button events as Android
  key/touch events — the "works with any game" hack. Also per-game key
  mapping (`KeyMapActivity`) and a web-hosted game catalog
  (`AppListAcitivity` + `UrlImageCache`), plus firmware update checker
  (`FWUpdateChecker`). Catalog/firmware URLs are dead — cosmetic loss only.
- The gamepad itself remains fully usable as a standard BT Classic HID
  gamepad without the app (pair in OS settings).

## APK Provenance
- **Package**: `com.fructel.gametel`, version 1.5.3 (versionCode 10506)
- **Source**: apkeep, `apk-pure`
- **SHA-256**: `7bf4de4072158c2118a86c1f7053d30d44a18d76fd582c298a6b30772ecd9cbe`
- 323 KB, native Java, unobfuscated; targets Android 2.1 (SDK 7).

## Feasibility
- **Confirmed local**: HID mode works with any modern OS/retro frontend
  (RetroArch etc.) — no cloud, no account.
- **Vendor channel**: framing + command set recovered above; enough for a
  clean-room client (ping, battery status, MAC, link-key management).
  FeatureReport contents (key mapping / config?) not yet decoded — follow-up.

## Sources
- PhoneArena (2011-11-18), Fructel/Gametel announcement:
  https://www.phonearena.com/news/Fructel-hopes-to-brings-a-universal-gamepad-to-Android-devices_id23893
- Pocket Gamer hands-on (2011), Fructel = Swedish company:
  https://www.pocketgamer.com/previews/hands-on-with-the-new-gametel-wireless-controller-for-android/
- Macworld (2012-01-09), iOS version incl. iCade modes:
  https://www.macworld.com/article/669419/ces-gametel-bluetooth-gamepad-for-iphone.html

## Open Questions
- FeatureReport (ID 16) payload layout — likely holds button-mapping config.
- Whether mapping writes persist on the pad (would make the dead app fully
  replaceable).
