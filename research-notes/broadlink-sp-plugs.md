# Broadlink SP2 / SP mini / SP3 Smart Plugs — Research Notes

## What it is
Broadlink (Hangzhou, alive) SP-family Wi-Fi smart plugs: SP2 (with power
metering), SP mini, SP3/SP3S (~2014-2019), plus the many OEM rebadges. The
same protocol family covers Broadlink RM IR blasters and A1 sensors.

## Local protocol — confirmed, exceptionally well documented
[mjg59/python-broadlink](https://github.com/mjg59/python-broadlink) includes a
full [`protocol.md`](https://github.com/mjg59/python-broadlink/blob/master/protocol.md)
(packet-level spec) and powers the Home Assistant `broadlink` integration
(local). Key facts:

- **UDP port 80** for all LAN traffic.
- **Discovery**: broadcast an encrypted discover packet to
  `255.255.255.255:80`; devices reply with type code, MAC and name.
- **Crypto**: AES-128-CBC. Devices ship with a well-known default key
  (`097628343fe99e23765c1513accf8b02`); after `auth`, each client gets a
  device-issued per-client key+id pair. Payload checksums are LE CRC16.
- **Packet header**: 56 bytes, starts with the magic `5aa5aa55 5aa5aa55`
  block, checksum fields at 0x20/0x34, command code LE16 at 0x26
  (e.g. `0x006a` = send command payload).
- **Plug commands** (inside encrypted payload): set power state
  (`SP2: {"pwr":0/1}`), get power state, SP2/SP3S energy read
  (`get_energy`), nightlight on SP3.
- Independent Chinese RE writeup (cnblogs, 2018-11-23) confirms LAN control
  needs no Broadlink server: replaying the LAN UDP packets switches the plug.

## Cloud dependency: none (including provisioning)
- Control is 100% LAN once the plug is on Wi-Fi; WAN-block safely.
- Provisioning can be done without the app/account: `python-broadlink`
  ships `broadlink.setup()` (SmartConfig-style SSID/password push to the
  plug's AP), so a fleet can be commissioned fully offline.

## Caveat
Newer Broadlink devices (2019+) added "cloud lock" behavior and newer
encryption variants; python-broadlink handles most, but the SP2/SP-mini era
units are the cleanest targets.

## APK
Not fetched — protocol.md + python-broadlink are definitive.

## Safety
LOW. Mains relay. AES with a published default key means pre-auth packets are
forgeable by anyone on the LAN until a client auths; LAN-segment.
