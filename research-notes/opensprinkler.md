# OpenSprinkler — Local HTTP API Research Notes

## What it is
Open-source irrigation controller (OpenSprinkler v3.x, OSPi, plus legacy
hardware) from OpenThings / Rayshobby LLC. Hardware schematics, firmware and
API are all published: [github.com/OpenSprinkler/OpenSprinkler-Firmware](https://github.com/OpenSprinkler/OpenSprinkler-Firmware)
(firmware releases current — 2025-11). The reference local-control device in
this category.

## Local protocol — vendor-documented HTTP GET API
- Built-in web server on **port 80**; every function is an HTTP GET with query
  params. API document on the support site (support.opensprinkler.com) and
  mirrored in the firmware repo.
- Auth: `pw=<md5(device_password)>` query parameter on every call; default
  password is `opendoor` (md5 `a6d82bced638de3def1e9bbb4983225c`). Password
  is set locally on the device.
- Key endpoints (unified firmware):
  - `GET /jc?pw=..` — controller variables; `/jn` station names; `/jp` programs
  - `GET /cv?pw=..&en=1` / `&en=0` — enable/disable operation
  - `GET /cm?pw=..&sid=<n>&en=1&t=<secs>` — manual station run; `en=0` stops
  - `GET /cp?pw=..&pid=<n>&uwt=..` — program control
  - `GET /co`, `/jo`, `/cs` — options/status
- JSON responses throughout. Home Assistant core integration `opensprinkler`
  is local; the device also does its own scheduling fully offline.
- Optional cloud (weather service `weather.opensprinkler.com`) only adjusts
  watering levels; the weather-service source is open
  ([OpenSprinkler-Weather](https://github.com/OpenSprinkler/OpenSprinkler-Weather))
  and self-hostable.

## Cloud dependency
None. The device is fully usable with zero accounts; weather adjustment works
with a self-hosted weather service.

## APK
Not fetched — open firmware + published API docs.

## Rating
**Confirmed** — open-source, vendor-documented, actively maintained 2025.

## Sources (accessed 2026-08-07)
- github.com/OpenSprinkler/OpenSprinkler-Firmware (releases through 2025-11)
- openthings.io; support.opensprinkler.com API document
- opensprinkler.com forums (active May 2025)
