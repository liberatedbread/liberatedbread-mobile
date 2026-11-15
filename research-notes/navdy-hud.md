# Navdy HUD — Research Notes

## What it is
Crowdfunded ($599) dash-top projector HUD (shipped 2016-17): Android-based
display + steering-wheel "Dial", wired OBD-II cable to the car (contains an
**STN1110** OBD chip), and a **Bluetooth Classic** link to the phone for
navigation, notifications, calls and media. Navdy Inc. went bankrupt
**December 2017**; users were warned devices "may stop functioning".

Sources:
- https://www.digitaltrends.com/cars/navdy-shutting-down/ (2018-01-22)
- https://www.vegard.net/life-after-navdy/ (2019-10-19, owner write-up)
- https://www.failory.com/cemetery/navdy

## Cloud status: dead, dated
Retail ended Dec 2017; company email warned of shutdown Jan 2018. The stock
app depended on Navdy's account service plus Google Maps for Business / HERE
API keys that died with it. Unpatched, the unit still shows OBD speed/RPM but
loses maps/search/notifications.

## Community RE: unusually deep
- **Navdy-Hackers hub**: https://navdy-hackers.github.io/ (and
  github.com/Navdy-Hackers) — curated guides.
- **XDA [MOD][DEV] NAVDY Display thread** (xdaforums.com/t/mod-dev-navdy-display-hud.3784638):
  the display exposes **fastboot/ADB over micro-USB** (hold power while
  plugging in; red LED) — community ROMs flashable, current lineage ~build 3057.
- **GitLab group `alelec/navdy`** (active into 2026):
  - `display-rom` — ROM builder for the display
  - `alelec_navdy_client` — DexPatcher port of the stock Android app
    (package `com.alelec.navdyclient`) replacing dead Google/HERE API keys;
    prebuilt APKs published (base: Navdy app 1.3.1718)
  - forks: `navdy-display-Hud-java` / `navdy-display-Obd-java` — jadx dumps of
    the display's Hud.apk and Obd.apk (full on-device source, no RE needed)
- **Navdy-MapDownloader** (several GitLab forks) — local workaround to fetch
  HERE `diskcache-v5/v4` offline map packs.
- **NavdyOBD** (gitlab.com/loushaoke/NavdyOBD) — app that opens a *direct
  connection to the STN1110* in the HUD, i.e. the Navdy doubles as an
  STN11xx OBD adapter (command-compatible with the repo's existing
  obd2-bluetooth-adapter STN coverage).

## Transport summary
- Phone ↔ display: Bluetooth Classic (SPP-family socket; protocol source is in
  the jadx'd Hud.apk dumps — not yet distilled to a spec).
- Display ↔ car: wired OBD-II via STN1110 (ELM327-superset AT commands).
- Display ↔ PC: micro-USB ADB/fastboot (root-level local control).
- Dial ↔ display: proprietary link (likely BLE/2.4 GHz — undocumented).

## APK provenance
- Original Android app "Navdy" v1.3.1718: delisted; **not fetchable** via
  apkeep (tried `com.navdy`, `com.navdy.app`, 2026-08-04). Original package id
  unconfirmed.
- Patched rebuilds distributed via GitLab (`alelec_navdy_client` releases) —
  that is the practical source today.

## Local feasibility: CONFIRMED (moderate, community-paved)
Everything needed to run the unit without Navdy Inc. exists: patched app,
flashable ROMs, offline map workaround, and full decompiled on-device sources.
Distilling the phone↔display BT protocol from `navdy-display-Hud-java` into a
spec is greenfield but unblocked.

## Open questions
- Exact RFCOMM UUID(s)/frame format phone↔display (source available, unread).
- Dial pairing/protocol.
- Whether the STN1110 is reachable over BT from any host (NavdyOBD suggests yes).

## Safety
Display-only + read-only OBD. LOW.
