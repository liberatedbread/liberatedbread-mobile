# OBDLink MX+

> **Status**: In Progress (static analysis complete; hardware capture pending)
> **Protocol**: Dual-mode Bluetooth — Classic v3.0 SPP/iAP2 (primary) + BLE GATT serial pipe
> **Manufacturer**: OBD Solutions LLC (ScanTool.net)
> **Manufacturer Status**: Active

## Overview

The OBDLink MX+ is the top of the OBDLink wireless line: an STN-chipset adapter
(STN2255 originally, STN2256 on current production per FRPM rev F) that speaks
the extended ST command set and is one of only three wireless adapters (MX, MX+,
EX) that reach **Ford MS-CAN** and **GM SW-CAN** in addition to every legislated
OBD-II protocol. MFi certification (iAP2) makes it the only wireless adapter in
the family that works with iOS against those manufacturer buses.

Unlike the BLE-only OBDLink CX, the MX+ leads with **Bluetooth Classic v3.0**
(SPP + iAP2) and also exposes a BLE GATT pipe — the vendor app treats it as
dual-mode and can demand Classic for some operations. See
[OBD-II Bluetooth Adapters](obd2-bluetooth-adapter.md) for the generic
ELM327/STN link layer this page builds on.

Everything below comes from static analysis of the official OBDLink Android app
(7.4.0, recovered .NET assemblies) plus vendor/community documentation — nothing
has been confirmed against hardware yet. The hardware-session checklist is in
`research-notes/obdlink-mx-plus-capture-plan.md`.

## Hardware

| Property | Value |
|----------|-------|
| Model | MX201 |
| Chipset | STN2255 (original, out of production) / STN2256 (current, reported) |
| Radio | Bluetooth Classic v3.0 (SPP, iAP2) + BLE; "secure 128-bit data encryption" (vendor claim) |
| Vehicle side | All legislated OBD-II protocols + Ford MS-CAN (J1962 pins 3/11) + GM SW-CAN (pin 1) |
| Power | 8–18 V from OBD pin 16; BatterySaver sleep < 2 mA (vendor claim) |
| Button | "Connect" button — physical-access gate for pairing; 15 s hold = factory reset |

## Initial Setup

| Property | Value |
|----------|-------|
| Setup required | Yes (pairing) |
| Method | `button_pairing` |
| Advertised name | `OBDLink MX+` |
| Passphrase protection | not_applicable (button press is the proof of possession) |
| Confidence | medium (vendor docs + app strings; not replayed) |

Pairing: press the Connect button — the blue LED blinks rapidly for a ~2 minute
window — then pair from the host OS Bluetooth settings. On Android the OS-level
bond is mandatory before the vendor app will connect (confirmed by an app error
string). The adapter's pairing mode is configurable between **Auto** and
**Manual** (a pairing-mode setting in the app). The app's setup wizard has
a dedicated press-the-pair-button page with an instructional animation.

**Factory reset**: hold the button ~15 s until the green POWER LED flashes
rapidly (vendor support article 43000714324). Clears adapter config and bonds;
touches nothing on the vehicle.

## Protocol Summary

### BLE GATT

| UUID | Role | Evidence |
|------|------|----------|
| `0000fff0-0000-1000-8000-00805f9b34fb` | Serial service | string literal in the app: its default serial service |
| `0000fff1-…` | Notify (adapter → host) | the app's default receive characteristic |
| `0000fff2-…` | Write (host → adapter) | the app's default transmit characteristic |

Same family-A pipe as the OBDLink CX. The app enables notifications via the
standard CCCD (`0x2902`) with a Notify/Indicate fallback. Not yet observed
on-air — the capture plan includes a GATT discovery dump to confirm the MX+ BLE
side matches.

### Bluetooth Classic

SPP (UUID `00001101-0000-1000-8000-00805f9b34fb`, string in the app) advertised
as `OBDLink MX+`. Primary link per the vendor spec sheet; iOS uses it via MFi
iAP2. The app raises a dedicated needs-Classic error when an
operation needs Classic, so a BLE-only client should expect some functions
(possibly including firmware update) to be Classic-only until proven otherwise.

The spec records this side in its `bluetooth_classic` block (`dual_mode: true`,
`ble_role: secondary_control`; SPP as the secure control profile, iAP2 listed
but not documented) and finds it with a `bt_classic_inquiry` discovery method
(name prefix `OBDLink MX+`, SPP service class, discoverable only inside the
Connect-button window). The stream is the same ASCII AT/ST command set as the
BLE pipe, lines ending in CR (`0d`), a reply ending at the `>` prompt. The
Classic bond lives in `bluetooth_classic.pairing` (required, inside a ~120 s
window opened by the Connect button); `device.pairing` describes only the BLE
pipe, whose pairing needs are still unknown. `host_compatibility` gives
CoreBluetooth two verdicts: the Classic link is `incompatible` on iOS (no
RFCOMM; workaround `vendor_mfi`, since iAP2 is reachable only through the
vendor's own MFi app), and the BLE link is `degraded`, the path a third-party
iOS client takes, minus whatever the app reserves for Classic.

### STN command surface visible in the app

Beyond the ELM327 baseline, the app uses `STI` (STN ID/firmware — the clone
discriminator), `STIM`, `STMFR`, `STPBR`, `STSLCS`, the `STSL*` sleep/wake
trigger family (`STSLVL*`, `STSLVG*`, `STSLU*`, `STSLX*`), and `STNFWv` in the
firmware path. Full reference: OBDLink FRPM rev F.

### Firmware update

In-app, over the existing serial link — **no separate BLE OTA/DFU service**.
Flow recovered from the app's firmware-update code:

1. App downloads a manifest and "v5" firmware file (parsed by a header
   reader and a file validator) from `api.obdlink.com/devices` —
   per-device-code manifests, Stable/Beta branches, optional private code.
2. The app's firmware loader connects to the adapter bootloader, checks
   bootloader version bounds and the device ID (the app's list covers two
   MX hardware revisions, the LX, the CX and others).
3. Upload is a start-upload command followed by chunked send-chunk
   commands; a dedicated validation image type verifies the flash afterwards.
4. Recovery path exists: a firmware-recovery utility that asks the user to
   power-cycle the device, pick it from a list and retry.

Latest MX+ firmware reported in the wild: 5.12.x. Whether image validation is
cryptographic (signature) or structural (header/checksum) is still open — the
app's invalid-image check is client-side and needs either IL-level
decompilation or an observed update to characterize.

## Tools Used

- [x] apkeep (APKPure) — official OBDLink app 7.4.0
- [x] jadx + custom .NET assembly-store extractor (XALZ/LZ4) + dnfile metadata dump
- [ ] btsnoop HCI capture of app ↔ adapter session (pending hardware)
- [ ] nRF Connect GATT dump (pending hardware)

## References

- [OBDLink MX+ product page](https://www.scantool.net/obdlink-mxp/)
- [OBDLink FRPM rev F (ST command reference)](https://www.scantool.net/scantool/downloads/682/obdlink_frpm_f.pdf)
- [Adapter LED / button semantics](https://support.obdlink.com/support/solutions/articles/43000722033-understand-obdlink-bluetooth-adapter-leds)
- [Factory reset procedure](https://support.scantool.net/support/solutions/articles/43000714324-restore-obdlink-bluetooth-adapter-to-factory-settings)
- [Firmware update support article](https://support.obdlink.com/support/solutions/articles/43000705180-update-obdlink-adapter-firmware)

## Contributors

- @kimi - APK recovery + static analysis, spec and capture plan
