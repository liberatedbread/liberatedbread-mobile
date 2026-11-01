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
  `6e400002-…` and subscribes to `6e400003-…`. Laird VSP
  `8ec90001-f315-4f60-9fb8-838830daea50` is a legacy/alternate identity.
- Commands are 15 bytes: ASCII `0`, a 12-byte payload, then two characters
  for the decimal command code. A one-digit code has NUL second.
- MOVE carries three little-endian float32 values (speed, hold, angle).
  These are app control values, not proven m/s, degrees or percent, and valid
  ranges need a capture.
- STOP is code 0, SPIN 1, MOVE 2, RESET_HEADING 3, ENTER_DFU_MODE 8,
  TURN_OFF 9, SLEEP 10, CONFIG_AUTO_MODE 15, CHIRP 18 and other recovered
  values are listed in the spec.

Notification IDs include auto acknowledgement, firmware/hardware version,
pose, battery voltage, stopped/stuck and NACK. Their payload layouts are not
recovered, so no battery or pose decoder is asserted.

## Safety and remaining work

This is a moving robot and tail assembly. Test STOP and small movement in a
clear area away from pets and cables. Tail calibration needs a flat surface.
Do not test DFU until normal control and charging state are established.
Auto-mode byte offsets, bonding requirements, drive scaling and firmware
compatibility remain open. Firmware recovered from the app is not committed
to the protocol repository.
