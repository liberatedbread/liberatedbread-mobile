# Magic Home / Zengge Wi-Fi LED Controller

> **Status**: Spec Available (unverified) — protocol active; block from the internet to keep it
> **Protocol**: WiFi
> **Manufacturer**: Zengge (white-labeled: Magic Home, Magic Hue, MagicLight, Flux, and dozens more)
> **Manufacturer Status**: Active

## Overview

Zengge's Wi-Fi LED controllers and bulbs, sold under dozens of brands (Magic Home, Magic Hue, MagicLight, Flux). flux_led reverse-engineered the protocol and Home Assistant uses it.

## Protocol Summary

Plaintext binary on TCP 5577 (last byte = additive checksum), no auth: power `71 23 0F`, colour `31 RR GG BB WW ...`, state query `81 8A 8B`. Discovery/config over the Hi-Flying UDP 48899 `HF-A11ASSISTHREAD` channel.

See `device-specs/devices/magic-home-zengge-wifi.yaml` for the full machine-readable spec.

## References

- <https://github.com/Danielhiversen/flux_led>
- <https://github.com/vikstrous/zengge-lightcontrol>
