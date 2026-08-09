# Mimo Smart Baby Monitor (Rest Devices) — Research Notes

## What it is
Mimo (2013–2016, Rest Devices Inc., Boston) is a smart baby monitor: a
machine-washable kimono/onesie with two respiration sensor stripes and a
clip-on "turtle" module (nRF51822-class BLE) that streams breathing
waveform, body position, motion/activity, and skin temperature. The turtle
talks BLE to a "lilypad" base station, which relays over Wi-Fi to the
Mimo cloud; the phone app is a cloud client only.

## Why it's abandoned (dated sources)
- Latest Android app is v2.2.7, released 2016-01-18 (APKPure version
  history, `com.restdevices.mimo`). No updates in 10 years; delisted from
  Google Play.
- 2017-03: last sign of life — J&J's "Nod" sleep-coaching app built on
  Mimo hardware (https://www.mddionline.com/digital-health/how-a-new-app-is-helping-babies-and-parents-get-more-sleep).
- Verified 2026-08-04: `mimobaby.com` is now a squatted Indonesian
  gambling-spam page — the company domain is fully dead.

## Local BLE feasibility: CONFIRMED (community protocol exists)
Jason Kridner (BeagleBoard.org) connected a BeagleBone directly to the
turtle over BLE with bluepy — no base station, no cloud:
- Part 1: https://www.beagleboard.org/blog/2015-11-30-baby-monitor-using-beaglebone-and-mimo-smart-baby-monitor-sensor-part-1
- Code + raw captures: https://gist.github.com/jadonk/f2323348eb7706889f88
- Frame-format breakdown provided by a Rest Devices employee:
  https://forum.quantifiedself.com/t/tapping-into-mimo-smart-baby-monitor/1758
  (respiration, motion, temperature layout)

GATT (from live capture, not the APK):
- Service: `d96a513d-a6d8-4f89-9895-ca131a0935cb`
- Characteristic: `c3ae33e1-e40c-4137-a040-adbab921d894` (READ + NOTIFY)
- 20-byte frames beginning `AA ED 18 ...`; respiration samples arrive as
  a stream of notifications; example frames in the gist.

## APK Provenance
- **Package**: `com.restdevices.mimo` v2.2.7 (versionCode 2270001), 3.36 MB
- **Source**: apkeep (APKPure mirror)
- **SHA-256**: `648603a933ee5bba855d9701d8a05d082af50ff2cf8a8e59d7e30b08c65b10e7`
- jadx decompile OK (workspace/static/mimo-baby-monitor). **The app
  contains no `android.bluetooth` code at all** — it is purely a
  WebSocket/cloud client (`WebSocketService`, Count.ly, Crittercism,
  Nest OAuth integration). The only UUID-looking strings are a WebSocket
  RFC 6455 GUID and a Nest client ID. The APK is therefore useless for
  BLE protocol recovery; the jadonk captures are the primary source.

## What needs cloud
Everything in the stock UX (history, alerts, multi-phone sync) — the app
has no local mode. The turtle itself streams live data to any BLE central
with zero pairing ceremony (confirmed by the bluepy capture), so local
monitoring is fully practical with a custom client.

## Open questions
- Full byte-level frame spec: QS-forum post gives field layout; should be
  re-captured and codified (frame types `...18 00...` vs `...18 01...`).
- Turtle↔lilypad pairing: does the turtle bond to the base station, and
  does that exclude a second central? (bluepy connected unpaired.)
- Lilypad base-station local protocol (Wi-Fi) unexplored — may allow
  local relay without cloud.
- Battery/charging cradle details; firmware update path unknown.

## Safety
MEDIUM — parents use this for infant breathing reassurance. Any local
client must present data verbatim and must not be represented as a
medical/SIDS-prevention alarm. Consumer wellness device, not FDA-cleared.
