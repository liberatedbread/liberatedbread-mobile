# Gerbing Thermogauge — APK Acquisition Attempt Log

## Target
- **Package**: `com.gyde.thermogauge`
- **Status**: **APK NOT ACQUIRED** — all mirror downloads blocked by Cloudflare
- **Unpublished**: April 5, 2024 from Google Play

## Acquisition Attempts

### 1. apkeep (Google Play)
- **Result**: FAILED — app unpublished, not available on Play Store

### 2. APKPure Direct Download
- URL: `https://d.apkpure.com/b/APK/com.gyde.thermogauge?version=latest`
- **Result**: Cloudflare challenge page (HTML, "Just a moment...")
- Bytes returned: ~5KB HTML, not APK

### 3. APKCombo
- Page loads successfully (HTTP 200, 80924 bytes)
- Download URL found: `/gerbing-heated-clothing-ther/com.gyde.thermogauge/download/apk`
- **Result**: JavaScript-rendered download button — direct curl cannot trigger download
- Checkin API: `https://apkcombo.com/checkin` (xid: `01a1200x20240308`)
- Cloudflare blocks programmatic download requests

### 4. cloudscraper (Python)
- **Result**: Import failed — dependency conflict between `urllib3`, `requests-toolbelt`, and `cloudscraper`

### 5. APKPure via cloudscraper
- Not attempted due to cloudscraper import failure

### 6. APKMirror
- **Result**: No results for "gerbing thermogauge"

### 7. Uptodown
- **Result**: Cloudflare challenge (HTTP 403)

### 8. APKMonk
- **Result**: DNS resolution failure

### 9. APK Support / APKFab
- **Result**: No direct download links found

### 10. archive.org (Wayback Machine)
- Google Play page snapshot returns Wayback Machine landing page
- No APK binary archives found

## Recommended Acquisition Paths

### Option A: ADB Pull (BEST)
```bash
./scripts/pull_apks_adb.sh com.gyde.thermogauge
# or directly:
adb shell pm path com.gyde.thermogauge
adb pull <path>/base.apk workspace/apks/adb/com.gyde.thermogauge.apk
```
Ask in heated-gear/motorcycle communities — 1,000+ installs means copies exist on phones.

### Option B: Browser-Based Download
Use a real browser with JavaScript to download from:
- https://apkcombo.com/gerbing-heated-clothing-ther/com.gyde.thermogauge/download/apk
- https://apkpure.com/gerbing-heated-clothing-%E2%80%93-ther/com.gyde.thermogauge

Record SHA-256 and compare across mirrors.

### Option C: Raspberry Pi / Selenium
Use Selenium/Playwright to automate browser download from apkcombo.

## Known Facts (from Target Doc)
- Version: 1.07 (build 107), ~29MB
- minSdk: Android 4.3 (BLE introduced in 4.3)
- Expected: Native Java, GATT-based, likely serial bridge module
- UUID candidates: `0xFFE0`/`0xFFE1` (HM-10), Nordic UART, `0xFFF0` family

## Once APK is Acquired
1. Record SHA-256
2. Decompile: `jadx -d decompiled/ [apk]`
3. Grep for UUIDs: `grep -rP '[0-9a-f]{8}-[0-9a-f]{4}...' decompiled/`
4. Find GATT write path and command table
5. Document heat settings, battery status, lock feature
6. Write `device-spec.yaml`
