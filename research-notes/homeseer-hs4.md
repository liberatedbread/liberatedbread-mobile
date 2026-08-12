# HomeSeer HS4 (HomeTroller hubs / HS4-Pi / self-hosted) — Research Notes

## What it is
Actively sold commercial home-automation platform: HomeTroller hubs and
HS4 software for Windows/Linux/Raspberry Pi. Value here is documenting the
vendor-supported local APIs; company is alive (docs updated 2024-10).

## Local API A — JSON over HTTP (confirmed, vendor-documented)
- Served by the HS4 web server (default **port 80**):
  `GET /JSON?request=getstatus&ref=*` — all device states
  `GET /JSON?request=controldevicebyvalue&ref=<n>&value=<v>` — control
  `GET /JSON?request=runevent&id=<n>` — trigger events
- Optional HTTP auth (HS user/pass); can be disabled for LAN/no-auth subnets.
- Doc: [docs.homeseer.com JSON API](https://docs.homeseer.com/hspi/json-api) (2024-10).

## Local API B — ASCII over TCP (confirmed, vendor-documented)
- Raw TCP control/status stream; enable in Setup → Network ("Control using
  JSON and ASCII commands"). Docs list the Control Port alongside the Network
  Port (default **10401**); the long-standing community default for ASCII is
  10400 (pyhs3/marthoc-homeseer).
- Doc: [docs.homeseer.com Network](https://docs.homeseer.com/products/network) (2022-08).

## Implementations
- [github.com/marthoc/homeseer](https://github.com/marthoc/homeseer) — Home
  Assistant custom integration, local JSON+ASCII (2024).
- pyhs3 (legacy HS3), countless Tasker/HTTP examples.

## Cloud dependency
None. MyHS (connected2.homeseer.com) is an optional remote relay; both local
APIs work with no account.

## APK
Not needed (vendor-documented). Not fetched.

## Rating
**Confirmed** — vendor-documented + shipping integrations.
