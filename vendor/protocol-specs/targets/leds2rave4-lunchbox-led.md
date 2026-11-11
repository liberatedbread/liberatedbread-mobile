# LEDs2RAVE4 / Lunchbox Dream LED family — implementation target

## Target metadata

- target_id: leds2rave4-lunchbox-led
- apps: com.spled.pzse (LED CHORD), com.led.spotled (SPOTLED), com.led.iledcolor
- device class: programmable LED skin / matrix panel
- transport(s): BLE
- local-only viability: **confirmed for SPOTLED and iLEDColor; source-derived for
  SP107E/SP110E**

## The app is the device identity

| Generation | Design app | Protocol |
|---|---|---|
| Dream LED Skin v1 | LED CHORD | SP107E 4-byte commands on `0xFFE0` |
| Dream LED Skin 2.0 | SPOTLED | Framed protocol on `0xFF20` |
| Dream Skin 3.0 early | SPOTLED | Framed protocol on `0xFF20` |
| Dream Skin 3.0 recent | iLEDColor | Separate A950 protocol |

For DreamPanel v3, horizontal serial-number rendering selects iLEDColor; vertical
selects SPOTLED. The tested iLEDColor panel had no FF20 service, so the generations do
not collapse into one protocol.

## Current verification

- **SPOTLED:** a 96×16 RGB unit answered GetVersion, GetDisplayInfo and GetBufferSize,
  accepted a static RGB upload and a single-frame native scroll-left upload. Start
  returned type 2 and finish type 4, both status zero. An eight-frame full-RGB upload
  was rejected with response 254.
- **iLEDColor:** a 32×64 unit completed Connect/TestPass, static RGB and eight-frame
  uploads. See `device-specs/devices/iledcolor-led-panel.yaml`.
- **SP107E/SP110E:** no live verification. SP107E static colour is `0x0c`; SP110E speed
  is 0–255 and its commands belong on FFE0/FFE1, not FF20.

The authoritative specs are `device-specs/devices/leds2rave4-lunchbox-led.yaml`,
`spotled-led-panel.yaml` and `iledcolor-led-panel.yaml`.

## Product-line census

- **OG back panel / pin panel:** DreamSkin products; identify app and GATT per unit.
- **Side panel:** DreamBox Conversion Kit inserts; SPOTLED is inferred from the feature
  list, with newer batches potentially iLEDColor. The serial-orientation test is needed.
- **Cosmic Strip:** SP110E / LED Hue, covered by the source-derived sp110e commands.
- Retired PXL-RT, mask, band, fan and visor products are separate identities; do not
  infer their protocols from the DreamSkin family.

## Discovery and implementation guardrails

- Known name prefixes: `SP1`, `LBXDRMSKIN_LED_`, `SpotLED_`, and `iledcolor-` for the
  separate target. Some SPOTLED advertisement samples omit FF20.
- SPOTLED: enable FF21 notifications and await query replies; do not ATT-read them or
  write CCCD bytes to FF21. Finish requires type-4 status zero. Pause type 254 is not
  exclusively an MTU error.
- iLEDColor: use A950/A951/A952/A953 with write-without-response; AF30 is only an
  advertisement signal.
- Query or read geometry. The 96×16 and 32×64 observations are unit-specific, not family
  constants.

## Remaining experiments

1. Capture SP107E/SP110E command tables and characteristic properties.
2. Determine SPOTLED's real multi-frame/resource limit and AE30/FF10 roles.
3. Test text/font records, brightness/screen mode, other geometries and reset behavior.
4. Continue iLEDColor brightness, playlist, password and OTA research in its own target.

## References

- https://www.lunchboxpacks.com/pages/dream-led-tutorial
- https://www.lunchboxpacks.com/blogs/resources/how-to-set-up-your-dream-led-skin-2-0
- https://leds2rave4.com/products/dreamskin-v3-the-dreampanel
- https://leds2rave4.com/blogs/animated-gifs/new-batch-of-v3-s-now-use-iledcolor-app
- https://github.com/iwalton3/python-spotled
- https://github.com/monty68/uniled
- https://pub.dev/packages/led_bt_jl_ota
