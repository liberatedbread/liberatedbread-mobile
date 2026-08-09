# ION Audio iCade Line — Research Notes

Date: 2026-08-04. Category: Bluetooth Classic game controllers (HID keyboard).

## Products
iCade arcade cabinet for iPad (2011, ThinkGeek/ION Audio), iCade Jr (iPhone),
iCade Mobile, iCade Core, iCade 8-bitty. All Bluetooth Classic, all present as
**BT HID keyboards**. The "iCade protocol" became a de-facto standard also used by
iControlPad, Gametel, SteelSeries Free (Arcade mode), early 8BitDo (NES30/SNES30
iCade mode) and others.

## Company / app status
- ION Audio still exists (inMusic Brands) but the iCade line is long discontinued
  (~2011–2014); the ionaudio.com iCade developer resource and games list are offline.
- **No companion app ever existed or was needed** — inputs arrive as ordinary
  keyboard events. Nothing cloud, nothing to shut down. This is the canonical
  "dead product that keeps working locally" case.

## Local feasibility verdict: CONFIRMED — plain HID keyboard, works forever
Any BT-HID-keyboard-capable host (Android, iOS, Linux, Windows, macOS) can pair and
receive input. The only task for a host implementation is the keymap, below.

## Protocol: press/release letter pairs
Each control emits ONE keypress event on press and a DIFFERENT keypress on release
(no key repeat; slight release latency). Canonical mapping (confirmed by Bluez-IME
iCadeReader.java HID usage codes, F-Droid build com.hexad.bluezime 1.20):

| Control | Press key | Release key |
|---|---|---|
| Stick Up    | w | e |
| Stick Down  | x | z |
| Stick Left  | a | q |
| Stick Right | d | c |
| Button 1 (A) | y | t |
| Button 2 (B) | u | f |
| Button 3 (C) | i | m |
| Button 4 (D) | o | g |
| Button 5 (X) | h | r |
| Button 6 (Y) | j | n |
| Button 7 (Z) | k | p |
| Button 8 (W) | l | v |

(8-bitty exposes the same scheme; button naming varies by device.)

## Pairing specifics
- **iCade cabinet**: pairing mode = hold bottom 4 buttons + top white button ~4 s,
  release. The host shows a numeric passcode which must be "typed" on the cabinet:
  stick Up=1, Down=2, Left=3, Right=4, top red=5, bottom red=6, top-left black=7,
  bottom-left black=8, top-right black=9, bottom-right black=0, white buttons=Enter
  (Wikipedia pairing section).
- **8-bitty**: hold the two center buttons 4 s; no passcode needed (FCC ID
  V77-9ECEA manual, fcc.report).
- Device name: "ION iCade Game Controller" (cabinet) / "8-bitty".

## Community RE / tooling
- Bluez-IME (open source, F-Droid archive `com.hexad.bluezime` 1.20) contains a
  full iCade HID driver — keymap above derived from it.
- RetroArch, PPSSPP, Emu-EX-plus-alpha and many emulators have a built-in
  "iCade mode" toggle.
- Manomio's unofficial iOS SDK (historical) and ION's developer doc (archived).

## Open questions
- Per-model button numbering differences (8-bitty vs cabinet vs Mobile) — the
  press/release letter *pairs* are stable across the line, but physical labels vary.
- iCade Mobile / Core pairing PIN entry method (assumed same digit scheme as cabinet).

## Sources
- en.wikipedia.org/wiki/ICade — overview, pairing digit map, "essentially a BT keyboard"
- retrorgb.com/icadecontrollers.html — press/release behaviour, ecosystem
- fcc.report/FCC-ID/V77-9ECEA — 8-bitty manual (4-second two-button pairing, no PIN)
- forum.kodi.tv/showthread.php?tid=143187 — 8-bitty "actually a Bluetooth keyboard"
- workspace/static/zeemote-js1/.../iCadeReader.java — keymap verification
