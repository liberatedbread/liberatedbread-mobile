# OSRAM Lightify Gateway

> **Status**: Shutdown — Lightify cloud switched off 2026-08-31
> **Protocol**: WiFi
> **Manufacturer**: OSRAM (consumer arm later LEDVANCE)
> **Manufacturer Status**: Shutdown

## Overview

OSRAM's Wi-Fi-to-Zigbee bridge for Lightify bulbs/plugs. The cloud shutdown ended internet control and app device-management; the reverse-engineered local TCP protocol is the fully-working path left (and the bulbs are plain Zigbee any coordinator can adopt).

## Protocol Summary

Persistent binary TCP on port 4000, no auth: length/flag/command/request-id framing, device = uint64 MAC or a zone id. Commands 0x31 brightness, 0x32 power, 0x33 color-temp, 0x36 RGBW, 0x52 scene. mDNS host `Lightify-XXXXXXXX`.

See `device-specs/devices/osram-lightify-gateway.yaml` for the full machine-readable spec.

## References

- <https://github.com/noctarius/lightify-binary-protocol>
- <https://github.com/tfriedel/python-lightify>
