# Reolink IP Camera / Doorbell / NVR

> **Status**: Spec Available (unverified) — active; local despite cloud-default app
> **Protocol**: WiFi
> **Manufacturer**: Reolink
> **Manufacturer Status**: Active

## Overview

Reolink cameras/doorbells/NVRs are locally controllable with the internet blocked: HTTP CGI JSON API, RTSP/RTMP/FLV, ONVIF, and a proprietary Baichuan protocol on TCP 9000 (the only surface on some battery models).

## Protocol Summary

RTSP main rtsp://user:pass@{ip}/Preview_01_main; CGI POST /cgi-bin/api.cgi?cmd=Login returns a token reused as ?token=. Baichuan (9000): magic 0x0abcdef0, message ids 1 login / 3 Preview / 23 Reboot / 80 VersionInfo. ONVIF for discovery — see the ONVIF reference.

See `device-specs/devices/reolink-camera.yaml` for the full machine-readable spec.

## References

- <https://www.home-assistant.io/integrations/reolink/>
- <https://github.com/ReolinkCameraAPI/reolinkapipy>
- <https://github.com/thirtythreeforty/neolink>
