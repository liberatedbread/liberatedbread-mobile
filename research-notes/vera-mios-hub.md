# Vera (MiOS) Hubs — VeraEdge / VeraPlus / VeraSecure — Research Notes

## What it is
Z-Wave/Zigbee home-automation controllers from Mi Casa Verde → Vera Control →
Ezlo Innovation (acquired 2018). All run the MiOS "Luup" stack and expose a
vendor-documented, unauthenticated-by-default local HTTP API — the reference
example of a local-first hub.

## Local API (Luup Requests) — confirmed, vendor-documented
- Port **3480/HTTP**, no authentication on the LAN by default.
- `GET /data_request?id=user_data` — full JSON dump of devices, scenes, rooms.
- `GET /data_request?id=lu_action&DeviceNum=<n>&serviceId=urn:upnp-org:serviceId:SwitchPower1&action=SetTarget&newTargetValue=1`
  — actuate any device (serviceId/action are UPnP-standard).
- `GET /data_request?id=action&serviceId=urn:micasaverde-com:serviceId:HomeAutomationGateway1&action=RunScene&SceneNum=<n>` — run scene.
- `id=sdata` — compact status dump; `id=variableget&DeviceNum=<n>&serviceId=...&Variable=...` — read state.
- Sources: [wiki.mios.com Luup Requests](https://wiki.mios.com/index.php/Luup_Requests)
  (2017) — "everything you can do locally with Vera on port 3480";
  [support.getvera.com Plugin Development](https://support.getvera.com/hc/en-us/articles/360021950733-Plugin-Development) (2019).
- Community stacks: openLuup (pure-Lua emulation of the whole Luup env),
  Home Assistant `vera` integration (local HTTP), ALTUI UI.

## Discovery
Hub announces via UPnP/SSDP on the LAN; IP also resolvable via DHCP scan.
No cloud needed to find or control it.

## Cloud status (checked 2026-08-07)
Ezlo Innovation is alive: support.ezlo.com updated 2024-02, community.ezlo.com
active through 2025. Ezlo has been migrating *cloud* features (remote access,
some integrations) toward paid subscriptions (smarthome.community 2020;
community.ezlo.com subscription thread 2025). **None of this touches port
3480**: the local API works with WAN unplugged and no account. Even if Ezlo
dies, these hubs keep working locally; openLuup can absorb plugins.

## APK
Not needed — API is vendor-documented. VeraMobile app (`com.vera.mobile...`)
only matters for provisioning/cloud. Not fetched.

## One-time cloud steps
None for control. Initial hub setup can be done fully locally via the web UI
on port 80 (same box). MiOS account only enables remote relay.

## Rating
**Confirmed** — vendor-documented API, multiple independent implementations.
