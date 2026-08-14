# Polaroid Zip (POLMP01) — Research Notes

2015 ZINK 2x3" mobile printer. Bluetooth Classic (confirmed — **not BLE**,
unlike the HP Sprocket 200). Hardware discontinued but the companion app
(`com.polaroid.mobileprinter`, C&A Marketing) is still maintained
(v8.x as of 2024), so this is "at-risk/documented", not orphaned. Fully
local: no account, no cloud in the print path.

## APK Provenance
- **Package**: `com.polaroid.mobileprinter` ("Polaroid ZIP" / "Zip Printer")
- **Source**: apkeep, apk-pure mirror
- **APK SHA-256**: `2dce097d579dd015af6c0147473059c4b41a9a8aa20a24f4ef9a67309f27d354`
- **Note**: APKPure served an old build (manifest stamped 2016-06-08,
  single 3 MB classes.dex, unobfuscated, package `com.manta.pc` — "manta"
  is the internal codename). Assets include printer firmware
  `assets/fw/manta_110.rbn` (OTA update image) and `Manta.sqlite`.

## Transport: two Bluetooth Classic channels
1. **SPP (UUID 00001101-0000-1000-8000-00805f9b34fb)** — control channel.
   `PrintConnectMgr.java` opens an insecure RFCOMM socket to 0x1101 and
   exchanges framed commands (below).
2. **OBEX OPP (UUID 00001105-0000-1000-8000-00805f9b34fb)** — image push.
   `BluetoothOppTransfer.java` opens RFCOMM to 0x1105 and does a standard
   OBEX PUT of the rendered image (`image/*`). This means a plain OPP
   push from a PC (obexftp / ussp-push / BlueZ) very likely prints
   without any app — needs bench validation.

## SPP control protocol (from `PrintPacket.java`)
Fixed header per command frame: `1B 2A 43 41` (ESC `*` `C` `A`), then
`00 00`, then command byte + subcommand byte, then payload (BE fields).

| Bytes 6-7 | Name | Payload |
|-----------|------|---------|
| `00 00` | PRINT_READY | img size 24-bit BE (bytes 8-10), count (11), post mode (12), page01/02 (13-14), print mode (15), ratio S (16) |
| `00 01` | PRINT_CANCEL | — |
| `01 00` | PRINT_INFO query | — |
| `01 01` | CHANGE_INFO | auto-exposure (8), auto-power (9), print mode (10) |
| `02 00` | PRINT_ACTION | data type (8) |
| `03 00` | FW_UPGRADE start | size 24-bit BE (8-10), data type (11) |
| `03 01` | FW_UPGRADE cancel | — |
| `05 00` | DATA / UPGRADE_DATA | 16-bit BE size + payload (used for .rbn firmware chunks) |
| `06 00` | STATUS query | — |

Responses carry battery status, FW/TMD version, MAC, error code/type,
last print number (fields in `PrintPacket`). Exact response layout not
yet mapped — one HCI snoop would finish it.

## Local control feasibility
- **Confirmed local**: app needs no account; print path is SPP + OPP only.
- Generic-print hypothesis: OPP push of a correctly sized JPEG (2x3",
  the app renders at 1280px-class sizes) should print directly — the same
  trick as the older PoGo. UNVERIFIED on the Zip.
- Cloud URLs in the dex (`*.elb.amazonaws.com`) are analytics/registration
  only, not in the print path.

## Open questions
1. Does the Zip accept a bare OPP push, or must SPP PRINT_READY precede it?
2. Response frame layout for STATUS/INFO.
3. NFC tag only boots pairing — no protocol role.

## Sources
- APK static analysis (above; jadx output in workspace/static/polaroid-zip/)
- Package id + developer (C&A Marketing): https://polaroid-zip.en.uptodown.com/android/download
- Polaroid/ZINK support (app contacts): https://support.zinkproducts.com/hc/en-us/articles/360000986728-Download-Mobile-App
- RPi forum attempt (rfcomm ch1 fails — correct channel is OPP, not SPP):
  https://forums.raspberrypi.com/viewtopic.php?t=186183
