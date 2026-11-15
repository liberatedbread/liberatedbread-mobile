# Drobo NAS Status Daemon

> **Status**: Spec Available (unverified; read-only)
> **Protocol**: LAN (TCP 5000, pushed XML)
> **Manufacturer**: Drobo (StorCentric)
> **Manufacturer Status**: Shutdown — sales ended 27 January 2023; liquidated 2023

## Overview

Drobo is gone and Drobo Dashboard is unsupported, but Drobo FS, 5N, 5N2 and
B800fs units keep running their BeyondRAID arrays. The daemon behind Dashboard
still pushes the whole array status to anyone who connects to **TCP 5000** — no
request, no login, no TLS — so a phone or monitor can show each bay's
traffic-light status, warn on a failed or missing drive and track free space.

The spec is **read-only on purpose**. The same daemon listens on TCP 5001 and
UDP 5002; one of them carries an undocumented command set that includes
destructive drive operations.

## Initial Setup

| Property | Value |
|----------|-------|
| Setup required | No |
| Method | Connect to TCP 5000 and read |
| Discovery | None documented (Dashboard probably used UDP 5002 broadcasts) |
| Passphrase protection | not_applicable — no authentication |
| Confidence | medium |

## Protocol Summary

Each frame: 16-byte header, then XML.

| Offset | Size | Field |
|--------|------|-------|
| 0 | 8 | `DRINASD\0` (older firmware: `DRINASD9` / `DRINASDa`) |
| 8 | 4 | Version, seen as `01 01 00 00` |
| 12 | 4 | Body length, big-endian, counting a trailing NUL |

The body is `<ESATMUpdate>`: `mStatus` (`0x8000` OK, `0x8004` yellow, `0x8006`
red, `0x8240` relayout…), protected capacity in bytes, thresholds, and one
`<nX>` record per bay under `<mSlotsExp>` with its status (`3` green, `2`
yellow, `1` red, `0x80` empty, `0x86` failed), drive make, serial and size. It
repeats every 10–20 s while the socket is open.

The 16-byte header layout comes from one owner's reading of a single 5N2,
with no published capture; the two exporters skip the header by searching
for the XML start.

See `device-specs/devices/drobo-nasd-status.yaml` for the full spec.

## References

- [droboports wiki: NASD XML format](https://github.com/droboports/droboports.github.io/wiki/NASD-XML-format)
- [jerimiah797/drobo-nas-protocol](https://github.com/jerimiah797/drobo-nas-protocol)
- [cosmouser/drobo_exporter](https://github.com/cosmouser/drobo_exporter)
- [Drobo 5N2 user manual](https://www.manualslib.com/manual/1300917/Drobo-5n2.html)
