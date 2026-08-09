# Green Throttle Atlas Controller — Research Notes

Date: 2026-08-04. Category: Bluetooth Classic game controllers (HID + SPP).

## Product
Atlas Bluetooth controller (Green Throttle Games, 2012–2013, $29.99–49.99) for
Android phones/tablets driving a TV via the company's "Arena" app; up to 4
controllers on one device was its differentiator. Founded by Charles Huang
(Guitar Hero creator).

## Company / app status — fully dead
- Arena app pulled from Google Play in Nov 2013; company effectively shut down
  late 2013; Google acquired the assets/team, confirmed **2014-03-12**
  (TechCrunch, Droid Life, 9to5Google). Nothing of the platform survives.

## Local feasibility verdict: CONFIRMED for later units (HID firmware)
- A **2013-09-17 press release** (TriplePoint PR) announced "HID Compatible Atlas":
  *"Green Throttle's new firmware supports HID and Bluetooth SPP protocols.
  Developers may choose to integrate Green Throttle's proprietary SDK..."*
  → Units with the updated firmware pair as **standard BT HID gamepads** and need
  nothing else. Units running original firmware speak proprietary SPP and wanted
  the Arena/SDK stack (dead).
- Arena app APK: not attempted — package id unconfirmed (delisted Nov 2013,
  pre-dating most mirrors). Marked unfetchable unless a mirror surfaces.

## Protocol notes
- HID mode: standard gamepad, no vendor protocol.
- SPP mode: proprietary, undocumented publicly. The Arena APK (if ever found) would
  be the RE target; the Bluez-IME project never covered Green Throttle.

## Open questions
- Which firmware a given used unit runs, and whether the HID update can still be
  applied (the updater presumably lived in the Arena app — potentially a
  one-time dead-app dependency for old-firmware units).
- SPP protocol details (would need Arena APK or HCI snoop on hardware).

## Sources
- techcrunch.com/2014/03/12/googles-acquisition-of-green-throttle-games... (2014-03-12)
- droid-life.com/2014/03/12/google-buys-game-developer-green-throttle-games/
- pressreleases.triplepointpr.com/2013/09/17/green-throttle-games-announces-hid-compatible-atlas...
- allthingsd.com (2013-04-25) — original Arena experience review
