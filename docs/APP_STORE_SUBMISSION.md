# App Store submission runbook

First iOS submission for **Liberated Bread** (`ca.pigscanfly.liberatedbread`,
`0.1.0+1`). This file tracks exactly what is ready in the repo and what still
needs your Apple account. Everything under "Done in the repo" is committed and
validated; everything under "You must do" needs credentials/logins/approvals
that live outside this machine.

## ⚠️ Read this first — the one thing that gates "tonight"

The app's Wi-Fi discovery (mDNS + SSDP) needs the **multicast entitlement**
(`com.apple.developer.networking.multicast`). It is declared correctly in
`ios/Runner/Runner.entitlements`, **but Apple grants it by manual review**, and
as of now the request has **not been filed**. Until it is granted *and* baked
into an App Store distribution provisioning profile, any signed distribution
build fails at signing with:

> Provisioning profile "…" doesn't include the com.apple.developer.networking.multicast entitlement

Apple's grant typically takes **days**, not minutes. So a full-featured
submission cannot complete tonight on the multicast path. Your two realistic
choices:

- **Path A — full app, submit when the grant lands (recommended).** File the
  multicast request now (step 1 below), finish everything else, and upload the
  moment the entitlement + profile are ready. Not tonight, but correct.
- **Path B — ship tonight, BLE-only.** Remove the multicast entitlement so the
  build signs and uploads tonight; **Wi-Fi discovery is dead at runtime** (BLE
  still works). Re-add it in `0.1.1` after the grant. This is a product call —
  if you want it, tell me and I'll stage the one-line change + a note in the UI.

Either path still needs an Apple **Distribution** certificate, an App Store
Connect app record, and a distribution profile (the Mac currently has only a
*Development* cert). Those are quick, but they are Apple-account logins.

---

## Done in the repo (committed + validated)

- **Export compliance key** — `ios/Runner/Info.plist` now declares
  `ITSAppUsesNonExemptEncryption = true`. The app bundles standard AES-128
  (RustCrypto) for device interop; you'll claim the mass-market exemption at
  submit (see step 6). Without this key every upload stalls in *Missing
  Compliance*.
- **Privacy manifest wired to ship** — `ios/Runner/PrivacyInfo.xcprivacy` is now
  a member of the Runner target's Copy Bundle Resources (added to
  `project.pbxproj`). Validated with `plutil -lint` **and** `xcodebuild -list`
  on the Mac (project loads, targets/scheme intact). Content is correct: no
  tracking, no data collected, no first-party required-reason APIs (bundled
  plugins carry their own manifests).
- **App Store ExportOptions** — `ios/ExportOptions-appstore.plist`
  (`method=app-store-connect`, `teamID=B6SUD26678`). The `provisioningProfiles`
  entry names the profile `"Liberated Bread App Store"` — rename it there if you
  call your profile something else.
- **Bluetooth / Local Network / Bonjour** usage strings and `NSBonjourServices`
  are present and in sync with the vendored specs (verified).
- **First-launch Terms gate** links the live disclaimer + privacy URLs and states
  the app is experimental (tested).
- **Icons** — full set incl. the 1024 marketing icon, RGB, no alpha.
- Version stays **0.1.0+1** (valid for a first submission; honestly signals
  "experimental"). To ship as 1.0.0 instead, edit only `pubspec.yaml`'s
  `version:` line.

Minor, non-blocking (left as-is): the iOS launch screen is the default blank
Flutter splash. Submittable; polish later.

---

## You must do (Apple account / App Store Connect / a Mac)

### 1. File the multicast entitlement request  ⏳ *do this first — it's the long pole*
https://developer.apple.com/contact/request/networking-multicast — describe the
use ("discovering the user's own local IoT/smart-home devices over mDNS/SSDP").
After it's granted: enable **Multicast Networking** on the App ID
`ca.pigscanfly.liberatedbread`, then regenerate the App Store distribution
profile so it includes the entitlement.

