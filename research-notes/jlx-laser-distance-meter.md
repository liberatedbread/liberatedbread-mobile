# Johnson JLX LDM330 / LDM130 (Winho platform) — Research Notes

Desk research + APK static analysis only. **No hardware was in hand; nothing
here is verified over the air.** All protocol facts are derived from the
decompiled companion app.

## APK Provenance

- **App**: "Measure-Up" by Johnson Level (listing contact
  `lmorales@johnsonlevel.com`); Play listing currently shows v1.6 /
  ~8K downloads per chrome-stats; the APKPure mirror serves v1.0.1.
- **Package**: `com.winho.measure_up`
- **Source**: `./scripts/fetch_apks_apkeep.sh com.winho.measure_up` (APKPure)
- **APK SHA-256**: `fc7ac7272f8604bc3636874055a4d6fe7f6b5e989ee02db1255ce9a9e9fd9deb`
  (bare APK, ~3.7 MB, versionCode 2 / versionName 1.0.1)
- **Framework**: native Java, old-school (support-library era, Fabric/Crashlytics
  bundled), **not obfuscated** — class/method names intact.
- **Static output**: `workspace/static/jlx-laser-distance-meter/com.winho.measure_up/`
  (gitignored) via `./scripts/run_static_target.sh jlx-laser-distance-meter`.
  Note: that script's summary.md escaping is buggy (backslash-backtick
  expansion garbles the summary); jadx/apktool decompilation itself worked.

## The Winho OEM platform (rebadge family)

`com.winho.Constants` / `AppName.java` / `AppType.java` show the single app
codebase builds these branded variants:

```
AppName: IM2, MEASURECAM, TargetCAM, StarrettSTR3, StarrettSTR3MeasureCam,
         StarrettSTR3TargetCam, MeasureMate, RonixMeasureBox, RonixMeasureCam,
         RonixTargetCam, MeasureUp, OTHER
AppType: ALL, MEASURECAM, TargetCAM, OTHER
```

This build is `AppName.MeasureUp` / `AppType.MEASURECAM`. Implication: Johnson
LDM130/LDM330, Starrett STR3-family laser meters, Ronix-branded meters, and
"Measure Mate"-branded meters likely all speak the same protocol. Only the
Johnson app was analyzed; the siblings were not fetched or diffed.

The vendor app's device picker is an **unfiltered BLE scan** — every
peripheral is listed and the user taps the meter
(`BluetoothSettingActivity.java`, `startLeScan` with no ScanFilter). So the
advertised local name and advertised service UUIDs are **not recoverable
from the APK**.

## BLE GATT layout (from `com/winho/ble/step/BleService.java`, `BleAttribute.java`)

| UUID | Role |
|------|------|
| `0000f151-0000-1000-8000-00805f9b34fb` | Command characteristic (write, app→device) |
| `0000f154-0000-1000-8000-00805f9b34fb` | Data characteristic (notify, device→app) |
| `00002902-0000-1000-8000-00805f9b34fb` | CCCD used to subscribe `f154` |

The app iterates **all** discovered services looking for these two
characteristic UUIDs (`set_151_154_Characteristic`), so the containing
service UUID is unpinned. `0000f150` is the conventional guess (service
F150 + characteristics F151..F154) — hypothesis only.

## Connection choreography (decompiled)

1. Connect GATT (autoConnect=true), discover services.
2. On `onServicesDiscovered`: enable notifications on `f154` (CCCD write),
   then write the **init frame** `03 0D 0A 03 0D 0A` to `f151`
   (`sendInitBle_151`). The app comment notes the device answers with a
   beep.
3. On `f154` notification, first byte-compare against fixed control frames:
   - `Ztest01` + 3 NUL → write init frame again; mark connected.
   - `Ztest02` + 3 NUL → write **link keep-alive** (below); marks the link
     as held.
   - `Zbleoff` + 3 NUL → device radio powering down; UI shows disconnect and
     the app auto-reconnects (`bleServiceHelper.reConnection()`).
   - anything else → parse as a measurement frame.
4. The **measure command** (`sentMeasure`) is only sent from the camera
   measure screen (`TCameraMenCam`); normally the meter pushes readings when
   its own button is pressed.

## Command frames (write to `f151`)

13-byte checksummed frame: `'#' 0x0A <ascii command> <NUL pad to 12> <cksum>`
where `cksum = sum(bytes 0..11) & 0xFF`.

| Command | Bytes | Check |
|---------|-------|-------|
| measure | `23 0A 6D 00×9 9A` | 0x23+0x0A+0x6D = 0x9A ✓ |
| link    | `23 0A 4C 69 6E 6B 00×6 BB` | sum = 0x1BB → 0xBB ✓ |

Init is a separate fixed 6-byte frame with no checksum: `03 0D 0A 03 0D 0A`.

