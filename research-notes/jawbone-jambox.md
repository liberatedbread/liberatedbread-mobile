# Jawbone Jambox (Jambox / Big Jambox / Mini Jambox) — Research Notes

Date researched: 2026-08-03. Researcher: BT-Classic audio swarm.

## Verdict
**CONFIRMED viable, two independent local paths.** (1) Companion app talks to the
speaker over plain Bluetooth Classic SPP (standard UUID 00001101) using a small
binary "JCI" protocol, recovered intact from the APK. (2) Firmware/voice updates
work fully offline via USB with community-archived Jawbone Updater + JBZ/DFU
files. Company dead, cloud dead — but the hardware doesn't need either.

## Cloud / company status
- Jawbone (AliphCom) began formal **liquidation in July 2017**; customer support
  went dark January 2017; ~$930M VC burned
  ([TMS retrospective](https://tms-outsource.com/blog/posts/what-happened-to-jawbone/)).
- **MyTALK cloud is dead** (jawbone.com offline). MyTALK was the original route
  for firmware updates, voice packs, and "Dial Apps".
- The companion app shows a **login-on-first-use screen** ([Engadget Mini Jambox
  review, 2013](https://www.engadget.com/2013-09-24-jawbone-mini-jambox-review.html)).
  APK contains `MyTalkClient` (analytics/registration) and `companion/datamodel/Login`.
  Whether login can be bypassed for pure device control is UNVERIFIED — but the
  SPP protocol itself is unauthenticated, so a replacement client needs no cloud.

## Companion app / APK provenance
- **Package**: `com.jawbone.companion` ("Jawbone" app, iOS/Android, launched with
  Mini Jambox Sept 2013; covers Jambox, Big Jambox, Mini Jambox)
- **Version**: 2.5.13 (versionCode 34)
- **Source**: apkeep, apk-pure
- **APK SHA-256**: `7dda1109ff4af871e21a3c64e325857e0eafedf353ff637d62e6cb552eed20d5`
- **Decompiled**: jadx → `$REPO/workspace/static/jawbone-jambox/` (unobfuscated,
  old-school clean Java)

## Transport
- Bluetooth Classic **SPP/RFCOMM, standard SPP UUID `00001101-0000-1000-8000-00805F9B34FB`**
  (`com/jawbone/bluetooth/Bluetooth.java`), insecure-socket capable; HFP + A2DP for audio.
- Mini Jambox is BT 4.0 (A2DP 1.2, HFP 1.6) but app control stays on SPP.
- Speaker is CSR BC03/BC05/BC07-based (`com/jawbone/jci/BC03.java` etc.) — the JCI
  layer sits on top of the usual CSR headset stack (PSKeys, DSP apps).

## JCI protocol (from `com/jawbone/jci/`)
Framing (`JciRequest.java`): 6-byte header + payload, total `(size*2)+6` bytes:
- byte 0: signature `0xA0`; byte 1: command id; bytes 2–3: 16-bit tag
  (client tag counter starts at -275); byte 4: attr; byte 5: size in 16-bit words.
- Responses (`JciResponse.java`): tag, cmd, result code, attr, size, payload.

Command IDs (`JciCommands.CommandType`):
GetHeadsetVersion=1, ReadPSKey=2, WritePSKey=3, PostMessage=5, CancelMessage=6,
RegisterNotification=7, CancelNotification=8, EventNotification=10,
ResetHeadsetJCI=12, ReadHeadsetInternalData=13, ChangeHeadsetFriendlyName=16,
ConfigureLED=17, **Authentication=18**, PlayTone=19, PlayPrompt=20, ReadFile=25,
SetLocator=27, SetCustomEQ=28.

Result codes include PSKeyWriteFailure=9, DSPnotStarted=23, etc. (`CommandResult`).

Feature surface (`JciFeatures.java`): LiveAudio toggle, voice announcements,
voice caller-ID, TapTap / ShakeShake / MultiShake modes, paired-device priority
list, custom EQ, friendly name. Exactly the MyTALK-era personalisation, done locally.

## Local firmware path (no cloud, documented + archived)
- [Robert's unofficial Jambox support page](https://robertianhawdon.me.uk/jambox/):
  hosts Jawbone Updater 2.2.5 (Win/Mac, md5s published), recovery Updater 1.6.2,
  and the final JBZ/DFU firmware files for all three Jambox models. Flow: power
  off → micro-USB → tray icon → "Update from local DFU package". Also recovers
  bricked units.
- [bacch.com/jambox-info](https://www.bacch.com/jambox-info) and
  [ruibm.com](https://ruibm.com/category/software/) document the same
  local-JBZ update flow; [XDA thread](https://xdaforums.com/t/q-big-jambox-firmware.2578223/)
  confirms bypassing MyTALK was already a thing in 2013.

## Feasibility / next steps
1. Generic-linux client: `rfcomm`/BlueZ to channel of SPP UUID, send JCI frames —
   start with GetHeadsetVersion(1) and ReadHeadsetInternalData(13) (battery etc.).
2. Check Authentication(18) usage — is it actually required before other commands?
   (App has `Authentication` command; may be a no-op/challenge on headsets.)
3. Optional: verify login-bypass in app (patch or stub MyTalkClient) OR just skip
   the app and write a fresh client.
4. Firmware: JBZ/DFU over USB is solved by community; over-SPP DFU likely exists
   in JCI but undocumented — treat as optional, brick-risk.
- safety_class: LOW (consumer speaker).

## Open questions
- Does the app gate device features behind Jawbone account login? (mitigation:
  third-party client — protocol is unauthenticated at SPP level)
- JCI tag byte order + Authentication payload semantics (read `JciDevice.java` deeper).
- Whether Mini Jambox exposes any BLE control (BT 4.0) in addition to SPP.
