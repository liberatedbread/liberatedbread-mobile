# Shining Glasses — target spec starter

## Target metadata
- target_id: shining-glasses
- app package_id(s): com.icwork.shiningglass
- device class: LED glasses
- transport(s): Bluetooth (BLE)
- local-only viability: high (local BLE control expected; no cloud dependency)

## Known facts (public)
- App listing describes Bluetooth-controlled LED glasses with customizable display patterns.
- Low app rating (2.5) suggests opportunity for replacement app.
- May share protocol family with Shining Mask (cn.com.heaton.shiningmask).
- Similar device class to CHEMION LED glasses (Nordic nRF51, 9x24 LED grid).

## Device discovery signals (hypotheses)
- BLE advertised name patterns: unknown (discover via scan; look for "Shining", "Glass", or generic names)
- Service UUIDs: unknown (discover via APK analysis + GATT enumeration)
- Address behavior: unknown

## Threat model + guardrails
- Scope: only owned devices.
- No safety concerns; display-only wearable.

## First experiments
1) Static APK scan (com.icwork.shiningglass):
   - search for UUID literals and GATT references
   - search for "shining", "glass", "bluetooth", "led", "aes", "encrypt"
   - compare BLE code paths with shining-mask APK for shared protocol
2) Check if AES-128 ECB encryption is used (as in shining-mask).
3) HCI snoop: connect and set a simple pattern.

## Protocol hypotheses (to validate)
- May share encryption and command format with Shining Mask (AES-128 ECB)
- Pairing/bonding: likely none required
- LED grid dimensions: unknown (likely smaller than mask)
- Command format: mode, color, speed, brightness, bitmap upload

## Control surface inventory
- Set display pattern/animation
- Set color
- Set brightness
- Set speed/animation rate
- Upload custom bitmap

## Evidence checklist
- APK hashes + version code
- HCI snoop log

## Spec output (clean-room)
Write a derived spec in:
- docs/devices/shining-glasses.md
- device-specs/devices/shining-glasses.yaml (if enough protocol data found)

## References
- https://play.google.com/store/apps/details?id=com.icwork.shiningglass
- https://github.com/GoneUp/mask-go (related Shining Mask RE)
- https://github.com/gsuberland/ChemionHacking (analogous LED glasses RE)
