# Aqara Hub family (M1S Gen 2 / M2 / AC Partner P3)

> **Status**: Protocol recovered from the Aqara Home app (v4.2.1, SecNeo-packed — payload dumped from a rooted Android device); provisioning crypto verified against the vendor library on-device; not replayed against hub hardware
> **Protocol**: WiFi/LAN (mDNS + UDP multicast discovery, encrypted UDP 10008 provisioning) — steady-state control is cloud-relayed
> **Manufacturer**: Lumi United (Aqara)
> **Manufacturer Status**: Active

## Overview

Aqara's Wi-Fi hubs bridge the vendor's Zigbee and BLE sensors to the LAN and
cloud; some models add an IR blaster (M2, AC Partner P3) or a speaker and RGB
night light (M1S Gen 2). This entry exists because the vendor app is packed
(SecNeo/Bangcle) and its local surface had never been documented; the full
analysis is in the machine-readable spec
(`device-specs/devices/aqara-hub.yaml`).

The headline finding cuts both ways:

- **Local**: discovery and Wi-Fi onboarding. Hubs answer mDNS
  `_aqara._tcp.local.` and a UDP multicast `whois` probe, and accept Wi-Fi
  credentials as AES-128-CBC-encrypted JSON on UDP port 10008. The crypto
  parameters are app-wide constants and are recovered and verified (below).