## Measurement frames (notify on `f154`, 10 bytes ASCII)

Layout per `BleService.measureData()` + `changeUnit.java`:

- byte 0: prefix/type character — **discarded** by the app; meaning unknown
  (possibly length/area/volume/angle discriminator).
- bytes 1–6: fixed 6-character ASCII decimal, parsed via
  `Float.parseFloat`. **Always meters** — proof: for unit codes b/c the app
  multiplies by 3.28084 (m→ft) / 39.37 (m→in) for display.
- byte 7: unit code = the meter's **display** unit:
  `a`=m, `b`=ft, `c`=in, `d`=ft'in" 1/32, `e`=in 1/32, `f`=in 1/16,
  `g`=in 1/8, `h`=in 1/4, `i`=in 1/2, `j`=呎 (Taiwanese/Chinese foot,
  app converts m×3.3).
- bytes 8–9: NUL padding.

Example decode: `?? "12.345" 'a' 00 00` → 12.345 m, display in meters.

Error handling: `TCameraMenCam.displayData` guards against the literals
`error1`…`error6`, so measurement failures presumably arrive as ASCII
`errorN` frames (hypothesis — those strings never originate in the app).

**Angle**: the LDM330 has an integrated angle sensor (digital level,
indirect measurement per the product page), but no angle code path exists
in the recovered BLE code — every frame carries one scalar. Angle is either
on-device-only or multiplexed via the unknown byte-0 prefix. Needs a capture.

## Known facts vs hypotheses vs verified

- **Known (from decompiled code)**: both characteristic UUIDs; CCCD usage;
  the three control strings; init/link/measure byte sequences; checksum =
  8-bit sum; measurement frame layout and unit table; value always meters;
  unfiltered scanning; no pairing/bonding.
- **Hypothesis**: service UUID 0xF150; error1..6 as device error frames;
  byte-0 prefix as a measurement-type discriminator; sibling brands
  (Starrett/Ronix/MeasureMate) speaking this protocol.
- **Verified against hardware**: nothing.

## Cross-brand survey (similar Bluetooth LDMs)

Source: [ImageMeter supported Bluetooth devices](https://www.imagemeter.com/manual/bluetooth/devices/)
(the broadest catalog: which models transmit units, support remote trigger,
or are encrypted), plus GitHub/forum projects.

- **Winho platform** (this target): not listed by ImageMeter at all; no
  prior public RE found.
- **Mileseey**: older models (P7/T7/R2B/M120/DT20-old, plus Suaoki
  rebadges) use an open BLE protocol that transmits the unit. Newer models
  (DT20-new, D5/D5T/D9 Pro, S50, Rock K3) are listed unsupported — DT20-new
  switched to an encrypted protocol; D9 Pro is hung off the Tuya Smart Life
  app ([EEVblog thread](https://www.eevblog.com/forum/projects/mileseey-d9-pro-laser-distance-measure-ideas-for-interfacing-via-bluetooth/)).
- **Bosch**: GLM 50 C / 100 C / PLR 30–50 C speak Bluetooth Classic SPP
  with a documented protocol ([philipptrenz/BOSCH-GLM-rangefinder](https://github.com/philipptrenz/BOSCH-GLM-rangefinder),
  remote trigger supported). The newer xx-27 C / GLM 120–400 C generation is
  BLE + MeasureOn app; partially RE'd in [pklaus/bsch](https://github.com/pklaus/bsch).
- **Leica DISTO**: BLE with a vendor-published interface document; widest
  third-party support (D1/D2/X3/X4/D510/D810/S910…); D810/S910 must be set
  to "Unencrypted App Mode".
- **CEM iLDM** (iLDM-150/-25/-80C): open BLE protocol with unit + remote
  trigger; Ridgid LM400 may be a CEM rebadge.
- Others in the ImageMeter table worth noting: Stabila LD250 BT/LD520,
  Stanley TLM99s(i)/TLM165si, Sndway SW-GQ series (angle), UNI-T LMxxB,
  Würth WDM, DeWalt DW03050, Hilti PD-I — mostly BLE, mostly open.

## Blocked without hardware

1. Advertised local name + advertised service UUIDs (app scans unfiltered).
2. Actual containing service UUID for f151/f154.
3. Byte-0 prefix semantics (length vs area vs volume vs angle frames).
4. Whether the angle sensor reading is exposed at all.
5. Error frame formats (`error1`..`error6` guess).
6. Whether sibling brands' builds share the exact UUIDs (fetch and diff
   `StarrettSTR3*` / `Ronix*` APKs as follow-up).

Next experiments with hardware: nRF Connect scan (name, services) → connect,
subscribe f154, write init → press measure on the meter and capture frames
in each unit mode → trigger an out-of-range error → check LDM330 angle
readout frames.
