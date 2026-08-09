# Nura Nuraphone (and NuraLoop / NuraTrue family) — Research Notes

Date researched: 2026-08-03. Researcher: BT-Classic audio swarm.

## Verdict
**CONFIRMED viable with a one-time cloud caveat.** Qualcomm GAIA protocol over
Bluetooth Classic RFCOMM (standard SPP UUID, channel 1), encrypted with a
per-device 16-byte AES key. Three independent open-source clients exist and the
official APK decompiles cleanly. Local control is fully offline **once the
device key is known**; recovering the key needs Nura's backend (still up as of
mid-2026 per opennura/jura docs) OR a key read from a previously-paired phone.

## Cloud / company status
- Nura (Melbourne) **acquired by Denon (Masimo) April 2023; Nura-branded
  products discontinued shortly after** ([Wikipedia: Nura (company)](https://en.wikipedia.org/wiki/Nura_(company))).
  NuraNow subscription program ended. Company defunct 2023.
- Official app `com.nuraphone.android` still listed on Play (v4.5.4 observed
  2026), but is a dead product's app — expect delisting. Nura backend
  (key provisioning, account, hearing-profile sync) is at-risk; opennura and
  jura docs both warn "back up your key; if the backend dies an existing key
  still works but no new key can be recovered".
- Hearing-profile *creation* (otoacoustic measurement) runs on-device via the
  app; profiles are stored on the headphone and usable offline.

## Companion app / APK provenance
- **Package**: `com.nuraphone.android` ("nura")
- **Version**: 4.5.4 (versionCode 1410), XAPK
- **Source**: apkeep, apk-pure
- **XAPK SHA-256**: `cb520a2bfa6262f2c55565f294ce74ef2ca13037540e9d11a5b8d01cc1d33975`
- **Decompiled**: jadx → `$REPO/workspace/static/nuraphone/` (Kotlin, readable;
  Flutter UI on top of a native `com.nuraphone.android` core)

## Transport (from static analysis + community)
- Bluetooth Classic **SPP/RFCOMM, standard SPP UUID `00001101-0000-1000-8000-00805F9B34FB`**,
  insecure socket (`bluetooth/BluetoothCommunicator.java`). Community reports
  GAIA service on **RFCOMM channel 1** (opennura). iOS uses BLE GATT instead.
- Quirk (both opennura + jura document this): the headphone "serves the wrong
  Bluetooth channel while streaming audio" — drop the A2DP link first, open the
  control channel, then resume audio.
- Device classes in APK: Nuraphone, NuraLoop, NuraTrue(-Pro), NuraSport, NuraLite
  (`bluetooth/*Device.java`).

## Protocol
- **Qualcomm GAIA framing** (`commands/GAIACommand.java`): SOF byte, version,
  flags, payload; command ids in `commands/GAIACommandID.java`; responses in
  `GAIAResponse.java`. GAIA core itself is well documented by open-source
  implementations (see qualcomm-gaia-ecosystem note).
- **Crypto layer** (`crypto/NativeWrapper.java`, native lib): authenticated
  AES encrypt/decrypt, `cryptoInit(key)`, challenge-response auth, nonce/counter
  management. All control commands are encrypted with the per-device key —
  this matches the community RE exactly.
- Controls mapped by community: ANC / Social (passthrough) / off, immersion
  level (-2..+4), personalised vs neutral sound, profile switch/rename/compare,
  touch-button remap, battery/state monitoring.

## Prior community reverse engineering (strong)
- [CallumCarmicheal/Nura-Windows](https://github.com/CallumCarmicheal/Nura-Windows) —
  deepest RE: full NuraLib SDK (auth, RFCOMM encrypted session, key provisioning),
  behavior "aligned with the decompiled Android app". Apache-2.0.
- [jamesy0ung/opennura](https://github.com/jamesy0ung/opennura) — macOS/iOS client;
  Nuraphone primary, NuraLoop/NuraTrue Pro/Denon PerL Pro partial. GPLv3.
- [RohitJacob/jura_ai](https://github.com/RohitJacob/jura_ai) — macOS fork adding
  on-Mac key recovery via Nura backend relay. GPLv3.

## One-time cloud dependency (explicit)
First-time setup needs the device key, obtained either (a) from Nura's backend
via account email + verification code (still working per community docs, could
die any day), or (b) manually extracted from a phone that was previously paired
with the official app (keychain/SharedPrefs). **After that: fully local.**
Buying one second-hand today without backend access = verify backend status first.

## Safety
- safety_class: LOW with caveat — both community projects warn about possible
  sudden loud output while experimenting; advise wearing headphones with in-ear
  tips out during first connect/testing.

## Next steps
1. Spec GAIA-over-SPP framing + Nura command IDs from APK constants + Nura-Windows.
2. Document key-recovery flow (backend relay) and offline fallback extraction.
3. Note RFCOMM-channel-1 / drop-A2DP-first quirk in any spec.
