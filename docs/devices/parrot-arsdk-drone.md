# Parrot Drones (AR.Drone / ARSDK3)

> **Status**: Abandoned — Parrot exited consumer drones in 2019
> **Protocol**: WiFi
> **Manufacturer**: Parrot SA
> **Manufacturer Status**: Abandoned

## Overview

Parrot's consumer drones (AR.Drone 1.0/2.0, Bebop, Anafi), controlled entirely over the drone's own Wi-Fi AP with no cloud. Parrot open-sourced the SDK.

## Protocol Summary

AR.Drone: AT commands over UDP 5556 (AP 192.168.1.1). ARSDK3: a TCP 44444 JSON discovery handshake, then UDP 54321 commands / 43210 navdata (AP 192.168.42.1). No account or pairing secret.

See `device-specs/devices/parrot-arsdk-drone.yaml` for the full machine-readable spec.

## References

- <https://github.com/felixge/node-ar-drone>
- <https://github.com/robotika/katarina/blob/master/bebop-protocol.md>
- <https://developer.parrot.com/docs/olympe/overview.html>
