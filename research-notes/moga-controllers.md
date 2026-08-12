# PowerA MOGA Controllers — Research Notes

Date: 2026-08-04. Category: Bluetooth Classic game controllers (SPP + HID).

## Products
PowerA MOGA line (2012–2015): MOGA Pocket, MOGA Pro, MOGA Pro Power, MOGA Hero Power,
MOGA Rebel. (MOGA Ace Power is iOS/Lightning — out of scope.) All are BT Classic
dual-mode phone gamepads, widely available used for $10–30.

## Company / app status
- MOGA brand and the companion "MOGA Pivot" app are discontinued; the app was
  delisted from Google Play (last version 1.25, Aug 2016 per its Uptodown listing).
  PowerA itself survives as a licensed-accessories maker (ACCO Brands subsidiary).
- User report (2022): original MOGA Pocket/Pro "is a paperweight" without the defunct
  Pivot app; Hero Power's HID "B" mode still works fine
  (blog.bluestarcreations.net rant, 2022-07-16).
- Pivot never needed cloud: it pairs/configures locally (config is a bundled asset
  XML). The only loss is Play Store availability.

## Local feasibility verdict: CONFIRMED (two independent paths)
1. **Mode B = standard Bluetooth Classic HID gamepad.** Pairs in OS settings; works
   with any game/emulator with HID support. Zero software needed. Physical A/B
   switch on Pocket/Pro selects the mode; LED colour indicates mode (orange = B).
2. **Mode A = proprietary serial over SPP/RFCOMM**, fully recovered below from the
   Pivot APK (and independently implemented by the MogaSerial project for Windows,
   github.com/Zel-os/MogaSerial, and by the "MOGA Universal Driver" XDA app).

## APK provenance
- Package: `com.bda.pivot.mogapgp` ("MOGA Pivot", PowerA/BDA)
- Version: 1.25 (latest known; older 1.19/1.21/1.23 on Uptodown)
- Source: apkeep, `apk-pure`; 33,547,421 bytes
- SHA-256: `5bd90a3be0b8d813711499a1c63fefd4abe7af61d6242e719ce573e5bead3ca0`
- Decompiled with jadx to workspace/static/moga-controllers/ (triage pass).
  Note: apkeep lookup under the *old* id `com.bda.pivot.moga` returns nothing; the
  correct id is `com.bda.pivot.mogapgp`.

## Mode A protocol (from static analysis of com.bda.controller.service.Device)
Transport: RFCOMM/SPP, service UUID `00001101-0000-1000-8000-00805f9b34fb`
(standard SPP). Controller IDs 1..8. Poll-driven: host sends 5-byte commands,
controller answers with state frames.

### Host → controller command frame (5 bytes)
```
[0]=0x5A  [1]=len(5)  [2]=op  [3]=controllerId  [4]=XOR(bytes 0..3)
```
- op `0x43` 'C' — sent every poll cycle (keepalive/session)
- op `0x41` 'A' — request info/handshake (pre-connect); also sent when idle
- op `0x44` 'D' — request Gen1 state report (protocol version 0/2)
- op `0x45` 'E' — request Gen2 state report (protocol version 1)
- Poll cadence: ~83 ms when active (nominal 12 Hz), 500 ms idle; "panic mode"
  (no RX >1 s) halves the interval; RX silence >2 s = disconnect.

### Controller → host response frame
```
[0]=0x7A  [1]=len  [2]=op  [3]=controllerId  [payload...]  [len-1]=XOR(bytes 0..len-2)
```
- op `0x61` 'a', len 12 — handshake/info; supported version = high nibble of byte 10
  (0/2 → Gen1 polling, 1 → Gen2 polling)
- op `0x64` 'd', len 12 — Gen1 state report:
  - byte 4: buttons (active-LOW): bit0=Y bit1=B bit2=A bit3=X bit4=START bit5=SELECT bit6=L1 bit7=R1
  - byte 5: d-pad (active-LOW): bit0=UP bit1=DOWN bit2=LEFT bit3=RIGHT
  - bytes 6–9: left X, left Y, right X, right Y — int8; Y axes are host-negated
  - byte 10: power (bit0 = low battery)
- op `0x65`/`0x66` ('e'/'f'), len 14 — Gen2 state report: same layout plus
  bytes 10–11 = analog L2/R2 triggers (uint8), power at byte 12;
  d-pad byte gains bit4=L2 bit5=R2 bit6=THUMBL bit7=THUMBR.

## Open questions
- Exact op semantics of 'C' vs 'A' (both sent per cycle; 'C' looks like a session
  keepalive). Not needed to implement: replay the same poll loop.
- Mode selection on later models (Hero/Pro Power) without a physical A/B switch.
- Whether Pivot had any online activation — none seen statically; appears fully offline.

## Sources
- APK analysis: com.bda.pivot.mogapgp 1.25 (this repo's workspace, derived facts only)
- github.com/Zel-os/MogaSerial — independent Windows driver for Mode A serial protocol
- xdaforums.com/t/app-2-3-3-moga-universal-driver.1953647 — MOGA Universal Driver
- blog.bluestarcreations.net (2022-07-16) — Pivot defunct, Mode B HID usable
- moga-pivot.en.uptodown.com — package id + version history (1.25, 2016-08-06)
