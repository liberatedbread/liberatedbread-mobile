# Smarter iKettle / Smarter Coffee — Research Notes

## What it is
Smarter Applications Ltd (London) sold the iKettle (1.0 Wi-Fi 2014, 2.0 2015,
3rd gen 2017 FCC id 2AKC5-SMKET01) and Smarter Coffee machines (1st and 2nd gen).
Two generations of connectivity:

- **iKettle 1.0/2.0, Smarter Coffee 1** — Wi-Fi with a **fully local LAN binary
  protocol** (UDP discovery + TCP control, port 2081). Legacy app "Smarter"
  (`am.smarter.smarterandroid`, desc: "Control Smarter Coffee 1 and the
  iKettle 2.0 from anywhere via your smartphone").
- **iKettle 3rd gen, Smarter Coffee 2nd gen** — Electric Imp cloud platform +
  Firebase; newer app "Smarter 3 - Connected Kitchen" (`am.smarter.smarter3`).
  The HA community component (2024) goes through Firebase cloud, not LAN.

## Why it's abandoned (dated sources)
- Electric Imp forums, 2025-12-15 thread "Unbless Smarter iKettle v3 after
  manufacturer seemingly discontinued service" — an Electric Imp staffer replies
  (2025-12-16) "The company is no longer in business."
  (https://forums.electricimp.com/t/unbless-smarter-ikettle-v3-after-manufacturer-seemingly-discontinued-service/6967)
- Google Nest Community, 2025-12-02: multiple users report Smarter account
  linking broken (Google Home auth flow hangs after "successfully linked").
  (https://www.googlenestcommunity.com/t5/Home-Automation/Smarter-kettle-and-coffee-not-connecting-to-google-home/m-p/567974)
- App-store mirrors stopped updating years ago; company dormant.

## Local feasibility
- **Gen 1/2 (iKettle 2.0, Coffee 1): excellent, fully local.** LAN protocol
  publicly documented since 2016: iBrew (github.com/Tristan79/iBrew, discussed in
  Home Assistant Community thread 1870) and aslabicki/Smarter-iKettle-API
  (.NET wrapper, kettle TCP port 2081, water-level sensor calibration values
  2080–2250). No cloud needed after initial Wi-Fi provisioning.
- **Gen 3 (iKettle 3.0, Coffee 2.0): poor.** Device refuses connections on
  2000/2081 (HA thread 1870 p.6, 2024-04); control path is Electric Imp/Firebase
  cloud, now orphaned with the company dead. "Unblessing" the Electric Imp would
  let the device join a new Wi-Fi but no local API is known. Greenfield.

## APK
- `am.smarter.smarterandroid` (legacy, v3.2.5) — apkeep/apk-pure, fetched
  2026-08-03, SHA-256 `28e9774de3f9896b7a13b50ceac37f5741ee2111bf6d600416de5799d9537dbb`, 6.9 MB.
- `am.smarter.smarter3` (XAPK) — apkeep/apk-pure, fetched 2026-08-03,
  SHA-256 `192b4315a71690dc788a452687b3d10f494ac0ba2da44ad95cca1134374069fd`, 24 MB.

## Protocol recovered (jadx triage of legacy app)
Transport: UDP 2081 broadcast discovery (`c/b.java`, 2-byte payload `{100,126}`),
TCP control session; **all frames terminated by `0x7E`**; reads loop until 0x7E.
Kettle opcodes from `models/d.java` (semantics from KettleControlPanel call sites,
partially inferred):

| Frame (hex) | Meaning |
|---|---|
| `15 <temp> <units> 7E` | Start heat to target temp (°C), units flag |
| `16 7E` | Sent on control-panel stop path (stop/interrupt heat?) |
| `30 7E` | Stop heating |
| `2C 7E` | Sent on panel exit (end session / close command?) |
| `2E 7E` → reply `2F …` | Status query (temp, water sensor, on-base) |
| `1F <keepWarmMin> <temp> <babyTemp> 7E` | Set kettle defaults |
| `19 <value> 00 7E` | Set scalar setting (keep-warm time?) |
| `6E 7E` | Firmware-update init (FirmwareUpdateService) |
| `70 <len32> 7E` + 261-byte blocks `7E 7E 7E` | Firmware image upload |

Cross-check against iBrew's published command list before writing the spec.

## Open questions
1. Precise semantics of opcodes 0x16/0x2C/0x30 (stop vs end-session) — reconcile
   with iBrew.
2. Status reply (`2F`) byte layout incl. water-sensor encoding (aslabicki notes
   raw range 2080–2250).
3. Gen-3: any local fallback after Electric Imp unblessing? Needs hardware.
4. Smarter Coffee 1 command set (same framing, different opcodes) — in same app,
   `CoffeeControlPanel.java`.

## Safety
Kettle = unattended heating appliance. Water-level sensor reading must gate any
boil command (dry-boil risk); the hardware has a thermostat cutoff but do not
rely on it.
