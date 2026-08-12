# Sony Ericsson LiveView (MN800) — Research Notes

2010 clip-on/wrist Bluetooth display for Android phones. One of the earliest
community reverse-engineering successes — plain SPP, trivial binary protocol,
fully local by design (predates cloud-everything).

## Device / Company Status
- **Product**: Sony Ericsson LiveView MN800 (2010): 128x128 OLED, 4 buttons +
  touch edges, vibrate, LED, ~4-day battery.
- **Company**: Sony Ericsson joint venture ended — Sony completed the buyout of
  Ericsson's stake in Feb 2012 and renamed to Sony Mobile; the LiveView line was
  abandoned in favour of the SmartWatch (MN2) the same year. Companion app last
  updated ~2012 (v1.0.A.0.23), long delisted from Play.
- Product infamous for connection-drop bugs — a big motivation for the community
  to replace the official app entirely.

## Local Feasibility: CONFIRMED
- **Transport**: Bluetooth Classic 2.1, SPP/RFCOMM, standard SPP UUID
  `00001101-0000-1000-8000-00805F9B34FB`. Confirmed in the official app:
  `com/sonyericsson/extras/liveview/btdisplay/JerryBTManager.java:364`
  (`createRfcommSocketToServiceRecord(JERRY_UUID)`), `JERRY_UUID` defined in
  `JerryDisplayService.java`. No cloud involvement at any layer.
- **Community RE (2011-2012)**: XDA thread "LiveView reverse-engineering effort"
  (xdaforums.com/t/liveview-reverse-engineering-effort.1422106/) — protocol
  mapped by archivator/boombuler/pedrodh; open-source replacement app
  "OpenLiveView" was built from it.
- **Maintained implementation today**: Gadgetbridge ships a LiveView driver
  (codeberg.org/Freeyourgadget/Gadgetbridge — "Supports Pebble, Mi Band,
  Liveview, ..."), so the protocol is available as working, current Java code.
  iOS PoC: github.com/AriX/iLiveView.
- Protocol shape (from community docs + Gadgetbridge driver): small binary
  frames over SPP — 1-byte message ID, length, payload; messages for time,
  display text/bitmaps, menu items, LED, vibrate; device reports button presses
  and capabilities. Trivial to implement from any language with an RFCOMM socket.

## APK Provenance
- **Package**: `com.sonyericsson.extras.liveview`
- **Source**: apkeep, APKPure. Only version listed: `1.0.A.0.23`.
- **SHA-256**: `2481e9687cdf13519d9f976d7cbfa2a43a059ad60843be7934ab871aea1572c0` (993,393 bytes)
- Stock app runs on Android 2.x-4.x era devices; Gadgetbridge is the modern path.

## Open Questions
- Original OpenLiveView repo (boombuler/OpenLiveView) now 404s on GitHub —
  Gadgetbridge is the canonical living implementation; confirm which commit
  imported the LiveView driver for attribution.
- LiveWare-era plugin model details only matter for the stock app, not for
  re-implementations.

## Sources
- xdaforums.com/t/liveview-reverse-engineering-effort.1422106/
- codeberg.org/Freeyourgadget/Gadgetbridge (LiveView driver)
- github.com/AriX/iLiveView
- coolsmartphone.com/2012/01/31/sony-ericsson-liveview-is-not-dead-yet/
- Static pass: jadx on com.sonyericsson.extras.liveview 1.0.A.0.23 (workspace/static/liveview)
