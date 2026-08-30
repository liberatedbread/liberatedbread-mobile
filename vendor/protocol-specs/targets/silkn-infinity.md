# Target: Silk'n Infinity / Silk'n 7 (IPL)

## Target metadata
- target_id: silkn-infinity
- app package_id(s): com.ewavemobile.silkn (Hair Removal – Silk'n 6.1/38 analyzed)
- device class: IPL hair removal (BLE)
- transport(s): BLE
- local-only viability: high — device standalone; BLE is telemetry + opt-in lock

## Known facts (verified from RE sources)
- VERIFIED (static, app 6.1): primary service `720411AC-ADFE-2015-0820-835742AD3835`;
  chars `12345678-9012-3456-7890-1234567890{11,22,33,44,55}` = treatment info
  (notify, 20B), errors (notify), lock/unlock (rw), device IO (r), color
  measurements (r).
- VERIFIED (static): scan name filter `Infinity` / `SilknV_F` / `Silkn7_App`;
  no bonding, no auth, no paywall.
- VERIFIED (static): app cannot fire flashes or set intensity; only write is
  the lock characteristic (2 bytes: mode 0x30/0x31, state 0x30/0x31).
- Cloud: ws.silknglobal.com REST; account-centric app but hardware unaffected.
- Full details: research-notes/silkn-infinity.md (+ .yaml)

## Threat model + guardrails
- IPL device; firmware interlocks (skin-contact, color sensor) must not be defeated.

## First experiments
1) ./scripts/detect_devices.sh; confirm advertised name + service UUID.
2) HCI snoop: connect + one treatment pulse + lock/unlock cycle.
3) Replacement MVP: subscribe `…9011`/`…9022`, parse counters, clear lock.

## Evidence checklist
- APK: com.ewavemobile.silkn 6.1 (38), sha256 TBD (workspace/apks/apkeep)
- HCI snoop log: TBD

## Spec output (clean-room)
- device-specs/devices/silkn-infinity.yaml — after hardware verification
