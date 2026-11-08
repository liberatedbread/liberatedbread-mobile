# LOYPRO matching — LOY5265115155 and the 16-way ambiguity

Research reviewed 2026-11-07. One advertisement supplied the name and FFF0;
no full GATT table or command response exists. Address and raw payloads were
deliberately not retained.

## Conclusion

The best candidate is the **LOY / LOYPRO (`com.yskj.loypro`) LED-display
family**, because that app explicitly accepts `LOY` in its scan filter. The
related LOY PLAY and AUTOBABA/LOY SPACE app versions accept only `YS` and
`TL`. Exact model and geometry remain unproven.

## Why the original 16 matches were wrong

`local_name` and `service_uuids` are alternative axes in the current matcher,
so FFF0 alone activated every candidate. It is shared by unrelated protocol
families and cannot identify a device.

- Aurora expects `FS`, AUTOBABA `YS`/`TL`, CoolLEDX `CoolLEDX`, ELK variants,
  iBBQ, IDL, `sps`/`tps`, `MASK`, OBD names, `URTM`/`SYWP`, and other
  incompatible prefixes. All fail the observed name.
- FFF1 write+notify, FFF2 write/FFF1 notify, FFF3 write/FFF4 notify,
  FFF4 notify-only, and custom `d44bc439-…` channels are different GATT
  layouts. The unit has not yet supplied its layout.
- CoolLEDX geometry records, Heaton TR prefixes, Inkbird readings and
  encrypted BM2 data could discriminate further, but were absent in this
  observation. Absence is not proof of impossibility.
- OBDLink MX+ uses Classic SPP, and `Example Smart Bulb` is a fixture, not
  production identification.

AUTOBABA is the closest protocol relative but is not an exact identity match.
Create/maintain the separate `loypro-led-display` candidate rather than
expanding its YS/TL filter to LOY.

## Matching rule adopted

1. Apply name constraints before service hints.
2. Keep FFF0 in `services`, not in `identification` or `discovery.methods`
   where it becomes an independent match axis.
3. Corroborate with the characteristic layout and manufacturer/service data
   when present.
4. Use a read-only AA55 device-information response for final model,
   firmware and geometry confirmation. Do not send another protocol's
   initialization to see what happens.

The source-derived 20-byte query in the spec is only a next-step candidate;
it was not transmitted. The intermittent advertisement prevented GATT
enumeration in this pass.

## Sources

- LOYPRO 2.1.04, LOY PLAY 1.7.15 and LOY SPACE 1.2.19 scan/filter analysis.
- [ztrawhcs/yskj-led-sign](https://github.com/ztrawhcs/yskj-led-sign),
  independent LOY PLAY / YSKJ client evidence on another named unit.
- AUTOBABA live GATT findings, used only as protocol-family context.
