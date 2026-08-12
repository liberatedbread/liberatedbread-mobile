# SteelSeries Free Mobile Wireless Controller — Research Notes

Date: 2026-08-04. Category: Bluetooth Classic game controllers (HID + iCade).

## Product
SteelSeries Free Mobile Wireless Controller (2012) — pocket BT Classic gamepad
(2 analog sticks, d-pad, 4 face buttons, 2 shoulders). Internally Zeemote-based:
it advertises as **"Zeemote: SteelSeries Free"**. Discontinued ~2014.

## Company / app status
- SteelSeries (GN Store Nord) is alive, but the Free was dropped long ago and the
  SteelSeries Engine no longer supports it. The Android SteelSeries Engine app is
  gone from current lineups.
- Crucially, **the Engine was only ever an optional convenience** (mouse/keyboard
  remapping on PC/Mac). The controller itself needs no software.

## Local feasibility verdict: CONFIRMED — two local modes, no app
From the official user guide (archived copy in workspace/, facts derived below):

### Modes (remembered across power cycles)
- **Gamepad Mode (default)** — standard BT HID gamepad for Android/PC/Mac.
- **Arcade Mode** — iCade-protocol Bluetooth keyboard for iOS (see
  icade-controllers.md for the keymap).
- Toggle: while powered OFF, hold **A+B for 3 s**. Power on: hold **A for 3 s**.
- LED: single blink = Gamepad mode, double blink = Arcade mode; blink every 1 s =
  disconnected, every 3 s = connected.

### Pairing
- Advertised name: `Zeemote: SteelSeries Free`
- Legacy PIN if prompted: **0000** (Android/Windows/Mac all documented)
- On iOS the passcode is "typed" via button key mappings (same iCade scheme).

### SteelSeries Engine (optional, historical)
Windows/Mac software for mouse/keyboard emulation and presets; a stripped-down
Android version only tested buttons and linked the game list. Never cloud-bound.
Its absence changes nothing about local HID operation.

## Community RE
- Bluez-IME (open source, F-Droid `com.hexad.bluezime` 1.20) treats the Free as a
  Zeemote-family device — its ZeemoteReader has a dedicated SteelSeries button
  report type (0x1C), confirming SPP/Zeemote heritage (see zeemote-js1.md).
- PPSSPP/RetroArch iCade modes cover Arcade mode.

## Open questions
- Does the Free expose the Zeemote SPP joystick service (like the JS1) in addition
  to HID? Bluez-IME's SteelSeries handling suggests yes — worth a live SDP scan.
- Whether the iCade keymap in Arcade mode matches the cabinet exactly (assumed).

## Sources
- SteelSeries Free user guide (steelseriescdn.com PDF; archived in workspace/) —
  modes, pairing, PIN 0000, "Zeemote: SteelSeries Free" name
- 148apps.com review (2012-12-11) — "Bluetooth keyboard emulation, similar to iCade"
- workspace/static/zeemote-js1/.../ZeemoteReader.java — SteelSeries report type 0x1C
