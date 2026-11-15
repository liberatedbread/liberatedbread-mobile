# LEGO MINDSTORMS EV3 — Research Notes

## What it is
LEGO MINDSTORMS **EV3** brick (retail 31313, 2013; Education 45544). Bluetooth **Classic (BR/EDR) SPP** (PAN also possible); the identical packet protocol runs over Bluetooth, USB, and Wi-Fi (per LEGO's developer docs).

## Why it is abandoned
- LEGO Education **discontinued the entire EV3 line on 2021-06-30** ([MIT App Inventor community, 2021-09, citing the LEGO Education notice](https://community.appinventor.mit.edu/t/mindstorm-ev3-or-nxt-are-no-longer-for-sale/41624)); retail EV3 was wound down in the same window ([Chief Delphi, 2022-10](https://www.chiefdelphi.com/t/lego-mind-storm-discontinued/416711)). LEGO's own EV3 downloads were frozen and the tablet apps delisted.
- **No cloud dependency** — the brick is a local RFCOMM/USB/UDP peer. Retirement only killed the official apps/IDE; open-source tooling (ev3dev, Pybricks) is actively maintained.

## Local Bluetooth Classic feasibility: EXCELLENT (vendor-documented)
- LEGO **published** the "EV3 Communication Developer Kit" ([legocdn PDF](https://le-www-live-s.legocdn.com/sc/media/files/ev3-developer-kit/lego%20mindstorms%20ev3%20communication%20developer%20kit-f691e7ad1e0c28a4cfb0835993d76ae3.pdf)) plus Firmware and UI developer kits; the EV3 runs Linux and its firmware source was released (GPL).
- Bluetooth session (RFCOMM channel 1 after pairing; PIN shown on brick, default **1234**):
  1. Host opens the RFCOMM channel and sends a plain-text unlock request: `GET /target?sn=<brick-serial> VM=<version> Proto=EV3`
  2. Brick replies `Accept:EV340`; the serial is then shown on the brick's display and the session is unlocked.
  3. From then on, packets are length-prefixed: 2-byte LE length, 2-byte message counter, 1-byte type, then payload.
- Message types: `0x00` direct command with reply, `0x80` direct command without reply, `0x01`/`0x81` system command with/without reply, `0x02`/`0x03` command reply (OK/error). Direct commands use the EV3 **bytecode** instruction set (opcodes like `opOUTPUT_SPEED`, `opOUTPUT_START`, `opINPUT_READ`, `opUI_DRAW_…`, `opSOUND…`) — same bytecode the VM executes, fully listed in the Communication Developer Kit / firmware source.
- Community stacks: **ev3dev** (full Debian on the brick), **Pybricks** (MicroPython firmware, officially derived from the released EV3 source), c4ev3 (C), leJOS EV3, MonoBrick, and multiple Python RFCOMM libraries (e.g. `ev3-dc`, `python-ev3`). MIT App Inventor ships Ev3* components.

## APK provenance
- Not applicable: official control was desktop (EV3 Lab/Home Edition) or tablet apps, all delisted and unnecessary. No APK fetched — the vendor Communication Developer Kit + firmware source supersede any app mining.

## Open questions
- PAN (Bluetooth tethering profile) as an alternative TCP transport on stock firmware — documented in the CDK; worth covering in the spec.
- NFC-less brick-to-brick BT mailbox messaging details (in CDK).

## Verdict
Document. Vendor-published protocol + open firmware source + active ev3dev/Pybricks ecosystems; fully local. Difficulty: trivial to easy (bytecode table is large but published).
