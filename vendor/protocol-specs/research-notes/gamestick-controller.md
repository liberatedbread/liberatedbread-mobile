# PlayJam GameStick Controller — Research Notes

Date: 2026-08-04. Category: Bluetooth Classic game controllers (HID).

## Product
GameStick (PlayJam, Kickstarter 2013): an HDMI-stick Android microconsole plus a
Bluetooth Classic gamepad (with a storage slot for the stick). Extra controllers
were sold separately for local multiplayer.

## Company / cloud status
- GameStick servers became unresponsive in **2016**; PlayJam announced the official
  death of the console in **2017** (cweiske.de research blog, 2023-04-17).
- The gamestickers.net community forum shut down in 2023.
- The console UI requires server responses for OOBE update-check and registration;
  cweiske reverse-engineered the API (firmware v2058/v2071 images, mitmproxy +
  jadx; the update endpoint was `http://update.gamestickservices.net/check.php`)
  and bootstrapped a community replacement. This is a *console* problem.

## Local feasibility verdict: CONFIRMED (controller), console needs the RE'd server
- The GameStick controller is a **standard BT Classic HID gamepad** — it pairs with
  PCs/Android as a generic controller (contemporaneous analyses group it with the
  OUYA pad as plain HID, e.g. mgarcia.org C.T.R.L.R analysis, 2013-12-16).
- No companion phone app ever existed for the controller.
- The console hardware is usable today only via the community server work above,
  but the controller needs nothing.

## Pairing
- Pair from host OS Bluetooth settings; controller advertises as "GameStick"
  HID device. (Exact pairing-button hold: hold the GameStick/system button to
  enter pairing — verify against a unit; PlayJam docs are offline.)

## Community RE
- cweiske.de "GameStick: First game installation since 6 years" (2023-04-17) —
  full server API reverse engineering; GameStick Fans Discord holds cache/APK dumps.

## Open questions
- HID descriptor / button map quirks — not yet captured; trivial with btmon.
- Whether the controller has a second (proprietary) mode when bound to the stick
  (no evidence of one; believed pure HID).
- Exact pairing button combo (PlayJam manuals offline; Wayback may have the PDF).

## Sources
- cweiske.de/tagebuch/gamestick-first-install.htm (2023-04-17) — server death 2016/2017, API RE
- cnet.com/reviews/playjam-gamestick-preview/ — product background
- mgarcia.org/2013/12/16/4-Mad-Catz-M-O-J-O-The-C-T-R-L-R/ — GameStick pad classed as plain HID
