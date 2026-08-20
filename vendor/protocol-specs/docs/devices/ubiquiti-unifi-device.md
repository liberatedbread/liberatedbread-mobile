# Ubiquiti UniFi / EdgeMAX Device (identify-only)

> **Status**: Complete (UDP-10001 discovery hardware-verified 2026-08-14; identify-only)
> **Protocol**: Ubiquiti device discovery (UDP 10001) / LLDP
> **Manufacturer**: Ubiquiti Inc.
> **Manufacturer Status**: Active — recognised and linked to UniFi OS, not controlled here

## Overview

Ubiquiti UniFi/EdgeMAX infrastructure — APs, switches, gateways/consoles
(UDM, Cloud Key), the UniFi NAS and the UniFi Protect NVR — answer the Ubiquiti
device-discovery protocol on UDP 10001. This app **identifies** them (pictogram
from the platform string + a deep-link to `https://<ip>/`) rather than
implementing UniFi control. UniFi Protect **cameras** get their own spec because
there we expose the video feed.

Verified live 2026-08-14 against a large fleet: U6 APs (platform `UFP-UAP-B`),
an EdgeSwitch 10X, a UniFi NAS Pro (`UNASPRO`), a UNVR and a Cloud Key Gen2+
(`UCKP`), each decoded from its discovery TLVs.

## Protocol Summary

- **UDP 10001**, request/response (no unsolicited beacons). Probe v1 =
  `01 00 00 00`, v2 = `02 08 00 00` (try v1, fall back to v2).
- Reply: `[version u8][command u8][length u16 BE]` then TLVs
  `[type u8][length u16 BE][value]` — note the 1-byte type, 2-byte BE length.
  Key TLVs: `0x0c` platform (e.g. `UVC G4 Pro`, `ES-10X`, `UNVR`, `UCKP`),
  `0x0b` hostname, `0x03` firmware, `0x02` MAC+IP. Pictogram comes from the
  platform string.
- Also emits **LLDP**.

**Admin**: `https://<ip>/` (UniFi OS console or standalone device page).

## References

- <https://nmap.org/nsedoc/scripts/ubiquiti-discovery.html>
- <https://www.rapid7.com/blog/post/2019/02/01/ubiquiti-discovery-service-exposures/>
