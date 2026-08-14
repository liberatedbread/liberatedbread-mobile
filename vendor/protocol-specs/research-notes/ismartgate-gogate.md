# iSmartGate / GoGate (Gogogate2) — Research Notes

## What it is
Remsol (Barcelona) wired smart gate/garage controllers: Gogogate2 (2014,
up to 3 doors), iSmartGate PRO/LITE/MINI (2017+). Marketed as HomeKit-first;
"Your data is stored locally, NOT in the cloud" is a vendor slogan.
Vendor **active** — ismartgate.com reachable 2026-08-07.

## Local path (confirmed)
Both families expose an **undocumented-but-implemented local HTTP API**:
- Home Assistant core integration `gogogate2` (iot_class: local_polling,
  auto-discovered on the LAN) — home-assistant.io/integrations/gogogate2.
- Python client [bdraco/ismartgate](https://github.com/bdraco/ismartgate)
  (fork of vangorra/python_gogogate2_api), verified from source 2026-08-07.

Wire format (from ismartgate/__init__.py):
- `GET http://<ip>/api.php?data=<encrypted>` where `data` is a JSON array
  `[username, password, option, arg1, arg2]` encrypted with the device
  credential cipher (key derived from `sha1(username.lower()+password)`,
  sliced into a passphrase; AES family, differs slightly between Gogogate2
  and iSmartGate firmware).
- `option` ∈ `info` (full status) / `activate` (door id in arg1).
- Responses are **XML** (`<response><door1><status>closed</status>...`,
  `<outputs>`, `<network>`, `<wifi>`, error block with numeric codes).
- Credentials are the device's local web-UI login (default `admin` /
  user-set); no vendor cloud account involved in the LAN path.

iSmartGate additionally speaks **HomeKit (HAP)** locally — pairing via the
printed HomeKit code; works through HA homekit_controller.

## Cloud status
Optional remote access relay exists (`remoteaccessenabled` flag in info
response) but local control never touches it. Initial setup is local (device
AP + web UI). No one-time cloud step required.

## Caveats
- Firmware updates have shifted the local API before; Hubitat users report
  status endpoints changing (community.hubitat.com/t/ismartgate-pro/44891,
  2020-07-11) and HA issue #93976 shows XML parse breakage after reboots.
- Gogogate2 vs iSmartGate differ in error codes and door fields (library
  maintains two parsers).

## APK
Not fetched — local protocol already implemented in two maintained libraries
and a HA core integration; no RE needed. Apps exist (`iSmartGate` /
`Gogogate`) if future wire-level confirmation is wanted.

## Rating
**Confirmed** — HA core integration + maintained PyPI library.

## Safety
MEDIUM — relay output pulses door/gate openers; wired magnetic sensor
reports position. Gates add vehicle-pinch considerations.
