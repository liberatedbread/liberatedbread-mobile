# Amazon Echo Button — Research Notes

Big BLE push-button with RGB LED ring (2× AAA), sold 2017 as an Alexa Gadget for Echo-device party games. An "Amazon day-1 gadget" (launch-day accessory program) that Amazon killed off.

## Why it's abandoned
- Discontinued by Amazon; confirmed by Amazon staff on the official forum: "Echo buttons are discontinued by Amazon" ([Amazon forum, 2024-10-15](https://amazonforum.my.site.com/s/question/0D54P00007QPFV1SAP/)). Retail summary: [thedombot.com — Echo Buttons: Discontinued but Still Cool](https://thedombot.com/collections/echo-buttons-discontinued-but-still-cool-amazon).
- There is **no companion app at all** — pairing was a voice-driven flow ("Alexa, set up my Echo Button") against an Echo speaker. So there is no APK to acquire, and the Alexa Gadgets toolkit path is cloud/Echo-dependent.
- Normal (Amazon-intended) use still requires an Echo speaker; that path depends on Amazon infrastructure continuing to support a discontinued gadget.

## Local BLE feasibility: PROMISING (one confirmed data point, greenfield otherwise)
- [Matthew Petroff's teardown (2017-12-31)](https://mpetroff.net/2017/12/amazon-echo-button-teardown/) is the key prior art:
  - SoC: Cypress **CYW20735** BLE chip (public dev tools exist).
  - The button **advertises as a BLE gamepad**, name like `EchoBtn2V8.3` (last chars per-unit). Petroff **successfully paired it to a computer** — i.e. it behaves as a standard BLE HID device without any Echo or cloud involved.
  - Hardware is hack-friendly: no glue, Tag-Connect **SWD header reachable from inside the battery compartment** (SWDIO/SWCLK/GND/RESET/VCC/SWO mapped to test points), U.FL antenna footprint, cuttable traces.
- Two local-control routes:
  1. **As-is**: pair over BLE as HID gamepad; button presses arrive as standard HID input reports on any Linux/Windows/Android host (BlueZ `hid` profile). Confirmed pairable; whether the host can also *drive the LEDs* via HID output reports is unknown.
  2. **Firmware**: SWD-accessible CYW20735 → dump/reflash for full button+LED control. Heavier lift, no published work found.
- GATT service table (HID 0x1812 etc.) not yet enumerated — open question, cheap to answer with `bluetoothctl` once a unit is in hand.

## APK details
- None exists. Pairing/config lived in the Alexa app (`com.amazon.dee.app`) as a voice-driven Gadget flow — acquiring that APK would teach nothing about the button's BLE profile. `apk_acquired: false` is therefore "not applicable", not "failed".

## Open questions
- Full GATT/HID descriptor dump; LED control channel (HID output report vs custom GATT characteristic).
- Does pairing require the long-press orange pairing mode each time, and does it bond with arbitrary hosts?
- Multiple buttons per host (Echo supported 4).
- Firmware version in the advertised name (`2V8.x`) — per-unit or per-fw string?

## Sources
- https://mpetroff.net/2017/12/amazon-echo-button-teardown/ (2017) — BLE gamepad, CYW20735, SWD pinout
- https://amazonforum.my.site.com/s/question/0D54P00007QPFV1SAP/ (2024) — "discontinued by Amazon"
- https://thedombot.com/collections/echo-buttons-discontinued-but-still-cool-amazon — retail/discontinuation summary
