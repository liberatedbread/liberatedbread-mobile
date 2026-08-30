# Home IPL + Bluetooth — market survey (2026-08-29)

Which home IPL hair-removal devices have an app with device connectivity, and
what does the app actually control? Compiled from APK static analysis (notes
linked) and desk research. Focus: does the hardware depend on the app/cloud?

| Device | App (package) | Radio | Device works standalone? | Lock/activation | Paywall | Note |
|---|---|---|---|---|---|---|
| FOREO Peach 2 family | FOREO For You (`com.foreo.foreoapp`) | BLE | **No — ships locked** | BLE unlock, keyless MAC-derived; **offline-reproducible** | Pro mode subscription, **app-side enforcement only** | research-notes/foreo-peach-2.md |
| Braun Silk-expert Pro 5 / Pro 7 | Braun IPL (`com.pg.grooming.braun.ipl`) | BLE (+Wi-Fi some SKUs) | **Yes** | none | none | research-notes/braun-silk-expert-pro5.md |
| Silk'n Infinity / Silk'n 7 | Hair Removal – Silk'n (`com.ewavemobile.silkn`) | BLE | **Yes** | opt-in app lock, 2-byte clear | none | research-notes/silkn-infinity.md |
| Philips Lumea 9000/9900 | Philips Lumea IPL (`com.philips.platform.lumea`) | **none** (camera/mic + cloud ML) | **Yes** | none (SkinAI *app* features gated by server-validated serial) | none (Zuora = rental display) | research-notes/philips-lumea.md |
| Philips Lumea Prestige BRI95x | Lumea app ≤5.x | BLE (historical) | presumably yes | TBD | TBD | dropped from current app; needs old-APK dig if ever targeted |
| SmoothSkin Pure / Pure Fit (CyDen) | **none exists** | — | yes | — | — | negative finding, no app to RE |
| Ulike (Air series) | none (web treatment tracker only) | — | yes | — | — | negative finding |
| JOVS (Venus Pro etc.) | none found | — | yes | — | — | negative finding |
| CosBeauty Joy (HK/CN market) | COSBEAUTY app (package TBD) | likely BLE (app scheduling) | unknown | unknown | unknown | package not located; CN/HK market |
| Ya-Man (Japan market) | YA-MAN app (Japan-only) | unknown | unknown | unknown | unknown | not pursued, region-locked |
| CurrentBody / Kenzzi / Nood / RoseSkinCo | none | — | yes | — | — | negative findings |

## Takeaways

- Only **FOREO** ships a device that is non-functional without an app action —
  and its unlock is offline-reproducible (see the Peach 2 note). FOREO is also
  the only vendor with a feature paywall (Pro mode subscription), which is
  enforced app-side only.
- **Braun** and **Silk'n** are pure telemetry/coaching links with unauthenticated
  BLE; **Philips** removed the radio entirely.
- For the "abandoned hardware keeps working" mission, FOREO Peach 2 is the
  high-value target (real lock + real paywall, both soft); Braun/Silk'n
  replacement apps are nice-to-have telemetry readers.
