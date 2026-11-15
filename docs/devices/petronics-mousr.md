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
activation requirement. The user guide's "pairing" is the app's device list —
press the chin pushbutton, open the app, tap the toy — with no PIN and no OS
Bluetooth step, so the spec records no pairing (low confidence: not replayed).

| Property | Value |
|----------|-------|
| Setup required | No account found |
| Service | `6e400001-b5a3-f393-e0a9-e50e24dcca9e` |
| Command input | `6e400002-b5a3-f393-e0a9-e50e24dcca9e` |
| Notifications | `6e400003-b5a3-f393-e0a9-e50e24dcca9e` |
| Firmware update | Nordic Secure DFU service `0000fe59-0000-1000-8000-00805f9b34fb` (bootloader control point `8ec90001-f315-4f60-9fb8-838830daea50`, packet `8ec90002-f315-4f60-9fb8-838830daea50`) |
| Factory reset | Unknown; DFU and tail calibration are not resets |

An earlier note called `8ec90001`/`8ec90002` a Laird virtual serial port. They
are the Nordic Secure DFU bootloader characteristics; no Laird VSP UUID
(`569a1101-…`) was recorded for this toy.

The factory name is reported as exactly `Mousr`, and the spec matches it as
an exact name together with the Nordic UART service. The service alone is
not a match: many unrelated products carry it, and this spec has movement
commands. The exact match also keeps out `MousrDfu`, the bootloader name,
which the spec declares as update mode. The app lets an owner rename the toy;
a renamed unit is not auto-matched and has to be added by hand.

## Command packet

Every ordinary command is exactly 15 bytes:

```text
offset 0:  ASCII 30
offset 1:  12-byte payload, zero-filled when unused
offset 13: two-byte command code
```

A two-digit code is its two ASCII digits: code 18 ends `31 38`. **The second
byte of a one-digit code is unresolved.** The analysis behind this spec gave
two readings that contradict each other, and no capture settles which is
right:

- form A, ASCII `0` then the digit: code 2 ends `30 32`, code 0 ends `30 30`;
- form B, the digit then NUL: code 2 ends `32 00`, code 0 ends `30 00`.

The declared commands keep the bytes recorded for each, which mix the two
(stop is form B; spin, move, reset heading and turn off are form A). Each
one-digit command is therefore marked `verification: hypothesis` and its
description gives the other form. Try stop in both forms first and keep
whichever the toy obeys.

| Code | Command | Code | Command |
|---:|---|---:|---|
| 0 | stop | 18 | chirp |
| 1 | spin | 19 | set sound volume |
| 2 | move (drive vector) | 23 | tail flick |
| 3 | reset heading | 24 | reverse |
| 4 | request debug log | 25 | tail calibration |
| 5 | planned spin | 26 | set tail |
| 8 | enter bootloader (DFU) mode | 28 | initialize device |
| 9 | turn off | 31 | flip the robot over |
| 10 | sleep | 41 | configure driver assist |
| 15 | configure autonomous play mode | 45 | tutorial step |
| 46 | set time | 100 | invalid command |

Only commands with an established payload are declared in the YAML.
Auto-mode offsets, debug-log transfer, calibration, driver assist, set time
and bootloader entry are listed so they can be captured, but their payloads
cannot be inferred from a code number alone. Move and spin are flagged
`advanced` because they drive a robot with no established physical scaling;
sleep, turn off and reset heading are ordinary app controls and are not.

### Drive vector

The move command places three little-endian IEEE-754 binary32 values in the payload:

```text
offset 1: speed, float32 LE
offset 5: hold, float32 LE
offset 9: angle, float32 LE
offset 13: code 2 (ASCII 02 as declared; see above)
```

These are app control values, **not established m/s, degrees or percent**.
Valid ranges need a capture. The app therefore presents them as raw,
unbounded float32 inputs with an attended-motion warning rather than
inventing a physical scale. Stop is an independent fixed command and should
be tested first.

### Notifications

Recovered IDs include `15` auto acknowledgement, `28/29` firmware/hardware
version, `30` initialization complete, `48` pose, `64` stuck distance sensor,
`98` battery voltage, `99` stopped, `100` stuck and `255` negative
acknowledgement. Their full payload layouts are not established, so the spec
does not invent battery or pose decoders.

## Safety and recovery

This is a moving robot and tail assembly. Test stop and small movement in a
clear area away from pets, people, cables and edges. Tail calibration needs
a flat, unobstructed surface. Do not attempt DFU until ordinary control and
charging state are established. The app's bundled recovery firmware is
valuable, but is not shipped here and has no verified update sequence. The
spec's `features` block records the Nordic Secure DFU path and the
`MousrDfu` update-mode name.

`scripts/test_petronics_mousr_spec.py` checks packet lengths, that the
declared stop and chirp bytes equal the spec's own vectors, and the integer
and fractional float32 drive vectors. It does not establish the one-digit
code byte: it checks that every one-digit command is marked `hypothesis` and
that both forms are written down.

See `device-specs/devices/petronics-mousr.yaml` for the full spec.

## References

- [Mousr Kickstarter FAQ](https://www.kickstarter.com/projects/525985345/mousr-the-robotic-mouse-that-plays-with-your-cat/faqs) — product and Bluetooth-control background
- Official Mousr 1.0.7 app and bundled User Guide v1.2, analysed 2026-11-01 — command and safety evidence
