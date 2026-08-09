# Pentair IntelliCenter — Local WebSocket API Research Notes

## What it is
Pentair's current flagship pool/spa outdoor control panel (OCP). Manufacturer
active (Aug 2026). Distinct from ScreenLogic: IntelliCenter exposes its own
local network API on the panel itself — no protocol-adapter brick required.

## Local protocol — JSON over WebSocket, RE'd and in production
Firmware **v3.004+** exposes a JSON WebSocket API on **TCP port 6680** of the
OCP (Ethernet connected, "Web and Mobile Interface" enabled in OCP settings).
Documented by implementation in
[tagyoureit/nodejs-poolController](https://github.com/tagyoureit/nodejs-poolController)
(v10.0, 2026 — new `ocpws` transport, full bidirectional support) and the
Home Assistant custom integrations
[jlvaillant/intellicenter](https://github.com/jlvaillant/intellicenter) (2020)
and [joyfulhouse/intellicenter](https://github.com/joyfulhouse/intellicenter)
(active 2025-11, "local push").

### Discovery
mDNS browse `_http._tcp.local` for instance names of the form
`Pentair -i -n<alias>` (per njsPC docs).

### Protocol shape
JSON request/response with `messageID` correlation:
- `GetParamList` with `objnam:"ALL"` — enumerate full config (circuits,
  bodies, pumps, heaters, schedules, chemistry, valves, covers, security).
- `SetParamList` — writes (circuit toggle, heat mode/setpoint, schedules,
  light commands).
- `RequestParamList` — subscribe; panel pushes live `NotifyList` updates.

### Security caveat
Port 6680 has **no authentication** — any LAN host can read/write the full
object model, including PIN-based PERMIT roles in plaintext (njsPC README
warning). Treat as trusted-LAN-only; never port-forward.

### Older firmware
v1.x/v2.x panels speak a different local WebSocket dialect on **port 6681**
(used by jlvaillant/intellicenter); v3 moved to 6680.

## Cloud dependency
None. Pentair Home cloud is optional; all local functions work with the
Ethernet cable and the documented WS API.

## APK
Not fetched — protocol documented by three independent implementations.

## Rating
**Confirmed** — njsPC 10.0 + two HACS integrations, active maintenance 2025-2026.

## Sources (accessed 2026-08-07)
- github.com/tagyoureit/nodejs-poolController (README "Local Network Comms (IntelliCenter v3)")
- github.com/jlvaillant/intellicenter; github.com/joyfulhouse/intellicenter + pyintellicenter
- community.home-assistant.io/t/integration-pentair-intellicenter-local-push-pool-control/956184 (2025-11-28)
