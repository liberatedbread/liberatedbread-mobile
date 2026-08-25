# EmazingLights Spectra — target spec starter

## Target metadata
- target_id: emazinglights-spectra
- app package_id(s): com.emazinglights (Android, v1.8 / versionCode 37, **delisted from
  Google Play**; targetSdk 28, minSdk 18)
- device class: programmable LED glove set (gloves + BLE "Smart Hub" relay)
- transport(s): Bluetooth (BLE) phone→hub; proprietary 2.4 GHz hub→gloves (not
  phone-reachable, out of scope)
- local-only viability: **high** — all control is local BLE with no bonding, no
  encryption, no authentication; the app contains no crypto at all. The cloud API
  (gloving.com) only covers community features (glove-set sharing) and is not
  needed for control.

## Architecture: the hub is the target
The phone never talks to the gloves. It talks over BLE to the Spectra **Smart
Hub** (OTA device type "PhotoHub"), which relays to the gloves over a
proprietary 2.4 GHz link. A replacement client only implements the hub's BLE
interface. The hub is a Qualcomm CSR101x-family part — its OTA service uses the
documented Qualcomm CSR (µEnergy) firmware-update UUID family
(`…-8506-11E3-BAA7-0800200C9A66`).

## Orphan evidence
- App delisted from Google Play.
- OTA manifest `http://www.facemeltcrew.com/ios/testmanifest.json` — the only
  backend URL the firmware updater knows — is **dead**: the domain no longer
  resolves (verified 2026-08-25, curl: could not resolve host). No vendor
  firmware image remains obtainable.

## Known facts (static analysis of com.emazinglights v1.8)
- Full details in `device-specs/devices/emazinglights-spectra.yaml`; summary:
- **Discovery**: manufacturer-specific AD data (type 0xFF), not the name.
  hex(company ID) + hex(payload minus last byte) must equal ASCII `LEHUB1`;
  last payload byte must be `0x01` (pairing-mode flag). Company-ID split
  ambiguous: `0x454C`+`HUB1` or `0x004C`+`EHUB1`. Advertised name is
  user-renamable over GATT, display-only.
- **Frame format**: fixed 20-byte frames `[0x55][opcode][index][16B payload,
  zero-padded][XOR checksum over bytes 0..18]`, plain GATT writes, 200 ms pacing
  between frames during uploads.
- **Opcodes**: 0x01 writeModeSettings, 0x02 writeBlockSettings (one per color),
  0x03 changeDisplayMode, 0x04 changeRunMode, 0x05 setPWMColor,
  0x07 flashingPatternSettings (14-byte custom pattern), 0x09 exitPairingMode,
  0x0A syncStarted (1=start/2=end). 0x06 skipped (likely reserved).
- **Upload sequence**: 0x01 → N×0x02 → optional 0x07 → 0x03(1) → 0x04(index 1,
  payload 0,0).
- **Housekeeping service** `0788EAD1-…`: battery (read), firmware version
  (read; hex int, hi=major lo=minor), hub name (read/write; ASCII-hex encoded).
- **OTA**: CSR service + 3 characteristics; CRC32 of 16-byte-padded image,
  12-byte new-image header `[CRC32 LE][length LE][00 10 01 08]`, syncStarted
  bracket, 16-byte block streaming, 10 s stall watchdog.

## Device discovery signals
- Manufacturer data (AD type 0xFF) containing ASCII `LEHUB1` with trailing
  pairing-mode byte (`0x01` = pairing active).
- Command service `f4db6da0-2fcf-d296-a741-42ff6328ef42` / characteristic
  `58511d0a-2cd1-6188-5445-9f98c91be785`.
- Housekeeping service `0788ead1-3899-45ac-0346-094599b058b8`.
- OTA service `8a97f7c0-8506-11e3-baa7-0800200c9a66` (CSR OTA family).

## Threat model + guardrails
- Owned devices only. The hub accepts commands from any central in range while
  its pairing-mode flag is set — no bonding, no auth. Note as a wearer-privacy
  consideration, not an attack surface to tool against.
- The app's community cloud API uses a hardcoded static token over plain HTTP.
  The token is a vendor credential and is deliberately **not** recorded in this
  repo; the API is not needed for control.

## Remaining experiments
1) **Advertisement capture** — resolve the company-ID/payload split of the
   `LEHUB1` manufacturer data (`0x454C`+`HUB1` vs `0x004C`+`EHUB1`) and record
   the full AD structure. Highest value per effort; one nRF Connect scan.
2) **HCI snoop of a full sync** — confirm 200 ms pacing is required (vs
   cosmetic), whether the command characteristic notifies, and whether the hub
   gates mode writes on the 0x09 exitPairingMode handshake.
3) **Extract the built-in flashing-pattern table** — the `flashingPatternCode`
   ↔ pattern mapping lives in the app's bundled local database (seeded default
   data); extract and publish it so replacement apps can offer the classic
   strobe/gap/repeat patterns without trial and error.
4) **Battery characteristic encoding** — one read at a known charge state
   (raw percent vs voltage).
5) **changeDisplayMode / changeRunMode operand semantics** — values observed
   (1; index 1, payload 0,0) but meanings inferred; vary operands on live
   hardware.
6) Confirm gloves cannot be driven hub-less (no evidence they can; assumed no).

## Control surface inventory (replacement app MVP)
- scan for the `LEHUB1` manufacturer-data marker + pairing flag; connect
- set direct RGB color (opcode 0x05)
- mode upload: mode settings → per-color blocks → optional custom flashing
  pattern → display/run (opcodes 0x01/0x02/0x07/0x03/0x04), 200 ms pacing
- read battery and firmware version; rename the hub
- local mode/glove-set storage that survives an app reinstall (the vendor cloud
  did this; it is gone)
- OTA update is documented but moot until a firmware image is recovered — the
  vendor's image host is dead

## References
- ACM TOSN 2023 BLE OTA survey (CSR µEnergy OTA UUID family):
  https://dl.acm.org/doi/fullHtml/10.1145/3579856.3595806
- OTA manifest (dead, orphan evidence): http://www.facemeltcrew.com/ios/testmanifest.json
- Vendor site: https://www.emazinglights.com/
- Community API base (not needed for control; token intentionally not recorded):
  http://gloving.com/app/v2/api.php