- **Not local**: everything after onboarding. The current app contains no
  LAN command channel for hubs at all — control (arm/disarm, light, IR,
  Zigbee child state) and event delivery are relayed through Aqara's cloud.
  Onboarding also needs the cloud: the payload embeds a cloud-issued
  `bindKey`. See [Cloud dependency](#cloud-dependency).

## Hardware

| Property | Value |
|----------|-------|
| Models covered | Hub M1S Gen 2 (HM1S-G02), Hub M2 (Ethernet + IR), AC Partner P3 (IR) |
| Radio | Wi-Fi 802.11b/g/n 2.4 GHz + Zigbee 3.0; BLE (commissioning/locks) |
| Setup AP | `lumi-gateway-<model><suffix>`, `Aqara Hub *` (open) |
| Setup-AP address | 192.x.y.1 (the /24 gateway of the lease it hands you); UDP 10008 |

## Initial Setup

| Property | Value |
|----------|-------|
| Setup required | Yes — Wi-Fi join **and** cloud account binding |
| Method | `softap_udp` (primary), `softap_http` / `ble_provisioning` / wired-Ethernet variants |
| Setup AP | `lumi-gateway-*` / `Aqara Hub *`, open |
| Passphrase protection | device_encrypted (AES-128-CBC, app-wide key — recovered) |
| Confidence | medium (recovered from app code; crypto oracle-verified; no hub hardware replayed) |

The onboarding exchange, recovered from the app:

1. Join the hub's setup AP. The hub is at `192.x.y.1`, UDP port 10008.
2. Send one datagram: JSON
   `{"cid":" ","ssid":"…","passwd":"…","lang":"…","bindKey":"…","country_domain":"…","timeZone":"GMT±8"}`
   encrypted with AES-128-CBC (PKCS7, fixed IV — parameters in the spec's
   `aqara_lan_protocol.crypto`).
3. Hub replies with encrypted JSON (`iotError`/`errorMessage` on failure);
   the client closes with an encrypted `{"ack":1}`.
4. The hub joins the home Wi-Fi and advertises `_aqara._tcp` on the LAN.

Variants by model: plaintext JSON over TCP 10000 (`{"ssid","password",
"bindKey"}`), an HTTPS POST while on the setup AP (default-looking endpoint
`https://192.168.5.1:4567/` is a placeholder in the binary — unverified),
BLE "Magic Pair" commissioning (service `0000fcb9-…`), and standard Matter
commissioning (BLE `0xFFF6` / `_matterc._udp`) on Matter-capable models.
Ethernet models (M2) skip the AP: find the hub with the multicast probe and
push the same encrypted payload to its LAN address.

**Factory reset**: hold the hub button ~10 s until the yellow LED flashes —
this resets the *network* only and keeps Zigbee child bindings (the
router-replacement move). On the M1S Gen 2, pressing the button 10 times
restores factory defaults (bindings cleared). Both per vendor documentation,
neither replayed here (`verified: false` in the spec).

**Rebinding to a new network**: in place via the 10 s network reset; no full
factory reset needed.

## Pairing

| Property | Value |
|----------|-------|
| Pairing required | Yes — but the "pairing" is account binding, not a local exchange |
| Security mode | `app_layer` (bindKey issued by the vendor cloud) |
| One client at a time | N/A on LAN; account-bound in cloud |

Zigbee sensors pair *to the hub* (standard Zigbee joining while the hub is in
pairing mode), not to the phone. Aqara's BLE locks are a separate, fully
mapped local GATT surface (ECDH P-256 + AES-CCM session after a
cloud-assisted binding) — summarized in the spec's
`protocol_details.ble_lock_family` for a future dedicated entry.

## Cloud dependency

Steady-state control in app v4.2.1 is **cloud-only**: authenticated HTTPS
REST resource-writes (`subjectId`/`dataKey`/`value`) for control and cloud
push for events. Onboarding fetches the `bindKey`, region and position IDs
from the same REST API. If Aqara's cloud disappears:

- already-provisioned hubs keep answering discovery (mDNS/multicast) but
  expose no documented local control;
- adopting a reset hub is blocked on the `bindKey` unless testing shows hubs
  accept an arbitrary one (see `remaining_unknowns` in the spec).

Older hub firmware had a developer-mode LAN control protocol (multicast
`224.0.0.50`, ports 54321/9898) used by third-party projects such as the
[Home Assistant AqaraGateway integration](https://github.com/niceboygithub/AqaraGateway);
it has no trace in the current app and was not verified by this project.

## Protocol Summary

### Discovery

| Mechanism | Detail |
|-----------|--------|
| mDNS | `_aqara._tcp.local.`; TXT `md`=model, `id`=did, `pv`=`true` when already provisioned |
| UDP multicast | `230.0.0.1:10008`; send plaintext `{"command":"whois","address":"<your IP>","port":"<your port>"}` |
| Reply | JSON array of `{"command":"iam","address":"<ip>:<port>","model":"…","name":"…","registered":"yes|no"}` |

### Provisioning crypto (verified)

| Parameter | Value |
|-----------|-------|
| Algorithm | AES-128-CBC, PKCS7 padding, fixed IV (deterministic — no IV on the wire) |
| Key | `Uw4i98shjoeUQdaD` (ASCII, 16 bytes) |
| IV | `ddb3ba695a2e6f58562e17996d093d28` (hex) |
| Verification | Known-plaintext pairs reproduce the vendor library's output byte-for-byte (see spec) |

### Commands

See the spec's `commands` block: `discover_whois` (multicast probe) and
`provision_wifi` (encrypted UDP 10008 datagram). There are no post-setup LAN
commands to document — that is the finding, not an omission.

## Tools Used

- jadx (decompile of the memory-dumped payload dex)
- Rooted Android device + `/proc/<pid>/mem` dumping (SecNeo unpack)
- On-device JNI oracle harness (`app_process`) for the crypto verification
- pycryptodome (offline key search against oracle pairs)

## References

- [Aqara Hub M2 help center](https://store-support.aqara.com/products/aqara-smart-hub-m2) — vendor reset procedure
- [Aqara Hub M1S Gen 2 manual (ManualsLib)](https://www.manualslib.com/manual/3613999/Aqara-M1s-Gen-2.html) — button/reset table
- [Aqara Hub M1S Gen 2 spec sheet](https://www.aqara.com.cn/en/product/hub-m1s-gen-2/specs/)
- [niceboygithub/AqaraGateway](https://github.com/niceboygithub/AqaraGateway) — third-party local control for older firmware (prior art, unverified here)

## Contributors

- @claude — payload recovery, protocol analysis, crypto verification
