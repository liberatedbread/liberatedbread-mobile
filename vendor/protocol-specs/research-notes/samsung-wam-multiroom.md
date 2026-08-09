# Samsung Wireless Audio Multiroom (WAM) / Radiant360 R-series — Research Notes

## What it is
Samsung's pre-SmartThings multiroom audio system (~2014–2017): Radiant360
R1/R3/R5/R7 speakers (WAM150/250/350/750), WAM270/750 curved and M-series
soundbars, WAM250/550/750 hubs. Samsung discontinued the hardware and let the
"Samsung Multiroom" app rot (Play Store listing abandoned; users report
forced-migration breakage) — the local API is the rescue.

## Local protocol — documented, no auth
- **HTTP on port 55001**, XML-in-URL command format:
  `http://<ip>:55001/UIC?cmd=<pwron>on</pwron><name>SetVolume</name><p type="dec" name="volume" val="20"/>`
- Canonical RE documentation: [bacl/WAM_API_DOC](https://github.com/bacl/WAM_API_DOC)
  (2017, full command list extracted from the app — 200+ commands).
- Discovery: SSDP (UPnP MediaRenderer) — speakers also expose standard
  DLNA rendering; the 55001 UIC API is the control plane.
- Multiroom grouping commands (`SetSpkGroup` family), input select
  (`SetFunc`: wifi/bt/aux/hdmi/optical), EQ, player queue, URL playback
  (`SetUrlPlayback`), TuneIn preset recall.
- Auth: none.

## Community implementations (confirmed)
- [krygal/samsung_multiroom](https://github.com/krygal/samsung_multiroom) —
  Python API wrapper (MIT, 2018–19).
- npm `samsung-multiroom` (cosminlupu, tested on R1; get/set volume, mute).
- [Strixx76/samsungwam](https://github.com/Strixx76/samsungwam) — Home
  Assistant custom integration (2023), speakers + soundbars.
- VoxCommando users run it via plain HTTP scrape actions (forum, updated
  2026-04) — confirms the API still works on surviving units.

## APK
Not fetched — command set already extracted and published (bacl/WAM_API_DOC);
the delisted Samsung Multiroom app adds nothing a spec needs. Provisioning
caveat: initial Wi-Fi setup historically went through the app; speakers
retain credentials and support WPS, so a spec should document WPS/AP-mode
onboarding as the app-free path.

## Cloud steps required
None for control. The speakers' UPnP/DLNA renderer and the entire 55001 API
are LAN-local. Spotify Connect on these units was firmware-side and is
degraded/dead; local `SetUrlPlayback`/DLNA covers streaming.

## Open questions
1. Event/push channel: UIC API is poll-only; volume/playback changes made on
   the device need polling (Strixx76 integration polls).
2. Exact grouping sync behavior (which units allow slave grouping after app
   deprecation).

## Safety
LOW — audio only.

## Sources (accessed 2026-08-07)
- github.com/bacl/WAM_API_DOC (2017-04)
- github.com/Strixx76/samsungwam (2023-03)
- github.com/krygal/samsung_multiroom
- npmjs.com/package/samsung-multiroom
- voxcommando.com forum topic 2773 (HTTP command examples, updated 2026-04-24)
