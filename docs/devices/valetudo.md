# Valetudo (rooted vacuum)

> **Status**: Spec Available (unverified) — open by design; the rescue path
> **Protocol**: WiFi
> **Manufacturer**: Sören Beye (Hypfer) + community (vacuum vendors: Roborock, Dreame, Midea)
> **Manufacturer Status**: Active

## Overview

Cloud-replacement software that runs ON a rooted robot vacuum (Roborock, Dreame, Midea), intercepting the vendor firmware's cloud comms and exposing a fully local UI/REST/MQTT. The canonical way to de-cloud a working robot.

## Protocol Summary

On-robot HTTP REST base `/api/v2` (Swagger at `/swagger/`); `GET /api/v2/` lists the robot's capabilities; `PUT .../BasicControlCapability` {start|stop|home}. MQTT with Home Assistant autodiscovery. Requires rooting.

See `device-specs/devices/valetudo.yaml` for the full machine-readable spec.

## References

- <https://valetudo.cloud/>
- <https://github.com/Hypfer/Valetudo>
- <https://builder.dontvacuum.me/>
