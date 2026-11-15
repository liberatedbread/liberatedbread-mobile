# WiZ Wi-Fi Lights

> **Status**: Spec Available (unverified) — active (Signify/Philips)
> **Protocol**: WiFi
> **Manufacturer**: WiZ Connected (Signify / Philips)
> **Manufacturer Status**: Active

## Overview

Signify's (Philips) budget smart-lighting line — bulbs, strips, plugs — controllable entirely on the LAN with no account once on the network.

## Protocol Summary

UDP/JSON: the light listens on port 38899, the client receives pushes on 38900. Methods `setPilot`/`getPilot`/`registration`. Discovery is a UDP broadcast `registration` message.

See `device-specs/devices/wiz-wifi-light.yaml` for the full machine-readable spec.

## References

- <https://github.com/sbidy/pywizlight>
- <https://github.com/UselessMnemonic/OpenWiz>
