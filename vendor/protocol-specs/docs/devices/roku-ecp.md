# Roku External Control Protocol

> **Status**: Complete local discovery and core control documented
> **Protocol**: WiFi (SSDP + HTTP REST on port 8060)
> **Manufacturer**: Roku / TCL
> **Manufacturer Status**: Active

## Overview

Roku TVs and players expose the External Control Protocol (ECP), a local HTTP
API with no authentication. Discovery starts with SSDP `ST: roku:ecp`; the
returned `LOCATION` identifies the host and port, and clients then fetch
`/query/device-info` for stable XML identity.

## Discovery

Use:

```bash
python scripts/roku_discover.py --timeout 5
```

Identity should use `serial-number` first, then `device-id`. The user-facing
name comes from `user-device-name`. AirPlay mDNS (`_airplay._tcp.local.`) can
also locate compatible TCL Roku TVs, but ECP identity should still be fetched
from `/query/device-info`.

## Local API

| Method | Path | Description |
|---|---|---|
| GET | `/query/device-info` | XML identity, model, serial, software version |
| GET | `/query/apps` | Installed apps and app IDs |
| GET | `/query/active-app` | Foreground app |
| GET | `/query/media-player` | Playback state and metadata |
| GET | `/query/icon/<app_id>` | Channel icon (binary image) |
| GET | `/query/tv-channels` | Tuner channels (Roku TV) |
| GET | `/query/tv-active-channel` | Tuned channel with signal info (Roku TV) |
| POST | `/keypress/<key>` | Press and release a remote key |
| POST | `/keydown/<key>` / `/keyup/<key>` | Hold and release a key |
| POST | `/launch/<app_id>` | Launch channel/app, with optional deep link |
| POST | `/install/<app_id>` | Open the Channel Store page for an app |
| POST | `/search/browse?keyword=...` | **Sunset** — removed in Roku OS 12.0 |
| POST | `/input?<name>=<value>` | Sensor/custom input to the running app — does **not** switch TV inputs |

TV input switching is a keypress: `POST /keypress/InputHDMI1` (through
`InputHDMI4`, `InputAV1`, `InputTuner`).

Since Roku OS 14.1, the keypress/keydown/keyup, icon and tv-channel commands
require *Settings > System > Advanced system settings > "Control by mobile
apps" = Enabled*; a device with it disabled answers 403.

## Remote control surface

The spec's `commands` block names one invocation per remote key, and its
`entities` block declares the remote as `button` entities in remote-layout
order — power, navigation and D-pad, playback transport, volume, live-TV
channels, then inputs. That is every key the official Roku app's remote
sends over ECP; `scripts/test_roku_spec.py` renders each button from the
YAML alone and diffs the result against the documented key vocabulary.

## Channel launcher

The `Channel` select entity joins three endpoints into a picker: options
come from `/query/apps` (one `<app>` element per installed channel, the
`id` attribute is the launchable value, the text is the name), the current
channel from `/query/active-app` (same shape; **no `id` on the home
screen**, which reads as nothing selected), and choosing an option sends
`POST /launch/{app_id}`. Both queries stay readable when "Control by
mobile apps" is disabled, so the list loads even on a TV that answers 403
to every keypress.

Machine-readable spec: `device-specs/devices/roku-ecp.yaml`

