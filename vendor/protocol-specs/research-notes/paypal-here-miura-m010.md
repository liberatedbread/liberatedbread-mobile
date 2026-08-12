# PayPal Here / Miura M010 — Research Notes

Magstripe + EMV chip/contactless mPOS reader sold as **PayPal Here** (US) and
**iZettle/Zettle Reader** (EU); same Miura Systems M010 hardware. Bluetooth
Classic SPP. **Payment service dead/migrated; local pairing works but useful
local function is minimal — documented for completeness, honest rating: LOW value.**

## Abandonment / cloud status
- PayPal migrated PayPal Here merchants to Zettle in 2021
  ([American Banker, 2021-07](https://www.americanbanker.com/payments/news/zettle-in-paypal-adapts-its-european-card-reader-for-u-s-market)).
- By early 2023 PayPal Here acceptance was dead: TfL removed approval for PayPal
  card devices since "it is no longer possible to accept 'PayPal Here'"
  ([TfL OnRoute, Spring 2023, p. PDF](https://content.tfl.gov.uk/onroute-spring-2023.pdf)).
- Zettle itself retired legacy readers: "By the end of May 2021, we will retire
  the Card Reader Pro & Pro Contactless"
  ([Zettle help: Discontinued card readers](https://www.zettle.com/gb/help/articles/2980873-discontinued-card-readers), accessed 2026-08).
- PayPal Here app is delisted from Play (survives on APK mirrors — see below).

## Hardware / transport
- Miura M010: ARM9 + Linux (MSCLE), magstripe (3-track), EMV L1/L2 contact +
  contactless, PCI PTS certified with SRED/DUKPT
  ([HIPS spec sheet](https://hips.com/ch/terminals_m010),
  [Bluefin Decryptx docs](https://developers.bluefin.com/decryptx/docs/miura-shuttle)).
- Interfaces: **Bluetooth (Classic SPP)**, USB serial, TCP/IP. Pairs in host OS
  Bluetooth settings; advertises as `Miura<serial6>`
  ([Lightspeed pairing guide](https://retail-support.lightspeedhq.com/hc/en-us/articles/229131308-Pairing-the-Miura-M010-with-Zettle)).
- Protocol is identical across transports; Miura markets "Open Protocols"
  (integrator-documented MPI command/response frames) — but integrator docs are
  NDA-gated; no public RE found.

## APK Provenance
- **Package**: `com.paypal.here` ("PayPal Here")
- **Source**: apkeep, apk-pure — downloaded successfully
- **Version fetched**: latest mirror (APKPure lists 2.6.1 .. 4.0.7)
- **APK SHA-256**: `5c7699c4a036eca7e5c348993fe07678d236133df53efaed3a92a269d2b7620b`
- **Static pass**: not performed (68 MB hybrid app; triage budget) — candidate
  for follow-up to extract Miura framing constants.

## Feasibility — honest verdict
- **Pairing + socket open: confirmed plausible** (standard SPP pairing flow).
- **Device-management commands** (battery, firmware version, status): likely
  reachable over SPP with the MPI frame format; needs RE or leaked integrator docs.
- **Payments: impossible locally.** EMV keys/DUKPT are injected per-acquirer and
  transactions require a processor backend. The card-data path is encrypted by
  design (SRED). This device cannot be "liberated" into a useful payment tool.
- Value to repo: documents a prominent dead-cloud reader and its SPP transport;
  realistic reuse is as a battery/serial/BLE-vs-classic development terminal only.

## Open questions
- MPI frame sync/length/CRC layout (extractable from `com.paypal.here` DEX —
  Miura SDK classes ship in the app).
- Whether unconfigured/factory M010 units accept any command without
  acquirer key injection.
