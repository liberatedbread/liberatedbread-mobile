# iOS Development from Linux

iOS apps must be compiled by Xcode, which only runs on macOS. This document
describes two workflows for iterating on the iPhone app when your primary
editing environment is Linux (including Claude Code on the web).

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
2. Export your distribution certificate as a `.p12` file from Keychain Access.
3. Add these secrets in **Settings → Secrets and variables → Actions**:

   | Secret | Value |
   |--------|-------|
   | `IOS_CERTIFICATE_P12` | `base64 -i cert.p12` |
   | `IOS_CERTIFICATE_PASSWORD` | password used when exporting |
   | `IOS_PROVISIONING_PROFILE` | `base64 -i profile.mobileprovision` |

4. Edit `ios/ExportOptions-adhoc.plist` — fill in your Team ID, bundle ID,
   and profile name.

**Triggering a build**

```bash
# From GitHub UI: Actions → "iOS ad-hoc build" → Run workflow
# Or via gh CLI:
gh workflow run ios-adhoc.yml --ref <your-branch>
gh workflow run ios-adhoc.yml --ref <your-branch> -f mock=true
```

The workflow uploads the `.ipa` as an artifact (~5–10 min build time).
Download it from the Actions run page and install with Apple Configurator 2.

## Option C — iOS Simulator via Android/iOS cloud (advanced)

Services like [Codemagic](https://codemagic.io) and
[Bitrise](https://bitrise.io) offer macOS build agents with persistent
simulator sessions, but they don't support interactive hot reload either.
Options A and B above cover most development needs.

## Why hot reload is impossible directly on Linux

`flutter run` communicates with the Dart VM service running inside the app on
the device. On iOS, the app must be code-signed and sideloaded by Xcode's
device agent — a macOS-only process. Flutter's toolchain delegates to Xcode
for this, so even wireless deployment ultimately requires a macOS host
initiating the session.
