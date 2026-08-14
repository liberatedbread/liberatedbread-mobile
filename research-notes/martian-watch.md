# Martian Watches (Passport/Victory/G2G/Notifier/mVoice) — Research Notes

Analog-face smartwatches with an OLED ticker line. Company vanished, app
delisted — but the last APK decompiles cleanly and the watch speaks a trivial
framed protocol over RFCOMM. Voice models also work as a generic BT speakerphone
with zero software.

## Device / Company Status
- **Products**: Passport/Victory/G2G (2013, BT Classic + microphone/speaker),
  Notifier MN200 (2014), mVoice / mVoice G2 (2016-2018, Alexa tie-in).
  Martian Watches, Irvine CA.
- **Company defunct**: martianwatches.com domain has been resold — it now
  301-redirects to a spam finance blog (verified 2026-08-07). Stock was
  fire-saled on meh.com through 2016-2018; by 2019 owners on iFixit report the
  required app is unobtainable
  ([iFixit thread, 2019-03](https://www.ifixit.com/Answers/View/554268/)).

## Local Feasibility: CONFIRMED (protocol recovered from APK)
- **Voice/calls with NO app**: the 2013 voice models are a standard Bluetooth
  handsfree (HFP) + speakerphone — pairing with any phone gives calls and
  phone-voice-assistant triggering with zero vendor software
  ([PCMag review](https://au.pcmag.com/smartwatches/12086/martian-notifier-review),
  [Gadgeteer G2G review](https://the-gadgeteer.com/2013/08/30/martian-watches-g2g-watch-review/)).
  This survives the company's death untouched.
- **Smart features (notifications, config, camera shutter, weather, alarms)**:
  framed binary protocol over RFCOMM, recovered by jadx from the last app:
  - Watch hosts an RFCOMM server, **service UUID
    `0000fff0-0000-1000-8000-00805F9B34FB`** (`SpwatchService.java:169`,
    `listenUsingRfcommWithServiceRecord` / `createRfcommSocketToServiceRecord`).
  - **Frame format** (`SpwatchService.write()`, line ~1627):
    `0x3C | cmd(1) | len_hi | len_lo | payload... | 0x3E` — start byte 60 ('<'),
    trailer 62 ('>'), 16-bit big-endian payload length.
  - ~80 opcodes recovered: TIME=41, NOTIFICATION=5, TEXT=2, CALLER_ID=37,
    ALERT=40, ALERT_BUZZ=71, ALARM=72, BATTERY=9, VERSION=54, SETUP=45,
    BUTTON_EVENT=20, DISPLAY_STATUS=25, LED_CONFIG_*=26-29, BUZZER_*=31-34/60/68,
    FS_READ/WRITE=48/50, CAMERA=52, FIND_PHONE=56, DIAL_PHONE=57,
    AUDIO_STATE=61, WEATHER, WORLD_CLOCK etc.
  - Writing a minimal local client is an afternoon job: open RFCOMM to 0xFFF0,
    send SETUP + TIME, then push NOTIFICATION/ALERT frames.

## APK Provenance
- **Package**: `com.martianwatches.martianwatchalerts` ("Martian Watch Alerts")
- **Source**: apkeep, APKPure. Only version listed: `3.0.1`.
- **SHA-256**: `cf71d5216c58abb6f052f2fb0cc660c539d7a81ccc9e5166329af6e92967401b` (6,357,208 bytes)
- App requests legacy permissions and expects old Android; a clean-room client
  from the recovered frame format is the better path.

## Open Questions
- Which opcodes the BLE-based Notifier/mVoice models share (FFF0 over GATT
  appears in the same APK — dual transport) — live capture on a Notifier would
  confirm.
- Whether watches enforce the app's AUTHORIZE (55) handshake before accepting
  config — try a raw client first, fall back to replaying the init sequence
  (`write(1,{4})` -> `write(1,{1})` observed in ConnectedThread).

## Sources
- iFixit answer 554268 (2019-03: app unobtainable)
- martianwatches.com -> spam redirect (verified 2026-08-07); meh.com fire-sale listings 2016-2018
- au.pcmag.com Martian Notifier review (generic-headset behaviour)
- Static pass: jadx on com.martianwatches.martianwatchalerts 3.0.1 (workspace/static/martian)
