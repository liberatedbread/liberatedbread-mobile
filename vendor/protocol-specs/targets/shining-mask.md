# Shining Mask — target spec starter

## Target metadata
- target_id: shining-mask
- app package_id(s): cn.com.heaton.shiningmask
- device class: LED mask
- transport(s): Bluetooth (BLE)
- local-only viability: high (fully local BLE control; no cloud dependency)

## Known facts (public)
- Programmable LED face mask with customizable patterns, colors, and animations.
- Well reverse engineered by community: GoneUp/mask-go (Golang implementation), Bishop Fox security research.
- Protocol uses AES-128 ECB encryption with a fixed key (documented in open-source projects).
- No authentication or pairing required — anyone in BLE range can connect (security concern documented by Bishop Fox).
- 16-pixel-high display with column-based encoding.

## Device discovery signals (hypotheses)
- BLE advertised name patterns: unknown (discover via scan; likely "Mask" or model-specific)
- Service UUIDs: to be confirmed from APK analysis
- Address behavior: unknown

## Threat model + guardrails
- Scope: only owned devices.
- Note: no authentication means anyone can hijack the display in BLE range.

## First experiments
1) Static APK scan (cn.com.heaton.shiningmask):
   - search for UUID literals and GATT references
   - search for "aes", "encrypt", "ecb", "mask", "shining"
   - identify the fixed AES key constant
   - identify command format and bitmap encoding
2) Cross-reference with GoneUp/mask-go and Bishop Fox research.
3) HCI snoop: connect and set a simple pattern.

## Protocol hypotheses (to validate)
- Pairing/bonding: none required
- Encryption: AES-128 ECB with fixed key from app
- Commands (plaintext before encryption):
  - Mode: 05MODEnn (01=steady, 02=blink, 03=scroll left, 04=scroll right)
  - Foreground color: 06FC + RGB bytes
  - Background color: 06BC + RGB bytes
  - Speed: 06SPEEDnn
  - Brightness: 06LIGHTnn
  - Image: 06IMAGnn
  - Animation: 06ANIMnn
- Bitmap upload: column encoding (2 bytes row bitmask + 3 bytes RGB per column)
- Max 100-byte packets: <length><packet_count><data_up_to_98b>
- Upload handshake: DATS → DATSOKP → data packets with REOK ack → DATCP → DATCPOK

## Control surface inventory
- Set display mode (steady, blink, scroll)
- Set foreground/background color
- Set brightness
- Set speed
- Upload custom bitmap/animation

## Evidence checklist
- APK hashes + version code
- HCI snoop log

## Spec output (clean-room)
Write a derived spec in:
- docs/devices/shining-mask.md
- device-specs/devices/shining-mask.yaml

## References
- https://play.google.com/store/apps/details?id=cn.com.heaton.shiningmask (note: package listed as cn.com.heaton.shiningmask)
- https://github.com/GoneUp/mask-go
- https://bishopfox.com/blog/invasion-of-the-face-changers-halloween-hijinks-with-bluetooth-led-masks
