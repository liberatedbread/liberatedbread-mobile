# Xiaomi Mijia Kitchen Appliances (miio) — Research Notes

## What it is
Xiaomi/Mijia WiFi kitchen appliances speaking the miio LAN protocol:
- **Mijia IH rice cookers** — `chunmi.cooker.normal1..5`,
  `chunmi.cooker.press1/press2` (Chunmi is the Xiaomi-ecosystem OEM).
- **Mi Smart Air Fryer** (3.5 L, 4 L, 6.5 L) — `careli.fryer.maf01/maf02/
  maf03/...maf10a` (Careli OEM).
- Adjacent: Yunmi/Viomi kettles & water heaters, Mijia microwaves — several
  are miio or MIoT-spec over the same local transport.

Manufacturer ACTIVE (Xiaomi). Mi Home cloud is the default UX but every
miio device also answers on the LAN.

## Local feasibility — confirmed
Standard **miio protocol**: UDP 54321, AES-128-CBC-encrypted JSON payloads,
per-device 16-byte token (32 hex chars). Discovery = broadcast "hello"
handshake to 54321 (0x2131 magic), no cloud needed at runtime.

Reference implementations:
- github.com/rytilahti/python-miio — `Cooker` class
  (`miio.integrations.chunmi.cooker`): status (menu/program, stage, cook
  phase, temperature, remaining time, rice taste/thickness prefs),
  start cooking with program + duration + auto-keep-warm, cancel.
  `AirFryer` class (`miio.integrations.careli.fryer`): status, set target
  time/temp, mode, start/pause/cancel.
- openHAB miio binding lists `chunmi.cooker.*` and `careli.fryer.maf01–03`
  (+ maf10a support request 2025-02, issue openhab-addons#18258).
- Home Assistant: core Xiaomi Miio integration (iot_class local_polling);
  HA custom components (e.g. tsunglung/XiaomiAirFryer, al-one/xiaomi_miot)
  expose cookers/air fryers locally. Newer MIoT-spec models are equally
  local via the same encrypted transport with `get_properties/set_properties`
  calls.

## The one cloud step: token extraction (document it honestly)
miio needs the device token once. Options, best-first:
1. Xiaomi cloud token extractors (e.g. PiotrMachowski
   Xiaomi-cloud-tokens-extractor) — needs Mi Home account credentials once.
2. `miio-extract-tokens` from a Mi Home Android backup / APK data.
3. Some older firmwares answer with an unencrypted token in the discovery
   handshake before first cloud registration.
After extraction the path is fully local — but **re-pairing / firmware
updates can rotate the token**, re-opening the cloud dependency.

## APK
Not required — protocol and device models are fully covered by python-miio.
Mi Home APK (`com.xiaomi.smarthome`) already fetched by a prior swarm
(present in workspace/apks).

## Open questions
1. Exact per-model menu/program ID tables for rice cookers (python-miio has
   them for normal2 fw 1.2.8; other models partially mapped).
2. Which newer models are MIoT-spec vs legacy miio RPC — affects command
   envelope, not locality.
3. Kettle coverage: Mi Smart Kettle is BLE (out of scope here); Viomi
   `yunmi.waterheater.*` miio — needs model census.

## Safety
Heating appliances. Rice cookers/air fryers enforce their own temp/time
limits; still, remote start of an unattended air fryer deserves a warning in
any client (grease-fire risk if misused). Keep keep-warm auto behavior as
the device default.
