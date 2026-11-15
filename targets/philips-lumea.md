# Target: Philips Lumea (IPL) — finding: no device radio in current app

## Target metadata
- target_id: philips-lumea
- app package_id(s): com.philips.platform.lumea (Lumea IPL 6.x analyzed)
- device class: IPL hair removal
- transport(s): NONE in current app (camera/mic + cloud ML); BLE only in
  historical Prestige BRI95x era (app ≤5.x)
- local-only viability: n/a — device is fully standalone and never locked

## Known facts (verified from RE sources)
- VERIFIED (static, app 6.x): zero Bluetooth permissions/GATT usage — the app
  never talks to the device. "Smart features" = phone camera/mic + on-device
  TFLite flash counter.
- VERIFIED (static): SkinAI app features unlock via QR/serial validated
  server-side (anti-counterfeit API); nothing written to device.
- VERIFIED (static): guest mode exists; no feature paywall (Zuora = Try&Buy
  rental display only).
- Details: research-notes/philips-lumea.md

## Next actions (only if a BRI95x Prestige is ever targeted)
- Fetch Lumea app ≤5.x and RE its BLE protocol.

## Status
- Parked: nothing to liberate; device standalone, app optional.
