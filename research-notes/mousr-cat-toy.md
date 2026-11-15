# Petronics Mousr — Research Notes

## Current status (2026-11-01)

The validated spec is `device-specs/devices/petronics-mousr.yaml`; the owner
guide is `docs/devices/petronics-mousr.md`. The recovered official 1.0.7 app
contains all ordinary command builders, three application-firmware packages,
a SoftDevice/bootloader package and the user guide. No account was found for
ordinary BLE operation. No toy or HCI capture has verified the recovered wire
facts.

## GATT and command envelope

- Nordic UART service `6e400001-b5a3-f393-e0a9-e50e24dcca9e`; phone writes
  `6e400002-…` and subscribes to `6e400003-…`.
- `8ec90001-f315-4f60-9fb8-838830daea50` and `8ec90002-…` are the Nordic
  Secure DFU control point and packet characteristics, under service
  `0000fe59-0000-1000-8000-00805f9b34fb`. The August note's "Laird VSP"
  label for them was a misidentification; Laird VSP is `569a1101-…`, which
  was not recorded for this toy. The spec carries a `firmware_update`
  feature with the `MousrDfu` update-mode name.
- Commands are 15 bytes: ASCII `0`, a 12-byte payload, then two bytes for
  the command code. A two-digit code is its two ASCII digits. For a one-digit
  code the analysis gave two contradictory readings — ASCII `0` then the
  digit, or the digit then NUL — and nothing observed settles it. The spec
  records both and marks those commands `hypothesis`.
- The move command carries three little-endian float32 values (speed, hold,
  angle). These are app control values, not proven m/s, degrees or percent,
  and valid ranges need a capture.
- Codes: stop 0, spin 1, move 2, reset heading 3, enter bootloader mode 8,
  turn off 9, sleep 10, configure autonomous play 15, chirp 18; the other
  recovered codes are listed in the spec by role.
- Discovery matches the exact name `Mousr` together with the Nordic UART
  service. The service alone is shared by many products and is not a
  match; a renamed toy is added by hand.

Notification IDs include auto-mode acknowledgement, firmware/hardware
version, pose, battery voltage, stopped/stuck and negative acknowledgement.
Their payload layouts are not recovered, so no battery or pose decoder is
asserted.

## Safety and remaining work

This is a moving robot and tail assembly. Test stop and small movement in a
clear area away from pets and cables. Tail calibration needs a flat surface.
Do not test DFU until normal control and charging state are established.
Auto-mode byte offsets, bonding requirements, drive scaling, the one-digit
code byte and firmware compatibility remain open. Firmware recovered from the app is not committed
to the protocol repository.
