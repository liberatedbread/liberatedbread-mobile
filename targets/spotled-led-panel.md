# SPOTLED LED panels — target spec starter

## Target metadata
- target_id: spotled-led-panel
- app package_id(s): com.led.spotled (SPOTLED)
- iOS app id: 1564039607
- publisher: Wen Lv (Android) / Host No.4 Technology (Chengdu) Co., Ltd. (iOS)
- device class: wearable full-color LED matrix panels — hats, badges, backpack and
  hydration-pack skins, chest panels, flexible banner signs
- transport(s): BLE
- local-only viability: high — no pairing, no bonding, no auth, no account needed for
  device control

## Status
**Protocol mapped.** See `docs/devices/spotled-led-panel.md` (canonical) and
`device-specs/devices/spotled-led-panel.yaml`. This starter tracks what is left to verify
against real hardware and the open questions that need a device in hand.

## Why this target matters
SPOTLED is one of the highest-leverage single targets in the LED sign category: one protocol
covers products from dozens of unrelated resellers, claiming 140k+ users. A working local-first
client for `0xFF20` immediately serves LED hats, badges, chest panels, banner signs and the
Lunchbox / LEDs 2 RAVE 4 Dream Skin 2.0 and early 3.0 panels at once.

The app is rated ~2.7 on Play. The hardware long outlives it.

## Known facts (public + community RE)
- Full BLE protocol reverse engineered in `iwalton3/python-spotled` from BLE sniffing:
  service `0xFF20`, command `0xFF21`, data `0xFF22`.
- Design tool feature set: full-color text with fonts and effects, freehand graffiti, still
  image upload, GIF animation upload, music-rhythm display.
- Devices are connected from inside the app, not through system Bluetooth pairing.
- Geometry is queryable (`GetDisplayInfo`), so a client never needs a user-supplied panel size.

## Device discovery signals
- BLE:
  - service UUID: `0000ff20-0000-1000-8000-00805f9b34fb` — **the dependable signal**
  - advertised name: varies by reseller, no reliable family-wide prefix.
    Known: `LBXDRMSKIN_LED_` (Lunchbox Dream Skin)
  - address behavior: unconfirmed (assume public until observed otherwise)

## Threat model + guardrails
- Owned devices only. These panels accept commands from anyone in range with no bonding or
  auth — document as a wearer-privacy consideration, do not build tooling that targets panels
  worn in public.

## Remaining experiments
1) Confirm the CCCD handle. `0x0F` is observed on specific units and is currently hardcoded
   upstream; a portable client must discover it. Verify across at least two different
   reseller products.
2) Test a **full-color RGB** panel. Colour `Frame` records (type 96, depth 24) are implemented
   upstream but were never tested — the original author had only monochrome hardware.
   Confirm the bitmap byte layout and channel order.
3) Sweep MTU behaviour. `PauseSending` fires for chunks too large *or* too small; establish the
   working range on real hardware and confirm `(MTU - 3)` holds across firmware revisions.
4) Verify the `buffer_size / chunk_size` ack cadence matches observed `ContinueSending` timing
   (upstream comments describe it as "every 6 data commands", which may be a coincidence of one
   device's buffer size).
5) Enumerate advertised names across several reseller products to see whether any usable
   family-wide pattern exists beyond the service UUID.
6) **Probe an iLEDColor DreamPanel v3 for `0xFF20`.** If the new Lunchbox board still speaks
   SPOTLED, `targets/iledcolor-led-panel.md` collapses into this target. Cheapest possible test,
   highest payoff.

## Control surface inventory (replacement app MVP)
- scan by service UUID, connect without an account or system pairing
- bootstrap correctly: notifications, `GetBufferSize`, `GetDisplayInfo`
- render content to device-reported geometry and color depth
- brightness (0-100), screen mode (normal / flipped / mirrored)
- text with fonts, colors and the 8 scroll/stack/expand/laser effects
- still image and animated GIF upload with correct offset-resume flow control
- music-rhythm bar visualizer
- local design storage that survives an app reinstall

## References
- https://github.com/iwalton3/python-spotled
- https://pypi.org/project/spotled/
- https://play.google.com/store/apps/details?id=com.led.spotled
- https://apps.apple.com/us/app/spotled/id1564039607
- https://www.lunchboxpacks.com/blogs/resources/how-to-set-up-your-dream-led-skin-2-0
