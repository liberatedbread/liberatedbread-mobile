# Insta360 360° and Action Cameras

> **Status**: Spec Available (untested)
> **Protocol**: BLE GATT, camera Wi-Fi AP with TCP 6666, or station-mode LAN
> **Manufacturer**: Insta360 / Arashi Vision Inc. (active)

## Overview

The spec covers X3/X4/X5, ONE X/X2/RS/R, Ace/Ace Pro and GO 2/GO 3 families,
with later model identifiers recorded where evidence is weaker. These models
do not share one settled control implementation: direct BLE framing, GPS
remote emulation and Wi-Fi TCP differ by generation. Read the model matrix in
`device-specs/devices/insta360-camera.yaml` before sending anything.

The spec contains authorization and sync order, message framing, command and
notification codes, station-mode provisioning, preview-stream structure and
worked examples. This project has not replayed them on a camera.

## Direct BLE setup

1. Power the camera, scan for the model-specific advertised name and connect.
2. Request a larger MTU and subscribe to the notify characteristics listed in
   the spec.
3. Send `CHECK_AUTHORIZATION` with a stable client identifier. If refused,
   send `REQUEST_AUTHORIZATION` and approve the client on the camera.
4. GO-line models also require the sync exchange before normal commands.
5. Select the model's framing and command dialect. Do not send both candidate
   framings as an identification probe.

No ordinary Bluetooth bond is required; authorization is an application-layer
prompt. Status-number interpretations differ between public sources, so the
spec records the discrepancy instead of hiding it.

## Camera Wi-Fi and station mode

For the camera-hosted network, enable Wi-Fi and join its SSID. The established
gateway is `192.168.42.1`; connect to TCP port 6666 and send the documented
sync packet, then keep the session alive. Older firmware used the fixed
passphrase `88888888`; other firmware can generate a per-device passphrase.
Treat those as product facts, never as an owner's current credential.

Station mode is an alternative: over an authorized BLE session or the AP's
TCP session, send `SET_WIFI_CONNECTION_INFO` with the home SSID and
passphrase. The passphrase is a plain protobuf string. Wait for the result
notification and the camera's new address rather than guessing it.

## Factory reset and rebinding

Reset effects are not established. A `RESTORE_FACTORY_SETTINGS` message (code
57, empty body) exists, but it is untested and may clear AP credentials,
saved networks, authorized clients and settings. Use it only with owner
consent and a recovery path, not as a discovery probe.

A new phone needs a fresh BLE authorization. A new router can be supplied by
repeating station-mode provisioning without a factory reset.

## Privacy and security

The camera's AP and TCP protocol are not a secure boundary by themselves.
Public research on an older ONE RS also reported a root shell reachable from
its AP. Keep the camera on a trusted network, do not expose its AP or TCP
services to untrusted users, and keep firmware current. Photos, videos,
location and Wi-Fi credentials are private; examples in the spec use invented
or documentation-range identifiers.

## References

- [Insta360 GO 3 quick-start guide (FCC exhibit)](https://fccid.co/api/files/s1/2awwh_cinsabka_usersmanual_6668120_bd5f3f923d.pdf)
- [Insta360 GO 2 manual (FCC exhibit)](https://fccid.co/api/files/s1/2awwh_ing2_usersmanual_5146676_f38fdfbedb.pdf)
- [xaionaro-go/insta360ctl](https://github.com/xaionaro-go/insta360ctl)
- [RigacciOrg/insta360-wifi-api](https://github.com/RigacciOrg/insta360-wifi-api)
- [pchwalek/insta360_ble_esp32](https://github.com/pchwalek/insta360_ble_esp32)
