# OpenEVSE / EmonEVSE Charging Station

> **Status**: Spec Available (unverified) — active; open by design
> **Protocol**: WiFi
> **Manufacturer**: OpenEVSE LLC (with OpenEnergyMonitor)
> **Manufacturer Status**: Active

## Overview

An open-source EV charging station: an ESP32 Wi-Fi gateway wraps a controller that speaks the RAPI serial protocol. Everything is local and open — no cloud.

## Protocol Summary

HTTP API (`/status`, `/config`, `/override`) + WebSocket + MQTT (`openevse-xxxx/...`), optional OCPP. The controller RAPI serial protocol underneath sets current (`$SC`), pause/resume (`$FS`/`$FE`), etc.

See `device-specs/devices/openevse.yaml` for the full machine-readable spec.

## References

- <https://github.com/OpenEVSE/openevse_esp32_firmware>
- <https://openevse.stoplight.io/docs/openevse-wifi-v4/>
- <https://github.com/lincomatic/open_evse/blob/master/firmware/open_evse/rapi_proc.h>
