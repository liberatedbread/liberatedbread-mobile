# Meizu MYVU / Star Air AR Glasses

> **Status**: Spec Available (untested)
> **Protocol**: BLE session plus Bluetooth Classic RFCOMM relay
> **Manufacturer**: Meizu / Hubei Xingji Meizu Group (active)

## Overview

The spec covers MYVU / Star Air XGA010C and records evidence for later V2
GATT layouts separately:
`device-specs/devices/meizu-myvu-glasses.yaml`. It documents the two-link
setup, application-layer ECDH exchange, session initialization, heartbeat,
per-session Classic relay, message framing and worked vectors. The public
unofficial SDK is the main evidence; nothing has been replayed by this
project.

## Setup and pairing

Both links are required, in order:

1. **BLE session.** Connect over LE and run the application-layer bond on
   characteristic `0x2020`: version negotiation, an ECDH P-256 exchange and
   encrypted DeviceInfo in both directions. Complete the RunAsOne
   initialization and maintain the heartbeat. The LE link itself is not
   bonded through the operating system.
2. **Classic relay.** Read the per-session RFCOMM service UUID announced over
   BLE, then open the Classic relay to that UUID. This phase needs a BR/EDR
   bond. Do not reuse a channel number captured in another session; the UUID
   and SDP record select the current relay.

There is no certificate or shared installation secret in the app-layer ECDH
step, and no vendor account is required. Treat session keys, device identity
and captured traffic as owner-private even though the cryptographic exchange
itself is described in the spec.

## Factory reset and rebinding

The public SDK names a factory-reset action over the relay, but its wire form
and cleared state are not documented. Use the vendor app's own reset option;
the menu path was not recorded. The 8-second power-button hold is only a hard
reboot, not a known factory reset.

To move to a new phone or client, disconnect in the vendor app and remove or
disable the glasses in the old phone's Bluetooth settings. Then repeat both
link phases. ECDH keys are per session; whether the glasses retain multiple
BR/EDR bonds is unknown. There are no Wi-Fi credentials to rejoin.

## Protocol summary

The BLE side establishes session state and carries link control. The Classic
side carries the main application relay. Message IDs, ordering, heartbeat and
acknowledgement rules matter: a duplicated or skipped sequence can leave
messages buffered indefinitely. The YAML declares the initialization order,
packet types, encryption envelopes, field encodings, relay discovery and
negative findings. Do not reduce the device to a single GATT command
characteristic.

## References

- [MYVU AR Glasses XGA010C user manual](https://fms.res.meizu.com/dms/2025/02/17/7355710f-cfac-46ca-9f6c-857703cac963.pdf)
- [Unofficial Meizu-Myvu-SDK](https://github.com/Panny777/Meizu-Myvu-SDK)
- [Unofficial Meizu-Myvu-Client](https://github.com/Panny777/Meizu-Myvu-Client)
- [Common Bluetooth Classic Patterns](../protocols/bluetooth-classic-common.md)
