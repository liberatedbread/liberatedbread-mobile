# openScale-documented BLE Body Scales

> **Status**: Spec Available (unverified) — active vendors; openScale documents the protocols
> **Protocol**: BLE
> **Manufacturer**: Beurer / Sanitas / SilverCrest, Medisana, Trisa (openScale documents 85 scales)
> **Manufacturer Status**: Active

## Overview

Three BLE body-scale families openScale documents that are not already here — Beurer/Sanitas, Medisana BS444 and Trisa Body Analyze 4.0. Local BLE reads, no cloud.

## Protocol Summary

Beurer/Sanitas: service 0xFFE0, char 0xFFE1, 22-byte record. Medisana BS444: 0x78b2 service, indicate 0x8a21/0x8a22, trigger `02 7b 7b f6 0d`. Trisa: 0x78b2 with an XOR challenge-response and mantissa/exponent weight.

See `device-specs/devices/openscale-body-scales.yaml` for the full machine-readable spec.

## References

- <https://github.com/oliexdev/openScale/wiki/Supported-scales-in-openScale>
- <https://github.com/oliexdev/openScale/wiki/Medisana-BS444>
- <https://github.com/oliexdev/openScale/wiki/Trisa-Body-Analyze>
