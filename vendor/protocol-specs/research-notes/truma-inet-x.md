# Truma iNet X / iNet X Pro — Strict Read-Only Research Notes

Consolidated 2026-11-06 from the MIT Node/TypeScript client at `004a8327`, an
independent Home Assistant integration at `08daf61c`, vendor documents and
static app analysis. No panel, appliance, adapter, account or credential was
used. The legacy **iNet Box** is a different protocol (`TRBT:` ASCII over
Nordic UART); do not send its frames to an iNet X panel or CBOR to an iNet Box.

## Scope and safety

The intended profile is topology and telemetry only. Heating, cooling, hot
water, fans, pumps, switches, timers, fault resets, configuration, firmware
and bond management are excluded.

**Read-only still requires GATT writes** to announce and issue read requests.
The general client's default discovery also emits `client-system-time` and
`client-last-message` frames. Those change client state and are not passive.
Omit them in a strict-read sequence until an owner-approved test proves they
are needed. Do not run that default flow unchanged under a no-parameter-writes
requirement.

## BLE identity

| Role | UUID |
|---|---|
| Advertised service | `fc310001-f3b2-11e8-8eb2-f2801f1b9fd1` |
| Main service | `fc314000-f3b2-11e8-8eb2-f2801f1b9fd1` |
| Control | `fc314001-f3b2-11e8-8eb2-f2801f1b9fd1` |
| Request/write | `fc314002-f3b2-11e8-8eb2-f2801f1b9fd1` |
| Data/notification | `fc314003-f3b2-11e8-8eb2-f2801f1b9fd1` |
| Optional additional notification | `fc314004-f3b2-11e8-8eb2-f2801f1b9fd1` |
| Software revision | `00002a28-0000-1000-8000-00805f9b34fb` |

Name prefix: `Truma iNetX`. The name can arrive in a scan response, so an
initial passive scan may see only the service. Community evidence reports a
rapidly rotating resolvable private address: **do not use the MAC as durable
identity** or change host privacy settings to make it stable. Bonding is
reported as Just Works only in the panel's add-device mode, with about four
slots. Do not clear bonds for telemetry setup. Linux/ESPHome connectivity
reports are host-specific, not blanket proof that a kernel or proxy cannot
work.

## Frame and control exchange

Header fields before CBOR:

| Offset | Size | Meaning |
|---:|---:|---|
| 0 | 2 | Target address/group, little-endian |
| 2 | 2 | Source address/group, little-endian |
| 4 | 2 | Declared body length, little-endian |
| 6 | 2 | Operation, little-endian |
| 8 | 8 | Sequence |
| 16 | 2 | Flags, little-endian |
| 18 | variable | CBOR value in normal frames |

The builder uses `bodyLength = 1 + 8 + 2 + cborLength`; a complete physical
frame is `bodyLength + 7`. Preserve these observed formulas rather than using
a generic header interpretation. Validate physical length and header before
trying CBOR.

1. Subscribe to control and data notifications.
2. Announce the request on control as `01 <length_lo> <length_hi>`.
3. Wait for `81 00`, then send the complete request.
4. Wait for `f0 01` acceptance. This is transport progress, not a setting
   change.
5. On control `83 <length_lo> <length_hi>`, send `03 00` to request the
   response.
6. Reassemble data notifications to the announced length; responses can be
   queued and a new frame can start while old ones drain.
7. Acknowledge each flushed response with `f0 01`.

Do not rely on the upstream trailing-fragment heuristic alone: a short first
fragment can be mistaken for trailing data after a completed response. Use
announced lengths and explicit frame state.

## Strict-read sequence

- Protocol-version request (operation 1) supplies protocol version and an
  assigned client address. Retain that source address for the session.
- Topic registration (operation 3, flags `0x0002`) uses `tn` arrays.
- Device-list request (operation 2, flags `0x0001`) discovers source groups.
- Group reads (operation 3, flags `0x0004`) replace target at offset 0 and
  learned source at offset 2, both little-endian.

Exclude clock/last-message updates, `{tn,pn,v}` setters, resets, install/demo
operations and pairing/bond APIs. Whether this reduced sequence returns
complete telemetry still needs a bonded owner-panel test.

Topic/group hints are not universal: heating often appears at `0x0201`, tank
and switches at `0x0405`, room climate at `0x0101`, but a reported air
conditioner appeared at `0x0406`. Discover `Devices` and retain source group
with every `(group, topic, parameter)` reading.

## Telemetry model and redaction

Responses can be a record or `[context, record]`, with `topics`, `tn`, `pn`,
`v`, `type`, `min`, `max`, `enum`, `avail`/`a`, `perm` and `Devices`.
Availability and permission metadata are not evidence of hardware absence or
a license to actuate. Multiple publishers require `groups`, not one shared
value. Refresh device-supplied enums/ranges rather than freezing one vehicle's
labels.

Candidates, conditional on the actual appliance, include AirHeating/WaterHeating
temperature, FreshWater/GreyWater levels, starter/leisure voltage, shore-power
presence, fan level and active/running state. One Victron example uses tenths
of a degree C and rejects `65535`, but neither is a universal scale/sentinel.
Type-105 active values distinguish off/running/standby; do not apply that to
`RoomClimate.Active` type 107. `System.FlameStatus` follows gas or electric
heat. `GasBtl.RemTime` remains unitless after its remaining-time interpretation
was not substantiated.

Redact `CertThumb`, `Muid`, `SerialNr`, `UniqueID`, `UserName`, `Uuid`, real
MACs, assigned labels, raw identity responses and account data by default.
The upstream diagnostic logger can print complete decoded payloads; enabling
it is not a safe production default.

## Remaining validation

Live pairing/encryption, Panel 1/Panel 2 inventory, completeness of the strict
sequence, real ATT/MTU fragmentation, firmware compatibility, parameter
scales/sentinels and optional remote-module behavior remain unverified. The
upstream build/lint/70 tests and nine synthetic transport tests passed; these
do not establish appliance behavior.

## Sources

- [node-red-contrib/node-red-contrib-truma-inetx](https://github.com/node-red-contrib/node-red-contrib-truma-inetx),
  the MIT transport/frame reference
- [rpodgorny/hass-truma-inetx](https://github.com/rpodgorny/hass-truma-inetx),
  independent vehicle behavior; its vendored protocol code has a separate
  licensing boundary and was not copied
