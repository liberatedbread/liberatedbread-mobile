# Petronics Mousr

> **Status**: Spec Available (static-analysis-derived; untested on hardware)
> **Protocol**: BLE, Nordic UART
> **Manufacturer**: Petronics Inc.
> **Manufacturer Status**: Abandoned — consumer production and support ended

## Overview

Mousr is a phone-direct robotic cat toy. Ordinary operation does not require
an account or cloud service. The recovered official 1.0.7 app supplies the
command builders, command vocabulary, firmware recovery packages and user
guide. No community protocol implementation was found.

The command envelope and drive-vector encoding are now recovered, but no toy
or HCI capture has verified them. Notification payloads, auto-mode settings,
physical scaling of drive values and firmware compatibility remain open.

## Initial Setup and Pairing

Charge and wake the toy, then connect to the Nordic UART service and enable
notifications. Static analysis found no account or application-layer
activation requirement. The guide discusses Bluetooth pairing, but whether a
persistent bond is required on every firmware/phone combination is unverified.

| Property | Value |
|----------|-------|
| Setup required | No account found |
| Service | `6e400001-b5a3-f393-e0a9-e50e24dcca9e` |
| Command input | `6e400002-b5a3-f393-e0a9-e50e24dcca9e` |
| Notifications | `6e400003-b5a3-f393-e0a9-e50e24dcca9e` |
| Alternate identity | Laird VSP `8ec90001-f315-4f60-9fb8-838830daea50` |
| Factory reset | Unknown; DFU and tail calibration are not resets |

The advertised factory name is `Mousr`, but it is user-renamable. `MousrDfu`
is the bootloader identity, not a target for ordinary commands. Prefer the
Nordic UART service for discovery.

## Command packet

Every ordinary command is exactly 15 bytes:

```text
offset 0:  ASCII 30
offset 1:  12-byte payload, zero-filled when unused
offset 13: two-character decimal command code
```

A one-digit code has NUL as its second character. Thus code 2 ends in ASCII
`02`, code 18 in `18`, and code 0 in ASCII `0` followed by NUL.

| Code | Command | Code | Command |
|---:|---|---:|---|
| 0 | STOP | 18 | CHIRP |
| 1 | SPIN | 19 | SOUND_VOLUME |
| 2 | MOVE | 23 | Flick_SIGNAL |
| 3 | RESET_HEADING | 24 | Reverse_SIGNAL |
| 4 | GET_DEBUG_LOG | 25 | Tail_Calib_SIGNAL |
| 5 | SPIN_PLAN | 26 | Set_Tail_SIGNAL |
| 8 | ENTER_DFU_MODE | 28 | INITIALIZE_DEVICE |
| 9 | TURN_OFF | 31 | FLIP_ROBOT |
| 10 | SLEEP | 41 | CFG_DRIVER_ASSIST |
| 15 | CONFIG_AUTO_MODE | 45 | TUTORIAL_STEP |
| 46 | CMD_SET_TIME | 100 | INVALID |

Only commands with an established envelope and clear scope are declared in
the YAML. Auto-mode offsets, debug-log transfer, calibration, driver assist,
set-time and DFU are not safe to infer from a code number alone.

### Drive vector

MOVE places three little-endian IEEE-754 binary32 values in the payload:

```text
offset 1: speed, float32 LE
offset 5: hold, float32 LE
offset 9: angle, float32 LE
offset 13: ASCII 02
```

These are app control values, **not established m/s, degrees or percent**.
Valid ranges need a capture. The app therefore presents them as raw,
unbounded float32 inputs with an attended-motion warning rather than
inventing a physical scale. STOP is an independent fixed command and should
be tested first.

### Notifications

Recovered IDs include `15` auto acknowledgement, `28/29` firmware/hardware
version, `30` initialization complete, `48` pose, `64` stuck distance sensor,
`98` battery voltage, `99` stopped, `100` stuck and `255` negative
acknowledgement. Their full payload layouts are not established, so the spec
does not invent battery or pose decoders.

## Safety and recovery

This is a moving robot and tail assembly. Test STOP and small movement in a
clear area away from pets, people, cables and edges. Tail calibration needs
a flat, unobstructed surface. Do not attempt DFU until ordinary control and
charging state are established. The app's bundled recovery firmware is
valuable, but is not shipped here and has no verified update sequence.

`scripts/test_petronics_mousr_spec.py` checks packet lengths, decimal codes,
and integer and fractional float32 vectors.

See `device-specs/devices/petronics-mousr.yaml` for the full spec.

## References

- [Mousr Kickstarter FAQ](https://www.kickstarter.com/projects/525985345/mousr-the-robotic-mouse-that-plays-with-your-cat/faqs) — product and Bluetooth-control background
- Official Mousr 1.0.7 app and bundled User Guide v1.2, analysed 2026-11-01 — command and safety evidence
