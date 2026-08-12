# LEDs2RAVE4 / Lunchbox Dream LED family — target spec starter

## Target metadata
- target_id: leds2rave4-lunchbox-led
- app package_id(s) — **one per product generation, not interchangeable**:
  - com.spled.pzse (LED CHORD) — Dream LED Skin v1, SP107E controller
  - com.led.spotled (SPOTLED) — Dream LED Skin 2.0 and early Dream Skin 3.0 / DreamPanel v3
    (protocol mapped; tracked as its own family in `targets/spotled-led-panel.md`)
  - com.led.iledcolor (iLEDColor) — recent and future DreamPanel v3 board revisions
    (tracked separately in `targets/iledcolor-led-panel.md`)
- device class: programmable LED skin / matrix panel for hydration packs and backpacks
- transport(s): Bluetooth (BLE)
- local-only viability: high for v1 and v2/v3-SPOTLED (both fully mapped); unknown for
  v3-iLEDColor

## The app is the device identity
Three generations of an outwardly similar product ship three different apps, and the third swap
happened **mid-production-run**. Identify the app before the hardware.

| Generation | Product | Design app | Protocol |
|---|---|---|---|
| v1 | Dream LED Skin | LED CHORD | SP107E 4-byte commands on `0xFFE0` |
| v2 | Dream LED Skin 2.0 | SPOTLED | SPOTLED framed protocol on `0xFF20` |
| v3 early | Dream Skin 3.0 / DreamPanel | SPOTLED | SPOTLED framed protocol on `0xFF20` |
| v3 recent | Dream Skin 3.0 / DreamPanel | iLEDColor | **unmapped** |

Vendor guidance for telling v3 units apart: power the panel on and look at the serial number —
if it renders **horizontally**, the unit is a new-board revision and needs iLEDColor.

## Known facts (public)
- Dream LED Skin (v1) tutorial connects to an "SP107e" controller using the "LED CHORD" app.
- Dream LED Skin 2.0 tutorial uses SpotLED; device names begin with `LBXDRMSKIN_LED_`.
- Dream Skin 3.0 / DreamPanel v3 is advertised at 2048 LEDs, double the 2.0 panel. Pixel
  arrangement is **not** published (64×32 is the obvious candidate, unconfirmed).
- Powered by an external USB bank (Lunchbox "Powerbox" or any 10,000 mAh+ pack).
- LEDs2RAVE4 is Lunchbox's collaboration partner for the Dream Skin line.
- SPOTLED protocol is independently reverse engineered in `iwalton3/python-spotled`.

## Device discovery signals
- BLE advertised name patterns:
  - `SP107e` — v1 controller
  - `LBXDRMSKIN_LED_` prefix — Dream Skin matrix panel
- Service UUIDs:
  - `0000ffe0-0000-1000-8000-00805f9b34fb` — SP107E command protocol
  - `0000ff20-0000-1000-8000-00805f9b34fb` — SPOTLED framed protocol
    (`0xFF21` command, `0xFF22` data)
- Geometry: **do not infer from the model name.** SPOTLED's `GetDisplayInfo` (command `0x12`)
  returns real width, height, color depth, frame limit and brightness.

## Threat model + guardrails
- Owned devices only. These panels connect without bonding and accept commands from anyone in
  range; note that as a wearer-privacy consideration, not an attack surface to tool against.

## Remaining experiments
1) **iLEDColor v3 board** — highest priority. Before assuming a new protocol, probe the panel for
   the `0xFF20` SPOTLED service; a match collapses the work. If absent, HCI snoop
   connect → brightness → upload one small GIF.
2) Confirm DreamPanel v3 pixel geometry by querying the device rather than trusting the 2048-LED
   marketing figure.
3) Determine whether the `0xFF20` panel firmware is genuinely an SP110E board. The SPOTLED framed
   transport (length + command ID + serial + content + sum checksum) does not resemble the SP110E
   4-byte command set, so the "SP110E" label attached to this protocol may be a misattribution
   carried forward from early notes.
4) Verify the SP107E/SP110E per-opcode tables against live capture — the device spec flags most
   individual effect/brightness opcodes as MEDIUM confidence, sourced secondhand.

## Control surface inventory (replacement app MVP)
- scan + connect, auto-detecting which of the three protocols the panel speaks
- query and honour real panel geometry
- brightness, speed, screen mode (normal / flipped / mirrored)
- text with fonts, colors and scroll effects
- still image and animated GIF upload with device-driven flow control
- local design storage that survives an app reinstall

## References
- Dream LED Skin tutorial (LED CHORD, SP107e): https://www.lunchboxpacks.com/pages/dream-led-tutorial
- Dream LED Skin 2.0 (SpotLED, LBXDRMSKIN_LED_): https://www.lunchboxpacks.com/blogs/resources/how-to-set-up-your-dream-led-skin-2-0
- DreamSkin v3: The DreamPanel: https://leds2rave4.com/products/dreamskin-v3-the-dreampanel
- New batch of V3's now use iLEDColor: https://leds2rave4.com/blogs/animated-gifs/new-batch-of-v3-s-now-use-iledcolor-app
- python-spotled (SPOTLED BLE protocol): https://github.com/iwalton3/python-spotled
- SPOTLED on Google Play: https://play.google.com/store/apps/details?id=com.led.spotled
- iLEDColor on the App Store: https://apps.apple.com/us/app/iledcolor/id6737223690
