# App Store submission runbook

First iOS submission for **Liberated Bread** — `ca.pigscanfly.liberatedbread`,
version `0.1.0+1`. App ID owner: **Pigs Can Fly Labs LLC — Team ID
`GQ358PSWM3`** (the `ca.pigscanfly.*` bundle belongs to this org team).

> ⚠️ **Team mismatch to fix:** the Mac's current signing cert is the *individual*
> "Holden Karau" team (`B6SUD26678`). Since the App ID is registered under the
> LLC (`GQ358PSWM3`), your **Distribution cert and App Store provisioning profile
> must be issued under the LLC team**, and `ExportOptions-appstore.plist` uses
> `GQ358PSWM3`. (If you actually intend to ship under the individual team
> instead, switch the App ID + plist back to `B6SUD26678`.)

Timeline: ~1 month, so this follows **Path A** — file the slow Apple approval
first, stage everything else, submit once it lands. Everything under "Ready in
the repo" is committed and validated (incl. a real iOS build + app run on the Mac
Mini). Everything under the numbered steps needs your Apple account / App Store
Connect / a Mac.

Work the numbered steps roughly in order; **Step 1 is the long pole — do it
today** because Apple's grant can take days.

---

## Ready in the repo (done + validated)

- **Export-compliance key** — `ios/Runner/Info.plist` declares
  `ITSAppUsesNonExemptEncryption = true` (you chose: uses encryption, claim the
  mass-market exemption; see Step 7).
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
- **Marketing version** stays `0.1.0` (to ship as 1.0.0 edit only
  `pubspec.yaml`'s `version:` — consider doing so, since a 0.x version alongside
  any "early"/"preview" wording is part of what reads as a beta under Guideline
  2.2). The **build number** — the
  `+N` half — must increase on every upload; see the note in Step 5. Do not
  freeze it: App Store Connect rejects a second upload carrying a
  `CFBundleVersion` it has already seen, and `pubspec.yaml` is the only source
  of that value.

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

## Step 1 — File the multicast entitlement request  ⏳ *(do first; grant takes days)*

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

The Mac has only an "Apple Development" cert on the *individual* team. Create an
**Apple Distribution** cert **under Pigs Can Fly Labs LLC (GQ358PSWM3)**:
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
`ExportOptions-appstore.plist` (or rename that string). Download it (or let
Xcode manage it) so it's in the login keychain on the build Mac.

## Step 5 — Build + upload the signed IPA (on the Mac)

The Mac is already staged: Flutter 3.44.8 is at `~/flutter-3.44.8`. Build from a
clean checkout of this branch:
```sh
export PATH="$HOME/.cargo/bin:$HOME/flutter-3.44.8/bin:/opt/homebrew/bin:$PATH"
git clone -b unfuck git@github.com:liberatedbread/liberatedbread-mobile.git ~/lb && cd ~/lb
flutter pub get
flutter build ipa --release --build-number=$(date +%Y%m%d%H%M) \
  --export-options-plist=ios/ExportOptions-appstore.plist
```

**`--build-number` is not optional on a re-upload.** `pubspec.yaml`'s
`version: 0.1.0+1` is the only source of `CFBundleVersion` (`Info.plist` reads
`$(FLUTTER_BUILD_NUMBER)`), and nothing bumps it. The first upload succeeds; the
second — a TestFlight build after a rejection, or the re-export once the
multicast entitlement is granted — is refused by App Store Connect for a
duplicate build number, and the refusal arrives by email after the upload, not
during it. Any monotonic value works; the timestamp above needs no state.
`.github/workflows/ios-adhoc.yml` uses `github.run_number` for the same reason.
That needs the Step-2 cert + Step-4 profile in the keychain. Then upload the IPA
(`build/ios/ipa/*.ipa`) one of:
- **Transporter.app** (Mac App Store) — drag the IPA in, Deliver. Simplest.
- **Xcode** ▸ Organizer ▸ Distribute App.
- **`xcrun altool`** (needs an App Store Connect API key in
  `~/.appstoreconnect/private_keys/AuthKey_<KEYID>.p8`):
  ```sh
  xcrun altool --upload-app -f build/ios/ipa/*.ipa -t ios \
    --apiKey <KEYID> --apiIssuer <ISSUER-UUID>
  ```

