# Fermob Lighting (Linkio BLE) lamps — Hoopik, MOOON!, Inouï, Aplô — target spec starter

## Target metadata
- target_id: fermob-linkio-lamps
- app package_id(s): TBD on Android; iOS "Fermob Lighting" is App Store
  id 1456590371 (Fermob, 2020)
- device class: outdoor/indoor portable LED lamps and garlands (Hoopik
  GL1200 confirmed; MOOON! floor lamp confirmed by a second user; Inouï,
  Hoopik H24, Aplô Premium/Moliare and MOOON! desk lamps listed in the app's
  device table but untested)
- transport(s): BLE GATT, phone-direct, no cloud ("Linkio" protocol — the
  name of the BLE stack vendor whose protocol Fermob licenses)
- local-only viability: **high** — the vendor app is local already; one MIT
  HA integration controls two lamp families.

## Known facts (public; HA community 2026-05 → 2026-08)
- Advertisement carries the 128-bit service UUID
  `41c13060-6def-11e5-bcde-0002a5d5c51b`; manufacturer id 7 identifies
  Fermob within the Linkio family.
- Dimmable-white and tunable-white lamps share the handshake and the command
  header; they differ only in payload — one level byte for dimmable, cold-
  and warm-white values for tunable (3000–6000 K on MOOON!).
- A handshake precedes control ("pairing" about 4 s on first connect, about
  1 s on reconnect); a "private mode" with stored keys exists. **The
  handshake is not described in any public source** — it is the open
  question.
- Sources: [HA thread](https://community.home-assistant.io/t/fermob-hoopik-gl1200-new-ble-integration-for-home-assistant-no-hub-no-cloud/1010855)
  (2026-05-18, updated 2026-08-17) · [edouardrosset/ha-fermob](https://github.com/edouardrosset/ha-fermob) (MIT).
  The author and a contributor worked from the vendor app's JavaScript and
  APK — restate, do not copy.
- Linkio sells the same BLE module and protocol to other lighting brands;
  a Linkio-family spec could cover more than Fermob. Scope this first.

## Device discovery signals
- BLE: service UUID above in the advertisement; name pattern not published.
- Wi-Fi: none.

## Threat model + guardrails
- Lamps; low risk. Owned units only. If the "private mode" key is a per-lamp
  secret, treat it like a PIN: placeholder it, never publish a vendor
  default.

## First experiments
1) Read the integration source for the handshake, header and payload bytes.
2) Search for other Linkio-based brands (same service UUID) to size the spec.
3) HCI capture of first pair + reconnect + one brightness write.

## Control surface inventory (replacement app MVP)
- on/off · brightness · colour temperature (tunable models) · battery if
  exposed

## References (URLs only)
- https://community.home-assistant.io/t/fermob-hoopik-gl1200-new-ble-integration-for-home-assistant-no-hub-no-cloud/1010855
- https://github.com/edouardrosset/ha-fermob
- https://apps.apple.com/fr/app/id1456590371
