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
  `scripts/release.sh` reads it off the clock in UTC (minutes since the epoch
  on Android, `YYYYMMDDHHMM` on iOS), so nobody bumps it and the pubspec `+N`
  is ignored. UTC, because a local-time stamp repeats an hour when clocks
  fall back and App Store Connect refuses a number that does not rise.
- **Stamp**: the app's record of which build it is. `scripts/release.sh`
  passes in `git describe --tags --always --dirty` as `AppConstants.appVersion`.

| Stamp | Means |
| --- | --- |
| `v0.1.0` | built from the tag |
| `v0.1.0-3-g1a2b3c4` | three commits after `v0.1.0`, at commit `1a2b3c4` |
| `…-dirty` | built with uncommitted changes, so no commit fully describes it |
| `1a2b3c4` | a bare commit: no tag reachable. Cut `v0.1.0` before the first store upload |
| `dev build` | not built by `release.sh`, e.g. a `flutter run` or a CI smoke build |

The stamp appears at the top of Diagnostics, on line one of **Copy for a bug
report**, and as the app version on the user's Home Assistant device page.
Neither store shows users a commit, so the stamp is how a report gets back to
source.

Ad-hoc IPAs from `.github/workflows/ios-adhoc.yml` carry the same
`git describe` stamp, so a tester's report names the commit instead of
`dev build`. That checkout is shallow: a tagged ref stamps as its tag, any
other ref as its bare SHA.

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
   The script refuses to build when the result could not be traced back to
   one commit:

   - **HEAD carries no tag.** The stamp would name a commit (`vX.Y.Z-N-g<sha>`,
     or a bare SHA before the first tag), not a release.
     `LB_RELEASE_UNTAGGED=1` overrides for a throwaway build.
   - **Uncommitted changes.** `-dirty` names no commit, and an untracked
     source file leaves no trace at all. `LB_RELEASE_DIRTY=1` overrides.
   - **The tag disagrees with `pubspec.yaml`.** One version in the listing,
     another in every bug report. No override: fix the tag.
   - **Untracked or ignored files under `device-specs/devices/`,
     `device-specs/examples/` or `assets/radio/`.** pubspec bundles those
     directories, so they ship, and the stamp cannot see them. No override:
     remove them, or commit them (upstream, for the spec directories).

   Before it looks, the script deletes `device-specs/examples/index-temp.json`,
   the gitignored local index that `run-*.sh` rebuilds on every launch and the
   app prefers over `index.json`, so a release always reads the committed
   index. It deletes a Finder `.DS_Store` in any of the three for the same
   reason: ignored, so the guard would refuse it, and written by merely
   opening the folder on the Mac that builds for iOS. The two overrides are
   for a throwaway build on a branch; a store upload should need neither.
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

- **Data safety**: declare **Approximate location**, collected and shared
  with third parties (RepeaterBook, myGMRS), optional, processed ephemerally,
  purpose *App functionality*; nothing else. Since the Radio tab's "Suggest
  channels near me" (PR #67), a repeater search the user starts reads one
  position on the phone, works out the US state(s) in range on the phone
  (`lib/services/us_state_resolver.dart`), and sends those state codes to
  each directory the user has turned on: RepeaterBook with the user's own
  access token, myGMRS anonymously. Coordinates never leave the phone; the
  app remembers the last position on the phone only, rounded to about 1 km,
  until the user taps *Forget location* on the Repeater sources screen.
  Declaring is the choice that cannot be wrong: the user-initiated and
  ephemeral-processing exemptions might cover it, but the RepeaterBook request
  is not anonymous (it carries the user's token), so the app cannot vouch for
  what that directory keeps. The RepeaterBook token and the iRobot sign-in are
  the user's own credentials sent to the service that issued them, disclosed
  where they are entered, the same way the App Store runbook treats them. The
  banner check is anonymous.
- **Ads**: answer *yes*. The banner is an affiliate promotion, and declaring
  "no ads" while shipping it is a policy violation.
- **Location permission declaration**: the app requests
  `ACCESS_FINE_LOCATION` (foreground only, never background). Check first
  whether Play still asks for the declaration: its location form is about
  background access, which this app does not request. If it does ask, file
  early, since review can take days to weeks, and name both uses:
  - Android 11 and earlier need location permission for any BLE scan;
  - on the Radio tab, "Suggest channels near me" reads one position when the
    user taps it, in the foreground, to find repeaters in range. Only the US
    state(s) derived from it are sent, to the directories the user turned on.

  There is no fallback that keeps the radio feature. `neverForLocation` on
  `BLUETOOTH_SCAN` with the location permissions capped at API 30 fixes the
  BLE half, but geolocator then finds no location permission in the manifest
  on Android 12+ and the repeater search fails there; the cap means dropping
  location-based suggestions on Android.
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
- the only connections beyond the user's own devices are:
  - the anonymous banner check;
  - spec-pack downloads the user starts;
  - their own Home Assistant server;
  - a one-time sign-in to iRobot's cloud, only if the user picks that route
    for a robot vacuum, to read the robot's local password;
  - a repeater search the user starts on the Radio tab: the US state(s) in
    range, never coordinates, to myGMRS (`api.mygmrs.com`, anonymous) and,
    once the user pastes their own access token, to RepeaterBook
    (`www.repeaterbook.com`, with that token; saving the token also checks it
    there once). Each directory can be turned off;
- the last position used for a repeater search stays on the phone, rounded to
  about 1 km, until the user forgets it;
- the banner is an affiliate link.

`ios/Runner/PrivacyInfo.xcprivacy` and Step 7 of
`docs/APP_STORE_SUBMISSION.md` make the same claims; keep all three in step.
A new outbound client means a new bullet in each (and
`test/platform/ios_privacy_manifest_test.dart` fails until the manifest has
one).

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
has the device catalogue that shipped. A bare SHA is an untagged commit, from
an ad-hoc IPA or an `LB_RELEASE_UNTAGGED=1` build: check it out directly.
`-dirty` means no commit matches the build exactly. `dev build` means it did
not come from a release, so ask where it came from.
