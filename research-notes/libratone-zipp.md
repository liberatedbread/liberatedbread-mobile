# Libratone Zipp / Zipp Mini — Research Notes

## What it is
Danish Libratone's Wi-Fi multiroom speakers: Zipp (2015) and Zipp Mini,
Zipp 2/Mini 2 (2017, added Alexa). Libratone pivoted to earbuds years ago
and abandoned the speaker line; official protocol documentation was requested
and **declined by the vendor** (per Chouffy's RE notes). The local UDP
protocol was reverse-engineered instead — this is a confirmed community-RE
rescue.

## Local protocol — UDP, reverse-engineered
- Binary/JSON command protocol over UDP. Client must listen on **3333/udp**
  and **7778/udp** for speaker responses/events; discovery is "LSSDP"
  (Libratone's SSDP variant) — class `com.libratone.model.LSSDPNode` in the
  Android app.
- Command vocabulary recovered from APK decompilation + the LoxWiki command
  list (Benjamin Hanke). Implemented commands include play/pause/stop/
  next/prev, volume get/set, voicing (EQ) get/set + list, room-setting
  get/set, standby now + standby timer, favorite recall, name get/set,
  firmware version, serial, battery level, mute status, charging status.
  Unimplemented-but-identified command IDs (from the app): 10
  fetchSourceInfo, 103 fetchDeviceState, 152 fetchSource, 281
  fetchMusicServiceCapability, 304 fetchLimitedFunctionList, 520
  fetchMuteStatus, 530 fetchOtaAutoDownLoadStatus, 537 fetchWifiLinein,
  1284 fetchChargingStatus, 1285 fetchPrivateMode, 1536–1538 USB playback.
- Auth: none.

## Community implementations (confirmed)
- [Chouffy/python_libratone_zipp](https://github.com/Chouffy/python_libratone_zipp)
  (PyPI `python-libratone-zipp`; tested on Zipp 1, firmware 809/879) + HACS
  integration `Chouffy/home_assistant_libratone_zipp`.
- [abustany/libratone-rs](https://github.com/abustany/libratone-rs) —
  independent from-scratch Rust implementation of the same UDP protocol
  (Zipp Mini), which cross-confirms the RE.
- RE notes: chouffy.net/Hardware/Libratone Zipp (2024-02-20).

## APK
Not fetched (Libratone app); both existing implementations already decompiled
it and published the command tables — re-fetching adds nothing for a spec
beyond confirming IDs, which are listed above.

## Cloud steps required
None for control. Firmware updates and some streaming-service logins went
through Libratone's service; core playback control is LAN-local. AirPlay and
DLNA on the speakers are also local sinks.

## Open questions
1. Discovery: python lib uses fixed IP; LSSDP broadcast details should be
   pinned down from libratone-rs (it implements discovery).
2. Zipp 2 / Mini 2 (newer firmware) command drift — untested by either lib.
3. Favorites *definition* (not just recall) unimplemented.

## Safety
LOW — audio only.

## Sources (accessed 2026-08-07)
- github.com/Chouffy/python_libratone_zipp (+ README command tables)
- github.com/abustany/libratone-rs (2021-02)
- chouffy.net/Hardware/Libratone%20Zipp (2024-02-20)
- loxwiki.eu Libratone Zipp WLan Lautsprecher command list
