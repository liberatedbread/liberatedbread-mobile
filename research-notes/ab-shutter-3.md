# AB Shutter 3 / Generic BT Classic HID Shutter Remotes — Research Notes

## What This Is
"AB Shutter 3" is the default Bluetooth device name of the ubiquitous $2–10
selfie/camera shutter remote sold under dozens of brands (CamKix, Mpow-era
no-names, AliExpress unbranded). Two-button puck (iOS button + Android button),
CR2032 cell. This note covers the whole family of **Bluetooth Classic HID
shutter remotes**, not a single SKU. There is no company to die — the value
here is documenting that these are plain BT Classic HID and need **no app, no
cloud, no pairing PIN** beyond OS-level HID pairing.

## Transport
- Bluetooth Classic (BR/EDR), HID profile (HIDP, SDP service UUID `0x1124`).
- MobileRead teardown/usage report identifies a **YiChip BT chip, Classic
  Bluetooth** inside the AB Shutter 3 — not BLE (older clones) — while some
  newer clones are BLE HID. Both behave identically at the OS level; the
  Classic variants are the ones in scope here.
- Presents as a HID keyboard/consumer-control combo device.

## Behaviour (community-confirmed)
- Pairs with OS Bluetooth settings; no companion app exists or is needed.
- Button presses emit standard HID key events:
  - Volume Up / Volume Down (the two shutter buttons — the phone camera app
    treats volume keys as shutter release; on Samsung One UI 6+ you must set
    Camera Settings → Volume key function → Shutter).
  - Some units also emit Play/Pause, Next/Previous track (per StackOverflow
    report of the same key set arriving on Windows).
- Works on Android, iOS, Windows, Linux, and even jailbroken/Kindle KOReader
  setups via evtest/HID passthrough (MobileRead Kindle page-turner guide,
  July 2026 — still actively used).
- On Linux the events arrive as ordinary evdev input; `evtest` shows the
  keycodes directly — zero reverse engineering required.

## Cloud / App Status
- No cloud, no account, no app. Fully local by design.
- "Abandonment" angle: these ship with zero software support and the brands
  churn constantly, but they are immune to bit-rot because they use the
  standard HID profile.

## Feasibility
- **Trivial.** Pair and read keys. This is the reference example of "BT
  Classic gadgets that just work with generic tools."
- Gotcha to document: iOS vs Android button sends different keycodes on some
  clones; test with `evtest`/key-event viewer. Some clones auto-sleep and
  need one press to reconnect.

## Sources
- MobileRead, "Tutorial Working Cheap Bluetooth page turner on PW6",
  identifies AB Shutter 3 as YiChip **Classic Bluetooth**, active thread 2026:
  https://www.mobileread.com/forums/showthread.php?p=4584542
- GitHub gist (liquidguru, 2026-07-21), "Bluetooth Page Turner for Kindle
  Paperwhite 6" using AB Shutter 3:
  https://gist.github.com/liquidguru/1e9c77f9389cdf23f94d2a94b220c90a
- StackOverflow (2015), confirms HID key set Volume Up/Down, Play/Pause,
  Next/Previous:
  https://stackoverflow.com/questions/33955141/manage-bluetooth-remote-shutter-keys-from-my-windows-application

## Open Questions
- Exact HID report descriptor per clone (not needed for use; only if building
  a sniffer-level spec).
- Ratio of Classic vs BLE clones currently on the market.

## APK
- None exists. N/A by design.
