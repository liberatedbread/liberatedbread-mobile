# Amcrest / Dahua IP Camera / NVR

> **Status**: Spec Available (unverified) — active; documented CGI API
> **Protocol**: WiFi
> **Manufacturer**: Dahua Technology (Amcrest is a US brand on Dahua firmware)
> **Manufacturer Status**: Active

## Overview

Amcrest is a US brand OEM'd on Dahua firmware; both share a documented CGI/HTTP API and RTSP, controllable locally with no cloud. ONVIF Profile S devices.

## Protocol Summary

RTSP rtsp://user:pass@{ip}:554/cam/realmonitor?channel=1&subtype=0. CGI base /cgi-bin/... (magicBox.cgi identity, snapshot.cgi, eventManager.cgi event stream) over HTTP Digest. See the ONVIF reference for discovery.

See `device-specs/devices/amcrest-dahua-camera.yaml` for the full machine-readable spec.

## References

- <https://s3.amazonaws.com/amcrest-files/AMCREST_CGI_SDK_API.pdf>
- <https://github.com/rroller/dahua>
- <https://github.com/tchellomello/python-amcrest>
