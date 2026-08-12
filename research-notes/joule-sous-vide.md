# ChefSteps/Breville Joule Sous Vide — Research Notes

## What it is
Joule (CS10001, ~2016; Joule Turbo 2023) — app-controlled immersion
circulator with **no physical controls**: the app (BLE or WiFi/cloud) is the
only way to set temperature and start a cook. ChefSteps was acquired by
Breville in 2019-07 (thespoon.tech, 2019-07-17).

## Company / service status (dated sources)
- Breville acquired ChefSteps 2019-07. (https://thespoon.tech/developing-breville-acquires-chefsteps-maker-of-the-joule-sous-vide/)
- The legacy ChefSteps app is retired; Joule owners are moved to the
  Breville+ / Sage+ apps ("Joule app 2.0", rebuilt from the ground up) —
  chefsteps.com/update-app, live as of 2026-08-07.
- Cloud service is ALIVE under Breville. Risk is future cloud retirement:
  a cloud-only Joule is a brick, hence the value of the local BLE path.

## Local feasibility — confirmed (BLE, no cloud, no pairing PIN)
From mitchcapper/JouleUWP `JOULE_PROTOCOL.md` (2016, still the canonical
community doc, repo updated 2026-02):
- Joule "can be completely controlled by bluetooth for all aspects of
  operation and by multiple users. There is no pin or security requirement
  for pairing" — fully local, no account.
- Command/status channel is **Google Protocol Buffers**: `base.proto` (all
  control/status messages) and `remote.proto` (cloud encapsulation). Both
  proto files ship as assets in the official app; decompiled app source +
  protos were republished at the JouleUWP releases page (jouleapp.zip).
- Cook model: Joule runs one "program" at a time (setPoint °C, cookTime s,
  delayedStart s, holdingTemperature; start/stop = start a new program /
  stop it). Status messages include bath temp, heater temp, board temps,
  pump RPM.
- WiFi side is a **dud for local control**: device makes an outbound
  HTTPS/WebSocket connection to cloud (historically AWS/Heroku); a port
  scan found no open ports; no LAN API exists. Control messages over the
  cloud WebSocket are the same protobuf as BLE.
- Firmware: device can be told to TFTP-download firmware from any LAN host
  (sha256 checked, no signature verification per JouleUWP) — a local
  firmware-rescue angle.

## Community implementations
- github.com/mitchcapper/JouleUWP — unofficial UWP client + protocol doc.
- github.com/sameer/joule-ha — unofficial API library (updated 2024-01).
- HA-Joule custom component (HA community thread 34370) — set temp + start
  cooks from Home Assistant over BLE.

## APK
Legacy app (`com.chefsteps.joule`) delisted from Play; replacement is the
Breville+ app. Not fetched via apkeep — unnecessary, the community already
published the decompiled app + proto files (see above). BLE GATT UUIDs are
NOT yet documented in JouleUWP (doc stops at protobuf layer) — one HCI
snoop or APK string sweep would close that gap.

## What needs cloud
Nothing for basic control: BLE works with zero account, zero pairing PIN.
Cloud is only needed for remote (out-of-home) control, guided recipes, and
firmware delivery (but TFTP path may bypass that).

## Open questions
1. BLE GATT service/characteristic UUIDs and the exact BLE framing
   (protobuf stream delimiter) — not in JouleUWP; needs one HCI snoop.
2. Whether Breville+ app firmware changed the BLE protocol (Joule Turbo is
   BLE-only — no WiFi at all — so BLE control must still exist).
3. Confirm TFTP firmware path on current firmware.

## Safety
1100 W heater; no local interlock beyond the device's own water-level and
overheat sensors. Sous-vide temps are low (<100 °C) but a stuck "run"
command with no water = hazard; keep stop-program command prominent.
