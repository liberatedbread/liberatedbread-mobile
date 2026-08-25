# Onewheel (BLE)

> **Status**: Spec Available (unverified) — active but hostile; firmware unlock handshake
> **Protocol**: BLE
> **Manufacturer**: Future Motion
> **Manufacturer Status**: Active

## Overview

The Onewheel self-balancing board (V1/+/XR/Pint/GT) is controlled over BLE with a per-attribute GATT. Future Motion is hostile — firmware ≥ 4034 won't stream telemetry until the client answers a keyed challenge — so the community pOneWheel app implements the published unlock handshake.

## Protocol Summary

Service e659f300-…; per-attribute chars (f303 battery %, f30b speed RPM, f316 voltage, f311 firmware). Unlock (FW ≥ 4034): read challenge from f3fe, write CRX + MD5(challenge + published static key) to f3ff.

See `device-specs/devices/onewheel-ble.yaml` for the full machine-readable spec.

## References

- <https://github.com/ponewheel/android-ponewheel>
