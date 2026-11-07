# Instant Pot Smart Bluetooth (Smart-60)

> **Status**: Spec Available (unverified; source disagreements noted)
> **Protocol**: BLE
> **Manufacturer**: Instant Brands (now Instant Pot Brands)
> **Manufacturer Status**: Abandoned — app reported withdrawn from both stores; vendor through Chapter 11 in June 2023

!!! warning "Remote start heats a sealed pot"
    These commands start pressure-cooking programs. Only start one with someone
    at the cooker, and always offer Cancel.

## Overview

The Instant Pot Smart (Smart-60, 6 qt) was Instant Pot's first Bluetooth
cooker. Its companion app is reported withdrawn and no longer runs on current phones, but the
cooker still talks BLE straight to a phone with no account: 20-byte frames start
and cancel programs, and the cooker notifies its state, remaining time, pressure
and temperature.

The one public reverse-engineering is OpenPot, whose README and code disagree
in several places. The spec follows the code (which drove a cooker) and lists
every disagreement in `remaining_unknowns`.

## Initial Setup

| Property | Value |
|----------|-------|
| Setup required | No network setup; a one-time BLE bond |
| Method | `ble_direct` after bonding |
| Advertised name | `Instant Pot Smart` |
| Confidence | medium (manual + OpenPot) |

**Erase pairings**: hold **Pressure** 10 s (long beep). **Bluetooth off/on**:
hold **Adjust** 10 s. No full factory reset is documented.

## Pairing

| Property | Value |
|----------|-------|
| Pairing required | Yes |
| Security mode | `just_works` (inferred) |
| Bonding | `required` |
| One central at a time | Yes |
| Confidence | medium |

**Entering pairing mode**: while the phone pairs, hold **Adjust** about 3 s
until a short beep, then accept the phone's prompt.

## Protocol Summary

| UUID | Name | Description |
|------|------|-------------|
| `0000dab1-0000-1000-8000-00805f9b34fb` | Command | 20-byte frames starting `aa 55 5a 01` |
| `0000dab2-0000-1000-8000-00805f9b34fb` | Status | Notify; frames start `aa 55 40 02` |
| `0000daa1-0000-1000-8000-00805f9b34fb` | Clock | uint32 LE seconds since 2001-01-01 local |
| `0000daa2`/`daa3` | Delay timers 1/2 | `[hours, minutes]` |
| `0000dac1-0000-1000-8000-00805f9b34fb` | Recipe step | Undocumented beyond the README |

Every frame's last byte makes all 20 bytes sum to 0 mod 256. Cancel is
`aa555a010e000000000000000000000000000098`; Manual high pressure for 30 minutes
is `aa555a010c20300000001e00000000000000002c`. `scripts/test_instant_pot_spec.py`
checks these against the rule.

See `device-specs/devices/instant-pot-smart-bluetooth.yaml` for the full spec.

## References

- [lizardlab/openpot](https://github.com/lizardlab/openpot)
- [Instant Pot Smart-60 manual](https://www.manualslib.com/manual/2251041/Instant-Pot-Smart-60.html)
