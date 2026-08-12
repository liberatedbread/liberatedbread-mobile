# Tailwind iQ3 — Research Notes

## What it is
Tailwind iQ3 (1st gen, 2.0, 2.1) — smart garage/gate controller with
hardwired commercial-grade door sensor, auto-open/close via phone GPS+car
Bluetooth, up to 3 doors per controller. Vendor (Tailwind / gotailwind.com,
Canada) **active** — site reachable 2026-08-07; iQ3 2.0/2.1 (2025–26) add
Security+ 2.0 (yellow learn button) support. 2025-manufacture white-learn-
button openers are MyQ-only per the vendor.

## Local path (confirmed, vendor-supported)
**Official local API**, firmware ≥ 10.10 (rolled out with the HA core
integration, HA 2024.1). Vendor sponsored development of the reference
client [frenck/python-gotailwind](https://github.com/frenck/python-gotailwind)
(verified from source 2026-08-07):

- `POST http://<device-ip>/json` with header `TOKEN: <6-digit local control
  key>`, JSON body describing the request.
- Requests: device status (`status`), door status, `identify`, LED
  brightness, and door operate (`{"data":{"value":{"index":N,"operation":
  "open"|"close"}}}` shape via TailwindDoorOperationRequest).
- Local control key is shown in the Tailwind app (per-device settings) after
  enabling local control.
- HA core integration `tailwind` — iot_class: **local_polling**, zeroconf
  auto-discovery (home-assistant.io/integrations/tailwind). Community
  (Homey, Node-RED) builds on the same local API.

## Cloud dependency — one-time step
Honest answer: the **Tailwind app needs a vendor account** for onboarding,
and the 6-digit local control key is read from the app. After that,
day-to-day control is 100% LAN. There is no documented way to extract the
key without the app; if the Tailwind cloud dies, already-paired
installations keep working locally (key is stored in clients), but new
provisioning would be at risk.

## APK
Not fetched — vendor documents the local API through the sponsored library;
no RE needed. (Tailwind Android app exists on Play if needed later.)

## Rating
**Confirmed** — HA core integration + vendor-sponsored client library.

## Safety
MEDIUM — local API can open/close without presence confirmation; the iQ3's
own "Night Mode" auto-close is on-device. The library respects door
lockout/disabled states.
