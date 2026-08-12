# Roborock (newer, non-miio) — Local API Research Notes

## What it is
Roborock vacuums from the S7 MaxV generation onward (S7 MaxV/MaxV Ultra,
S8 line, Q5/Q7/Q8/Q Revo series, and later) no longer speak classic miio
LAN. They use a newer Roborock-specific local protocol, reverse-engineered
in python-roborock and used by the Home Assistant core `roborock`
integration (iot_class: local_polling).

## Local protocol
- Discovery/control traffic on UDP port 58867 ("L01" protocol); HA docs
  explicitly note the firewall must allow HA → vacuum on 58867
  (home-assistant.io/integrations/roborock, verified 2026-08-07).
- Encrypted with per-device local keys (AES; key schedule differs from
  miio). Versioned protocol ("A01"…"L01" message families) with
  session/nonce negotiation; python-roborock is the reference.
- After setup, control is LAN-local: users run the integration across
  VLANs with only port 58867 open (HA community, 2025-01). Some builds fall
  back to cloud when the local connect fails (HA issue #151913) — so the
  local path is real but not enforced; firewall the WAN to force it.

## What needs cloud — the honest caveat
- One-time: integration/app setup authenticates with a Roborock account
  (email one-time-code login) to fetch device local keys from the Roborock
  cloud. There is no known account-free key extraction for these models.
- Rooting newer Roborocks is mostly not possible (Valetudo supports only up
  to S7 / Q7 Max — see valetudo note), so the cloud-keyed local API is the
  only local path for S7 MaxV+.

## APK
- Roborock app `com.roborock.smart` — not fetched in this pass (protocol
  already covered by python-roborock; APK RE only needed if key derivation
  changes). apkeep fetchability unverified.

## Open questions
1. Do keys rotate on re-provisioning / app re-login? (affects offline
   longevity of a blocked-WAN install)
2. Exact message-family versioning per model (python-roborock `protocols/`
   is the spec source).
3. Whether the robot keeps serving 58867 indefinitely with WAN blocked
   (anecdotal reports say yes; some integrations silently fall back to
   cloud on failure — spec should document detection of that fallback).
