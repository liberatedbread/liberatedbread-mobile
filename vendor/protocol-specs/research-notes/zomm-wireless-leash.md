# ZOMM Wireless Leash — Research Notes

## What This Is
ZOMM Wireless Leash (2010–2013; ZOMM LLC, Tulsa OK — Shark Tank S4, 2012).
Key-fob sized BT gadget: phone-separation alarm ("leash"), two-way key finder,
speakerphone, and panic/emergency-call button. Company **dead**: site dark by
2015 (Woot forum), company "shut its doors in 2018" after suing Apple
(SlashGear retrospective, 2025-05-30).

## Cloud dependency (important)
- Feature configuration (leash range short/long, tones, emergency number)
  was done via a **My.ZOMM.com account** + USB/website sync (CNET review).
  That service is dead — advanced reconfiguration of stored profiles is lost.
- Core functions need **no cloud**: pairing is standard Bluetooth; the leash
  alarm fires on link loss (you can even trigger it by toggling the phone's
  Bluetooth off, per the Woot FAQ). Documented one-time/historical cloud
  dependency only.

## Transport (from app static analysis + manual)
- Bluetooth Classic (BR/EDR). Device side: **HFP 1.5 / HSP** (pairs as a
  hands-free/headset — Newegg-hosted official manual).
- Android app talks to the fob over RFCOMM with a **custom SPP UUID**:
  `5a4f4d4d-5f41-4e44-524f-49445f534543` — ASCII for `ZOMM_ANDROID_SEC`
  (from `bluetooth/ZBluetooth.java:130`).
- App also opens a listening RFCOMM socket on standard SPP UUID
  `00001101-0000-1000-8000-00805f9b34fb` (`ZBluetoothService.java:75`).

## Protocol (from com.zomm v2.0.16 DEX)
The app emulates the HFP Audio-Gateway side with canned AT responses and adds
ZOMM vendor extensions:
- Version query: `AT+ZOMM?` → `+ZOMM:` responses (`HFP_AG_ZOMM_VERSION_REQ`)
- Config read: `\r\n+ZOMM:\r\n` (`HFP_AG_READ_CONFIG_REQ`)
- Standard HFP SLC canned strings: `+BRSF: 99`, `+CIND:` indicator list,
  `+CIEV: 5,4` (battery-level indicator)
- Z-protocol service IDs: 0=reserved, 1=proximity, 2=telephony,
  3=physical_activity, 4=temperature, 5=battery, 6=emergency, -2=diagnostic
- Value opcodes: 64=GET_REQUEST, 65=GET_CONFIRM, 66=SET_REQUEST,
  67=SET_CONFIRM, 68=INDICATION
- Value IDs: 1=battery_state, 2=battery_level, 3=alerting_state /
  config_param; immediate-alert values 0=none, 1=leash, 2=panic, 3=chirp,
  4=silent, 5=silent_leash
- Feature bitmask (PSKEY_FEATURES=11): 128=leash, 64=leash_vibrate,
  32=leash_audio, 16=leash_lights, 2048=panic; plus enable/disable masks
  (e.g. 65407 = enable leash)
- PSKeys: 8=ecall number, 11=features, 16=device name, 19=volumes
- Exact binary frame layout for the value get/set PDUs not yet traced —
  next step is following `ZBluetooth.write()` callers.

## APK Provenance
- **Package**: `com.zomm` ("myZOMM"), version 2.0.16 (versionCode 16)
- **Source**: apkeep, `apk-pure`
- **SHA-256**: `91de8877c15d017303e6b917506e53eee50cb917c72b06b8fecaa44ee4edb104`
- ~3.9 MB, native Java, unobfuscated (`com.zomm.*` intact); Google Maps v1
  era (readystatesoftware mapviewballoons).

## Feasibility
- **Confirmed local use**: pair as HFP hands-free with any OS today; link-loss
  alarm and Z-button work without any software. 
- **Full local control hypothesis (strong)**: the app proves a complete local
  config/alert protocol over RFCOMM — a clean-room client can talk to the fob
  with zero cloud. Needs one HCI snoop or further DEX tracing for frame layout.

## Sources
- SlashGear (2025-05-30), company shut down 2018:
  https://www.slashgear.com/1868313/what-happened-zomm-wireless-tether-shark-tank-season-4/
- Woot forum (2015-04-20), "ZOMM is out of business":
  https://forums.woot.com/t/zomm-wireless-leash-for-cellphones/118534
- CNET review (config via My.ZOMM.com account):
  https://www.cnet.com/reviews/zomm-wireless-leash-review/
- Official manual (HFP 1.5/HSP profiles), Newegg mirror:
  https://images10.newegg.com/UploadFilesForNewegg/itemintelligence/UserManual/75-995-220.pdf
- Gadgeteer review (pairing: hold Z button 9 s from off):
  https://the-gadgeteer.com/2012/12/23/zomm-wireless-leash-review-2/
