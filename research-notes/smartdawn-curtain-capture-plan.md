# SmartDawn 400 RGB LED Smart Curtain — Hardware Capture Plan

Date: 2026-08-08
Target: SmartDawn "400" smart curtain light (400 LEDs, almost certainly a
20×20 pixel matrix; SmartDawn curtain SKUs are JY25CUT-series, e.g.
JY25CUT10400502 — the "400" in the marketing name maps to the LED count,
width/height are reported by the device itself).
Spec: `device-specs/devices/smartdawn-smart-lights.yaml`
Docs: `docs/devices/smartdawn-smart-lights.md`
Status: protocol fully mapped from app code; **zero over-the-air captures
exist**. This plan is the checklist for the first hands-on session with the
owner's unit.

---

## 1. APK provenance (what the spec was verified against)

| Artifact | Source | SHA-256 | Notes |
|---|---|---|---|
| SmartDawn v1.2.4 (`com.daniaokeji.smartdawn`, versionCode 10204) | Vendor CDN: `http://file.daniaokeji.com/download/SmartDawn.apk` | `58aaf3d6027c59aa5ab7876930fb16661d224d28220f58f227e35c2ddeca07aa` | Fetched 2026-08-08; identical hash to the 2026-08-03 research-store copy (`~/research/smartdawn-smart-lights/artifacts/SmartDawn.apk`). Google Play and APKCombo also carry v1.2.4 but are login/captcha gated; APKPure/Aptoide/Huawei do not index the app. |
| SuperPix v4.4.1 (`com.daniaokeji.cs`, sibling app, same platform) | apkeep / APKPure (XAPK) | `7362e15819a9ebf095539bb33790499d36abaf211dabfe23898541fc5e6159fe` (XAPK) | Cross-check only. |
| SmartPixels legacy (`com.daniaokeji.lights` family) | Vendor CDN: `https://cdn.daniaokeji.com/download/smartpixels.apk` | `f245f05c50082a40af6f19d74d3c566f12a745d4f059b085adad539709dc31b3` | Cross-check only. |

Decompiles (jadx) live in `workspace/static/smartdawn/{smartdawn-1.2.4,
superpix-4.4.1,smartpixels}/`. APKs in `workspace/apks/`.

---

## 2. Identifying the curtain on the first BLE scan

Watch for an advertisement matching ALL of:

- **Local name**: 6–8 characters starting with `DN` (case-insensitive) —
  the SmartDawn app's own filter (`MainActivity.bleCheckName`: trimmed
  length 6–8, `toUpperCase().startsWith("DN")`). Expect something like
  `DNxxxxxx`.
- **Service UUID in adv data**: `00000074-1972-1925-3022-077119514e44` —
  the app scans with a `ScanFilter` on exactly this UUID
  (`BleUtils5.java:312`).
- **Manufacturer-data record**: 14 bytes, layout (from `MFD.java`):
  fw_ver u16 / fact_id u16 / prod_type u16 / width u8 / height u8 /
  group u16 / vendor u16 / flags u8 (low nibble = runMode, bit 4 =
  isLeader) / pad u8. For a 20×20 curtain expect width=0x14, height=0x14.
  *This is the pre-connect answer to "is it really 400 LEDs".*
- **MAC OUI**: UNKNOWN. Do not rely on it; record it. The controller SoC
  is unidentified (FCC ID unresolved), so we cannot even guess the OUI
  vendor. Capture the full MAC and look it up in the IEEE registry — if
  the same OUI shows up on the owner's other Daniao-platform devices it
  becomes a rankable (never decisive) identification signal worth adding
  to the spec once the `mac_prefixes` schema work lands
  (branch `claude/device-support-mac-prefix-k3lqj3`).

Quick check: `bluetoothctl scan on` or `nRF Connect` — a DN-prefixed name
plus the 00000074-… service UUID is effectively conclusive; nothing else
in the repo's 78 specs advertises that UUID.

---

## 3. Captures to take (priority order)

### 3.1 GATT dump (5 min, no app needed)

Connect with nRF Connect / `bluetoothctl` and dump services.

Expected (from `BleUtils5.java:64-70`):

| UUID | Name | Properties to confirm |
|---|---|---|
| `00000074-1972-1925-3022-077119514e44` | Daniao DDP Service | sole custom service |
| `01020074-…` | DDP Write | write (app uses WRITE_TYPE_NO_RESPONSE) |
| `01010074-…` | DDP Notify | notify |
| `02020074-…` | BIN Write | write |
| `02010074-…` | BIN Notify | notify |
| `27923001-2072-…` | Uploader | write — **note the 2072**, every other UUID uses 1972 |

Answers: does the shipping hardware expose exactly these five
characteristics? Any extra services (OTA service of the BLE SoC vendor,
Device Information) that identify the chipset? Do the Uploader/BIN
characteristics accept writes without the app session?

### 3.2 Connect handshake + GATT notify dump (10 min)

Enable Android **HCI snoop log** (Developer Options), then in the vendor
app: connect to the curtain, wait idle 10 s, disconnect.

Answers:

- MTU actually negotiated (app requests 512, payload = MTU−3, fallback 20 —
  what does the curtain accept?)
- Exact inbound burst after subscribe: expect `M_DEVICE_INFO_NOTIFY`
  (mt=2103) — decode the DeviceInfo protobuf: width, height, chipType,
  colorOrder, fwVer, lednums (=400?), productType.
