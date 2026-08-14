# Zepp Swing Sensors (Baseball / Golf / Tennis) — Research Notes

## What it is
Zepp Labs (Los Gatos, CA) sold a multi-sport BLE motion sensor — Zepp 1 (square, 2013) and
Zepp 2 (round, 2016) — that clips to a golf glove, baseball/softball bat knob, or tennis
racket butt and streams swing data to per-sport apps (Zepp Baseball, Zepp Golf, Zepp Tennis).
Same hardware across sports; different app per sport.

## Why it is abandoned / at-risk
- Zepp Labs was acquired by Huami (Amazfit) in July 2018
  ([China Money Network, 2018-07-27](https://www.chinamoneynetwork.com/2018/07/27/xiaomis-smartwatch-partner-huami-corp-acquires-us-sport-sensor-firm-zepp)).
- Huami renamed itself Zepp Health (2021) and pivoted the brand to smartwatches; the
  sport-sensor line was dropped. Sensors now only circulate second-hand.
- The sport apps are gone from Google Play / App Store (mirrors only). App versions frozen:
  Baseball 3.4.3, Golf 4.4.5, Tennis Classic 2.2.1.
- Community reporting (May 2026): "Zepp Labs discontinued tennis support when its app
  infrastructure was quietly taken offline"
  ([Aura Tide Collective, 2026-05-07](https://www.auratidecollective.com/blogs/performance-lab/zepp-tennis-dead-what-still-works-2026)).
- Amazon listings explicitly say "Discontinued by the Manufacturer"
  ([amazon.sa listing](https://www.amazon.sa/-/en/Zepp-Baseball-Analyzer-Discontinued-Manufacturer/dp/B00I1MYCHG)).

## Local BLE feasibility
- Sensor connects to phone via BLE; the official user guide states the sensor works both
  connected (online mode) and standalone, buffering swings on-device
  ([Zepp Golf user guide PDF](https://images-na.ssl-images-amazon.com/images/I/A1-u5qzL0HS.pdf)).
- Swing capture and 3D analysis run locally in the app (native DSP), not server-side.
- **Cloud dependency to verify**: the apps historically required a Zepp account login;
  with auth servers offline the stock apps may be unusable at first launch. A local
  replacement client is the liberation path.
- BLE layer is plain Java (`com.zepp.ble.*`, ACTION_GATT_* broadcasts, `connectGatt`).
- UUID literals recovered from `com.zepp.baseball` / `com.zepp.zgolf` dex:
  - `d44bc439-abfd-45a2-b575-925416129600` — suspected sensor GATT service base
    (characteristics likely derived from this base in code; confirm via jadx/HCI snoop)
  - `6e400001-b5a3-f393-e0a9-e50e24dcca9e` / `6e400002` — Nordic UART (likely DFU channel)
  - `0000fee9-...` (DuetHealth?), `00002902` CCCD, `00001101` SPP (legacy)
- Zepp Tennis Classic (`com.zepp.ztennis`) dex shows only SPP `00001101` — Zepp 1 may use
  classic Bluetooth SPP on Android in the old app; the newer per-sport apps use BLE.

## APK details (fetched via apkeep, apk-pure)
| Package | Version | SHA-256 |
|---|---|---|
| `com.zepp.baseball` | 3.4.3 | 1746e80520ac05ce720842ee6d0c0b8e9dd39ac02fe5bc7f4a56511de001b466 |
| `com.zepp.zgolf` | 4.4.5 | c4f749a385c352e5454ffa3db6ed325586c13560357b35ead3afd7420f33d714 |
| `com.zepp.ztennis` | 2.2.1 | 2e4e80a5d4c2916f206349b1e6769ad9331afbec429b9c53101738f064be899d |

## Prior art / open questions
- No public community RE of the Zepp BLE protocol found — this would be new work.
- Confirm the full GATT table (service `d44bc439...` characteristics) via jadx of
  `com.zepp.ble` classes or an nRF Connect scan of a live sensor.
- Does the app allow guest/local use without login after first run? Determines difficulty.
- Sensor firmware update channel (Nordic UART) — worth documenting for brick-avoidance.
- Zepp Play Soccer uses a different app/protocol — see `zepp-play-soccer.md`.
