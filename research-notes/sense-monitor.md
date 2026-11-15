# Sense Home Energy Monitor — DUD (cloud-only)

## Verdict
**Rejected for local control.** Verified 2026-08-07.

## Evidence
- The Sense monitor (Sense Labs; also the Schneider Electric "Wiser Energy"
  rebadge) communicates only with Sense's cloud over TLS. There is no local
  API, no documented LAN protocol, and no offline mode — community consensus
  over years of HA forum threads (e.g. "Local only (non-cloud) home energy
  monitor options", 2019; "obtain and store data from a Sense ... when
  internet is down", 2024-12: answer is cloud sync, not local access).
- The Home Assistant `sense` integration and the underlying `sense_energy`
  library are `cloud_polling` — they hit Sense's servers with your account.
- Device disaggregation happens server-side; even raw waveforms are not
  exposed locally.
- MITM path: traffic is TLS to vendor/AWS endpoints; per repo rules
  MITM-only paths are out of scope, and no working pinned-cert bypass is
  documented.

## What would change this
Only a firmware-level jailbreak/reflash (none published as of 2026-08) or a
vendor-provided local API. Company is active and well-funded (Series D 2024),
so a rescue angle is unlikely to emerge organically.

## Recommendation
Do not spend APK/RE time here. Local-only buyers should use IoTaWatt, Shelly
EM/3EM, eGauge, or Brultech (all covered in sibling notes).
