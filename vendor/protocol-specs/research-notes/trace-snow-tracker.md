# Trace (AlpineReplay) Action-Sports Tracker — Research Notes

## What it is
- **Trace** is a small ruggedized BLE+GPS IMU puck (Kickstarter 2013 by ActiveReplay/AlpineReplay, shipped 2014) for surf/snow/skate. Clips to a board or helmet, records up to ~50 sessions onboard, syncs to phone over BLE.
  - [TechCrunch 2013-07-31](https://techcrunch.com/2013/07/31/activereplays-trace-wants-to-bring-quantified-self-tech-to-action-sports-for-players-and-spectators/), [Delve design case study](https://www.delve.com/work/alpinereplay-trace-action-sports-tracker)
- Companion apps: **Trace Snow** (formerly AlpineReplay, `com.alpinereplay.android`), Trace Surf, Trace Skate. Trace Snow also worked phone-GPS-only (no hardware required).

## Why it's abandoned
- Company (AlpineReplay, Inc., later "Trace") pivoted away from action sports to AI soccer cameras (TraceCam) between 2018–2020; the snow/surf/skate line was dropped. Company alive but is now a completely different product ([yespress company timeline](https://yespress.io/trace)).
- Trace Snow app last updated **2017-01-07 (v5.6.3)**; pulled from Play Store — `com.alpinereplay.android` returns **404** (verified 2026-08-04). Backend (alpinerеplay.com / snow.traceup.com) dead.
- Users stranded: [NYSkiBlog thread 2020-12-31](https://nyskiblog.com/forum/threads/ski-tracking-apps-and-stats.791/page-3) ("the app went away so abruptly and without warning"). Slopes built an importer for orphaned Trace recordings ([getslopes.com/import/trace](https://getslopes.com/import/trace)).

## Local feasibility — strong
- **Full named GATT table recovered** from the app's own sync SDK (`com/traceup/core/sync/sdk/TRCSDK.java`) — see below. Recording start/stop, file listing, disk space, LED control, firmware version, GPS satellite status are all plain named characteristics.
- Device advertises with name **"Trace"** (`BluetoothPairingManager.java` matches `d.getName().equalsIgnoreCase("Trace")`).
- Prior community RE: [github.com/wfraser/arz](https://github.com/wfraser/arz) — reverse-engineers Trace Snow's internal `.arz` session file format (files pulled from `Android/data/com.alpinereplay...`), useful for decoding sessions after BLE offload.
- No pairing crypto evident at triage depth. Cloud was only needed for leaderboards/social/3D replay.

## APK Provenance
- **Package**: `com.alpinereplay.android` ("Trace Snow Ski Snowboard Track")
- **Source**: apkeep, `apk-pure`
- **APK SHA-256**: `7a25b85781b26883ddf241c5e58b07466a12afae1aa018f7ca2509f4690f29a8` (39.6 MB)
- **Version**: 5.6.3 (2017-01-07, per Uptodown/apk.gold metadata)
- **Framework**: native Java, unobfuscated sync SDK (`com.traceup.core.sync.sdk`)

## BLE UUIDs (from TRCSDK.java — all named in source)
| UUID | Role |
|------|------|
| `0000A100-8501-11e3-ba12-0002a5d5c51b` | TRACE_SERVICE |
| `0000a101-...-0002a5d5c51b` | CHAR_RECORDING (start/stop recording) |
| `0000a102-...` | CHAR_STATUS |
| `0000a103-...` | CHAR_BATTERY |
| `0000a104-...` | CHAR_FILES (session file list) |
| `0000a105-...` | CHAR_CLEAR_FILES |
| `0000a106-...` | CHAR_DISK_SPACE |
| `0000a107-...` | CHAR_BT21_STATUS |
| `0000a108-...` | CHAR_BT21_CONTROL |
| `0000a109-...` | CHAR_FIRMWARE |
| `0000a110-...` | CHAR_REBOOT |
| `0000a111-...` | CHAR_LED_CONTROL |
| `0000a112-...` | CHAR_HARDWARE |
| `0000a113-...` | CHAR_SESSION_LENGTH |
| `0000a114-...` | CHAR_MAX_VELOCITY |
| `0000a117-...` | CHAR_RESET_MAX_VELOCITY |
| `0000a118-...` | CHAR_ALTITUDE |
| `0000a119-...` | CHAR_GPS_SATELLITE_STATUS |
| `0000a120-...` | CHAR_GPS_SATELLITE_LIST |
| `0000a121-...` | CHAR_GPS_REQUEST_INFO |
| `0000a122-...` | CHAR_GPS_REQUEST_INFO_RESPONSE |

(All share the `0000a1XX-8501-11e3-ba12-0002a5d5c51b` base.) App also defines SPP UUID `00001101-...` for BT2.1 legacy transfer. Session file transfer mechanism (which characteristic streams `.arz` payloads) not yet pinned down — next step.

## Open questions
1. File-download path: which characteristic streams session files, and in what framing?
2. Any write-key/ACK handshake on CHAR_RECORDING? (Static read suggests plain writes.)
3. Does puck work for surf/skate with same GATT (Trace Surf/Skate apps likely share SDK)?

## Status
- APK acquired: yes. Decompiled: yes (triage). UUIDs: fully recovered with names. Protocol: partial. HCI snoop helpful but a naive GATT client may already suffice.
- safety_class: LOW (sports metrics only).
