# iOS Development from Linux

iOS apps must be compiled by Xcode, which only runs on macOS. This document
describes three workflows for iterating on the iPhone app when your primary
editing environment is Linux (including Claude Code on the web).

Read the [multicast entitlement](#prerequisite--the-multicast-entitlement)
section first if you intend to test Wi-Fi device discovery. It gates every
option below, and it is the one prerequisite that needs Apple's approval rather
than a setting you can change yourself.

## Prerequisite — the multicast entitlement

`ios/Runner/Runner.entitlements` declares
`com.apple.developer.networking.multicast`. Both halves of the Wi-Fi scan need
it: `multicast_dns` binds UDP 5353 and joins 224.0.0.251 directly, and the SSDP
half sends M-SEARCH to 239.255.255.250 from its own socket. Since iOS 14 raw
multicast is blocked without this entitlement.

`NSBonjourServices` in `Info.plist` does **not** cover this. That key applies to
mDNS performed through the Bonjour APIs (`NWBrowser`, `NetService`), where
`mDNSResponder` does the multicast for you. This app uses raw sockets, so it
needs both: the entitlement to send at all, and the service-type list because
the OS still filters mDNS answers by declared type.

Unlike most capabilities, you cannot simply tick this one on in the App ID.
Apple grants it by request:

1. File the request at
   <https://developer.apple.com/contact/request/networking-multicast>. It asks
   for your Team ID, the App ID (`ca.pigscanfly.liberatedbread`), and what the
   app does with multicast. Describe the actual use — discovering local IoT
   devices via mDNS/DNS-SD and SSDP, on the user's own network, in the
   foreground, only while a scan is running. Turnaround is typically days, not
   hours.
2. Once granted, enable **Multicast Networking** on the App ID under
   *Certificates, Identifiers & Profiles → Identifiers*.
3. **Regenerate every provisioning profile** for that App ID and re-upload the
   ad-hoc one as `IOS_PROVISIONING_PROFILE` (see Option B). Existing profiles
   do not pick up a newly granted capability; they have to be reissued.

**Until it is granted**, expect this:

| Path | Effect |
|------|--------|
| Simulator builds (CI, and the no-secrets fallback in Option B) | Unaffected. Code signing is off, so the entitlement is never checked. |
| Signed device builds (Option B with secrets, Option A, Option C) | **Fail at signing**: *"Provisioning profile … doesn't include the com.apple.developer.networking.multicast entitlement."* |

That failure is deliberate and is why the entitlement is committed rather than
left for later. The alternative is worse: an app signed without it installs and
runs perfectly, sends its queries into a void, and reports the resulting silence
as *"Nothing answered on this network"* — pointing the user at a Local Network
toggle that was never the problem. `scripts/verify_ios_app.sh` asserts the
entitlement is present in any bundle carrying a provisioning profile, so a
profile that silently predates the grant reddens the ad-hoc build rather than
shipping.

macOS needs none of this — the App Sandbox governs there instead, via
`com.apple.security.network.server` (binding the mDNS socket) and
`com.apple.security.network.client`, both granted in
`macos/Runner/*.entitlements`.

## Option A — Hot reload via a local Mac (fastest iteration)

This gives true hot-reload (sub-second UI updates without restarting the app).

**One-time setup**

1. On your Mac, clone the repo and run `./scripts/setup.sh`.
2. Pair your iPhone wirelessly (optional but removes the USB cable):
   - Connect iPhone via USB and open **Xcode → Window → Devices and Simulators**.
   - Check **"Connect via network"** next to your device, then unplug USB.
3. Trust the Mac on the iPhone if prompted.

**Iteration loop**

```
# Linux (Claude Code / terminal)
git push origin <your-branch>

# Mac terminal (runs in the background while you edit)
git pull && ./scripts/run-ios-device.sh --mock
# or without mock:
git pull && ./scripts/run-ios-device.sh
```

After the initial install (~30–60 s for the first Rust cross-compile), every
`git pull` + `r` (hot reload) or `R` (hot restart) in the flutter terminal
takes 1–3 seconds.

To list paired iPhones:
```
./scripts/run-ios-device.sh --list
```

To target a specific device:
```
./scripts/run-ios-device.sh --device "Holden's iPhone"
```

## Option B — Ad-hoc IPA via GitHub Actions (no Mac needed)

Produces a signed `.ipa` you can install directly on registered devices via
[Apple Configurator 2](https://apps.apple.com/app/apple-configurator-2/id1037126344)
or AltStore. No Mac running locally required — the build happens on a GitHub
Actions macOS runner.

**One-time setup**

1. Create an **Ad Hoc provisioning profile** on
   [developer.apple.com](https://developer.apple.com) that includes your
   device UDIDs.
2. Export your signing certificate as a `.p12` file from Keychain Access.

   > **The `.p12` must contain an _Apple Development_ certificate.** A
   > distribution certificate alone is **not** enough — the archive step fails
   > before it ever reaches the export.
   >
   > Flutter picks the signing team by scanning
   > `security find-identity -p codesigning -v` and keeping only identities
   > whose name contains **Development** or **Developer** (`Apple Development:
   > …`, `iPhone Developer: …`). `Apple Distribution: …` matches neither, so a
   > distribution-only keychain yields an empty list and `flutter build ipa`
   > aborts with:
   >
   > ```
   > No valid code signing certificates were found
   > ...
   > No development certificates available to code sign app for device deployment
   > ```
   >
   > (If you drive `xcodebuild archive` yourself instead, the same missing
   > `DEVELOPMENT_TEAM` surfaces as *"Signing for 'Runner' requires a
   > development team"*.) The ad-hoc **export** still uses the profile and the
   > distribution identity — it is only the archive that needs a development
   > certificate.
   >
   > In Keychain Access, select the Apple Development certificate **and** the
   > distribution one, right-click → **Export 2 items…**, and save them as a
   > single `.p12`.

3. Add these secrets in **Settings → Secrets and variables → Actions**:

   | Secret | Required | Value |
   |--------|----------|-------|
   | `IOS_CERTIFICATE_P12` | yes | `base64 -i cert.p12` — must include an Apple Development certificate |
   | `IOS_CERTIFICATE_PASSWORD` | yes | password used when exporting the `.p12` |
   | `IOS_PROVISIONING_PROFILE` | yes | `base64 -i profile.mobileprovision` |
   | `IOS_TEAM_ID` | for export | your 10-character Apple Developer Team ID |
   | `IOS_PROFILE_NAME` | for export | your Ad Hoc profile's name, exactly as it appears on developer.apple.com |
   | `IOS_KEYCHAIN_PASSWORD` | no | password for the ephemeral CI keychain (any string; defaults to a build-local value) |

4. Nothing to edit in `ios/ExportOptions-adhoc.plist`. It ships with
   `YOUR_TEAM_ID` and `Liberated Bread Ad Hoc` placeholders, and the workflow
   substitutes `IOS_TEAM_ID` and `IOS_PROFILE_NAME` into its own workspace copy
   at build time — so no team ID or personal profile name is ever committed.
   Set both secrets rather than editing the file. If `IOS_PROFILE_NAME` is
   unset, `-exportArchive` fails with *"No profile matching 'Liberated Bread
   Ad Hoc' found"* unless your profile happens to carry that exact name. The
   bundle ID (`ca.pigscanfly.liberatedbread`) is the one value that is genuinely
   committed — change it in the plist only if you are shipping under your own.

**Triggering a build**

```bash
# From GitHub UI: Actions → "iOS ad-hoc build" → Run workflow
# Or via gh CLI:
gh workflow run ios-adhoc.yml --ref <your-branch>
gh workflow run ios-adhoc.yml --ref <your-branch> -f mock=true
```

The workflow uploads the `.ipa` as an artifact (~5–10 min build time).
Download it from the Actions run page and install with Apple Configurator 2.

With no signing secrets set at all, the workflow still runs: it skips signing
and uploads an unsigned **iOS Simulator** `.app` bundle instead of an `.ipa`.
That is useful as a compile check, but it cannot be installed on a phone.

## Option C — Remote Mac over SSH (hot reload, no push/pull)

Like Option A, but fully automated: you edit on Linux and
`./scripts/run-remote-mac.sh` keeps a Mac you can SSH into in sync. It
rsyncs the working tree over an SSH multiplexed connection, launches
`flutter run` on the Mac against your paired iPhone (or the Simulator),
then watches your local files — every save is re-synced and hot-reloaded
on the phone automatically (~1–3 s), with no git round-trip.

**One-time setup**

1. Enable SSH on the Mac (**System Settings → General → Sharing → Remote
   Login**) and set up key-based auth from Linux: `ssh-copy-id user@mac.local`.
2. Pair your iPhone with the Mac (see Option A — USB or wirelessly via
   Xcode → Devices and Simulators → "Connect via network").
3. Bootstrap the toolchain on the Mac (installs Flutter, Rust, and project
   deps via `scripts/setup.sh`):

   ```bash
   ./scripts/run-remote-mac.sh --host user@mac.local --bootstrap
   ```

**Iteration loop**

```bash
# Linux — this is the whole loop:
./scripts/run-remote-mac.sh --host user@mac.local --mock
# ...edit files locally; each save hot-reloads on the phone automatically.
```

Useful variants:

```bash
./scripts/run-remote-mac.sh --host mac --list                # list paired iPhones
./scripts/run-remote-mac.sh --host mac --device "My iPhone"  # pick a device
./scripts/run-remote-mac.sh --host mac --simulator           # iOS Simulator instead
./scripts/run-remote-mac.sh --host mac --no-watch            # manual r/R only
./scripts/run-remote-mac.sh --host mac --sync-only           # rsync and exit
```

Set `LIBERATED_BREAD_MAC_HOST` (and optionally `LIBERATED_BREAD_MAC_DIR`) to skip
`--host`. The SSH session is interactive, so `r` / `R` / `q` still work as
usual. Changes under `rust/`, `ios/`, `android/`, or `pubspec.yaml` are
synced too, but need a quit-and-rerun to take effect (hot reload only covers
Dart code and assets). Install `inotify-tools` on Linux for instant change
detection (the script falls back to 1 s polling without it).

## Option D — iOS Simulator via Android/iOS cloud (advanced)

Services like [Codemagic](https://codemagic.io) and
[Bitrise](https://bitrise.io) offer macOS build agents with persistent
simulator sessions, but they don't support interactive hot reload either.
Options A–C above cover most development needs.

## Why hot reload is impossible directly on Linux

`flutter run` communicates with the Dart VM service running inside the app on
the device. On iOS, the app must be code-signed and sideloaded by Xcode's
device agent — a macOS-only process. Flutter's toolchain delegates to Xcode
for this, so even wireless deployment ultimately requires a macOS host
initiating the session.
