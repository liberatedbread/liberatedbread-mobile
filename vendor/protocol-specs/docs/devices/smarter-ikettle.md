# Smarter iKettle 2.0 / Smarter Coffee

> **Status**: Shutdown — smart features removed from the app in mid-2025
> **Protocol**: WiFi
> **Manufacturer**: Smarter Applications Ltd
> **Manufacturer Status**: Shutdown

## Overview

Wi-Fi kettles/coffee makers whose app features were removed in 2025, leaving "very expensive ordinary kettles". The LAN protocol needs no cloud, so it is the rescue path.

## Protocol Summary

Binary protocol on port 2081 (UDP or TCP), no auth, `<id> <args> 0x7e` framing: 21 boil, 22 off, 0x40 device-info; responses 3 ack, 20 status (temperature + water level).

See `device-specs/devices/smarter-ikettle.yaml` for the full machine-readable spec.

## References

- <https://github.com/ian-kent/ikettle2/blob/master/protocol/README.md>
- <https://github.com/jkellerer/iBrew>
