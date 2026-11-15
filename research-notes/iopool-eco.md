# iopool EcO Smart Pool/Spa Monitor — Research Notes

## What it is
Compact floating/drop-in water monitor (temperature, pH, ORP/disinfectant;
salt-compatible variant exists). Belgian startup iopool. **BLE-only by design**:
the probe talks BLE to the phone within ~15 m; an optional "Connect" BLE→Wi-Fi
gateway (or an old phone) bridges to the internet. No subscription — 100% of app
features free (per vendor FAQ).

## Company status (checked 2026-08-04): ALIVE, but at-risk profile
- iopool.com is current (product pages updated 2026-04), still selling EcO Start
  and the Connect gateway; latest app version 2.43.6.
- However: small startup, sealed probe with ~2-year sensor life and a paid
  replacement model ($/€99–109), account-based app with AWS Cognito + Apollo
  GraphQL backend, and the pHin precedent (competitor acquired and killed by
  Hayward in the same niche). Classify as **cloud-at-risk hypothesis, not
  abandoned**. If the cloud dies, raw local BLE readings are the fallback —
  which is exactly what this repo documents.

## APK Provenance
- **Package**: `com.iopool`, version 2.43.6 (latest on APKPure)
- **Source**: apkeep, `-d apk-pure` → bare APK
- **APK SHA-256**: `5c61c0eacd9ee8dff9408dd95ba07c93dfb6f0d00e8bbe3cddd8da48f143ee43`
- **App framework**: React Native (Hermes bytecode bundle, 8.7 MB),
  `react-native-ble-manager` (it/innove), AWS Cognito auth, Apollo GraphQL,
  Sentry, Branch. Static analysis is harder than a native app — JS is compiled
  Hermes bytecode; UUIDs recoverable from the string table only.

## BLE details recovered (bundle string table)
Custom 128-bit UUIDs on base `....-f0a2-9b06-0c59-1bc4763b5c00`:

| UUID prefix | Likely role |
|-------------|-------------|
| `f3a00001`–`f3a00011` (seen: 01, 02, 08, 09, 0a, 11) | EcO probe service + characteristics (measurements, config, DFU?) |
| `f4000001`–`f4000003` | Secondary service/characteristics |
| `f4100001`, `f4100010`, `f4100011` | Third group (possibly Connect gateway or newer probe revision) |

Notably the bundle also contains pHin's UUIDs (`3206152C-76FD-...`,
`0000fe63-...`) — iopool added post-shutdown support for reading orphaned pHin
hardware over BLE (see phin-pool-monitor note).

## Prior community work
- [mguyard/hass-iopool](https://github.com/mguyard/hass-iopool) — Home Assistant
  integration, but it polls the **iopool cloud API**, not BLE. Confirms the API
  is read-only (no device control commands exist at all — the probe is
  measurement-only).
- No public BLE-protocol RE of the EcO found as of 2026-08-04.

## Local feasibility verdict
**Plausible but unproven (medium-hard).** The probe is BLE-native and the app
shows live readings when in range, so a local path exists by design. Unknowns:
whether reading requires an app account/pairing handshake, whether measurements
are sent as notifications vs. adverts, and whether the recommendation engine is
cloud-only (it is — but raw pH/ORP/temp are what matter). Needs an HCI snoop of
an app↔probe session, or decompilation of the Hermes bundle (hermes-dec /
hbctool) to extract the GATT flow.

## What needs cloud
- Account creation, pool profile, dosing recommendations, history sync,
  multi-user sharing, in-app chemical store.
- Initial probe activation may require the app/account — flag as open question;
  check whether probe advertises/connects without prior cloud registration.

## Open questions
- Activation flow: does a never-registered EcO work with a third-party BLE client?
- Which `f3a0xxxx` characteristics carry pH/ORP/temp, and their encoding.
- Role of `f400xxxx`/`f410xxxx` groups (Connect gateway vs. probe revision).
- iopool company financials (Belgian registry) for a firmer at-risk rating.

## Safety class
LOW — measurement-only device, no actuators; advisory water chemistry.
