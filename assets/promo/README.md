# Store promo assets

Upload-ready listing art. Not bundled into the app (`pubspec.yaml` lists its
assets explicitly).

| File | Use | Spec |
| --- | --- | --- |
| `icon_512.png` | Google Play hi-res icon | 512×512, 32-bit PNG |
| `feature_graphic_1024x500.png` | Google Play feature graphic | 1024×500, RGB PNG (no alpha) |
| `screenshots/framed/*.png` | Play phone screenshots (captioned) | 1080×1920 (9:16), RGB PNG, < 8 MB each |
| `screenshots/raw/*.png` | The un-captioned frames the above are built from | Native emulator resolution (1080×2400) |

The App Store uses the 1024×1024 icon already in
`ios/Runner/Assets.xcassets/AppIcon.appiconset/`; its screenshots must come
from an iPhone simulator at the exact sizes Apple asks for (see
`docs/APP_STORE_SUBMISSION.md` Step 8).

## Regenerating

Icon, feature graphic and framed screenshots are generated from
`tool/branding/brand.json` + `app_icon_mascot.png` and the raw shots:

```bash
python3 tool/branding/generate_promo.py
```

Captions live in `CAPTIONS` at the top of that script, keyed by raw file stem.

## Recapturing the raw screenshots

They come from the scripted walkthrough in mock mode, run on the Android
emulator with the shot server capturing over adb:

```bash
adb -s emulator-5554 reverse tcp:8099 tcp:8099
E2E_SHOT_DIR=/tmp/shots E2E_ADB_SERIAL=emulator-5554 python3 scripts/e2e_shot_server.py &
flutter test integration_test/e2e_walkthrough_test.dart -d emulator-5554 \
  --dart-define=LIBERATED_BREAD_MOCK=true --dart-define=E2E_HIDE_DEBUG_BANNER=true
```

The framer crops off the emulator's blank (black) status bar automatically.

Then copy the frames you want into `screenshots/raw/` under the names in
`CAPTIONS`. For a clean status bar, turn on SystemUI demo mode first
(`adb shell settings put global sysui_demo_allowed 1`, then the
`com.android.systemui.demo` broadcasts for clock/battery/network).
