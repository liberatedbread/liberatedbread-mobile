# FINIS Swimsense Live — Research Notes

## What It Is
Wrist-worn BLE swim watch (model 1.30.054) from FINIS, Inc. Released September 2016 at
$179.99 as the BLE successor to the 2010 ANT+/USB Swimsense. Tracks laps, stroke type
(free/back/breast/fly), stroke count, pace, SWOLF, calories; OLED display; pairs with the
"FINIS Live" iOS/Android app, which was contract-built by Intellectsoft.
- [DC Rainmaker in-depth review, 2016-09-13](https://www.dcrainmaker.com/2016/09/swimsense-everything-wanted.html)
- [Wareable release coverage, 2016-09-15](https://www.wareable.com/wearable-tech/swimsense-live-release-date-specs-price-features-3236)
- [FINIS Swimsense Live FAQ (PDF)](https://www.finisswim.com/documents/FAQs/SwimsenseLive_FAQ'S.pdf)

## Why It's Abandoned
- FINIS no longer sells or supports the watch; support told a customer "they no longer sell
  the Swimsense" ([Amazon listing review](https://www.amazon.ae/FINIS-1-30-054-Swimsense-Live-Watch/dp/B01M0YATL0));
  it is absent from finisswim.com. FINIS's swim electronics line moved to the FORM/Ciye-based
  Smart Goggle, which is itself sunset as of end of 2025 (see `finis-smart-goggle.md`).
- The cloud backend `apps.finisinc.com` (FINIS Live web platform / FINIS Connect downloads)
  does not answer: `curl https://apps.finisinc.com/` times out (verified 2026-08-07).
- FINIS, Inc. as a swim-gear brand is alive; only this product line and its cloud are dead.

## Local BLE Feasibility — GOOD
The app talks to the watch over plain unauthenticated BLE GATT; no pairing key, no account
needed at the protocol level. Full GATT map and command frames recovered from the APK.

### Advertising
Device name contains one of: `BLE-watch`, `FINIS-HRM`, `FINIS SWIMSENSE`
(from `FinisDeviceScanner.isFinisDevice()`).

### GATT (from `com/intellectsoft/finis/ble/BleConstants.java`)
| UUID | Role |
|------|------|
| `0000fff0-0000-1000-8000-00805f9b34fb` | FINIS service |
| `0000fff5-0000-1000-8000-00805f9b34fb` | Write characteristic (commands) |
| `0000fff4-0000-1000-8000-00805f9b34fb` | Read/notify characteristic 1 |
| `0000fff2-0000-1000-8000-00805f9b34fb` | Heart-rate characteristic (FINIS HRM strap) |
| `0000fff1-0000-1000-8000-00805f9b34fb` | HR write characteristic |
| `0000180f` / `00002a19` | Standard Battery service/level |

### Command frames (write to 0xFFF5; 0xAA-prefixed, 0xFF-terminated)
- Settings get: `AA 00 B1 FF`; Stats get: `AA 01 B5 FF`; Battery: `AA 00 B7 FF`
- Workout count: `AA 00 81 FF`; Warm-up preamble: `AA 00 80 FF`
- Workout data: date `AA 08 80 00 FF`, part1 `AA 08 90 00 FF`, part2 `AA 08 91 00 FF`,
  free `AA 08 92 00 FF`, breast `AA 08 93 00 FF`, fly `AA 08 94 00 FF`, back `AA 08 95 00 FF`
- Set watch time: `AA 08 B6 <12 bytes> FF`; HR strap frames use 0xC4/0x89/0xC2 leads
Response parsing lives in `com/intellectsoft/finis/ble/FinisBluetoothService.java` — a full
protocol spec can be finished from the decompiled tree alone, no device capture required.

## APK Provenance
- Package `com.finisinc.live`, version 2.0.0 (versionCode 12), ~6 MB bare APK
- Source: apkeep, apk-pure mirror, fetched 2026-08-04
- SHA-256: `cd1989b1f423dec604eac088578a1d2172412d59e79522dbfcea3661abab121b`
- Native Java, unobfuscated (`com.intellectsoft.finis.*`); Retrofit/RoboSpice for cloud sync

## What Needs Cloud
Post-swim upload to the FINIS Live web platform (dead) and third-party exports. The app
itself syncs watch→phone locally over BLE; per the DC Rainmaker review, opening the app
syncs immediately. Account registration exists in-app but is not part of the BLE exchange.

## Open Questions
- Exact byte layout of workout/stat responses (needs reading `FinisBluetoothService` parsers
  or one HCI snoop with a real watch).
- Whether the removed-from-Play iOS/Android apps still install and run without the backend.
- FINIS HRM strap (0xFFF1/0xFFF2 path) is a second accessory worth covering in the same spec.
