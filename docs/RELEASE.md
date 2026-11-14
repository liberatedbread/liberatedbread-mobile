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

## Where the release goes

There are three different destinations, and uploading to one does not publish
anywhere else:

- **Android AAB:** open [Play Console](https://play.google.com/console) →
  **Liberated Bread** → **Testing** → **Internal testing** → **Releases**, and
  upload `build/app/outputs/bundle/release/app-release.aab` there. After testing,
  promote that release to **Production** in the same console.
- **iOS IPA:** on the release Mac, upload `build/ios/ipa/*.ipa` with
  **Transporter**. It arrives in [App Store
  Connect](https://appstoreconnect.apple.com/) → **Apps** → **Liberated Bread**
  as a build. **TestFlight** is where that build is beta-tested; it is not the
  public release. To publish it, select the same build in the app's **App Store
  version**, submit that version to App Review, then release the approved
  version. Step 7 below and Apple runbook Step 9 walk through those screens.
- **Source tag and notes:** `git push origin "$TAG"` publishes the tag to GitHub;
  a [GitHub Release](https://github.com/liberatedbread/liberatedbread-mobile/releases)
  publishes the notes. Neither uploads an app binary to either store.

Before starting, confirm that the release manager can push to the GitHub
repository, create Internal testing and Production releases in Play Console,
and access the correct Apple team. Apple permits a **Developer** to upload
builds, but submission for review requires **Account Holder**, **Admin**, or
**App Manager**. The release Mac, Android upload key, Apple distribution
certificate/profile, both test phones and a supported LAN device must be
available; a green build alone is not a release sign-off.

Keep a release record outside the worktree, starting with these fields. Fill in
the store links and numbers as they appear so nobody has to reconstruct which
binary was tested and published later:

```text
VERSION=0.1.0
TAG=v0.1.0
RELEASE_SHA=<full commit SHA>
CI_RUN_URL=<green CI run for that exact SHA>
ANDROID_VERSION_CODE=<from release.sh / Play Console>
IOS_BUILD_NUMBER=<from release.sh / App Store Connect>
AAB_SHA256=<artifact hash>
IPA_SHA256=<artifact hash>
PLAY_INTERNAL_RELEASE_URL=<internal-track release>
TESTFLIGHT_BUILD_URL=<processed TestFlight build>
APP_STORE_VERSION_URL=<version submitted to App Review>
PRODUCTION_RELEASE_DATE=<YYYY-MM-DD, after actual publication>
```

## Cutting a release

### The guided scripts

Two interactive scripts walk this whole checklist, one per store:

```bash
./scripts/release-android.sh   # Google Play (Linux or macOS)
./scripts/release-apple.sh     # App Store (the release Mac)
```

Each asks first whether to **cut a new tag** (pubspec.yaml's version on the
CI-green tip of `origin/main`) or **build an existing tag**, for example one the
other platform's script already cut. `--new-tag` and `--from-tag vX.Y.Z` answer
that question up front. Then each script:

- runs every step a shell can run: fetch, the CI gate (it watches a running
  CI run), the clean worktree, `test.sh` and the netdisco suites, the phone
  preflight, the local tag, `release.sh`, the artifact checks (`jarsigner`,
  or `verify_ios_app.sh` plus the ITMS-91053 preflight), hashes, the tag push,
  and the GitHub Release from the CHANGELOG section;
- stops for every step that happens in a store console or on a phone, says
  exactly what to do, and waits for Enter (`q` stops the run);
- asks before anything outward-facing: creating the tag, pushing it, and
  publishing the GitHub Release;
- keeps the release record below in
  `../liberatedbread-release-records/<version>/`, along with the build logs
  and a copy of each uploaded artifact. A re-run of the same commit offers to
  skip each step that already passed, so a release that waits days for App
  Review is resumed with `--from-tag`.

The iOS upload goes through `xcrun altool` when an App Store Connect API key is
available (`ASC_KEY_ID`, `ASC_ISSUER_UUID`, and the `.p8` as in the Apple
runbook Step 5), and through Transporter otherwise. Play Console steps stay
manual. A failed check stops the script; nothing in it sets the `release.sh`
overrides. The steps below are what the scripts do, and they still work by
hand.

### By hand

This is the release manager's end-to-end checklist. The examples ship `0.1.0`;
substitute the version actually in `pubspec.yaml`. A store build must use
**neither** `LB_RELEASE_UNTAGGED=1` nor `LB_RELEASE_DIRTY=1`.

### 1. Finalize and gate the source

1. Edit `pubspec.yaml` if the marketing version is changing. Move everything
   under `CHANGELOG.md`'s **Unreleased** heading into a dated
   `## [X.Y.Z] - YYYY-MM-DD` section, leave a new empty **Unreleased** section,
   and prepare the stores' release notes from it. Do not date the section until
   the release is actually being cut.
2. Finish the one-time gates before building:
   - the required [websites](#websites) resolve and the support page has a
     visible contact method;
   - Android's upload key is backed up, and the Play listing, Data safety, ads,
     location declaration and content rating below are complete;
   - Apple runbook Steps 1–4 are done, including a distribution profile that
     carries multicast, and the Step 6–9 metadata has been reviewed;
   - the privacy policy, App Privacy answers and `PrivacyInfo.xcprivacy` still
     describe the app's actual outbound connections.
3. Commit those changes and push the release commit to `main`. Record its full
   SHA and require the CI run for **that SHA**, not an older green `main`, to
   complete successfully:
   ```bash
   git fetch origin main --tags
   export RELEASE_SHA="PASTE_THE_FULL_RELEASE_COMMIT_SHA"
   test "$(git rev-parse origin/main)" = "$RELEASE_SHA"
   gh run list --workflow ci.yml --commit "$RELEASE_SHA" --limit 20
   ```
   Every required job in that commit's CI run must be green. A running or failed
   job is a stop, not something to explain away in the release notes.

### 2. Create and test a clean worktree

Build both platforms on the release Mac where possible. Start from the exact CI-
green commit, not a dirty working copy or a moving branch. Run
`./scripts/setup.sh` first on a new release machine:

```bash
git fetch origin main --tags
test "$(git rev-parse origin/main)" = "$RELEASE_SHA"  # main has not moved
export VERSION="0.1.0"
export TAG="v$VERSION"
export RELEASE_DIR="$PWD/../liberatedbread-release-$VERSION"
test -z "$(git tag --list "$TAG")"       # never reuse a release tag
git worktree add --detach "$RELEASE_DIR" "$RELEASE_SHA"
cd "$RELEASE_DIR"
test "$(git rev-parse HEAD)" = "$RELEASE_SHA"
test "$(sed -n 's/^version:[[:space:]]*\([^+[:space:]]*\).*/\1/p' pubspec.yaml)" = "$VERSION"
test -z "$(git status --porcelain)"
flutter pub get --enforce-lockfile
./scripts/test.sh
./scripts/ci-netdisco-tests.sh
```

Stay in this worktree for every later step. If anything source-controlled
changes, stop: commit it, get the new SHA through CI, and start again with a new
clean worktree.

### 3. Run the physical-phone preflight, then tag

From the release worktree, use an Android phone and an iPhone on a LAN with at
least one supported device. These commands exercise real Bluetooth, Wi-Fi
discovery and the mock end-to-end flows against `$RELEASE_SHA`;
`--live-ble-any` also connects read-only to a nearby peripheral:

```bash
./scripts/run-android-device-tests.sh --all --expect-lan-devices --live-ble-any
./scripts/run-ios-device-tests.sh --all --expect-lan-devices --live-ble-any --keep-multicast
```

`--keep-multicast` is valid only after the iPhone's development profile includes
the entitlement. Do not add `--allow-keychain-wipe` unless every credential the
app holds on that phone is disposable. See
[BUILD_AND_TEST.md](BUILD_AND_TEST.md#integration-tests-on-a-physical-iphone)
for device selection, named BLE devices and the test builds these runners leave
installed. These tests are the preflight; the exact store artifacts get their
own check below.

When every suite passes, confirm that the runners restored the source tree and
create the local tag:

```bash
test -z "$(git status --porcelain)"
git tag -a "$TAG" -m "Liberated Bread $VERSION"
```

The build script needs this tag. It stays local until the artifacts pass their
static checks in Step 4.

### 4. Build and inspect the artifacts

For Android, install `android/key.properties` in the release worktree as
described under [Android signing](#android-signing), using an absolute path to
the backed-up upload keystore. It is gitignored deliberately. This check must
succeed: without the file Gradle silently falls back to the shared debug key,
and Play will reject the AAB:

```bash
test -s android/key.properties
```

For iOS, the runbook's Steps 1–4 must already be complete. Then build and verify:

```bash
./scripts/release.sh android   # -> build/app/outputs/bundle/release/app-release.aab
./scripts/release.sh ios       # -> build/ios/ipa/*.ipa
./scripts/verify_ios_app.sh build/ios/ipa/*.ipa
(
  set -e
  read -r -s -p 'Android upload keystore password: ' \
    ANDROID_UPLOAD_STORE_PASSWORD
  printf '\n'
  export ANDROID_UPLOAD_STORE_PASSWORD
  jarsigner -verify --strict \
    -keystore /absolute/path/to/upload-keystore.jks \
    -storepass:env ANDROID_UPLOAD_STORE_PASSWORD \
    build/app/outputs/bundle/release/app-release.aab upload
)
```

For `jarsigner`, use `storeFile`, `storePassword` and `keyAlias` from
`android/key.properties`; replace the example path and trailing `upload` if
yours differ. The keystore is the trust source for the self-signed upload
certificate, and the alias makes a bundle signed by another key fail the check.
The subshell keeps the password out of shell history and command arguments,
then discards it. Without the keystore, `--strict` rejects the self-signed
certificate even though its signature is valid.

Record each artifact's SHA-256 and the build number printed by `release.sh`.
The iOS verifier checks the bundle id, permission declarations, Rust FFI symbols
and signed multicast entitlement. It does not prove that LAN discovery works;
the phone checks below do.

The release script refuses these unsafe release builds:

- **HEAD carries no tag.** The stamp would name a commit (`vX.Y.Z-N-g<sha>`, or
  a bare SHA before the first tag), not a release. `LB_RELEASE_UNTAGGED=1`
  overrides for a throwaway build.
- **Uncommitted changes.** `-dirty` names no commit, and an untracked source
  file leaves no trace at all. `LB_RELEASE_DIRTY=1` overrides.
- **An Android build without `android/key.properties`.** Gradle would fall back
  to the debug signing config with only a warning, and Play rejects a
  debug-signed bundle. `LB_RELEASE_DEBUG_SIGNED=1` overrides for a local smoke
  test of the build itself.
- **The tag disagrees with `pubspec.yaml`.** One version in the listing, another
  in every bug report. No override: fix the version and cut a new tag.
- **Untracked or ignored files under `device-specs/devices/` or
  `device-specs/examples/`.** pubspec bundles those directories, so they ship,
  and the stamp cannot see them. No override: remove them, or land them
  upstream. (`assets/radio/` is listed file by file, so nothing stray there
  ships.)

Before it looks, the script deletes `device-specs/examples/index-temp.json`,
the gitignored local index that `run-*.sh` rebuilds on every launch and the app
prefers over `index.json`, so a release always reads the committed index. It
deletes a Finder `.DS_Store` in either directory for the same reason: ignored,
so the guard would refuse it, and written by merely opening the folder on the
Mac that builds for iOS. The three overrides are for throwaway builds on a
branch; a store upload should need none of them.

### 5. Publish the tag and upload to closed testing

Only after the static checks pass:

```bash
git push origin "$TAG"
```

**Android — Play Console:**

1. Open [Play Console](https://play.google.com/console) → **Liberated Bread** →
   **Testing** → **Internal testing** → **Releases**. Create a release and upload
   `build/app/outputs/bundle/release/app-release.aab`.
2. Add the release notes, review the release, and start the rollout to **Internal
   testing**. This reaches testers, not Production.
3. Add the test Google account as a tester, open the track's tester link on the
   Android phone, and install the release from Play.

**iOS — Transporter and TestFlight:**

1. On the release Mac, open **Transporter** and sign in with an Apple ID that has
   access to the Pigs Can Fly Labs LLC team. Choose **Add App**, select
   `build/ios/ipa/*.ipa`, then choose **Deliver**. This uploads to App Store
   Connect; it does not publish the app.
2. Open [App Store Connect](https://appstoreconnect.apple.com/) → **Apps** →
   **Liberated Bread** → **TestFlight**. Wait for the processing-complete email.
   If the build says compliance information is missing, answer the export-
   compliance questions in Apple runbook Step 6.
3. Add the processed build to an internal tester group. On the iPhone, open the
   tester invitation in **TestFlight** and install that build. External tester
   groups can require Beta App Review; they are not needed for this preflight.

An AAB is not an APK, and an App Store distribution IPA is not an ad-hoc IPA;
neither can be installed directly with the usual phone installer. These closed
tracks are how to test the exact artifacts before production.

Uploading freezes the tag. If a source fix is needed after an upload, do not
move or reuse the tag to make the stamp point somewhere else: bump the version,
cut a new tag and repeat the checklist. Store build numbers must rise on every
re-upload, including a rejection or a failed closed-test build. A packaging or
upload retry with **no source change** keeps the same tag, but still needs a new
build number. Both timestamps have minute resolution, so compare the new logged
number with the store's previous upload and wait until the next minute if they
would be identical.

### 6. Validate the exact store artifacts

On each phone, using the Internal testing / TestFlight install:

- [ ] Diagnostics shows exactly `vX.Y.Z` — not `dev build`, a bare SHA, another
      tag, or `-dirty` — and the store shows the build number just recorded.
- [ ] A fresh launch presents the current Terms, and its privacy and disclaimer
      links open the required pages.
- [ ] Bluetooth permission, scan, connect and a safe read or control work on a
      real peripheral.
- [ ] Local-network permission and Wi-Fi discovery work, and a supported LAN
      device can be opened and controlled. On iOS this also exercises the signed
      multicast entitlement in the real sandbox.
- [ ] Location-based repeater suggestions and every other feature changed since
      the previous release get a real-device smoke test.
- [ ] For an upgrade rather than the first release, install over the previous
      store version and confirm saved devices and credentials survive.

Do not substitute a debug build, a simulator, or a different commit for these
checks. Any failure stops submission and publication.

### 7. Submit and publish

#### Google Play

1. In Play Console, open the tested **Internal testing** release and choose
   **Promote release** → **Production**. This carries forward the same AAB; do
   not rebuild it or substitute an APK.
2. Check the release notes and store forms, review the Production release, and
   start its rollout. Use a staged rollout when available.

#### Apple App Store

TestFlight is beta distribution only; there is no "promote TestFlight to the App
Store" button. Publish the tested build as follows (also expanded in Apple
runbook Step 9):

1. Open [App Store Connect](https://appstoreconnect.apple.com/) → **Apps** →
   **Liberated Bread**. Under **App Store**, open the existing **Prepare for
   Submission** version, or choose **+ Version**. The version is the pubspec
   `X.Y.Z`, without `+N` and without the clock-derived build number.
2. Complete Apple runbook Steps 6–8. In the version's **Build** section, choose
   **Select Build** and select the exact TestFlight-validated build, checking
   its build number against the release record.
3. Under **Version Release**, choose **Manually release this version** to control
   launch timing, or automatic release if approval should publish it directly.
4. Choose **Add for Review**, create the submission, then open that submission
   and choose **Submit for Review**. These are two separate actions; the first
   alone sends nothing to Apple. Wait for the status to become **In Review**.
5. If manual release was selected, approval leaves the version in **Pending
   Developer Release**. Open it and choose **Release This Version** to publish.
   With automatic release, Apple publishes after approval instead.

For a later app update, Apple also offers phased release for automatic updates.
That is an update rollout control, not the way to publish the app's first
version. See [Apple's submission
guide](https://developer.apple.com/help/app-store-connect/manage-submissions-to-app-review/submit-an-app/)
for the current review UI.

#### Release record, public smoke test and cleanup

1. On the release Mac, hash the exact uploaded files and put the output in the
   release record:
   ```bash
   shasum -a 256 \
     build/app/outputs/bundle/release/app-release.aab \
     build/ios/ipa/*.ipa
   ```
   If the directory contains more than one IPA, match each hash to its build
   number before recording it; never guess which artifact was uploaded.
2. Preserve the AAB, the selected IPA, their hashes, the build logs and the
   completed release record in the team's release archive. Record the Play
   `versionCode`, Apple `CFBundleVersion`, closed-test links, review submission
   and actual publication date as each happens.
3. Open [GitHub Releases](https://github.com/liberatedbread/liberatedbread-mobile/releases)
   → **Draft a new release**. Choose the already-pushed `$TAG` (do not create a
   different tag), title it `Liberated Bread $VERSION`, paste the curated notes
   from the matching CHANGELOG section, and choose **Publish release**. Store
   uploads and App Review do not depend on this step.
4. Install each public store build on a real phone. Check Diagnostics for the
   tag, repeat a BLE and LAN smoke test, and confirm the public listing's version
   and release notes. Watch Play's release/vitals pages, App Store Connect's
   analytics/crash reports, TestFlight feedback and incoming bug reports.
5. Only after preserving the artifacts and record, leave the release worktree
   and remove it from the original checkout:
   ```bash
   cd /path/to/the/original/liberatedbread-mobile
   git worktree remove "$RELEASE_DIR"
   ```
   If Git says the worktree is not clean, inspect what remains rather than using
   `--force`; the keystore properties, artifacts or an accidental source edit may
   still need to be preserved.

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
  **Also declare** *App info and performance ▸ Diagnostics*:
  - collected: **yes**; shared: **no**;
  - processed ephemerally: **no** (reports are stored for triage);
  - required or optional: **"Users can choose whether this data is
    collected"**. This is Play's own wording for user-initiated collection,
    and it is accurate: nothing is sent without a tap;
  - purpose: **App functionality**.

  **And declare** *App activity ▸ Other user-generated content*, with the
  same answers (collected, not shared, not ephemeral, users can choose,
  App functionality). This is the optional note a user may type in the
  report's details box.

  These cover the device or radio report a user chooses to send from the
  "unexpected services" / "unexpected response" banner to
  `svc-reports.liberatedbread.com`,
  our own server. It carries no identifier. Play has no exemption for
  user-initiated data that reaches the developer, so it is declared, and the
  optional answer is where Play lets you say it is user-initiated. The iOS
  side is the App Store runbook's Step 7.
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
  - a diagnostics report about a device that did something its profile does
    not describe (an unexpected service, or a response the app could not
    read: a Wi-Fi reply's field names, never their values, or up to 32 bytes
    of a Bluetooth value that would not decode), sent to
    `svc-reports.liberatedbread.com` and/or by email to
    `svc-reports@liberatedbread.com`, **only when the user taps Send**. It
    shows its contents first, carries no addresses, names or identifiers,
    and the server keeps no IP address. A radio's report names its
    programming profile and what the radio answered, never its id, name or
    memory. If the user types a note in the optional details box, the note
    goes too;
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
- it has no accounts and no server of its own for device control. Its one
  server, `svc-reports.liberatedbread.com`, receives a diagnostics report
  only when the user taps Send on a banner about a device that did something
  its profile does not describe. That is user-initiated diagnostics, declared
  as Other Diagnostic Data;
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
