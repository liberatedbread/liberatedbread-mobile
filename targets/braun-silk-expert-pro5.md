# Target: Braun Silk-expert Pro 5 (IPL)

## Target metadata
- target_id: braun-silk-expert-pro5
- app package_id(s): com.pg.grooming.braun.ipl (Braun IPL 3.3.3/7067 analyzed)
- device class: IPL hair removal (BLE + Wi-Fi on some SKUs)
- transport(s): BLE (control/tracking), Wi-Fi AWS IoT (optional, cloud)
- local-only viability: high — device fully functional standalone; BLE needs no cloud

## Known facts (verified from RE sources)
- VERIFIED (static, app 3.3.3): no activation/lock; app never fires flashes.
  BLE = session markers, state readout (skin tone, head, energy, flash count),
  skin-tone trigger, Wi-Fi provisioning.
- VERIFIED (static): UUID template `A0F0XXXX-5047-4D53-8208-4F72616C2D42`;
  command `3C00` / read `3C01` / write-payload `3C02` / status `3C03` /
  push `3C04` / raw stream `4C00`.
- VERIFIED (static): GET `C0` / SET `C1`+`C2` / EXECUTE `C3` verb framing;
  MTU 515; bonding expected.
- VERIFIED (static): discovery via manufacturer data — company `0x00DC` (P&G),
  device type `0x61`.
- Cloud (Cognito + AppSync) only needed for account, Wi-Fi provisioning, and
  the cloud-side flash counter.
- Full details: research-notes/braun-silk-expert-pro5.md (+ .yaml)

## Device discovery signals
- BLE manufacturer data `0xFF`: company LE `DC 00`, protocol `0x65`, type `0x61`

## Threat model + guardrails
- IPL device; firmware interlocks (skin contact) must not be defeated.

## First experiments
1) ./scripts/detect_devices.sh; confirm adv manufacturer bytes.
2) HCI snoop of stock-app session (start session, read SESSION_DATA).
3) Replacement-app MVP: scan → bond → MTU 515 → GET DEVICE_DATA/SESSION_DATA →
   session markers.

## Evidence checklist
- APK: Braun IPL 3.3.3 (7067), sha256
  0ad7cfaa1249b64420de941d5467bd260111f365f4fdc86bd2cb4c80bd842b0c
- HCI snoop log: TBD

## Spec output (clean-room)
- device-specs/devices/braun-silk-expert-pro5.yaml — after hardware verification
