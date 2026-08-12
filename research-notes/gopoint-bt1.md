# GoPoint Technology BT1 / BT1A OBD-II adapter — Research Notes

## What it is
OBD-II dongle (~2011-2015) speaking **Bluetooth Classic SPP** (Android/PC)
and Apple iAP/MFi (iOS — BT1 was famously the *only* Apple-approved BT OBD
adapter). Notably **NOT ELM327-compatible**: "a very different chip and
protocol from all the others" (Harry's LapTimer dev, HP Tuners forum). GoPoint
also sold the cabled GL1.

## Cloud status: company effectively dead
- gopointtech.com is now a bare LiteSpeed directory listing (only a `blog/`
  dir dated 2023-02-23) — product pages, shop and support gone.
- The companion app ("BT1") is abandoned-era (v1.01, 2012-ish) yet still
  fetchable (below).
- Not a cloud device at all: everything was local dongle↔app. "Abandonment"
  here = dead vendor + aging app, not a shutdown.

## APK provenance
- **Package**: `com.gopoint.bt1`
- **Version**: 1.01 (versionCode 7), bare APK, 2.5 MB
- **SHA-256**: `dbacd1ea45f0bd0ea63d3ed89d8732dbe04c990779f2e2c4e2cfddec1ce61821`
- **Source**: apkeep / apk-pure, 2026-08-04
- jadx triage → `$REPO/workspace/static/gopoint-bt1/`

## Static findings (triage)
- `com/gopoint/bt1/scanmgr/a.java`: standard **SPP UUID
  `00001101-0000-1000-8000-00805f9b34fb`** — plain RFCOMM on Android.
- App is heavily identifier-obfuscated (single-letter classes throughout);
  no ELM327 `AT` command strings surfaced — consistent with the proprietary
  framing reported by third-party devs.
- `ScanService` / `DeviceListActivity` handle discovery/pairing.
- Hardware had a push-button pairing step (BT1 shipped with a pairing button;
  no fixed PIN dependency documented).

## Prior art
- TrackAddict and Harry's LapTimer both shipped working BT1 drivers —
  proof the protocol is learnable; neither is open source.
- GoPoint published a vendor "BT1 API" for app developers back when alive;
  copies may survive on archive.org (not yet located).
- No known open-source RE of the wire protocol.

## Local feasibility: UNPROVEN (moderate)
Transport is trivially local (SPP socket, no auth beyond pairing). The
application protocol needs RE from the small obfuscated APK or a live RFCOMM
capture from a dongle (plentiful/cheap on eBay). Value-add over the repo's
generic ELM327 coverage is mostly e-waste diversion — same calculus as the
automatic-adapter note.

## Open questions
- Is the BT1 protocol documented in the old vendor API PDFs (archive.org)?
- Does BT1A differ from BT1 on the wire?
- Any ELM327 emulation mode for generic tools? (none reported)

## Safety
Read/reset diagnostics only (app could clear DTCs). LOW.
