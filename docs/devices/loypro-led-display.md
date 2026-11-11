# LOY / LOYPRO Helmet LED Displays

> **Status**: Minimally verified (information query and GATT confirmed)
> **Protocol**: BLE, AA55 binary-TLV family
> **Manufacturer**: LOY / YSKJ OEM family

## Why this is a separate device family

The LOYPRO app (`com.yskj.loypro`) explicitly accepts advertised names beginning
**LOY**. Related LOY PLAY and AUTOBABA/LOY SPACE versions accept only `YS` and
`TL`. A LOY name therefore selects this candidate instead of AUTOBABA. The older
Shining Display helmet platform uses FA02 and is also different.

The observed physical unit is a helmet-worn motorcycle display. Its exact
hardware/reseller model is unknown: the device-information model field is literally
`server`, and the advertised digits have no documented model or resolution meaning.

## What is confirmed

A 2026-11-08 fresh connection completed GATT discovery and the documented
`dev_info_all` query. The checksum-valid 159-byte reply establishes:

- `0000fff0-0000-1000-8000-00805f9b34fb` service.
- `0000fff2-0000-1000-8000-00805f9b34fb` **write-without-response**.
- `0000fff1-0000-1000-8000-00805f9b34fb` **notify**.
- **48×16** panel geometry, decoded little-endian.
- Fixed brightness 15 and power type 1.
- Firmware capability tokens `pwd`, `remote`, `car_linkage`, `brake`, `HS:2`,
  `MTU:512` and `power`.

Only the information query and notification subscription were used. No display,
configuration, pairing, reset or firmware write was performed. The secondary
`5833ff…` service was absent only in that session, not proven absent elsewhere.

**FFF0 is not a device type.** LED panels, thermometers, battery monitors, OBD adapters
and treadmills all use it. Keep it in the GATT declaration, not in scan identity.

## Read-only identification

1. Rediscover the LOY name and connect without relying on a stale address.
2. Enumerate GATT and confirm FFF2 write-without-response and FFF1 notify.
3. Subscribe to FFF1, then issue the 20-byte information query on FFF2 with
   `response=False`:

```text
aa 55 ff ff 0e 00 01 00 c1 03 0a 00 1b 00 04 00 06 00 ff 03
```

A real client increments its sequence counter and reassembles replies by the AA55
length field. In panel TLV `0x1b`, a leading panel-data-type byte is followed by
**little-endian** width and height. Stop if no valid reply arrives; do not try another
protocol's initialization.

## Vehicle linkage is not accelerometer proof

This helmet reports `car_linkage` and `brake`, so the corresponding firmware feature
exists. The app defines assignable display programs:

- 67: turn left
- 68: turn right
- 69: brake
- 70: double flash / hazard
- 71: reverse

Those are program IDs, not five demonstrated motion gestures. An integrated
accelerometer, wireless accessory, wired vehicle input or another source remains
possible. Generic app wiring instructions are not evidence that this helmet must be
wired, and no live brake event or motion-triggered animation was captured.

The next read-only checks are vehicle telecontrol model 10942 and sensor type 0, using
the exact example queries in the spec. Do not enter the app's type-2 binding path or
change mappings.

## Setup, upload and reset boundaries

No account or pairing is required for the confirmed query path. The device reports
`pwd` support, but that does not establish whether a password is configured; use the
owner's normal app flow if enabled.

No factory reset is established. Raw-GIF support on related YS-family backpacks is not
evidence for this helmet. Query geometry before enabling a renderer. Display writes,
settings, binding, OTA and maintenance services remain unverified.

## References

- [LOY / LOYPRO on Google Play](https://play.google.com/store/apps/details?id=com.yskj.loypro)
- [`ztrawhcs/yskj-led-sign`](https://github.com/ztrawhcs/yskj-led-sign), independent family client tested on another device
- [AUTOBABA protocol relative](autobaba-led-backpack.md), with a different YS/TL identity
