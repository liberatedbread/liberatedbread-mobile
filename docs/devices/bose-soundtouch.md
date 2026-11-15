# Bose SoundTouch

> **Status**: Unsupported — cloud shut 2026-05-06; Bose published the local API at end-of-life
> **Protocol**: WiFi
> **Manufacturer**: Bose
> **Manufacturer Status**: Unsupported

## Overview

Bose's discontinued multi-room speaker line (SoundTouch 10/20/30, Portable, Wave, SA-4/SA-5). When Bose shut the SoundTouch cloud in May 2026 it patched the app for local-only control and published the local API — so the speakers keep working. (The newer Home Speaker 300/500/700 are a different family and do not use this API.)

## Protocol Summary

Unauthenticated HTTP/XML on port 8090 (`/key`, `/now_playing`, `/volume`, `/select`, `/setZone`), with a `gabbo` WebSocket push channel on port 8080. Discovery via `_soundtouch._tcp` mDNS and SSDP.

See `device-specs/devices/bose-soundtouch.yaml` for the full machine-readable spec.

## References

- <https://www.bose.com/soundtouch-end-of-life>
- <https://github.com/CharlesBlonde/libsoundtouch>
- <https://github.com/thlucas1/bosesoundtouchapi>
