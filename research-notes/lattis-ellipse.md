# Lattis Ellipse Smart Bike Lock — Research Notes

## What it is
- Solar-charged BLE U-lock with accelerometer (theft/crash detection), capacitive
  touchpad code entry, and app-based lock/unlock/share. Launched 2017 at $200.
- Company (Lattis, fka related to the Skylock crowdfunding era, founded 2013, SF)
  pivoted to B2B bike/scooter-share fleet hardware+software and no longer sells or
  supports the consumer Ellipse.

## Why abandoned / at-risk (dated sources)
- 2017-01: consumer launch coverage ([VentureBeat](https://venturebeat.com/business/lattis-bike-lock-sends-theft-alerts-and-tells-friends-if-you-crash), 2017-01-05).
- 2018-07: [CNET review](https://www.cnet.com/reviews/lattis-ellipse-smart-bike-lock-review-2/) — last consumer-era product coverage.
- 2026-01: [Levy Electric fleet-software guide](https://ride.levyelectric.com/post/starting-an-electric-scooter-fleet-here-are-the-best-options-for-rental-fleet-software-and-apps) lists Lattis purely as a B2B fleet platform; lattis.io sells only fleet solutions (checked 2026-08-04).
- Android app `io.lattis.ellipse` ("Ellipse", "Keyless bike lock…") is delisted from
  Google Play (Play search 2026-08-04 returns nothing); AppBrain showed 1,000+ installs.
  Last version 2.1.15 (versionCode 85). App is only on mirrors (APKPure).

## Local BLE feasibility
Lock/unlock is GATT writes over BLE; no internet needed for an already-provisioned
phone (auth material cached locally in Realm/`KeyCache`). BUT the pairing/auth scheme
uses a **server-signed message** (`signedMessage` handed to `SecurityHandlerV2`), so
first-time provisioning of a new phone almost certainly required the Lattis backend —
with the consumer backend's status unknown, re-pairing may be impossible. Mitigations:
- Physical touchpad code (`BUTTON_LOCK_SEQUENCE` characteristic configures it) works
  with no phone and no cloud — locks never fully brick.
- Existing paired installs keep working offline (cached keys).
- A community rescue path would need RE of the security handshake to self-issue
  signed messages (or key extraction from a paired phone / HCI snoop during pairing).

## APK Provenance
- **Package**: `io.lattis.ellipse` — version 2.1.15 (versionCode 85)
- **Source**: apkeep, apk-pure mirror (Play-delisted), 2026-08-04
- **SHA-256**: `8a5397782824166a5ebf74c14b44ea31935710aa85db6ff883af509336549dff`
- Decompiled with jadx to `workspace/static/lattis-ellipse/`; clean Java
  (`io.lattis.ellipse.sdk` + `com.lattis.ellipse` app), Realm DB, not obfuscated.

## BLE GATT (from `io/lattis/ellipse/sdk/Ellipse.java`)
Base UUID pattern `d3995xxx-fa57-11e4-ae59-0002a5d5c51b` (Dialog DA145x-era numbering).

| Service | Characteristics |
|---|---|
| Security `d3995e00` (advertised; used as scan filter) | SIGNED_MESSAGE `e01`, PUBLIC_KEY `e02`, CHALLENGE_KEY `e03`, CHALLENGE_DATA `e04`, STATE `e05` |
| Device `d3995e40` | LED `e41`, LOCK `e42`, INFO `e43`, MAGNETOMETER `e44`, CONNECTION `e45`, ACCELEROMETER `e46` |
| Configuration `d3995e80` | RESET `e81`, LOCK_ADJUST `e82`, SERIAL_NUMBER `e83`, BUTTON_LOCK_SEQUENCE `e84` |
| Firmware `d3995d00` | CODE_VERSION `d01`, WRITE_DATA `d02`, STATUS `d03`, DOWNLOAD_DONE `d04` |

- Security handshake (from `SecurityHandlerV2.java`): phone writes CHALLENGE_KEY
  derived from `userId` after reading PUBLIC_KEY, writes SIGNED_MESSAGE, then reads
  CHALLENGE_DATA; failure state `SECURITY_STATE_INVALID_ACCESS_DENIED` → disconnect.
- `Encryption.java`: SHA-256 + AES/ECB/PKCS5Padding helpers.
- `Configuration.WRITE_RESET_*`: 0xBC shipping, 0xBD factory, 0xBE development modes.

## What needs cloud
- Account creation, lock registration/pairing (server-signed auth messages), sharing
  access with other users, crash-alert SMS to contacts. Theft alerts are push
  notifications via app (needs app running; cloud push for remote alerts).
- Lock/unlock/status/touchpad code: local BLE only, once provisioned.

## Open questions
- Is the Lattis consumer auth backend still up? (An old install with cached keys can
  be checked with an HCI snoop; if the lock accepts cached SIGNED_MESSAGE offline,
  rescue tooling only needs key export.)
- Can BUTTON_LOCK_SEQUENCE be set via raw GATT without prior auth? If yes, that alone
  is a viable local re-provisioning path.
- Prior community RE: none found (no GitHub drivers/HA integration located).
- safety_class: LOW (property-security device, no injury vector; mechanical touchpad
  fallback limits lockout risk).