- Confirm the app sends `M_TIME_SYNC` (mt=2504) first, and the fragment
  header shape on the wire: `[serial][total][remaining][tag]` with tag=0
  on the DDP channel.

### 3.3 Color-change / effect-change capture (10 min)

With HCI snoop still on: change a solid color, change brightness, switch
one effect via the app.

Answers:

- Which mt the UI actually uses for a solid color (`M_SET_COLOR_MODE`
  2603 vs `M_SET_COLOR_EXT` 2628 vs `M_SET_PALETTE` 2601) and the exact
  protobuf payloads (`SetColorMode {mode, red, green, blue}` per
  p2p.proto) — the spec marks SimpleMessage field semantics "medium
  confidence"; this capture makes them confirmed.
- Brightness range on the wire (UI slider 0–100? raw 0–255?).
- `M_PLAY_EFFECT` (mt=2606) payload shape for effect selection.

### 3.4 Image/doodle upload with animation (20 min)

In the app: draw a small doodle on the canvas, then use photo-to-light,
then a scrolling text, then a multi-frame animation install.

Answers (the biggest open questions):

- **Pixel path on hardware**: spec now says the live path is
  `M_DOODLE_START` (2701) → BIN-channel buffer arrays tagged
  TUTU_DOODLE(1)/TUTU_RESTORE(4) → `M_DOODLE_END` (2702), with a
  palette-indexed ~200-byte chunk format. Confirm the tag byte values
  (1/2/4) on the wire and the chunk header `[x][y][colorCount]`.
- Does ANY flow emit standard DDP DISPLAY packets (datatype 0x01, flag
  0xE1)? The `mkOrginDdp` encoder ships in the app but has no call sites —
  is it truly dormant, or does some mode (video upload? `vidUpload` flag
  in DeviceInfo) use it? This decides whether the `daniao_ddp` handler
  needs the DDP-packet encoder at all.
- Animation install: capture `M_START_INSTALL_ANIMATION` (2918) /
  `M_INSTALL_ANIMATION_PACKET` (2919) / `M_END_INSTALL_ANIMATION` (2920)
  on the BIN channel — chunk size, acks on BIN Notify
  (`M_UPLOAD_PROGRESS` 2933?), and the file format header.
- What frame rate does an on-device animation run at, and is there a rate
  field in the install metadata? (Needed for `min_frame_interval_ms` /
  `default_frame_interval_ms` in the spec's image_upload feature.)

### 3.5 Firmware / uploader characteristic (only if an update is offered)

Check the app's firmware-update screen; if it offers an update, capture
the whole flow. Otherwise probe passively.

Answers:

- OTA query: `https://daniaokeji.com/led/ota?<product,fw,...>` — capture
  the actual parameters (need the product tuple from DeviceInfo) and the
  returned firmware URL; archive the firmware image.
- Confirm the OTA writes go to the Uploader characteristic
  (`27923001-2072-…`) and the mt sequence 2912/2913/2914.
- **Do not let the update complete if the owner wants to keep the current
  firmware for re-testing** — coordinate before tapping.

---

## 4. Exact open questions each capture settles

| # | Question | Capture |
|---|---|---|
| Q1 | Real matrix size of the "400" (20×20?) and lednums value | adv manufacturer data (§2), DeviceInfo (3.2) |
| Q2 | MAC OUI / chipset identity | scan log + GATT dump extra services (§2, 3.1) |
| Q3 | Negotiated MTU and fragment pacing on real hardware | 3.2 |
| Q4 | Solid-color command + payload semantics (2603 vs 2628) | 3.3 |
| Q5 | Brightness wire range | 3.3 |
| Q6 | Doodle BIN chunk format & tag bytes as specified | 3.4 |
| Q7 | Is DDP DISPLAY (0x01) streaming ever used, or dead code? | 3.4 |
| Q8 | Animation install flow, acks, frame-rate metadata | 3.4 |
| Q9 | OTA endpoint params + uploader behavior | 3.5 |
| Q10 | Does `M_DEVICE_INFO_NOTIFY` arrive unsolicited post-connect, or only after `M_GET_RUNNING_STATUS` (2104)? | 3.2 |
| Q11 | Wi-Fi hardware present (second radio / UDP 4048 listener)? | GATT/DeviceInfo `netstat`/`type` fields (3.2); optional: `nmap -pU:4048` on the LAN |
| Q12 | PUSH-flag frame-latch semantics (if DISPLAY packets appear) | 3.4 |

## 5. What to update afterwards

- Spec `verification` flags: flip the BLE setup method to verified, mark
  color/brightness command payloads confirmed, correct the pixel-path
  notes if Q6/Q7 differ.
- Add `width`/`height` (or a fixed resolution) for this variant once Q1 is
  answered; add `min_frame_interval_ms` if Q8 yields a rate.
- Add MAC OUI to identification once the `mac_prefixes` schema lands
  (upstream branch, not yet merged).
- `docs/devices/smartdawn-smart-lights.md` Hardware table: chipset, FCC ID
  (check the label on the owner's controller — resolves the long-standing
  FCC gap and unlocks internal photos).

## 6. Session logistics

- Owner's Android phone with the SmartDawn app (or a spare): enable
  Developer Options → HCI snoop log BEFORE opening the app; pull
  `/sdcard/Android/data/btsnoop_hci.log` (path varies) via adb after.
- A second phone running nRF Connect for the passive GATT work keeps the
  vendor-app session clean.
- Keep the curtain powered through the whole session; note the physical
  mode button behavior (press = next effect, hold = off, per FCC manual)
  if captures look desynced.
