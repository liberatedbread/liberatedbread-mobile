# Pacif-i Smart Pacifier (BlueMaestro) — Research Notes

## What it is
Pacif-i (BlueMaestro Ltd, UK; launched 2015, ~€40) is a pacifier with a
BLE temperature sensor: it broadcasts an infant's temperature to a phone
within ~9 m, logs medication doses, and has a buzzer + proximity
"find my pacifier" feature. Coin-cell powered (~1 year battery).

## Why it's abandoned
- Product discontinued years ago (no retailers; ZOL listing shows "no
  dealers"): https://detail.zol.com.cn/Intelligent-electronic/index395793.shtml
- Latest Android app is v1.14 from **2016-03-01** (APKPure version
  history, `com.pacifi.app`) — untouched for 10 years; delisted from
  Google Play.
- Vendor BlueMaestro itself is still alive (bluemaestro.com sells Tempo
  Disc environmental sensors, 2026) — this is an **orphaned product from
  a live vendor**. No cloud was ever required; the risk is purely app
  rot (target SDK too old for modern Android).

## APK Provenance (two generations fetched)
| Package | Version | SHA-256 | Notes |
|---|---|---|---|
| `com.pacifi.app` | 1.14 (vc 15), 6.4 MB | `e453b933f1f6c19dbdfc22e99dbfacaa45d8eddc7f742727cfa3e35d199f327d` | final app; analyzed below |
| `com.bluemaestro.pacifi` | older gen, 3.0 MB | `485508cb20664745d8229aee5f5afa5ff0ec838a75187748f88e8392d496c212` | also in UCF IoTProfiler dataset |
Both via apkeep (APKPure mirror). jadx decompile clean
(workspace/static/pacifi-smart-pacifier), unobfuscated.

## Protocol: FULLY RECOVERED from static analysis

### Passive mode — BLE advertisements (no connection needed)
From `com/pacifi/app/BLEManagement/ProcessUnconnectedDevice.java`:
- Manufacturer-specific AD structure (type `0xFF`), company ID `0x0133`
  (BlueMaestro; on-air bytes `33 01`), model byte `0xA0` = Pacif-i.
- Byte 4 = opcode; bytes 5–6 = int16 LE value.
  - opcode `0x00` → **temperature = value / 10.0 °C**
  - opcode != `0x00` → value is a pairing security key.
- Complete-local-name AD (type `0x09`) carries the device name.
This matches BlueMaestro's documented Tempo Disc/Pebble advertisement
format, which Home Assistant's `ble_monitor` already decodes
(https://custom-components.github.io/ble_monitor/by_brand) — a working
open-source parser to crib from.

### Connected mode — GATT
From `ConnectedPacifiDevice.java` / `ProcessConnectedDevice.java`:
- Custom service `20655000-02F3-4F75-848F-323AC2A6AF8A`
- Control characteristic `20655001-02F3-4F75-848F-323AC2A6AF8A` (write):
  4-byte command — `[code_lo, code_hi, cmd, 0x00]` where code is the
  16-bit security key from the advertisement, and cmd:
  `0x00` = ACTIVATE, `0xFF` = CONFIRM_PAIR, `0x01` = FIND (buzzer).
- Standard services present: `0x1809` Health Thermometer, `0x180F`
  Battery, `0x180A` Device Information.

## Local feasibility: CONFIRMED
Zero cloud involvement anywhere in the app: temperature arrives in plain
advertisements; history/medication logs are stored locally with PDF/CSV
export (`com/pacifi/app/pdf/Export.java`). A trivial passive BLE listener
(e.g. ble_monitor-style) reproduces the core function today.

## Open questions
- Whether temperature also streams on the `0x1809` Health Thermometer
  characteristic when connected (0x2A1C), or only via advertisements.
- Exact security-key handshake ordering (read advert key → ACTIVATE →
  CONFIRM_PAIR) — readable in `ProcessConnectedDevice.java` if needed.

## Safety
MEDIUM — infant temperature readings inform fever/medication decisions;
a client must display values verbatim and never as clinical advice.
Hardware note: pacifier is a mouth-contact device with small parts —
inspect seals before giving any decade-old unit to a child.
