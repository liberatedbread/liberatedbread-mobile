# Divoom Pixoo / Timebox pixel displays — target spec starter

## Target metadata
- target_id: divoom-pixoo
- app package_id(s): com.divoom.Divoom (Divoom: pixel art editor)
- publisher: Divoom Lab HK International
- device class: pixel-art LED matrix displays — Pixoo-16 / Pixoo-32 / Pixoo-64, Timebox, Ditoo
- transport(s): Wi-Fi LAN (HTTP) on the Pixoo-64 class; BLE on the smaller/older units
- local-only viability: high for the Wi-Fi models — a local HTTP API exists and is widely used
- manufacturer status: **active** (still shipping) — protocol is closed, not abandoned

## Why this target matters
The best-known consumer LED sign that is *not* an unbranded OEM product, and the closest thing
this category has to a de-facto standard. Two APIs exist side by side:

- a **local HTTP API** on the device itself (community-documented at `doc.divoom-gz.com`), and
- an **undocumented cloud API** (`appin.divoom-gz.com`) that the app actually uses for most
  features, including the gallery and several device functions.

The local API is community-maintained and reverse-engineered, not an official product — firmware
updates have changed or temporarily blocked it before. That is exactly the fragility this project
documents against.

Note the different posture from the rest of this repo: Divoom is an active manufacturer, so this
is an interoperability target rather than a rescue. Scope it accordingly.

## Known facts (public + community RE)
- Wi-Fi models accept HTTP POST to `http://<device-ip>/post` with a JSON body containing a
  `Command` field.
- `Draw/SendHttpGif` uploads animation frames; frames must be sent as successive commands rather
  than batched.
- Multiple independent client implementations exist across Python, Rust, TypeScript and Go,
  which makes the local surface well-corroborated.
- The app-facing cloud API is separate and largely undocumented.

## Device discovery signals (to confirm)
- Wi-Fi LAN: device obtains a normal LAN IP; discovery mechanism (mDNS service type? vendor
  broadcast? cloud-assisted only?) is **not yet confirmed** — this is the first thing to pin down,
  since the repo's WiFi device specs are discovery-driven.
- HTTP: `http://<ip>/post`, default port 80
- BLE (smaller/older Timebox-class units): service UUIDs unrecorded here; capture required

## First experiments
1) Put a Pixoo-64 on the LAN and run the repo's WiFi discovery sweep
   (`docs/devices/wifi-discovery.md`) to establish how the device is found without the cloud.
2) Enumerate the local HTTP command set against a live device and record which commands work
   with the phone app fully logged out and the WAN blocked.
3) Identify which app features degrade with no internet — that boundary defines what a
   local-first replacement can actually deliver.
4) For a BLE Timebox/Ditoo: HCI snoop connect → set brightness → upload one image.

## Threat model + guardrails
- Owned devices only.
- Active manufacturer: document the protocol, do not redistribute vendor content libraries or
  gallery assets.
- Do not commit any API keys or cloud credentials recovered from the APK.

## Protocol hypotheses (to validate)
- Local HTTP is a flat JSON command dispatcher with no authentication on the LAN.
- Animation upload is stateful across successive `Draw/SendHttpGif` calls (frame index + total).

## Replacement app / integration MVP
- discover the device on the LAN with no cloud round-trip
- brightness, channel/mode select, power
- push a still image and an animated GIF rendered to the panel size
- work fully offline

## References
- https://play.google.com/store/apps/details?id=com.divoom.Divoom
- https://divoom.com/blogs/app-guide/pixoo-64-api-beginner-guide
- https://github.com/4ch1m/pixoo-rest
- https://github.com/SomethingWithComputers/pixoo
- https://github.com/r12f/divoom
- https://github.com/Grayda/pixoo_api/blob/main/NOTES.md
