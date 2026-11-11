# Target: FOREO Peach 2 (IPL)

## Target metadata

- target_id: foreo-peach-2
- app package_id(s): com.foreo.foreoapp (FOREO For You 4.4.1/559 and 4.2.0 comparison)
- device class: IPL hair removal (BLE)
- transport(s): BLE
- local-only viability: **high for ordinary control; locked activation and direct Pro
  acceptance remain unverified**

## Evidence now held

- Static analysis: MAC-derived activation, security handshake, old/new and Duo command
  paths, exact model-specific scan names, and subscription/test-device Pro gating.
- 2026-11-07 Android HCI snoop: two stock-app connections to an already-active PEACH2
  running `PEACH2 F.REV.K`, SHA-256
  `b301ad5b7d29608989238cc05945e6f12b428adb5e3dd529771dd888508f5021`.
- Sanitized analysis: 27 writes/responses, 210 reads/responses and 517 notifications,
  with no addresses, serials or raw security payload retained.
- Comparison app 4.2.0: matching security, subscription and Basic/Pro implementations;
  JADX reported 69 errors elsewhere in the bundle, so only matching paths are used.

The capture confirms FFF0 containing FFF1/0A10/0A20, the MAC-derived security write,
0A20 state 01, serial read from 0A02, intensity 3/5, seven Basic writes, automatic fan
and seven-byte 0AC4 cooling profiles. No pairing, MTU request, locked activation, Pro
write or OTA occurred. The spec remains `untested` + `capture-verified`.

## New protocol findings

- App-configured exact names are `PEACH2`, `PEACH2GO`, `PEACH2Duo` and `PEACH2ProMAX`;
  fuzzy matching is disabled and the scan timeout is 30 seconds. Spaced/trademark forms
  remain aliases from earlier research.
- The app also derives activation state from the advertisement. Its exact value in this
  capture is undecoded.
- Security access is connection setup, not a Pro token: after its ATT Write Response,
  the app waits 500 ms and validates no challenge response.
- PEACH2/GO/Pro Max skip the pre-connect device-info API lookup; account registration is
  a separate later step, not proven unnecessary by that exception.
- 0A18/0A19 are body/head NTC, 0A0C is accelerometer input and 0A0D is vibrator setting.
  Units and value conversions remain unknown.
- Pro's confirmed gate is in the app before writing. Active subscription state is
  required normally; `testing == 1` is a separate exception. Direct firmware acceptance
  of Pro is unknown. Duo uses repeated 0AA2 mode bytes, not 0AD0.

## Important corrections retained

- 0A20 is not a stand-in service; it and 0A10 are under FFF0.
- Serial is read from 0A02 on this firmware. 0A05 belongs to a separate 0x181c service.
- 0A30, 0A07, Battery Service 0x180f, TI OAD and D0FF were absent from normal-mode
  discovery. Do not require 0A30 during setup.
- 0A08 is read + notify, not a verified OTA-trigger write. Do not write it.
- New cooling writes are `0a c4` plus seven bytes; query with `0b c4 00 07`.

The authoritative spec is `device-specs/devices/foreo-peach-2.yaml`.

## Guardrails

IPL can injure skin and eyes. Reproduce only unlock/settings supported by the stock app;
never defeat skin-contact or eye-safety interlocks. No remote-fire command was found,
but that is a capture-limited negative result, not proof of absence. Real unit MAC,
serial and activation values are not committed.

## Remaining experiments

1. Factory-locked first-run capture: advertisement activation bit, 0A20 locked value,
   activation write and persistence; map registration-server behavior after the local
   scan exception.
2. Pro-mode write and old-dialect/Duo behavior; 0A30 on firmware that exposes it.
3. Decode cooling-profile fields, NTC/accelerometer/vibrator values and 0AB1.
4. Establish a safe OTA entry/transfer/recovery path; do not probe 0A08 as a trigger.
5. Replacement-client replay from the YAML alone.

## References

- FOREO PEACH 2 manual: https://www.foreo.com/manuals/peach-2
- FOREO For You: https://play.google.com/store/apps/details?id=com.foreo.foreoapp
- Analysis APK SHA-256: `90a4ec8f5c22c1085d1500f6bf1954c28edcd81531f0eed94bf8a13aa494ae79`
- Comparison bundle SHA-256: `304f62e696975c580248dd3c1d63034f1e66a0177f8d4498dc6777144b4fd2a5`
