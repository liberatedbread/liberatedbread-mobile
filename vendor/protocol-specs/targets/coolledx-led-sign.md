# CoolLEDX / CoolLED1248 LED signs — target spec starter

## Target metadata
- target_id: coolledx-led-sign
- app package_id(s): com.jtkj.led1248 (CoolLED1248)
- publisher: yfxiong / Juntong Technology (believed; `jtkj` = JunTong KeJi)
- device class: BLE LED sign — car rear-window, bike, backpack, badge, bar/banner
- transport(s): BLE
- local-only viability: high — fully local BLE, no account required for device control

## Why this target matters
This is the highest-volume unbranded BLE LED sign platform in the world: ~350k app installs and
the default fitment for cheap LED signs on AliExpress, Amazon and Temu. Products carry no brand
name at all — the product page just shows a CoolLED1248 screenshot. Nobody is going to maintain
this app for the long tail of hardware it supports.

The `CoolLEDX` generation is already well mapped by the community. The value here is (a) folding
that work into a device spec, and (b) closing the gap on the newer `CoolLEDM`/`CoolLEDU`
generations, which are the ones currently shipping and are largely undocumented.

## Known facts (public + community RE)
- At least seven hardware generations share the `CoolLED*` advertising name: `CoolLED`,
  `CoolLEDA`, `CoolLEDX`, `CoolLEDS`, `CoolLEDM`, `CoolLEDU`, `CoolLEDUD`/`iLedBike`,
  `CoolLEDMX`, `CoolLEDUX`.
- Two protocol families: "basic" (CoolLEDX and earlier, fully mapped) and "advanced"
  (CoolLEDM and later, command table unknown).
- The BLE advertisement's manufacturer data carries MAC, height, width, color mode and firmware
  version — geometry never has to be configured by the user.
- App versions 2.x can import/export a `.JT` design file.
- Fully documented for CoolLEDX in `UpDryTwist/coolledx-driver`; original RE credited to
  CrimsonClyde (LED FaceShields).

## Device discovery signals
- BLE advertised local name: exactly `CoolLEDX` (or another `CoolLED*` / `iLedBike` name)
- Service UUID: `0000fff0-0000-1000-8000-00805f9b34fb`
- Characteristic: `0000fff1-0000-1000-8000-00805f9b34fb` (write + notify)
- Manufacturer data ≥ 11 bytes: `[0-5]` MAC, `[6]` height, `[7-8]` width BE, `[9]` color mode,
  `[10]` firmware version
- Address behavior: unconfirmed (assume public until observed otherwise)

## Threat model + guardrails
- Owned devices only. These signs accept commands from anyone in range with no pairing or auth —
  document that as a wearer-privacy consideration, do not build tooling that targets signs in
  public.
- Vehicle-mounted variants: no safety-critical or brake/turn-signal use cases.

## First experiments
1) Scan and dump the full advertisement for each generation available. Confirm the manufacturer
   data layout holds outside CoolLEDX.
2) Verify the basic-protocol command table against a real CoolLEDX: brightness `0x08`, speed
   `0x07`, text `0x02`, image `0x03`, animation `0x04`.
3) HCI snoop a CoolLEDM doing: connect → set text → set image → set animation. The frame
   structure is believed identical (`0x01` … `0x03` with `0x02` escaping); the goal is the
   command byte mapping and the payload encodings.
4) Check whether CoolLEDM/CoolLEDU require any password or handshake before accepting commands
   (the `0x1F` query returning `01 ff 00 01 00` is the obvious probe).
5) Export a `.JT` file from app v2.1.4 and diff against captured wire data to recover the format.

## Protocol hypotheses (to validate)
- Advanced protocol keeps `0x01`/`0x03` framing and `0x02`-prefix escaping, changes command IDs.
- Text/image/animation payloads are client-rendered bitmaps sized to the advertised geometry,
  encoded per color mode (`0x00` mono, `0x01` 7-color, `0x02` full RGB).

## Control surface inventory (replacement app MVP)
- scan, auto-detect geometry and color mode from the advertisement
- brightness, speed, power/switch
- render + upload text with color, still image, animated GIF
- music-reactive bar visualizer (`0x01`, 8 heights + 8 colors)
- graceful behavior on an unrecognised `CoolLED*` generation

## References
- https://github.com/UpDryTwist/coolledx-driver
- https://pypi.org/project/coolledx/
- https://play.google.com/store/apps/details?id=com.jtkj.led1248
