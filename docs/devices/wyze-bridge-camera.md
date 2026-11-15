# Wyze Cam (via docker-wyze-bridge)

> **Status**: Spec Available (unverified) — active; local stream via a community bridge
> **Protocol**: WiFi
> **Manufacturer**: Wyze Labs
> **Manufacturer Status**: Active

## Overview

Wyze cameras have no first-party local API — control is cloud-app only. The community docker-wyze-bridge authenticates to the Wyze cloud once (to enumerate cameras), connects over Wyze's TUTK P2P transport, and re-serves the video locally as RTSP/HLS/WebRTC. A 'cloud token to bootstrap, local stream thereafter' case.

## Protocol Summary

The bridge exposes RTSP 8554 (rtsp://{bridge-ip}:8554/{camera-name}), HLS 8888, WebRTC 8889, web UI 5000. Needs Wyze email/password + an API Key/ID (since May 2024) to enumerate cameras.

See `device-specs/devices/wyze-bridge-camera.yaml` for the full machine-readable spec.

## References

- <https://github.com/mrlt8/docker-wyze-bridge>
