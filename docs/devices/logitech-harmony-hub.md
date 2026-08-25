# Logitech Harmony Hub

> **Status**: Abandoned — Logitech ended Harmony manufacturing April 2021
> **Protocol**: WiFi
> **Manufacturer**: Logitech
> **Manufacturer Status**: Abandoned

## Overview

Logitech's IR/Bluetooth/IP universal-remote bridge. Logitech stopped making Harmony in 2021, but local control survives the cloud entirely.

## Protocol Summary

A local WebSocket API on TCP 8088; a one-time HTTP POST to port 8088 returns the `remoteId`, then JSON requests start/stop activities and send device commands. Idle sockets close after ~60s. SSDP search target `urn:myharmony-com:device:harmony:1`.

See `device-specs/devices/logitech-harmony-hub.yaml` for the full machine-readable spec.

## References

- <https://github.com/ehendrix23/aioharmony>
- <https://github.com/JordanMartin/harmonyhub-api>
- <https://www.home-assistant.io/blog/2018/12/17/logitech-harmony-removes-local-api/>
