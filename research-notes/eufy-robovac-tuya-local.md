# Eufy RoboVac (Tuya-based WiFi models) — Research Notes

## What it is
Anker/Eufy RoboVac WiFi models: 15C MAX (T2128), G10/G30 Hybrid, G32,
X8/X8 Hybrid, L35/LR30 Hybrid and similar. Internally these are Tuya
platform devices (Tuya radio module + Tuya protocol), but bound to the
EufyHome cloud rather than the Tuya cloud.

## Local protocol (community-confirmed)
- Tuya LAN protocol: TCP 6668 (protocol 3.3, AES-128-ECB payloads) /
  6667 (3.1). Commands are Tuya DPS (data-point) reads/writes — the
  RoboVac DPS map (power, mode, fan speed, direction pad, battery, error)
  is documented in community integrations.
- Reference implementations: CodeFoodPixels/robovac (HACS, actively used),
  jeff-hamm/python-eufy-robovac, whizzy.org writeup of full local X8
  control in HA (2026-05-16). LocalTuya can also drive them once DPS are
  known.

## What needs cloud — the honest caveat
- The 16-byte Tuya "local key" + device ID are issued by the Eufy cloud at
  pairing. Every current setup flow (CodeFoodPixels config flow, older
  eufy_vacuum YAML) asks for Eufy account credentials once to fetch them,
  then talks LAN-only (WAN blockable afterwards).
- **No account-free extraction is known.** Unlike Tuya-proper devices there
  is no iot.tuya.com developer-console trick; the key lives in the Eufy
  account. Old trick of reading keys from an old app version's local DB
  (eufy app 2.3.2 era, HA forums 2020) is long dead.
- So: confirmed local control, but with a mandatory one-time cloud step.
- Newer flagship (X10 Pro Omni and up): community reports indicate these
  moved off the plain-Tuya local scheme; treat as unsupported until proven
  (HA community thread, 2025-04).

## APK
- **Package**: `com.eufylife.smarthome` (EufyHome) — XAPK fetched via
  apkeep 2026-08-07: version 3.18.1 (1031), 330 MB.
- XAPK SHA-256: `22c253dfa810b813aa8c06bf1ce138015e26613f2c1f9ae9e84646f8304c1ac9`
- Not decompiled — protocol already documented; APK triage would only be
  needed to chase the X10-era protocol change.

## Open questions
1. Does the local key rotate on re-pairing / app logout? (determines
   offline longevity)
2. X10 Pro Omni / newer: protocol family (still Tuya DPS? new encrypted
   scheme?) — needs capture or APK triage of the fetched 3.18.1.
