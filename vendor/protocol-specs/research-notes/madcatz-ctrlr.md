# Mad Catz C.T.R.L.R — Research Notes

Date: 2026-08-04. Category: Bluetooth Classic game controllers (HID; dual-radio).

## Product
Mad Catz C.T.R.L.R (2013): full-size BT gamepad with phone "Travel Clip", 5
dedicated media buttons, 2×AAA batteries. Two hardware variants matter:
- **M.O.J.O.-bundled C.T.R.L.R** (silver media buttons): **BLE-only** (HID over
  GATT) — ships with a USB BT4 dongle for non-HOGP hosts. Out of Classic scope
  but noted for completeness.
- **Retail C.T.R.L.R**: **dual-mode radio — Bluetooth Classic 2.1 AND BLE (HOGP)**,
  same HID mappings in all modes (per Mad Catz developer doc
  CTRLR_M.O.J.O._Info_v1_6.pdf, analysed at mgarcia.org 2013-12-16).

## Company / app status
- Mad Catz Interactive filed for bankruptcy **2017-03-30** and liquidated; the
  brand was bought and relaunched by unrelated Mad Catz Global (2018). The
  C.T.R.L.R and its optional config app are long discontinued and unsupported.
- The "C.T.R.L.R app" was only a key-remapping convenience; every mode is plain
  HID, so its loss is inconsequential.

## Local feasibility verdict: CONFIRMED — three HID modes, zero software
Mode selected by a physical slide switch on the controller front:
1. **GameSmart Mode** — standard HID gamepad for Android (gaming + navigation).
2. **Mouse Mode** — BT HID mouse (left stick = cursor, right stick = wheel,
   buttons = clicks); usable for touch-style UI navigation.
3. **PC Mode** — standard HID gamepad mapping (numbered buttons, stick axes,
   d-pad as POV hat) for Windows/Mac/Linux; no drivers needed.

No cloud, no account, no app. Pairs from OS Bluetooth settings (Classic on the
retail unit; HOGP on BLE hosts).

## Community RE / notes
- mgarcia.org's 4-page M.O.J.O./C.T.R.L.R analysis (2013-12) remains the best
  public technical write-up, quoting the Mad Catz developer document directly.
- Works with generic gamepad-remapping tools (e.g. Game Controller 2 Touch PRO's
  compatibility list includes "Mad Catz Controller").

## Open questions
- Retail vs M.O.J.O. SKU identification from packaging/label (media-button colour
  is the documented tell).
- Whether the Android config app survives on any mirror (package id unconfirmed;
  not attempted — unnecessary for operation).

## Sources
- mgarcia.org/2013/12/16/4-Mad-Catz-M-O-J-O-The-C-T-R-L-R/ — dev-doc analysis,
  3 HID modes, two radio variants
- techpowerup.com/185483 — C.T.R.L.R announcement, HID modes (2013-06-11)
- hardforum.com/threads/mad-catz-goes-bankrupt.1928675/ (2017-03-31); bankruptcy
  and 2018 brand relaunch widely reported
