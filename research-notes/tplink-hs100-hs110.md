# TP-Link HS100/HS110 Smart Plug (Kasa era) — Research Notes

## What it is
TP-Link Kasa HS100 (switching) and HS110 (switching + energy monitoring) Wi-Fi
smart plugs, ~2015-2018. Same protocol family covers HS103/HS105, KP115 and
early Kasa bulbs. TP-Link the company is alive, but this plaintext local
protocol was **abandoned in newer firmware**: HS100 hw v4 with fw 1.1.0
(~2020) closed port 9999 ("Enhanced total encryption and security"), and newer
hardware moved to AES/KLAP with cloud-tied credentials.

## Local protocol — fully documented, confirmed
Reverse engineered by softScheck (blog 2016-07-29, repo
[softScheck/tplink-smartplug](https://github.com/softScheck/tplink-smartplug)):

- **TCP port 9999**, JSON commands, trivial XOR autokey "encryption"
  (initial key 0xAB = 171; each ciphertext byte XORed with previous plaintext
  byte). No authentication at all — commands accepted in any device state.
- **Discovery**: XOR-encoded JSON broadcast to UDP 9999; reply contains full
  sysinfo (alias, MAC, model, relay state, RSSI).
- **Commands** (JSON, nestable): `{"system":{"set_relay_state":{"state":1}}}`,
  `{"system":{"get_sysinfo":null}}`, HS110 energy:
  `{"emeter":{"get_realtime":null}}` (voltage/current/power/total).
- Full command list in `tplink-smarthome-commands.txt` in the softScheck repo.

Community implementations: [python-kasa](https://github.com/python-kasa/python-kasa)
(powers the Home Assistant `tplink` integration, `iot_class: local_polling`),
softScheck's own Python client + Wireshark dissector.

## Cloud dependency: none, even for provisioning
- Day-to-day control is 100% LAN; block WAN at the router and everything works.
- Initial provisioning can also be done without any account: plug exposes an AP
  (`TP-LINK_Smart Plug_XXXX`), and the XOR protocol exposes
  `netif.set_stainfo` to join it to the home Wi-Fi (python-kasa `kasa wifi
  join`, or the Kasa app used without signing in).
- The only cloud involvement is optional firmware updates / remote access via a
  Kasa account — and firmware updates are a **risk** (see next section).

## Trap for new players
Units that auto-updated to fw 1.1.0 (hw v4) lost port 9999; HA community
thread 2020-11-11 documents plugs "disappearing" after update. Recommendation
for repo users: block the plug from the internet to preserve the local API.
Newer Kasa devices (EP25, KP125M, TAPO P110 etc.) use different protocols —
out of scope for this note.

## APK
Not needed — protocol is community-documented with multiple independent
implementations. Companion app `com.tplink.kasa_android` not fetched.

## Safety
LOW. Mains-rated relay (13-16 A depending on region); no auth on the protocol
means anything on the LAN can toggle the load — segment accordingly.
