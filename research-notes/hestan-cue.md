# Hestan Cue Smart Cooking System — Research Notes

## What it is
Hestan Cue is a guided-cooking system from Hestan Smart Cooking: a portable 1600 W
induction cooktop plus pans/pots with a Bluetooth "smart capsule" in the handle
(temperature sensor). Both the burner and the cookware are BLE peripherals; the
phone app connects to both and orchestrates closed-loop temperature control
(burner power follows the pan's surface temperature). Sold 2017–2024ish, ~$250–500.

## Why it's abandoned (dated sources)
- Official banner on hestancue.com: "we've made the decision to retire the Hestan
  Cue app on July 21, 2025" (https://hestancue.com/, confirmed 2026-08).
- Support article "What is happening to the Hestan Cue app?" (2025-07-01):
  all guided recipes and content removed (https://support.hestancue.com/en/support/solutions/articles/19000166286).
- Support article (2025-07-01): after 2025-07-21 cooktop + cookware "will no
  longer be able to use any smart functions" — app-mediated BLE control is dead
  (https://support.hestancue.com/en/support/solutions/articles/19000166287).
- Hardware remains manually usable (burner has on-unit controls); the *closed-loop
  temperature control* — the entire point of the product — required the app.

## Local BLE feasibility
Strong. Per CNET (2017-04) the architecture is pure phone↔device BLE; there is no
hub and no evidence the burner needs the cloud for control — the cloud served
recipes/account/firmware. A local BLE client could set target temperature on the
burner and subscribe to pan temperature notifications. No community RE found as of
2026-08 — this is a greenfield protocol-spec opportunity.

## APK
- **Package**: `com.hestan.cue` ("Hestan Cue", Hestan Smart Cooking)
- **Source**: apkeep, apk-pure — fetched OK 2026-08-03 (app retired from Play but
  still mirrored)
- **SHA-256**: `8cc87db5e363822b1d9f8d029c51bf41c709554ce7e45d16476ea4d7064c388c` (77 MB APK)
- **Framework**: native Android (Kotlin/Java, obfuscated), Realm DB, AWS Cognito
  (account cloud), Nordic DFU library, RxAndroidBle/polidea-style BLE stack

## BLE UUIDs recovered (jadx static triage, obfuscated names)
From `sources/ec/c.java`, `ec/b.java`, `tb/o.java` (roles inferred from
`DeviceType` switch in `ec/c.java`):

| UUID | Role |
|------|------|
| `00001541-6209-4984-454e-f27d42fb55e3` | Induction **burner** primary service |
| `00001542-6209-4984-454e-f27d42fb55e3` | Burner characteristic (case 0) |
| `00001543-6209-4984-454e-f27d42fb55e3` | Burner characteristic (case 1) |
| `00001545-6209-4984-454e-f27d42fb55e3` | Burner characteristic (case 2, read/notify) |
| `00001546-6209-4984-454e-f27d42fb55e3` | Burner characteristic (case 3) |
| `00001547-6209-4984-454e-f27d42fb55e3` | Burner characteristic (case 4) |
| `0000fa81-8a11-4222-9610-53f79479ca03` | **Thermometer** (pan capsule) service |
| `0000fa83-8a11-4222-9610-53f79479ca03` | Thermometer characteristic (bool state) |
| `0000fa84-8a11-4222-9610-53f79479ca03` | Thermometer data — 6 bytes, little-endian (temp reading?) |
| `0000fa85-8a11-4222-9610-53f79479ca03` | Thermometer characteristic |
| `00001530-1212-efde-1523-785feabcd123` | Nordic legacy DFU service (firmware update) |
| `00001535-...-785feabcd123`, `00001537-...` | DFU characteristics |

Device model enum (`tb/s.java`): `CUE_BURNER_V1`, `_100V`, `_220V`,
`_220V_THERMOMIX` variants plus thermometer device types.

## What needs cloud
Recipes/content and account (AWS Cognito) are gone with the app sunset; firmware
update path (Nordic DFU) is local BLE but needs the DFU image extracted from the
app. Core temperature control is believed fully local BLE — unverified by capture.

## Open questions
1. Exact command encoding for set-temperature / power on the burner service
   (which of 1542/1543/1545 is the write char; byte layout) — needs HCI snoop or
   deeper decompile of `ec/c.java`.
2. Advertising name prefixes ("Cue"? "Hestan"?) — not recovered statically.
3. Does the burner enforce an app handshake/auth before accepting writes?
4. Whether the 220 V/Thermomix variants share the same GATT layout.

## Safety
Induction burner = heating appliance. Any local control implementation must clamp
target temperatures and respect over-temp cutoffs; recommend read-only
(thermometer) mode first.