### 2. Create an Apple **Distribution** certificate
Xcode ▸ Settings ▸ Accounts ▸ (your team) ▸ Manage Certificates ▸ **+** ▸
*Apple Distribution*. (The Mac currently has only "Apple Development".)

### 3. Create the App Store Connect app record
App Store Connect ▸ Apps ▸ **+** ▸ New App. Bundle ID
`ca.pigscanfly.liberatedbread`, primary language, SKU, name.

### 4. Create the App Store distribution provisioning profile
developer.apple.com ▸ Profiles ▸ **+** ▸ *App Store Connect* distribution, for
the bundle id, using the Distribution cert from step 2, **including** the
multicast entitlement (Path A) — name it `Liberated Bread App Store` to match
`ExportOptions-appstore.plist` (or rename the plist string).

### 5. Build + upload the IPA (on the Mac)
Flutter isn't pre-installed on the Mac; the build validation below installs 3.44.8
to `~/flutter-3.44.8`. Then:
```sh
export PATH="$HOME/.cargo/bin:$HOME/flutter-3.44.8/bin:$PATH"
cd <the repo on the Mac>
flutter build ipa --release --export-options-plist=ios/ExportOptions-appstore.plist
# Upload the result:
xcrun altool --upload-app -f build/ios/ipa/*.ipa -t ios \
  --apiKey <KEY_ID> --apiIssuer <ISSUER_ID>      # or use Transporter / Xcode Organizer
```
(`build ipa` needs the Distribution cert + the step-4 profile in the login
keychain. An App Store Connect API key under `~/.appstoreconnect/private_keys/`
makes `altool` non-interactive; otherwise upload via the Transporter app.)

### 6. Export compliance answer (at submit)
In App Store Connect, when prompted: **Yes**, uses encryption → **standard
encryption (AES-128)** → qualifies for exemption under **EAR 740.17(b)(1)**
(mass-market, self-classification; no CCATS needed). Then file the **annual**
self-classification report — one email to `crypt@bis.doc.gov` **and**
`enc@nsa.gov` listing the app. Set a yearly calendar reminder.

### 7. App Privacy (App Store Connect)
Set Privacy Policy URL = `https://liberatedbread.com/privacy/` (matches the
in-app link). Data collection questionnaire: the app collects nothing →
**Data Not Collected**.

### 8. Metadata + screenshots
Description, keywords, support URL (`https://liberatedbread.com/`), category, age
rating, promo text. Screenshots for the required device sizes (6.7"/6.9" iPhone;
iPad if you keep iPad support) — capture from a simulator or device.

### 9. (Optional, not submission-blocking)
Deploy `banner.json` v2 to `https://liberatedbread.com/app/banner.json`.

---

## On-Mac build validation

`flutter build ios --release --no-codesign` was run on the Mac Mini (Xcode 26.3,
Flutter 3.44.8) to prove the native build without needing a distribution cert.

**Result: ✅ PASS** — `Built build/ios/iphoneos/Runner.app (38.5 MB)`, Xcode
build 77 s. Verified in the built bundle:

- Rust FFI links — `liberated_bread_core.framework` present with ~2174 frb/rust
  symbols (cargokit compiled the crate for arm64 iOS and auto-added targets).
- `PrivacyInfo.xcprivacy` is bundled at the `.app` root (the `project.pbxproj`
  wiring works in a real build, not just `plutil`/`xcodebuild -list`).
- `ITSAppUsesNonExemptEncryption = true` is in the built `Info.plist`.

So the app compiles, links, and bundles correctly for iOS. The **only** remaining
gap to an uploadable IPA is code signing — i.e. the Distribution cert (step 2)
and the multicast-enabled App Store profile (steps 1 & 4). Nothing in the source
blocks the build.

Note: Flutter 3.44.8 applies project migrations on first open (UIScene lifecycle,
Swift Package Manager scaffolding). Those were applied to the Mac build copy, not
committed here. When you set up your own Mac build, let Flutter apply them and
commit the result separately if you want them tracked.
