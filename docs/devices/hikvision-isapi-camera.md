# Hikvision IP Camera / NVR (ISAPI)

> **Status**: Spec Available (unverified) — active; documented ISAPI
> **Protocol**: WiFi
> **Manufacturer**: Hangzhou Hikvision
> **Manufacturer Status**: Active

## Overview

Hikvision cameras/NVRs expose ISAPI (a REST/XML HTTP API) plus RTSP, controllable locally with no Hik-Connect cloud.

## Protocol Summary

RTSP rtsp://{ip}:554/Streaming/Channels/101 (last digit 1 main / 2 sub). ISAPI resources under /ISAPI/… (System/deviceInfo, Streaming/channels, Event/notification/alertStream) over Basic/Digest. See the ONVIF reference for discovery.

See `device-specs/devices/hikvision-isapi-camera.yaml` for the full machine-readable spec.

## References

- <https://github.com/maciej-or/hikvision_next>
- <https://pypi.org/project/hikvisionapi/>
