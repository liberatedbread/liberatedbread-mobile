# Securifi Almond / Almond 2015 / Almond+ / Almond 3 — Research Notes

## What it is
Touchscreen Wi-Fi routers with built-in Zigbee + Z-Wave radios (Almond+ 2014,
Almond 3 2016; Almond/Almond 2015 are radio-less but share the UI). Sold as
"router + smart-home hub" with local-first management.

## Company status (checked 2026-08-07) — effectively dead
- `securifi.com` responds today but the page is infested with casino/pharma
  spam links — domain abandoned, squatted or hijacked. Support/forums long
  gone; the Almond app is delisted (see APK below). Treat the ecosystem as
  orphaned: **local paths are the rescue**.

## Local control — confirmed (vendor feature, works with WAN down)
- Full local web UI on the router (port 80, default admin password set at
  local touchscreen setup): the **Sensors tab** adds/controls/views paired
  Zigbee/Z-Wave devices and rules — no account needed
  ([SmallNetBuilder Almond+ HA review](https://www.smallnetbuilder.com/smarthome/smarthome-reviews/securifi-almondplus-home-automation-features-reviewed/)).
- The capacitive touchscreen duplicates the same control offline.
- Cloud ("Almond account") was only ever for remote access — optional at setup
  ([SmallNetBuilder Almond+ review](https://www.smallnetbuilder.com/wireless/wireless-reviews/securifi-almondplus-reviewed/)).

## Programmatic API — hypothesis
No vendor or community-documented programmatic local API found. The web UI is
form/AJAX-driven, so endpoints are recoverable from the UI's own JS or by
proxying a browser session — straightforward but not yet done. The Android
app also talked to the hub on the LAN; its protocol is undocumented.

## APK — fetch attempt failed
- `com.securifi.almond`: apkeep google-play and apk-pure both fail
  (2026-08-07) — app delisted. Would need a third-party mirror (APKMirror
  hosts historical Almond builds) if protocol RE is wanted later.

## One-time cloud steps
None. Setup and control are local by design.

## Rating
**Confirmed** for web-UI local control (vendor feature, reviews verified);
**hypothesis** for scriptable endpoints.
