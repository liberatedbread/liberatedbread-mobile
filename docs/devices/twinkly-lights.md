# Twinkly Smart Lights

> **Status**: Spec Available (unverified) — active
> **Protocol**: WiFi
> **Manufacturer**: Ledworks Srl (Twinkly)
> **Manufacturer Status**: Active

## Overview

App-controlled decorative RGB/RGBW string, curtain and matrix lights. Control is a private-but-reverse-engineered local REST API (the promised public API never shipped); xled documents it.

## Protocol Summary

HTTP REST on port 80 with a short-lived token (`/xled/v1/login` + `/verify`, `X-Auth-Token`), plus a UDP 7777 realtime per-pixel channel. Discovery is a UDP 5555 broadcast.

See `device-specs/devices/twinkly-lights.yaml` for the full machine-readable spec.

## References

- <https://github.com/scrool/xled>
- <https://xled-docs.readthedocs.io/>
