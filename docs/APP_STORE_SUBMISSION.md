# App Store submission runbook

First iOS submission for **Liberated Bread** — `ca.pigscanfly.liberatedbread`,
version `0.1.0+1`, Apple **Team ID `B6SUD26678`** (Holden Karau).

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
  (`method=app-store-connect`, `teamID=B6SUD26678`, profile name
  `"Liberated Bread App Store"`).
- **Bluetooth / Local Network / Bonjour** usage strings + `NSBonjourServices`
  present and in sync with the specs.
- **First-launch Terms gate** links the disclaimer + privacy URLs, marks the app
  experimental.
- **Icons** — full set incl. the 1024 marketing icon (RGB, no alpha).
- **Version** stays `0.1.0+1` (matches the experimental framing; to ship as 1.0.0
  edit only `pubspec.yaml`'s `version:`).

**On-Mac validation (Mac Mini, Xcode 26.3 / Flutter 3.44.8):**
- `flutter build ios --release --no-codesign` → builds clean (Runner.app 38.5 MB);
  Rust FFI links via cargokit (arm64 iOS, ~2174 symbols); `PrivacyInfo.xcprivacy`
  and `ITSAppUsesNonExemptEncryption=true` present in the built bundle.
- App **runs** on an iOS 26.3 Simulator (see the on-Mac test results at the
  bottom of this file).

The **only** thing between this and an uploadable build is code signing — i.e.
Steps 1–4.

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

The Mac has only an "Apple Development" cert. Create a distribution cert:
Xcode ▸ **Settings ▸ Accounts ▸ (your team) ▸ Manage Certificates ▸ + ▸
Apple Distribution**. (Or developer.apple.com ▸ Certificates.)

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
flutter build ipa --release --export-options-plist=ios/ExportOptions-appstore.plist
```
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
> Wi-Fi, with no account and no cloud. Experimental and open.

**Description:**
> Liberated Bread is a universal remote for the devices on your own network. It
> talks to them directly — over Bluetooth Low Energy and your local Wi-Fi — with
> no account, no cloud relay, and no data collection.
>
> It ships with a catalogue of device profiles and can discover and control a
> wide range of gear on your LAN, including smart plugs and bulbs, media players
> and TVs, air purifiers, robot vacuums, treadmills and walking pads, label
> printers, cameras, and more — plus a bridge to your own Home Assistant server.
>
> Privacy by design: nothing you do leaves your device. The app's only outbound
> internet request is an anonymous check for a promotional banner. Everything
> else is direct, local device control.
>
> This is experimental software provided as-is. Please read the in-app terms and
> the disclaimer at https://liberatedbread.com/disclaimer/ before use — some
> supported devices (for example light-based beauty devices) can cause harm if
> used incorrectly; always follow the manufacturer's own safety guidance.

**Keywords (≤100 chars, comma-separated):**
> smart home,bluetooth,local network,LAN,IoT,device control,remote,home
> automation,ble,offline

**What's New (first version):**
> First release. Experimental local control for Bluetooth and Wi-Fi devices on
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
iPhone 16e). Summary: **the app builds, launches, and runs on iOS**; every
failure observed is environmental (a bare simulator has no real devices/LAN, and
some host tests do real socket/BLE I/O that behaves differently on macOS) — none
is a defect in the shipped app, and Linux CI is green on all of them.

- **iOS build:** `flutter build ios --release --no-codesign` ✅ — Runner.app
  38.5 MB; Rust FFI linked via cargokit; `PrivacyInfo.xcprivacy` +
  `ITSAppUsesNonExemptEncryption=true` present in the built bundle.
- **Runs on the Simulator:** ✅ launches to the first-run Terms gate (screenshot
  captured); the banner fetch fails gracefully offline as designed.
- **Integration tests on the iOS Simulator:**
  - ✅ `app_launch`, `mock_flow`, `error_flow`, `group_flow`, `native_core` — all pass.
  - ⚠️ `e2e_walkthrough` — 3 pass, 4 fail: *scan finds devices*, *connect to a
    device*, *spec-pack install*, *Home Assistant settings*. All four need a real
    device / LAN / HA server the bare simulator doesn't have. Not app defects.
  - `linux_virtual_ble` — not run on iOS (Linux-only harness).
- **Rust (`cargo test`) on macOS arm64:** ✅ all suites pass.
- **Dart unit/widget suite on the macOS host:** 1861 pass / 13 skip / **4 fail**,
  all environmental host quirks (Linux CI passes them):
  - `platform/deployment_targets_test` — an artifact of Flutter 3.44.8's project
    migration on the Mac working copy (the committed project is consistent).
  - `services/real_ble_service_emulated_test` — flutter_blue_plus reports
    "Device is disconnected" on a macOS host (no CoreBluetooth device).
  - `services/multicast_lock_test` (×2) — real UDP send on :5353 returns
    `No route to host (errno 65)` on the macOS host sandbox.

Bottom line: nothing in the app blocks iOS; remaining work is purely the Apple
signing/account steps above.
