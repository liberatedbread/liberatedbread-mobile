# Decent Espresso DE1 — Research Notes

## What it is
Decent Espresso (Hong Kong, company ACTIVE) DE1/DE1+/DE1PRO/DE1XXL — prosumer
espresso machines (~US$3.5–4.5k) whose front panel is an Android tablet
running the vendor's **open-source** app (de1app, Tcl/Androwish,
github.com/decentespresso/de1app). Control is local by design: tablet talks
to the machine over BLE; cloud is used only for optional profile sharing and
the "visualizer" shot-upload service.

## Local feasibility — confirmed, vendor-supported
Three documented local interfaces:

1. **BLE GATT (tablet ↔ machine)** — the native control channel. GATT layout
   is defined in the open-source de1app; community BLE libraries exist. No
   pairing secret; no account.
2. **Local HTTP/REST from the machine's tablet** — de1app plugin ecosystem:
   - built-in web server plugin (de1app) serves status/control pages on the
     LAN;
   - third-party `decent-advanced-rest-api` plugin
     (github.com/randomcoffeesnob/decent-advanced-rest-api): REST on port
     8888 (configurable) — machine state, shot control, profiles,
     settings. Documented with an open API surface.
3. **Official "Streamline" web UI** (developer preview, decentespresso.com
   blog 2026-02): the machine hosts a WebSocket interface to the DE1 and
   serves the HTML/JS UI over HTTP — vendor-shipped LAN API.

Company actively ships app updates (v1.37 stable, 2025-03) and the machine
works fully offline; internet is never required for brewing.

## APK
Not needed. The control app source is published by the vendor; the tablet
image is distributed through the machine's own update mechanism. No
cloud account is involved in any control path.

## What needs cloud
Nothing for control. Optional: visualizer.coffee shot sync, profile
download from the community repository, firmware/app updates (can also be
sideloaded).

## Open questions
1. BLE GATT UUID table + write/notify framing is in de1app source but not
   transcribed into a standalone spec — spec-writing opportunity (repo's
   own device-spec could fix this).
2. Streamline WebSocket message schema (vendor-preview, 2026) — document
   once stable.
3. REST plugin version compat across de1app 1.3x releases.

## Safety
Pressure/boiler appliance (9 bar, 96 °C water). Physical flow paddle +
machine firmware enforce limits; a LAN client mostly starts/stops shots and
edits profiles — low incremental risk, but keep "stop shot" prominent and
respect machine-side steam-boiler interlocks.
