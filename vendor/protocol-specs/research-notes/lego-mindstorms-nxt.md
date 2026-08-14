# LEGO MINDSTORMS NXT — Research Notes

## What it is
LEGO MINDSTORMS **NXT** (2006) and **NXT 2.0** (8547, 2009) programmable robotics brick. Bluetooth **Classic SPP** (CSR BlueCore, BT 2.0) — no BLE. The same telegram protocol is also available over USB.

## Why it is abandoned
- NXT retail was discontinued in 2013 (replaced by EV3); LEGO ended NXT software/firmware support years ago. The NXT-G desktop IDE does not run on modern macOS; LEGO's own support pages mark NXT retired ([MIT App Inventor community, 2021-09: "MindStorm EV3 or NXT are no longer for sale"](https://community.appinventor.mit.edu/t/mindstorm-ev3-or-nxt-are-no-longer-for-sale/41624)).
- LEGO's official "MINDdroid" Android app (`com.lego.minddroid`) is delisted (apkeep/APKPure 2026-08: not available).
- **No cloud has ever been involved** — the brick is a local SPP serial peer. Abandonment only affects the official tooling, which open-source replaced long ago.

## Local Bluetooth Classic feasibility: EXCELLENT (vendor-documented)
- LEGO **published** the "LEGO MINDSTORMS NXT Bluetooth Developer Kit": hardware schematic docs, **Appendix 1 — Communication protocol**, **Appendix 2 — Direct Commands** (mirror: [xatlantis.ch PDF](https://www.xatlantis.ch/doc/nxt/LEGO%20MINDSTORMS%20NXT%20Bluetooth%20Developer%20Kit.pdf); doc list also at [cs.uleth.ca handout](https://www.cs.uleth.ca/~benkoczi/3720/data/NXT_Bluetooth_handout-jeremy.pdf)).
- Connection: pair with PIN **1234**, then RFCOMM **channel 1** (SPP).
- Telegram framing (same over BT and USB): 2-byte little-endian length (excludes the 2 length bytes), then:
  - `byte0` = telegram type: `0x00` direct command, reply required · `0x80` direct command, no reply · `0x01` system command, reply required · `0x81` system command, no reply · `0x02` reply telegram
  - `byte1` = command opcode, then payload.
  - Reply telegram: `0x02, <echoed command byte>, <status byte>, payload...` (status 0x00 = success).
- Common direct-command opcodes (Appendix 2 — transcribe from the vendor doc before writing a spec; indicative list): `0x00` STARTPROGRAM, `0x01` STOPPROGRAM, `0x03` PLAYTONE, `0x04` SETOUTPUTSTATE (motors), `0x05` SETINPUTMODE (sensors), `0x06` GETOUTPUTSTATE, `0x07` GETINPUTVALUES, `0x0B` GETBATTERYLEVEL, `0x0F` LSWRITE, `0x10` LSREAD (I2C). System commands include file open/read/write/delete, GETFIRMWAREVERSION (`0x88`), GETDEVICENAME/SETBRICKNAME.
- Mature open-source stacks: **nxt-python**, **leJOS NXJ** (custom firmware, same BT), [nathankleyn/lego-nxt](https://github.com/nathankleyn/lego-nxt) (Ruby, BT+USB), RWTH Mindstorms NXT Toolbox (MATLAB), NXT-Python forks. MIT App Inventor still ships Nxt* components.

## APK provenance
- Not applicable in the usual sense: NXT control was primarily PC-based (NXT-G IDE). The one official Android app, MINDdroid (`com.lego.minddroid`), is delisted and unnecessary — the protocol is fully vendor-documented.

## Open questions
- None blocking. A spec should be transcribed from Appendix 2 rather than from memory (opcode table above is indicative).

## Verdict
Document. Easiest entry in the category: vendor-published protocol, PIN 1234 + RFCOMM channel 1, huge existing tooling. Difficulty: trivial.
