# Wilson X Connected Basketball — Research Notes

## Corrected protocol family (2026-11-01)

Wilson X belongs to the app's **fa10 three-axis accelerometer path**, not
94Fifty's HDLC/RFCOMM protocol and not the `aa80`/`fd40` 9-DoF variants.
The final official 1.3.8 app preserves enough logic for a local shot-stream
client, but no ball or packet capture has verified it.

| UUID | Role |
|---|---|
| `0000fa10-0000-1000-8000-00805f9b34fb` | Three-axis acceleration service |
| `0000fa11-0000-1000-8000-00805f9b34fb` | Acceleration notifications |
| `0000fa12-0000-1000-8000-00805f9b34fb` | Output mode, written before subscribing |
| `0000fa15-0000-1000-8000-00805f9b34fb` | Calibration data |
| `0000fa16-0000-1000-8000-00805f9b34fb` | Timing data, not decoded |

Hardware 130 selects mode 1: signed `(x,y,z)` bytes, each transformed as
`(signed_byte / 127.0) * 12.0 / 1000.0`; no clean physical unit is claimed.
Hardware 65/69/129 selects mode 6 below firmware 48 and mode A later. Mode 6
is 16 bytes: five big-endian u24 magnitudes (`sqrt(value) * 0.006`) and a
wrapping packet counter. Related mode 2 uses `sqrt(u24be) * 0.012`. Never
apply the signed-axis decoder to magnitude packets. Hardware 103 and 104 use
the separate 9-DoF paths.

Startup writes the selected numeric mode to `fa12`, then enables `fa11`
notifications. No bonding or app-level authentication was found in this path.
Decoder selection depends on advertised hardware/firmware values whose
capture layout still needs checking, so a generic client must not guess.

## Local/cloud boundary

The acceleration stream is local BLE. Shot make/miss classification happens
in the phone app's classifier, not through a cloud API; the phone-side proxy
characteristic is not the ball's original protocol. A first-run account flow
exists and no offline guest path has been proven. That means a replacement
client needs its own local profile flow even though the radio stream itself
needs no account.

Next evidence: read hardware/firmware advertisements, capture one mode-1
session with ground-truth shots, and establish `fa15`/`fa16` semantics and
offline onboarding before writing an app spec.
