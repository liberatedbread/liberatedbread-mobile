# InMotion Electric Unicycles

> **Status**: Spec Available (untested)
> **Protocol**: BLE (two incompatible generations)
> **Manufacturer**: INMOTION Technologies (active)

## Safety

A command that changes ride behaviour while someone is on the wheel can throw
the rider. Read telemetry with the wheel stationary and nobody riding it. Do
not experiment with speed limits, ride modes, calibration, lock state, lights
or motor commands on a moving wheel. The spec marks consequential commands
`advanced` and records recovery information where it is known.

## Overview

The spec covers V5/V8/Glide 3/V10-era wheels and V2 models from V9 through
V14. It includes discovery fingerprints, setup order, telemetry layouts,
model-specific command differences and worked vectors:
`device-specs/devices/inmotion-euc.yaml`. Nothing has been driven from this
document by the project; public WheelLog code and captured frames are the
principal evidence.

## Setup and pairing

No link-layer pairing or bonding is required on either control protocol.
Disconnect the previous phone before connecting another client. The vendor
cloud's owner binding and any separate Bluetooth-audio pairing are unrelated
to this BLE control path.

### Legacy wheels

Use this route when the GATT table has services
`0000ffe0-0000-1000-8000-00805f9b34fb` and
`0000ffe5-0000-1000-8000-00805f9b34fb`, but no Nordic UART service:

1. Power the wheel, scan for its advertised name and connect.
2. Subscribe to `0000ffe4-0000-1000-8000-00805f9b34fb`.
3. Send the application-layer password message described in the spec. It
   carries six ASCII digits and two zero bytes; do not confuse this with a
   Bluetooth PIN or publish an owner's changed password.
4. Poll slow information until serial, model and firmware are known, then poll
   fast information for telemetry. Writes to
   `0000ffe9-0000-1000-8000-00805f9b34fb` are split into at most 20-byte
   chunks.

### V2 wheels

Use this route when Nordic UART service
`6e400001-b5a3-f393-e0a9-e50e24dcca9e` is present:

1. Connect and subscribe to `6e400003-b5a3-f393-e0a9-e50e24dcca9e`.
2. Request car type, serial and versions before issuing controls.
3. Read settings once, then alternate real-time and total-statistics requests.
4. Select the reply layout from the model and firmware, not merely from the
   product name. Early V11 firmware differs from later V2 layouts.

## Factory reset and rebinding

No factory reset is established for either generation. Ride settings, the
legacy application password, any touch-screen access code, lock state and the
vendor-cloud owner binding are separate pieces of state; no known operation
clears them all.

A new phone uses the same direct BLE connection after the old one disconnects.
No Wi-Fi rejoin or cloud transfer is needed for the protocol in this spec.

## Protocol summary

Both generations use request/response messages around 250 ms apart, but their
GATT endpoints, message IDs and payload layouts differ. Decode serial and
model information before choosing a telemetry parser. The YAML carries the
field offsets, signedness, units, scaling and per-model command tables needed
to implement a client without copying WheelLog code.

## References

- [WheelLog Android source](https://github.com/Wheellog/Wheellog.Android)
- [INMOTION V11 manual (FCC exhibit)](https://fccid.co/api/files/s1/2adusv11_usersmanual_4904476_0813a721b0.pdf)
- [INMOTION V12 manual (FCC exhibit)](https://fccid.co/api/files/s1/2adusv12_usersmanual_5182155_e65090bccd.pdf)
- [INMOTION V12 Pro manual (FCC exhibit)](https://fccid.co/api/files/s1/2adusv12pro_usersmanual_7203048_ec4e0fad4a.pdf)
- [INMOTION V13 Challenger manual (FCC exhibit)](https://fccid.co/api/files/s1/2adusv13_usersmanual_6271116_7e90838860.pdf)
