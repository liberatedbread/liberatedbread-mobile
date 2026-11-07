# App Store submission runbook

First iOS submission for **Liberated Bread** — `ca.pigscanfly.liberatedbread`,
version `0.1.0+1`. App ID owner: **Pigs Can Fly Labs LLC — Team ID
`GQ358PSWM3`** (the `ca.pigscanfly.*` bundle belongs to this org team).

> ✅ **Development identity and multicast grant: done** (2026-09-16). The Mac's
> Xcode-managed development profile is issued to Pigs Can Fly Labs LLC
> (`GQ358PSWM3`) and carries `com.apple.developer.networking.multicast`, which
> only exists once Apple has granted the capability — so Step 1 is granted and
> the project commits `DEVELOPMENT_TEAM = GQ358PSWM3` on every configuration.
> **Still needed: an Apple Distribution certificate under `GQ358PSWM3`**
> (Step 2). `ExportOptions-appstore.plist` already names that team. (An older
> version of this note said the Mac only had a cert on the individual team
> `B6SUD26678`; that stopped being true when the LLC account was signed in.)

Timeline: ~1 month, so this follows **Path A** — file the slow Apple approval
first, stage everything else, submit once it lands. Everything under "Ready in
the repo" is committed and validated (incl. a real iOS build + app run on the Mac
Mini). Everything under the numbered steps needs your Apple account / App Store
Connect / a Mac.

Work the numbered steps roughly in order. Step 1's grant has landed, so the
long pole is now Step 2 (a Distribution certificate under the LLC team).

---

## Ready in the repo (done + validated)

- **Export-compliance key** — `ios/Runner/Info.plist` declares
  `ITSAppUsesNonExemptEncryption = true` (you chose: uses encryption, claim the
  mass-market exemption; see Step 6).
- **Privacy manifest ships** — `PrivacyInfo.xcprivacy` is wired into the Runner
  target (Copy Bundle Resources) and was confirmed inside the built `.app`.
- **App Store ExportOptions** — `ios/ExportOptions-appstore.plist`
  (`method=app-store-connect`, `teamID=GQ358PSWM3` [Pigs Can Fly Labs LLC],
  profile name `"Liberated Bread App Store"`).
- **Bluetooth / Local Network / Bonjour** usage strings + `NSBonjourServices`
  present and in sync with the specs.
- **First-launch Terms gate** links the disclaimer + privacy URLs and states the
  app is independent and unofficial. Deliberately does NOT say "experimental" or
  "beta": Guideline 2.2 rejects demos and betas, and reviewers act on that
  wording wherever they see it — first-run screen, screenshots, description.
- **Icons** — full set incl. the 1024 marketing icon (RGB, no alpha).
- **Build stamp** — `./scripts/release.sh ios` (Step 5) stamps
  `git describe` into the app, so Diagnostics and every copied bug report name
  the exact commit. A bare `flutter build ipa` ships as `dev build`. See
  [RELEASE.md](RELEASE.md).
- **Marketing version** stays `0.1.0` (to ship as 1.0.0 edit only
  `pubspec.yaml`'s `version:` — consider doing so, since a 0.x version alongside
  any "early"/"preview" wording is part of what reads as a beta under Guideline
  2.2). The **build number** (`CFBundleVersion`) must rise on every upload;
  `./scripts/release.sh ios` sets it from the clock, so the pubspec `+N` is
  ignored and needs no bump (see the note in Step 5 and
  [RELEASE.md](RELEASE.md)).

**On-Mac validation (Mac Mini, Xcode 26.3 / Flutter 3.44.8):**
- `flutter build ios --release --no-codesign` → builds clean (Runner.app 38.5 MB);
  Rust FFI links via cargokit (arm64 iOS, ~2174 symbols); `PrivacyInfo.xcprivacy`
  and `ITSAppUsesNonExemptEncryption=true` present in the built bundle.
- App **runs** on an iOS 26.3 Simulator (see the on-Mac test results at the
  bottom of this file).

The **only** thing between this and an uploadable build is code signing — i.e.
Steps 1–4.

---

## App ID capabilities — what to enable, now vs later

