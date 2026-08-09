# Ezlo Hubs (Ezlo Plus / Secure / Atom / PlugHub) — Research Notes

## What it is
Successor platform to Vera from Ezlo Innovation. Ezlo Plus and Ezlo Secure
(Z-Wave 700 + Zigbee), Ezlo Atom / PlugHub (ESP32-based micro-hubs). Runs
"Ezlo Linux firmware" with a different API than Vera's Luup Requests.

## Local API — confirmed (community-documented, vendor-tolerated)
- Local HTTP(S) server on **port 17000** on the hub itself.
- API is the same JSON "hub.*" method family as the cloud API
  (`hub.items.list`, `hub.item.value.set`, `hub.scenes.run`, `hub.info.get`,
  ...), callable via HTTPS POST with a token, explorable via
  [apitool.ezlo.com](https://apitool.ezlo.com).
- **Auth can be fully disabled for LAN use**: settings
  `offlineAnonymousAccess` / `offlineInsecureAccess` — after that, plain
  local HTTPS calls work with no token at all.
- Sources: [CW's Idiot Guide to Ezlo platform HTTP API](https://community.ezlo.com/t/cws-idiot-guide-to-ezlo-platform-http-api-commands-aka-luup-requests/215106)
  (2020-09, auth-off update confirmed 2024-08 in
  [Ezlo REST API thread](https://community.ezlo.com/t/ezlo-rest-api-documentation-etc/217675?page=2));
  [Python curl-config script thread](https://community.ezlo.com/t/python-script-for-ezlo-fw-http-api-curl-commands/214852) (2023);
  [support.ezlo.com Luup Requests guide](https://support.ezlo.com/hc/en-us/articles/8165438132252-How-to-Use-HTTP-API-Commands-AKA-Luup-Requests) (2024-02).
- Also exposes a WebSocket variant of the same API on the hub.

## Cloud dependency
- Provisioning the hub and the *default* authenticated mode need an Ezlo
  cloud account (token is derived from cloud credentials).
- Workaround: enable anonymous/insecure local access once (needs account at
  setup time), then operation is cloud-free; keep port 17000 off the WAN.

## Company status (checked 2026-08-07)
Ezlo alive but shaky: support docs updated 2024, community active 2025 with
threads about subscription paywalls and server-side outages. The local API
with auth disabled is the hedge.

## APK
Not needed — API reachable by curl once auth is off. Not fetched.

## Rating
**Confirmed** — working community usage (MSR, Postman, curl) documented
2020–2024; not a formal vendor spec, endpoints reconstructed from
apitool.ezlo.com.
