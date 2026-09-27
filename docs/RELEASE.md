# Releasing

How a build gets to Google Play and the App Store, and how a bug report from it
gets back to its commit. The Apple account side (certificates, profiles, App
Store Connect, export compliance, listing copy) is in
[APP_STORE_SUBMISSION.md](APP_STORE_SUBMISSION.md); this page does not repeat it.

## Versions, tags, build numbers

- **Version**: the `X.Y.Z` in `pubspec.yaml`'s `version:` line. That is the
  only place it lives.
- **Tag**: `vX.Y.Z`, on the commit you ship. Never move a tag once a build from
  it has been uploaded.
- **Build number**: both stores need it to rise on every upload.
  `scripts/release.sh` reads it off the clock, so nobody bumps it and the
  pubspec `+N` is ignored.
- **Stamp**: the app's record of which build it is. `scripts/release.sh`
  passes in `git describe --tags --always --dirty` as `AppConstants.appVersion`.

| Stamp | Means |
| --- | --- |
| `v0.1.0` | built from the tag |
| `v0.1.0-3-g1a2b3c4` | three commits after `v0.1.0`, at commit `1a2b3c4` |
| `…-dirty` | built with uncommitted changes, so no commit fully describes it |
| `dev build` | not built by `release.sh`, e.g. a `flutter run` or a CI smoke build |

The stamp appears at the top of Diagnostics, on line one of **Copy for a bug
report**, and as the app version on the user's Home Assistant device page.
Neither store shows users a commit, so the stamp is how a report gets back to
source.

## Cutting a release

1. If the version is changing, edit it in `pubspec.yaml` and commit.
2. Run `./scripts/test.sh`. If the Wi-Fi path changed, also run
   `./scripts/ci-netdisco-tests.sh`.
3. Tag the commit and push the tag:
   ```bash
   git tag -a v0.1.0 -m "Liberated Bread 0.1.0"
   git push origin v0.1.0
   ```
4. Build from a clean checkout of the tag:
   ```bash
   ./scripts/release.sh android   # -> build/app/outputs/bundle/release/app-release.aab
   ./scripts/release.sh ios       # -> build/ios/ipa/*.ipa (on the Mac; runbook Step 5)
   ```
   The script refuses to build if HEAD is tagged with a version that disagrees
   with `pubspec.yaml`.
5. Before uploading, install each build on a real phone. Check that Diagnostics
   shows the tag, and on the iPhone run a Wi-Fi scan.
   `./scripts/verify_ios_app.sh build/ios/ipa/*.ipa` checks the signed
   multicast entitlement, but only a real LAN proves discovery works.
6. Upload the AAB in the Play Console. Upload the IPA with Transporter (runbook
   Step 5).

## Android signing

Release builds sign with the upload key named in `android/key.properties`,
which is gitignored:

```properties
storeFile=/absolute/path/to/upload-keystore.jks
storePassword=…
keyAlias=upload
keyPassword=…
```

Without that file the build falls back to Android's shared debug key and logs a
warning, and Play rejects the result. Create the key once:

```bash
keytool -genkey -v -keystore upload-keystore.jks -keyalg RSA -keysize 2048 \
  -validity 10000 -alias upload
```

Enrol in Play App Signing so Google holds the app-signing key and can reset a
lost upload key. Back the upload key up off every build machine anyway.

## Google Play, the first time

- **Data safety**: declare no data collected or shared. The banner check is
  anonymous.
- **Ads**: answer *yes*. The banner is an affiliate promotion, and declaring
  "no ads" while shipping it is a policy violation.
- **Location permission declaration**: required, because the app requests
  `ACCESS_FINE_LOCATION`. File it early, since review can take days to weeks.
  The justification: Android 11 and earlier need location permission for any
  BLE scan, and the app never reads a location. If it is refused, the
  alternative is `neverForLocation` on `BLUETOOTH_SCAN` with the location
  permissions capped at API 30.
- **Listing**: content rating, target audience (not children), a 512×512 icon,
  a 1024×500 feature graphic, and at least two phone screenshots. For the
  screenshots, run `./scripts/run-android.sh --mock` and capture with
  `adb exec-out screencap -p > shot.png`.

## Websites

These must resolve for as long as the listings exist. The first-launch Terms
gate links `/privacy/` and `/disclaimer/`, so those two must be live before
anyone opens a store build.

| URL | Needed by |
| --- | --- |
| `liberatedbread.com/privacy/` | both stores (required), the Terms gate |
| `liberatedbread.com/disclaimer/` | the Terms gate, the App Store description |
| `liberatedbread.com/` | App Store support + marketing URL; needs a visible contact link |
| `liberatedbread.com/app/banner.json` | the app (live; keep it https) |
| `liberatedbread.com/shop/` | the banner's link (live) |

The privacy page should say what the code does:

- no accounts, analytics or tracking;
- device control stays on the local network;
- the only connections beyond the user's own devices are the anonymous banner
  check, spec-pack downloads the user starts, and their own Home Assistant
  server;
- the banner is an affiliate link.

`ios/Runner/PrivacyInfo.xcprivacy` makes the same claims; keep the two in step.

## Review

The likeliest first rejection is that **the reviewer has no IoT devices**.
Under Guideline 2.1, an app that controls hardware the reviewer does not own
looks like it does nothing. In the review notes, say:

- the app controls Bluetooth and local-network devices;
- it has no accounts and no server;
- "no devices found" is correct behaviour on a network with no supported
  hardware.

Attach a video of a mock-mode build on a Simulator
(`xcrun simctl io booted recordVideo demo.mp4`) and say that it shows simulated
devices. The rest of the Apple side, including the Guideline 2.2 wording rules,
is in the runbook.

## When a bug report arrives

Line one of the report is the stamp. `git checkout` the tag, or the SHA after
`-g`, and reproduce there. The vendored specs are a subtree, so that checkout
has the device catalogue that shipped. `-dirty` means no commit matches the
build exactly. `dev build` means it did not come from a release, so ask where
it came from.