## Step 6 — Export-compliance questionnaire (at submit, in ASC)

When prompted: **Yes**, uses encryption → **standard algorithms (AES-128)** →
**qualifies for exemption** under EAR **740.17(b)(1)** (mass-market,
self-classification; no CCATS/compliance code). Then file the **annual**
self-classification report — a once-a-year email (template at the bottom) to
`crypt@bis.doc.gov` and `enc@nsa.gov`. Set a yearly calendar reminder.

## Step 7 — App Privacy (ASC ▸ App Privacy)

- **Privacy Policy URL:** `https://liberatedbread.com/privacy/` (matches the
  in-app link).
- **Data collection:** the app collects nothing → answer **"Data Not
  Collected."** (It makes one anonymous GET for a promo banner and, only if the
  user configures it, talks to their own Home Assistant — no identifiers leave
  the device.)

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

## Step 9 — Age rating, category, submit

- **Category:** Utilities (primary), Lifestyle (secondary).
- **Age rating:** run the ASC questionnaire honestly; the app has no objectionable
  content → expected **4+**.
- Attach the build, fill "What's New" / description, add the support +
  marketing URLs, then **Add for Review**.

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
> password.
>
> This is independent, community-maintained software provided as-is. Please read the in-app terms and
> the disclaimer at https://liberatedbread.com/disclaimer/ before use — some
> supported devices (for example light-based beauty devices) can cause harm if
> used incorrectly; always follow the manufacturer's own safety guidance.

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
> builds for the platform you ship. See MAC_NOW.md and PORTABLE.md for the
> audit that found them.

- **iOS build:** `flutter build ios --release --no-codesign` ✅ — Runner.app
  38.5 MB; Rust FFI linked via cargokit; `PrivacyInfo.xcprivacy` +
  `ITSAppUsesNonExemptEncryption=true` present in the built bundle.
- **Runs on the Simulator:** ✅ launches to the first-run Terms gate (screenshot
  captured); the banner fetch fails gracefully offline as designed.
- **Integration tests on the iOS Simulator:**
  - ✅ `app_launch`, `mock_flow`, `error_flow`, `group_flow`, `native_core` — all pass.
  - ❌ `e2e_walkthrough` — 3 pass, 4 fail: *scan finds devices*, *connect to a
    device*, *spec-pack install*, *Home Assistant settings*. **A test bug, not
    the environment.** All four pump `LiberatedBreadApp` without overriding
    `sharedPreferencesProvider`, which `_TermsGate` reads in `initState`
    (`lib/app.dart:45`), so they throw `UnimplementedError` before touching
    Bluetooth or the network. The three that pass build their own scope. The
    other integration suites override it (`mock_flow_test.dart:62`,
    `group_flow_test.dart:82`). Tracked in PORTABLE.md.
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
  - `services/real_ble_service_emulated_test` — **not** "no CoreBluetooth
    device": the emulated harness needs no radio. The single failing case
    depends on a 3-second CCCD spurious-timeout window that only opens on
    Linux, and lacks the skip its sibling case carries. Tracked in PORTABLE.md.
  - `services/multicast_lock_test` (×2) — genuinely environmental: real UDP
    send on :5353 returns `No route to host (errno 65)` under the macOS host
    sandbox.

Bottom line: the app builds and runs on iOS, but two things block a submission
today and neither is an Apple account step. The privacy manifest had to declare
the Rust core's required-reason file-timestamp APIs or App Store Connect refuses
the upload (ITMS-91053) — fixed, see `ios/Runner/PrivacyInfo.xcprivacy`. And the
build number must increase per upload (Step 5). The pinned Bluetooth plugin also
carries two native crashers; see PORTABLE.md.
