# Nest Protect (2nd gen) — DUD: verified locally-inaccessible, rejected

## Verdict
**Rejected for control; passive presence detection only.** The Nest Protect
smoke + CO alarm has no local API of any kind. Its BLE surface is the Weave
commissioning transport (WoBLE) behind authenticated, encrypted Weave
PASE/CASE sessions keyed by the device's pairing code / cloud-issued token;
smoke/CO/alarm state is never readable locally. No public project has ever
read a Protect locally. Even Google's cloud SDM API does not expose Protect,
and the older Works-with-Nest API was shut down (2019–2021).

## Live observation (2026-08-14)
Five units observed on a home BLE scan (adapter fw13 #1), names `N04BB`,
`N04CN`, `N0479`, `N047B`, `N01YQ` (random addresses), all advertising the
Nest Labs 16-bit service `0xFEAF` with 17-byte service data, e.g.:

    10 01 00 02 5a 23 09 00 15 9b 8a 41 00 30 b4 18 00

This parses as OpenWeave's `WeaveBLEDeviceIdentificationInfo`
(`src/ble/WeaveBleServiceData.h`): block len/type `10 01`, version `00 02`,
vendor id LE `5a 23` = **0x235A Nest Labs**, product id LE `09 00` =
**0x0009 = `kNestWeaveProduct_Topaz2`** (openweave-core
`NestProductIdentifiers.hpp`) — Topaz is Nest's Protect codename, so
product 9 = **Nest Protect 2nd generation** — followed by an 8-byte Weave
device id (differs per unit) and a pairing-status byte.

## What IS extractable locally
Passive inventory only: a plain BLE scanner can count Protects, distinguish
units by the Weave device id, and read the pairing-status byte. No sensor
data, no alarm state, no battery level is present in the advertisement.

## Why the lead ends here
WoBLE sessions require the Weave security stack plus per-device secrets
(6-digit entry code printed on the device / cloud tokens); OpenWeave is
archived and ships no keys. MITM or key extraction is out of scope for this
repo. If alarm-state integration is needed, use the 120 V interconnect wire
or a separate listener sensor.

## Sources
- openweave/openweave-core: `src/ble/WeaveBleServiceData.h`
  (advertisement struct), `src/lib/profiles/vendor/nestlabs/
  device-description/NestProductIdentifiers.hpp` (product 0x0009 = Topaz2)
- Bluetooth SIG 16-bit UUID `0xFEAF` = Nest Labs Inc. (BlueZ
  `src/shared/util.c`, Nordic bluetooth-numbers-database)
- darkmentorllc/Blue2thprinting NAMEPRINT DB: `^N[A-Z0-F]{4}$` name
  pattern flagged as Nest, disambiguated by the Weave product id
- Google SDM API device list (no Protect); Works-with-Nest shutdown notices
