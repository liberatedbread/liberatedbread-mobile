# Google Chromecast (CASTv2)

> **Status**: Abandoned — Chromecast hardware discontinued Aug 2024
> **Protocol**: WiFi
> **Manufacturer**: Google
> **Manufacturer Status**: Abandoned

## Overview

Google's media-receiver line (the Chromecast dongles, Chromecast Audio, Chromecast with Google TV). Production ended in 2024; the CASTv2 protocol lives on in Cast-enabled devices. Discovery, CASTv2 control and the Default Media Receiver can load and control local media URLs with no account.

## Protocol Summary

TLS on TCP 8009 carrying length-prefixed protobuf CastMessages across the connection/heartbeat/receiver/media namespaces. Discovery via `_googlecast._tcp` mDNS (TXT `fn`/`md`/`id`).

See `device-specs/devices/chromecast-castv2.yaml` for the full machine-readable spec.

## References

- <https://github.com/thibauts/node-castv2>
- <https://github.com/thibauts/node-castv2-client>
- <https://github.com/home-assistant-libs/pychromecast>
