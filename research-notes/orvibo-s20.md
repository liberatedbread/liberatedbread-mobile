# Orvibo S20 (WiWo era) Wi-Fi Socket — Research Notes

## What it is
Orvibo S20 / WiWo-S20 Wi-Fi smart socket (~2013-2016), one of the first cheap
Wi-Fi plugs. Sold under WiWo branding; companion apps were "WiWo" / "Livermore"
era, later folded into Orvibo's HomeMate app. Orvibo (Shenzhen) is alive as a
company; the S20 hardware line is long EOL but the local protocol never changed.

## Local protocol — confirmed, multiple independent REs
Documented by Andrius Štikonas (blog 2015-02-24,
[stikonas.eu reverse-engineering writeup](https://stikonas.eu/wordpress/2015/02/24/reverse-engineering-orvibo-s20-socket/))
and implemented in
[happyleavesaoc/python-orvibo](https://github.com/happyleavesaoc/python-orvibo)
(powers the Home Assistant `orvibo` switch integration, `iot_class: local_polling`)
and node.js `ninja-allone`/`node-s20` code:

- **UDP port 10000** for discovery and control. All packets start with the
  magic word `0x68 0x64` ("hd") followed by a 2-byte little-endian length and
  a 2-byte command code.
- **Discovery**: broadcast `68 64 00 06 71 61` to port 10000; sockets reply
  with MAC and status.
- **Subscribe/session**: client sends a subscribe packet (`0x636c`) containing
  its MAC padded with spaces + reversed MAC; device replies with state
  (observed example `68 64 00 1e 63 6c ...`).
- **Control**: power on/off packet (`0x6463`) with the socket's MAC and a
  trailing state byte (`01` = on, `00` = off; example on-packet:
  `68 64 00 17 64 63 <mac> 20*6 00 00 00 00 01`).
- Device also listens on **UDP 48899** (HF-LPB100 module config channel).

## Provisioning: fully local, no cloud
The S20 contains an HF-LPB100 Wi-Fi module configurable with AT commands
(stikonas.eu documented the whole flow):
1. Put socket in rapid-blink mode, connect computer to the `WiWo-S20` AP.
2. Broadcast `HF-A11ASSISTHREAD` to UDP 48899; socket replies
   `IP,MAC,Hostname`.
3. Send `+ok`, then `AT+WSSSID=<ssid>\r`, `AT+WSKEY=...\r` etc. to join the
   home network.

No account, no Orvibo server involved at any point. The vendor app is
optional; blocking the device from WAN has no effect on local control.

## APK
Not fetched — protocol is fully community-documented (blog RE + two working
libraries + HA integration). Historical apps (`WiWo`, package around
`com.orvibo.wiwo`) are abandonware; HomeMate is the current app but targets
newer hardware.

## Safety
LOW. Mains socket; protocol has no auth/encryption — any LAN host that knows
the MAC can toggle the load.