When you **Register an App ID** (Explicit, `ca.pigscanfly.liberatedbread`), enable
**none** of the capabilities in that list. The app's one special entitlement,
**Multicast Networking**, is *not* in the list — it's request-gated (Step 1) and
appears only after Apple grants it. Everything else the app does on iOS today —
Bluetooth, mDNS/SSDP discovery, viewing a Wi-Fi camera's MJPEG feed in local mode
— uses **Info.plist** keys (usage strings + `NSBonjourServices`) + multicast, not
App-ID capabilities.

Capabilities are not a one-time decision: you can enable more on the App ID
later and regenerate the profile in minutes (only multicast is slow). A natural
moment to add any future ones is when you enable **Multicast Networking** on the
App ID after its grant (you're regenerating the profile then anyway).

**Realistic future capabilities for this app** (add when the feature actually
ships; keep them OUT of `Runner.entitlements` until then, or App Review will ask
why an unused entitlement is present):

- **Access Wi-Fi Information** + **Hotspot** (Hotspot Configuration) — *only* if
  you add **iOS onboarding of a new Wi-Fi device via its own SoftAP** (e.g.
  getting a Wi-Fi camera onto the network the first time). Note two iOS realities:
  (1) *using* a Wi-Fi device already on the LAN needs neither — that's plain LAN
  HTTP, already covered; (2) iOS has **no public API to list nearby SSIDs**, so
  the Android scan-and-match flow (`WifiNetworkScanner`, `visibleSsids()`) is
  inert on iOS — an iOS onboarding flow must *join a known SSID/prefix* via
  `NEHotspotConfiguration` (Hotspot) and read the *current* SSID via
  `CNCopyCurrentNetworkInfo` (Access Wi-Fi Information).
- **In-App Purchase** — if you monetize (paid spec packs / remove ads).
- **Associated Domains** — if liberatedbread.com should deep-link into the app.
- **Push Notifications** — only with a backend doing remote push (local
  notifications need no capability).

**Do NOT enable** (common misfires for a "controls home devices" app): HomeKit,
Matter/Thread/Media Device Discovery (the app uses its own BLE/LAN protocols, not
Apple's ecosystem); Network Extensions / Custom Network Protocol / Multipath /
Personal VPN (those are VPN/filter/system-network providers, not app sockets);
Wireless Accessory Configuration (needs MFi); Wi-Fi Aware; iCloud / App Groups /
Sign In with Apple. Background BLE is not here anyway — it's an Info.plist
`UIBackgroundModes` (`bluetooth-central`) key, only if you need BLE with the
screen off.

---

## Step 1 — File the multicast entitlement request  ✅ *(granted — the development profile carries the entitlement)*

The app's Wi-Fi discovery (mDNS + SSDP) needs `com.apple.developer.networking.multicast`.
It's declared in `ios/Runner/Runner.entitlements`, but Apple grants it by manual
review, and a signed distribution build **fails to sign** until it's granted and
baked into the App Store profile (Step 4).

1. Go to https://developer.apple.com/contact/request/networking-multicast
2. Describe the use: *"The app discovers the user's own local smart-home / IoT
   devices on their LAN via mDNS (Bonjour) and SSDP, to let them control those
   devices directly without a cloud account."*
3. When granted: in the Developer portal, edit the App ID
   `ca.pigscanfly.liberatedbread` and enable **Multicast Networking**, then
   regenerate the distribution profile (Step 4) so it includes the entitlement.

*(Fallback if the grant is denied/slow and you must ship: remove the multicast
line from `Runner.entitlements` to ship a BLE-only build — Wi-Fi discovery is
then dead at runtime; re-add in 0.1.1. Ask me to stage that if needed.)*

## Step 2 — Apple **Distribution** certificate

Create an **Apple Distribution** cert **under Pigs Can Fly Labs LLC
(GQ358PSWM3)**:
Xcode ▸ **Settings ▸ Accounts** ▸ select the *Pigs Can Fly Labs LLC* team ▸
**Manage Certificates ▸ + ▸ Apple Distribution**. (Or developer.apple.com ▸
Certificates, with the LLC team selected top-right.)

## Step 3 — App Store Connect app record

App Store Connect ▸ **Apps ▸ + ▸ New App**:
- Platform iOS, Bundle ID `ca.pigscanfly.liberatedbread` (register it under
  Identifiers first if it isn't listed).
- Name: **Liberated Bread** · Primary language: English (U.S.) · SKU:
  `liberatedbread-ios` (any unique string).

## Step 4 — App Store distribution provisioning profile

developer.apple.com ▸ Profiles ▸ **+ ▸ App Store Connect** distribution, for the
bundle id, using the Step-2 cert, **including the multicast entitlement** (needs
Step 1 granted). Name it `Liberated Bread App Store` to match
`ExportOptions-appstore.plist` (or rename that string). Download it onto the
build Mac, or let Xcode manage it. The Step-2 certificate and its private key
belong in the login keychain; Xcode manages the provisioning profile separately.

## Step 5 — Build, upload and closed-test the signed IPA (on the Mac)

Use the clean release worktree and build flow in
[RELEASE.md](RELEASE.md#2-create-and-test-a-clean-worktree) Steps 2–4. Do not
clone `main` and build its moving tip; `release.sh` requires an exact tag whose
version matches `pubspec.yaml`:

```sh
# release.sh puts the repo-managed SDK (~/.flutter-sdk, or FLUTTER_HOME) first
# on PATH and upgrades it to CI's pinned Flutter, so the SDK on PATH here is
# not the one that builds; ./scripts/setup.sh installs that SDK.
export PATH="$HOME/.cargo/bin:/opt/homebrew/bin:$PATH"
cd /path/to/liberatedbread-release-0.1.0
git describe --tags --exact-match   # must print the intended vX.Y.Z
test -z "$(git status --porcelain)"

# Preflight: without this declaration App Store Connect rejects the upload
# with ITMS-91053 for the Rust core's file-timestamp API use.
grep -q NSPrivacyAccessedAPICategoryFileTimestamp ios/Runner/PrivacyInfo.xcprivacy
flutter pub get --enforce-lockfile
./scripts/release.sh ios   # timestamp build number, App Store export plist,
                           # and the git-describe build stamp
./scripts/verify_ios_app.sh build/ios/ipa/*.ipa
```

**`--build-number` is not optional on a re-upload.** `release.sh` always
passes one (a UTC `YYYYMMDDHHMM` timestamp), so the pubspec `+N` is ignored.
Without it, a bare `flutter build ipa` takes `CFBundleVersion` from
`pubspec.yaml`'s `version: 0.1.0+1` (`Info.plist` reads
`$(FLUTTER_BUILD_NUMBER)`), which nothing bumps. The first upload succeeds; the
second — a TestFlight build after a rejection, or the re-export once the
multicast entitlement is granted — is refused by App Store Connect for a
duplicate build number, and the refusal arrives by email after the upload, not
during it. Any monotonic value works; the script's timestamp needs no state.
`.github/workflows/ios-adhoc.yml` uses `github.run_number` for the same reason.

The build needs the Step-2 certificate and private key in the keychain, and the
Step-4 multicast-bearing profile available to Xcode. After
`verify_ios_app.sh` passes, push the release tag as in
[RELEASE.md](RELEASE.md#5-publish-the-tag-and-upload-to-closed-testing) Step 5.

### Upload the IPA to App Store Connect

The recommended route is **Transporter**, not the App Store Connect web UI:

1. Install and open **Transporter** from the Mac App Store. Sign in with an Apple
   ID that has access to **Pigs Can Fly Labs LLC (`GQ358PSWM3`)**.
2. Choose **Add App**, select `build/ios/ipa/*.ipa`, and choose **Deliver**.
   Transporter uploads that exact IPA to App Store Connect; it does not submit or
   publish it.
3. Open [App Store Connect](https://appstoreconnect.apple.com/) → **Apps** →
   **Liberated Bread** → **TestFlight**. Wait for Apple's processing-complete
   email; the build cannot be tested until processing finishes.

The command-line alternative uploads the same IPA using an App Store Connect API
key stored at `~/.appstoreconnect/private_keys/AuthKey_<KEYID>.p8`:

```sh
export ASC_KEY_ID="PASTE_THE_KEY_ID"
export ASC_ISSUER_UUID="PASTE_THE_ISSUER_UUID"
xcrun altool --upload-app -f build/ios/ipa/*.ipa -t ios \
  --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_UUID"
```

To obtain those values, open App Store Connect → **Users and Access** →
**Integrations** → **App Store Connect API** → **Team Keys**. Someone with
permission to manage team keys may need to create the key first. A key with
**Developer** access can upload builds. The page shows the **key ID** and
**issuer ID**; Apple offers the `.p8` private-key download only once. Store it at
the path above with owner-only access, and never commit it, paste it into the
runbook, or print its contents into CI logs.

### Closed-test the uploaded build

1. Under **TestFlight**, create or open an **Internal Testing** group and add the
   processed build to it. If Apple marks the build **Missing Compliance**, answer
   the export-compliance questions in Step 6 first. External groups can require
   Beta App Review; internal testers are enough for this release check.
2. Internal testers must already be App Store Connect users with access to this
   app. Add them under **Users and Access**, then add them to the internal group.
   For a tester who is not in the Apple team, use an external group instead and
   allow time for any required Beta App Review.
3. On each iPhone, install Apple's **TestFlight** app, accept the invitation, and
   install the selected build. This is the installation path for an App Store
   distribution IPA; it is not an ad-hoc IPA that can be sideloaded directly.
4. Complete the real-phone checklist in
   [RELEASE.md](RELEASE.md#6-validate-the-exact-store-artifacts) Step 6. Passing
   TestFlight testing still does **not** publish the app: Step 9 selects this
   same build for App Review and public release.

### If the build or invitation does not appear

- Check that Transporter finished **Deliver**, that you are viewing the Pigs Can
  Fly Labs LLC team, and that the IPA's bundle id is
  `ca.pigscanfly.liberatedbread`. Then wait for Apple's processing email; a build
  cannot be assigned to testers before processing completes.
- Check the email for an upload or processing rejection. A duplicate
  `CFBundleVersion` is reported there rather than by a usable new TestFlight
  build. Rebuild the unchanged source with a higher build number; do not select
  an older build or overwrite the tag. See RELEASE.md Step 5 about timestamp
  resolution.
- **Missing Compliance** means the build exists but needs Step 6's answers, not
  that the upload vanished. For a missing invitation, confirm the tester belongs
  to the group and that this specific build is assigned to that group.
- If processing fails, use Apple's message to fix the signing or package issue,
  rerun `verify_ios_app.sh`, and upload a higher build number. Do not submit a
  different, untested build to App Review just to keep moving.

## Step 6 — Export-compliance questionnaire (when App Store Connect asks)

App Store Connect can request these answers while processing a TestFlight build
as well as during App Store submission; do not wait until Step 9 if it is
blocking testers. When prompted: **Yes**, uses encryption → **standard
algorithms (AES-128)** → **qualifies for exemption** under EAR **740.17(b)(1)**
(mass-market,
self-classification; no CCATS/compliance code). Then file the **annual**
self-classification report — a once-a-year email (template at the bottom) to
`crypt@bis.doc.gov` and `enc@nsa.gov`. Set a yearly calendar reminder.

## Step 7 — App Privacy (ASC ▸ App Privacy)

- **Privacy Policy URL:** `https://liberatedbread.com/privacy/` (matches the
  in-app link).
- **Data collection:** the app collects nothing → answer **"Data Not
  Collected."** The rationale, which must match the description below and the
  comment in `ios/Runner/PrivacyInfo.xcprivacy` word for word in substance: no
  account is required, no analytics or advertising SDK is linked, and nothing
  about what the user controls is reported anywhere. The app is not
  offline-only, though — these are the connections it opens beyond the user's
  own devices, every one optional or anonymous, and none a collection of data
  by this app:
  - an anonymous GET for the promotional banner config;
  - a device-profile pack download, if the user installs one — from GitHub or
    a URL they enter (`lib/services/spec_pack_service.dart`);
  - the user's own Home Assistant server, if they configure it;
  - a one-time sign-in to iRobot's cloud, only if the user picks the account
    route for a robot vacuum instead of typing its details in by hand
    (`lib/services/irobot_cloud_service.dart`) — their vendor account
    credentials go to the vendor to read the robot's local password, which is
    what makes local control possible afterwards; the password is used once
    and not stored. Disclosed on the form that asks for them.
  - a repeater search the user starts on the Radio tab ("Suggest channels near
    me"): the US state(s) in range, worked out on the phone from one position,
    go to each directory the user has turned on — myGMRS (`api.mygmrs.com`,
    `lib/services/mygmrs_client.dart`) anonymously, and RepeaterBook
    (`www.repeaterbook.com`, `lib/services/repeaterbook_client.dart`) only
    once the user pastes their own access token, with that token. Saving the
    token checks it with RepeaterBook once. Coordinates never leave the
    phone; the last position is remembered on the phone only, rounded to
    about 1 km, until the user taps *Forget location*. Stated in the location
    purpose string.

  If App Review asks how "Data Not Collected" squares with a sign-in form, the
  answer is the iRobot bullet: the credentials are sent to the vendor, not to
  us, and no identifier leaves the device for this app's benefit.

  If App Review asks how it squares with a location permission, the answer is
  the repeater bullet, and it is a decision, not an oversight (recorded in the
  manifest comment too): **no Location entry**. Apple counts data as collected
  when the developer or a third-party partner acting for the app can keep it
  beyond servicing the request. Precise location never leaves the phone. The
  state goes to a directory the user chose, with none of its code in the app
  and nothing sent to us; the token is the user's own credential for an
  account they already hold there. If either directory ever ships code in the
  app, or a request ever passes through a server of ours, answer Coarse
  Location (App Functionality, not linked, not tracking) instead, and change
  `NSPrivacyCollectedDataTypes` and its test in the same commit. Google Play's
  Data safety form is answered differently, on purpose — see
  `docs/RELEASE.md`.

## Step 8 — Listing metadata + screenshots (ASC)

Draft copy below — **review/edit before pasting**, especially brand names and the
safety wording. Then add screenshots for the required sizes.

**Screenshots** (Apple requires at least the 6.9"/6.7" iPhone set):
```sh
# on the Mac, from ~/lb after `flutter build ios --simulator --debug`:
UDID=$(xcrun simctl list devices booted | grep -oE '[0-9A-F-]{36}' | head -1)
xcrun simctl install "$UDID" build/ios/iphonesimulator/Runner.app
xcrun simctl launch "$UDID" ca.pigscanfly.liberatedbread
xcrun simctl io "$UDID" screenshot ~/shot1.png   # repeat after navigating
```
Use a 6.9" sim (iPhone 17 Pro Max) and a 6.7"/6.5" sim. Curate a few real
screens (device list, a control card, the camera view) — App Review dislikes
empty placeholder shots.

## Step 9 — Create the App Store version, submit and release

TestFlight testing is not App Store submission. Use the same processed build,
but attach it to an App Store version and send that version through review.
Submission and release require **Account Holder**, **Admin**, or **App Manager**
access. A **Developer** can upload builds, but may not see the submission and
release controls; ask a role holder to complete this step rather than uploading
another build in the hope that the buttons appear.

### A. Prepare the version

1. Open [App Store Connect](https://appstoreconnect.apple.com/) → **Apps** →
   **Liberated Bread**. In the **App Store** section, open the existing
   **Prepare for Submission** version, or choose **+ Version** to create one.
2. Enter the marketing version `X.Y.Z` from `pubspec.yaml` (`0.1.0` for the
   current draft). Do not include the pubspec `+N`; the clock-derived integer is
   the separate **build number**, not the public App Store version.
3. Confirm Steps 6–8 are complete: export compliance, App Privacy, description,
   keywords, support/marketing URLs, screenshots and What's New. Under **Pricing
   and Availability**, set the app's price and destination territories.
4. Set **Category** to **Utilities** (primary) and **Lifestyle** (secondary), and
   complete the age-rating questionnaire honestly; no objectionable content is
   expected, so the anticipated rating is **4+**.
5. Scroll to **Build**, choose **Select Build**, and pick the exact build that
   passed TestFlight validation. Check the displayed build number against the
   number recorded from `release.sh`; do not rebuild or select an older IPA.
6. Complete **App Review Information** with contact details and the review notes
   and mock-device video described in [RELEASE.md](RELEASE.md#review).
7. Under **Version Release**, choose:
   - **Manually release this version** — recommended for a controlled launch; or
   - automatic release, if Apple should publish as soon as the version is
     approved.

### B. Send it to App Review

1. Choose **Add for Review** at the top right and create a new submission (or add
   the version to an intentional existing draft). The status becomes **Ready for
   Review**; Apple has not received it yet.
2. Open the draft submission and choose **Submit for Review**. This second action
   is required. The status becomes **In Review**. See
   [Apple's submission guide](https://developer.apple.com/help/app-store-connect/manage-submissions-to-app-review/submit-an-app/)
   if the current console labels differ.
3. A metadata-only rejection can be corrected and resubmitted with the same
   build. If the code changes, follow RELEASE.md's new-version/new-tag rule and
   upload, closed-test and select the replacement build instead.

### C. Publish after approval

- For **manual release**, approval moves the version to **Pending Developer
  Release**. Open the App Store version and choose **Release This Version**.
  This is the action that makes the app public in the selected territories.
- For **automatic release**, Apple publishes the approved version without that
  final button.
- For a **later update**, App Store Connect also offers phased release for
  automatic updates. It is an update rollout option, not the initial app launch;
  the first public release uses the manual or automatic path above.

After public release, install from the App Store, check Diagnostics for the
release tag, and complete the release record in RELEASE.md Step 7.

## Step 10 — (optional, not blocking)

Deploy `banner.json` v2 to `https://liberatedbread.com/app/banner.json`.

---

## Paste-ready App Store Connect copy  *(DRAFT — review before use)*

**Name:** Liberated Bread
**Subtitle (≤30 chars):** Control your local devices
**Support URL:** https://liberatedbread.com/
**Marketing URL:** https://liberatedbread.com/
**Privacy Policy URL:** https://liberatedbread.com/privacy/

**Promotional text (≤170 chars):**
> Control the smart devices on your own network — directly over Bluetooth and
> Wi-Fi, with no account required. Open source.

**Description:**
> Liberated Bread is a universal remote for the devices on your own network. It
> talks to them directly — over Bluetooth Low Energy and your local Wi-Fi — with
> no account required, no cloud relay, and no data collection.
>
> It ships with a catalogue of device profiles and can discover and control a
> wide range of gear on your LAN, including smart plugs and bulbs, media players
> and TVs, air purifiers, robot vacuums, treadmills and walking pads, label
> printers, cameras, and more — plus a bridge to your own Home Assistant server.
>
> Privacy by design: device control is direct and local, and nothing about it
> is reported anywhere. The app makes no account and collects no data. The only
> connections it opens beyond your own devices are ones you can see and choose:
> an anonymous check for an in-app banner, downloading a device-profile pack if
> you install one, your own Home Assistant server if you configure it, and — if
> you pick the account route for a robot vacuum instead of entering its details
> by hand — a one-time sign-in to the vendor's cloud to read your robot's local
> password. When you ask for radio channels near you, only the US state(s)
> within your search radius go to the repeater directories you have turned on (myGMRS, and
> RepeaterBook with your own access token); your position stays on your phone.
>
> This is independent, community-maintained software provided as-is. Please read the in-app terms and
> the disclaimer at https://liberatedbread.com/disclaimer/ before use — some
> supported devices (for example light-based beauty devices) can cause harm if
> used incorrectly; always follow the manufacturer's own safety guidance. Treat
> every reading and control with care, and do not rely on the app for anything
> safety-critical: a reading it shows is a personal log, never a basis for a
> medication dose, and an alarm's own buzzer, not a notification, is what warns
> you.

**Keywords (≤100 chars, comma-separated):**
> smart home,bluetooth,local network,LAN,IoT,device control,remote,home
> automation,ble,offline

**What's New (first version):**
> First release. Local control for Bluetooth and Wi-Fi devices on
> your own network.

> ⚠️ Trademark check: the description lists device *categories*, not brand names,
> to avoid implying affiliation. If you add brand names for discoverability,
> confirm you're comfortable with Apple's third-party-trademark guidance first.

---

## Export-compliance annual self-classification email  *(send once a year)*

> To: crypt@bis.doc.gov, enc@nsa.gov
> Subject: Annual self-classification report — Liberated Bread (iOS)
>
> Please find our annual self-classification report under License Exception ENC,
> EAR 740.17(b)(1).
> - Manufacturer: Holden Karau
> - Product: Liberated Bread (iOS app, bundle id ca.pigscanfly.liberatedbread)
> - Item: mass-market mobile app using standard published encryption (AES-128)
>   for local device interoperability. ECCN 5D992.c.
> - Availability: Apple App Store.
> (Adjust to the current BIS reporting format/spreadsheet before sending.)

---

## On-Mac test results

Run on the Mac Mini (Xcode 26.3, Flutter 3.44.8, Rust arm64, iOS 26.3 Simulator /
iPhone 16e). Summary: **the app builds, launches, and runs on iOS**.

> **Corrected 2026-09-03.** This section previously called every failure below
> environmental. Three of them were not, and saying so hid real bugs for a
> release cycle. A failure that only reproduces on one machine is not thereby
> environmental — it is a failure that only one machine is positioned to see,
> which is the opposite of harmless when that machine is the only one that
> builds for the platform you ship. The audit that found them is kept out of
> the repo; ask a maintainer for it.

- **iOS build:** `flutter build ios --release --no-codesign` ✅ — Runner.app
  38.5 MB; Rust FFI linked via cargokit; `PrivacyInfo.xcprivacy` +
  `ITSAppUsesNonExemptEncryption=true` present in the built bundle.
- **Runs on the Simulator:** ✅ launches to the first-run Terms gate (screenshot
  captured); the banner fetch fails gracefully offline as designed.
- **Integration tests on the iOS Simulator:**
  - ✅ `app_launch`, `mock_flow`, `error_flow`, `group_flow`, `native_core` — all pass.
  - ✅ `e2e_walkthrough` — 7/7, 30 screenshots (2026-09-16, iPhone 17
    simulator). It was 3 pass / 4 fail for a release cycle, and the cause was
    the test, not the environment: four steps pumped `LiberatedBreadApp`
    without overriding `sharedPreferencesProvider` (they now go through the
    same `_pumpApp` main() does), and the device step still looked for the
    raw "Control Service" / "Power on" view that a matched light stopped
    rendering when the entity cards arrived. The step now waits for the card
    and screenshots before asserting, so a future failure leaves a picture.
  - `linux_virtual_ble` — not run on iOS (Linux-only harness).
- **Rust (`cargo test`) on macOS arm64:** ✅ all suites pass.
- **Dart unit/widget suite on the macOS host:** 1863 pass / 13 skip / **2 fail**
  (was 4; two were fixed by this audit):
  - `platform/deployment_targets_test` — **fixed.** It asserted a
    `MinimumOSVersion` key in `ios/Flutter/AppFrameworkInfo.plist` that the
    pinned toolchain *deletes on every iOS build* and no longer ships in its
    template. The committed plist was the stale artifact, not the Mac working
    copy — the earlier note here had it backwards. Linux CI stayed green only
    because it never builds for iOS.
  - `services/real_ble_service_emulated_test` — **fixed 2026-09-15** (F-019).
    It was never "no CoreBluetooth device": the emulated harness needs no
    radio. The one failing case held an enable in flight by withholding the
    CCCD ack, which resolves at the service's confirmation timeout — 3 s on
    Linux, 15 s everywhere else — so it only ever passed on Linux. The
    emulated peripheral can now ack late (`cccdConfirmDelay`), which is the
    real-world shape and the same on every host.
  - `services/multicast_lock_test` (×2) — genuinely environmental: real UDP
    send on :5353 returns `No route to host (errno 65)` under the macOS host
    sandbox.

Bottom line: the app builds and runs on iOS. The privacy manifest declares the
Rust core's required-reason file-timestamp APIs (ITMS-91053), and `release.sh`
keeps the build number rising per upload (Step 5). The two native Bluetooth
crashers found in that audit are now guarded in the local BSD plugin override:
`NSNull` options are ignored instead of being messaged as booleans, and a nil or
unsupported descriptor value is returned as an empty value instead of being
inserted into an `NSDictionary` literal (not as `NSNull`, which the Dart side
cannot decode, so a failed read would never report back). `test/platform/ble_native_patch_test.dart` pins
both guards and a release iOS build compiles and links them. Real-device BLE and
LAN validation is still outstanding: both paired iPhones rejected the developer
disk image before the hardware suite could start, so do not read that as a
runtime pass.
