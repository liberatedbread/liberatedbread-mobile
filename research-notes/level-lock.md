# Level Lock (Bolt / Lock / Lock+) — Research Notes

## What it is
Level Home "invisible" smart locks: Level Bolt (deadbolt internals only), Level
Lock / Lock+ / Lock+ Apple Home Keys (Matter-over-Thread). BLE to the Level Home
app; Apple HomeKit support (BLE on early models, Thread on Lock+); NFC key cards
and touch entry on Lock/Lock+.

## Cloud status: effectively shutting down
- **Sep 2024**: Assa Abloy acquired Level Home:
  https://community.smartthings.com/t/assa-abloy-acquires-level-lock-company/286658
- **Jun 2026**: AppleInsider reports the Level team gutted and Level "shutting
  down"; app, auto-unlock and door-status features still depend on Level's online
  services: https://appleinsider.com/articles/26/06/26/level-lock-team-gutting-leaves-unanswered-questions
- App still distributed (v2.5.0.56 fetched 2026-08), but the vendor's future is
  unresolved — textbook at-risk.

## Local control: CONFIRMED via HomeKit; vendor BLE protocol un-RE'd
- **Apple HomeKit path is local**: HAP runs over BLE (Bolt/Lock) or Thread
  (Lock+) directly to an Apple TV/HomePod or to Home Assistant's *HomeKit
  Controller* integration — no Level cloud involved in lock/unlock.
- Level Lock+ also supports **Matter-over-Thread**, commissionable locally by any
  Matter controller.
- What dies with the cloud: the Level Home app account features (guest passes,
  auto-unlock geofence, activity history), per the AppleInsider report.
- Vendor's own BLE GATT protocol (used by the Level app) is not publicly
  reverse-engineered; candidate UUIDs below.

## APK provenance
- Package **`co.level.app`** ("Level"), version **2.5.0.56** (vc 61220056),
  XAPK via apkeep (apk-pure), 2026-08-03.
- SHA-256 (xapk): `ecf7655afd17868df1722571b22a254f506d09c5e2fd2a14c9d17c177484fb44`
- Notable strings: `advertising_isHomekitPaired` (lock broadcasts HomeKit pairing
  state in BLE adverts — useful for discovery), NFC + BLE permissions.

## BLE UUIDs (from base-APK DEX strings; roles unconfirmed)
| UUID | Notes |
|------|-------|
| `9161b202-1b4b-4727-a3ca-47b35cdcf5c1` | Likely Level GATT service |
| `9161b203`–`9161b205` (same base) | Characteristics (roles TBD) |
| `256b4960-d04a-4a01-bebd-23f528e92855` | Present in DEX; role TBD |
| `0000fe03-0000-1000-8000-00805f9b34fb` | 16-bit service 0xFE03; possibly scan filter |
| `00002902-0000-1000-8000-00805f9b34fb` | CCCD |

## Open questions
- Confirm HAP-over-BLE works on all pre-Thread models with HA HomeKit Controller
  (well-trodden for other locks; not Level-specific documented).
- Vendor BLE GATT roles/handshake (for HomeKit-free control) — needs HCI snoop.
- Will Assa Abloy migrate Level locks into Yale Home (cf. August migration) and
  keep HomeKit/Matter firmware alive?
