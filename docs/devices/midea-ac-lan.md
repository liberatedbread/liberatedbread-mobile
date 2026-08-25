# Midea Air Conditioner / Dehumidifier (LAN)

> **Status**: Spec Available (unverified) — active; huge OEM footprint
> **Protocol**: WiFi
> **Manufacturer**: Midea Group (many rebrands: Comfee, Inventor, Pro Breeze, Artic King, Toshiba-app units)
> **Manufacturer Status**: Active

## Overview

Midea's Wi-Fi ACs and dehumidifiers, sold under many rebrands. Local control over TCP with a "one-time cloud, then local" story for V3 units.

## Protocol Summary

Encrypted appliance protocol on TCP 6444, discovered by a UDP 6445 broadcast. V2 needs no token; V3 needs a TOKEN+KEY fetched once from the Midea cloud, then works locally.

See `device-specs/devices/midea-ac-lan.yaml` for the full machine-readable spec.

## References

- <https://github.com/mill1000/midea-msmart>
- <https://github.com/nbogojevic/midea-beautiful-air>
