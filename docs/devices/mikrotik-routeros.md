# MikroTik RouterOS Device (identify-only)

> **Status**: Complete (MNDP discovery hardware-verified 2026-08-14; identify-only)
> **Protocol**: MNDP (UDP 5678) / LLDP
> **Manufacturer**: MikroTik
> **Manufacturer Status**: Active — recognised and linked to WebFig, not controlled here

## Overview

MikroTik routers, switches and APs announce themselves with MNDP (MikroTik
Neighbor Discovery Protocol). This app **identifies** them — shows a router
pictogram and deep-links to WebFig — rather than implementing RouterOS control
(the API/WebFig/Winbox all exist and are out of scope as home infrastructure).

Verified live 2026-08-14 against three RouterOS devices: a CCR2004-1G-12S+2XS
gateway ("newhouse-core", RouterOS 7.13), a CRS354-48P-4S+2Q+ ("CoreSwitch")
and a CRS326-24S+2Q+ ("Pleakley-switch"), each decoded from its MNDP TLVs.

## Protocol Summary

- **MNDP**, UDP 5678. Devices broadcast unsolicited ~every 60 s (listen with no
  probe), or solicit with a 4-byte zero datagram to `255.255.255.255:5678`.
- Payload: 4-byte header (`0x0000` + u16 seq) then TLVs, **type and length
  u16 big-endian**. Key TLVs: `0x0005` Identity (name), `0x0007` Version,
  `0x0008` Platform ("MikroTik"), `0x000c` Board (model), `0x0001` MAC. The
  device's IPv4 is the source IP of the datagram.
- Also emits **LLDP** (passive L2 listen).

**Admin**: `http://<ip>/webfig/` (or `https://<ip>/` with www-ssl); Winbox on
TCP 8291.

## References

- <https://help.mikrotik.com/docs/spaces/ROS/pages/24805517/Neighbor+discovery>
- <https://github.com/boundary/wireshark/blob/master/epan/dissectors/packet-mndp.c>
