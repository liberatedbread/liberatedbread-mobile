# LOYPRO matching and live confirmation — LOY<serial>

Research reviewed 2026-11-07; live protocol confirmation 2026-11-08. The supplied log
reported 16 equally good matches for a LOY-prefixed helmet. Address, raw payloads and
unit-specific serials are deliberately not retained here.

## Conclusion

The best match is the **LOY / LOYPRO (`com.yskj.loypro`) LED-display family**, because
that app explicitly accepts `LOY` in its scan filter. Related LOY PLAY and
AUTOBABA/LOY SPACE versions accept only `YS` and `TL`. A subsequent information response
confirms the AA55 family on the helmet; do not select any of the other 16 candidates
from the earlier name/service evidence alone.

The physical unit is a helmet-worn motorcycle display. Exact hardware/reseller model is
unknown: the model field is literally `server`, and advertised digits have no proven
model or resolution meaning. The older Shining Display/TR helmet platform uses FA02
and is a different protocol.

## Live evidence

- Initial advertisement: LOY name and FFF0, no manufacturer or service-data record,
  RSSI -59 dBm.
- Supplied Flutter/BlueZ session: FFF0 containing FFF2 and FFF1, with FFF1 notification
  enabling successful but no properties or command reply in that log.
- Fresh 2026-11-08 session: complete GATT discovery and one source-derived dev_info_all
  query. FFF2 is write-without-response and FFF1 is notify. A 159-byte response has a
  valid sequence, length and additive checksum.

The panel TLV decodes little-endian as **48×16**. Brightness is 15 and power type is 1.
Firmware capability tokens include `pwd`, `remote`, `car_linkage`, `brake`, `HS:2`,
`MTU:512` and `power`. The MTU token is a capability, not a negotiated-MTU measurement.
Unit-specific identity and CID values are omitted.

Only the information query and subscription were used. No display, configuration,
pairing, reset or firmware write was performed. A secondary `5833ff…` service was absent
only in that session.

## Vehicle linkage confirmed; trigger mechanism unknown

The helmet affirmatively reports `car_linkage` and `brake`. The app has a corresponding
configuration path, but the evidence does not establish accelerometer-triggered
animation:

- Ordinary assignable program IDs are 67 turn left, 68 turn right, 69 brake, 70 double
  flash and 71 reverse. These are display programs, not five demonstrated gestures.
- The linkage page uses telecontrol model 10942 and a read-only type-0 query. A separate
  type-2 bind operation exists but was not attempted.
- Generic app instructions discuss checking wiring and holding the brake to pair, but do
  not prove that this helmet requires wiring. An integrated sensor, wireless accessory
  or another input remains possible.
- A separate sensor query uses TLV `3e 01 00`; the app does not decode its returned byte
  into acceleration axes or thresholds.
- A separate model-keyed program table in the app names additional programs, but is not evidence that this
  helmet supports those inputs.

The next read-only checks are vehicle telecontrol and sensor value, using the exact
sequence examples in the authoritative spec. No binding, mapping or display writes are
recommended.

## Why the original 16 matches were wrong

`local_name` and `service_uuids` are alternative axes, so FFF0 alone activated unrelated
specs. FFF0 is shared by LED panels, thermometers, battery monitors, OBD adapters,
treadmills and serial modules. It is not a device type.

- Aurora expects `FS`, AUTOBABA `YS`/`TL`, CoolLEDX `CoolLEDX`, ELK variants, iBBQ,
  IDL, `sps`/`tps`, `MASK`, OBD names and `URTM`/`SYWP`; all fail the observed name.
- FFF1 write+notify, FFF2 write/FFF1 notify, FFF3 write/FFF4 notify, FFF4 notify-only,
  and custom `d44bc439-…` channels are different layouts. The live session supports the
  second layout and now confirms its properties.
- CoolLEDX geometry records, Heaton TR prefixes, Inkbird readings and encrypted BM2 data
  could discriminate further, but were absent. Absence is not proof of impossibility.
- OBDLink MX+ uses Classic SPP, and `Example Smart Bulb` is a fixture, not production
  identification.

AUTOBABA is the closest protocol relative but is not an exact identity match. Maintain
this separate LOYPRO spec rather than expanding its YS/TL filter to LOY.

## Matching and control rules adopted

1. Apply name constraints before service hints.
2. Keep FFF0 in `services`, not in `identification` or `discovery.methods` as an
   independent match axis.
3. Corroborate with characteristic layout and manufacturer/service data when present.
4. Use the read-only AA55 information response for final family, firmware and geometry
   confirmation. Do not send another protocol's initialization.
5. Keep `integration: supported` and `testing: minimally-verified` limited to the
   confirmed query path. Raw GIF, display writes, reset and OTA remain unknown.

## Sources

- LOYPRO 2.1.04, LOY PLAY 1.7.15 and LOY SPACE 1.2.19 scan/filter analysis.
- Supplied Flutter/BlueZ GATT session log, 2026-11-07.
- Sanitized dev_info_all query and response, 2026-11-08.
- [`ztrawhcs/yskj-led-sign`](https://github.com/ztrawhcs/yskj-led-sign), independent
  family client evidence on another named unit.
- AUTOBABA live GATT and information-response findings, used only as protocol-family
  context.
