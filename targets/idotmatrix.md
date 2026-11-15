# iDotMatrix pixel display — target spec starter

## Target metadata
- target_id: idotmatrix
- app package_id(s): com.tech.idotmatrix
- device class: pixel display (16x16 or 32x32 RGB LED matrix)
- transport(s): Bluetooth (BLE)
- local-only viability: high (core display control is BLE-local; cloud content library optional)

## Known facts (public)
- Small RGB pixel displays in various sizes (16x16, 32x32).
- Extensively reverse engineered: derkalle4/python3-idotmatrix-library, 8none1/idotmatrix, markusressel/idotmatrix-api-client, nj-designs/go-idot.
- Known commands: power on/off, graffiti mode (pixel-by-pixel), text mode, GIF upload with chunking, clock display, countdown timer.
- GIF upload uses 4KB chunks with CRC32 validation and acknowledgment protocol.
- App includes a cloud content library (optional).

## Device discovery signals (hypotheses)
- BLE advertised name patterns: "IDM-*" or model-specific (discover via scan)
- Service UUIDs: to be confirmed from APK analysis / community repos
- Address behavior: unknown

## Threat model + guardrails
- Scope: only owned devices.
- No safety concerns; display-only device.

## First experiments
1) Static APK scan (com.tech.idotmatrix):
   - search for UUID literals and GATT references
   - search for "idotmatrix", "graffiti", "gif", "crc32", "chunk"
   - identify command byte formats
2) Cross-reference with derkalle4/python3-idotmatrix-library source code for UUIDs.
3) HCI snoop: connect and set a static image.

## Protocol hypotheses (to validate)
- Pairing/bonding: no pairing required (verify)
- Power: 05 00 07 01 01 (on), 05 00 07 01 00 (off)
- Graffiti: pixel writes with x, y, R, G, B
- Text: font sizes 16/32, 8 animation modes, color gradients
- GIF upload: 4KB chunks, CRC32, ack protocol (05 00 01 00 01 mid, 05 00 01 00 03 complete)
- Time/date setting command
- Brightness control

## Control surface inventory
- Power on/off
- Set brightness
- Display static image / graffiti
- Display text with animation
- Upload GIF animation
- Set clock display
- Countdown timer

## Evidence checklist
- APK hashes + version code
- HCI snoop log

## Spec output (clean-room)
Write a derived spec in:
- docs/devices/idotmatrix.md
- device-specs/devices/idotmatrix.yaml

## References
- https://play.google.com/store/apps/details?id=com.tech.idotmatrix
- https://github.com/derkalle4/python3-idotmatrix-library
- https://github.com/8none1/idotmatrix
- https://github.com/markusressel/idotmatrix-api-client
- https://github.com/nj-designs/go-idot
