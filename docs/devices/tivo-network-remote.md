# TiVo Network Remote (DVRs and Minis)

> **Status**: Spec Available (unverified)
> **Protocol**: LAN (TCP 31339, ASCII lines)
> **Manufacturer**: TiVo (Xperi)
> **Manufacturer Status**: Unsupported — hardware sales ended 1 October 2025

## Overview

TiVo stopped selling DVRs on 1 October 2025, leaving a large fleet of Series 3,
Premiere, Roamio, Bolt and Edge boxes and Minis. Each one has a local remote
socket that needs no account: with **Network Remote Control** enabled it takes
plain-text commands on TCP 31339 that press remote buttons, jump to screens and
tune channels, and it reports the channel back as text.

## Initial Setup

| Property | Value |
|----------|-------|
| Setup required | Yes — enable Network Remote Control (off by default) |
| Method | `device_ui` |
| Discovery | mDNS `_tivo-remote._tcp` (only while enabled); legacy TiVoConnect beacon on UDP/TCP 2190 |
| Passphrase protection | not_applicable — the socket has no authentication |
| Confidence | medium |

**Enabling**: TiVo Central, Messages & Settings, Settings, then Remote, CableCARD
& Devices, then Network Remote
Control, Enabled. On Virgin Media boxes: Help & Settings, Settings, Devices.

**Factory reset**: Help, then Restart or Reset — never needed for this protocol,
and it turns the setting back off.

## Protocol Summary

One command per line, CR-terminated. One client at a time: connect, act,
disconnect. Pause 100–200 ms between commands.

| Command | Meaning |
|---------|---------|
| `IRCODE <key>` | Press a remote button (`UP`, `SELECT`, `TIVO`, `PLAY`, `NUM0`…) |
| `KEYBOARD <key>` | Type a key (Premiere and later; TiVo publishes no minimum software) |
| `TELEPORT TIVO\|LIVETV\|GUIDE\|NOWPLAYING` | Jump to a screen |
| `SETCH <n>` / `SETCH <major> <minor>` | Tune (must be on Live TV) |
| `FORCECH <n>` | Tune, cancelling a recording if needed |

| Reply | Meaning |
|-------|---------|
| `CH_STATUS 0702 LOCAL` | Current channel; sent on connect (whether later changes are pushed is undocumented) |
| `CH_FAILED NO_LIVE` | Not on Live TV; also `RECORDING`, `MISSING_CHANNEL`, `MALFORMED_CHANNEL`, `INVALID_CHANNEL` |
| `LIVETV_READY`, `INVALID_COMMAND`, `COMMAND_TIMEOUT` | Informational; `COMMAND_TIMEOUT` is harmless |

TiVo's own protocol PDF is gone from tivo.com (a 2008 edition survives in the
Internet Archive, unread here); the facts come from the openHAB
binding and McBrine's Network Remote, which agree. Whether a Mini accepts
`SETCH` is unknown.

See `device-specs/devices/tivo-network-remote.yaml` for the full spec.

## References

- [openHAB TiVo binding](https://www.openhab.org/addons/bindings/tivo/)
- [wmcbrine/tivoremote](https://github.com/wmcbrine/tivoremote)
- [TiVoConnect discovery specification (2003)](https://tivopod.sourceforge.net/tivoconnect.pdf)
- [TiVo Roamio Viewer's Manual](https://www.manualslib.com/manual/1305417/Tivo-Roamio.html)
