# Xiaomi Body Composition Scale S400

> **Status**: Complete (untested on hardware by us)
> **Protocol**: BLE
> **Manufacturer**: Xiaomi
> **Manufacturer Status**: Active (closed protocol; secrets bound to Xiaomi cloud account)

## Overview

The S400 (MJTZC01YM, MiOT model `yunmai.scales.ms104`) is Xiaomi's
dual-frequency BIA body-composition scale: weight, impedance, and heart rate.
Heart rate is the odd one out for a consumer: it is broadcast in the
advertisement rather than sent over the encrypted measurement channel, so
the spec declares the sensor but leaves it unbound — see the entity's notes
in `device-specs/devices/xiaomi-mi-scale-s400.yaml`.
Unlike the older Mi Scale v1/v2 (`xiaomi-mi-scale` spec),
nothing is plaintext — all measurement traffic is AES-CCM encrypted with a
per-device 16-byte BLE bindkey issued by the Xiaomi cloud account the scale
is paired to. Two community access paths exist: passive advertisement
decryption (openScale, xiaomi-ble/Home Assistant) and an authenticated GATT
session for live streaming and record download (xiaomi-s400-live).

## Hardware

| Property | Value |
|----------|-------|
| Model Number | MJTZC01YM (S400 Pro: MJTZC03YM) |
| MiOT model | `yunmai.scales.ms104` |
| Radio | BLE 5.0 |
| Power | 3x AAA |
| Range / resolution | 0.1–150 kg |
| Known firmware | 2.1.1_0006 (GATT path tested), 2.1.1_0057.0077 (field) |
| FCC ID | — |

## Initial Setup

| Property | Value |
|----------|-------|
| Setup required | Yes — one-time pairing to Xiaomi Home |
| Method | `ble_direct` after cloud pairing |
| Setup AP / advertised name | `Xiaomi Scale S400 XXXX` / `XMTZC14HM` / `XMTZC*` (firmware-dependent) |
| Passphrase protection | not_applicable (BLE bindkey + 12-byte login token instead) |
| Confidence | high (multiple independent implementations) |

Pair the scale to a Xiaomi Home account and complete one in-app measurement,
then extract the **BLE bindkey** (16 bytes hex) — and for the GATT path the
**12-byte BLE login token** — with a cloud token extractor
(e.g. PiotrMachowski/Xiaomi-cloud-tokens-extractor, which handles 2FA).

**Factory reset**: removing the device from Xiaomi Home (or pulling a
battery) unbinds it and **rotates the login token** — previously extracted
secrets stop working. Re-extract after any re-pair.

**Rebinding**: no Wi-Fi involved; rebinding to a new Mi account is a fresh
pairing and invalidates old secrets.

## Protocol Summary

### Passive broadcast (no connection)

- Service Data (AD type 0x16) for Body Composition Service `0x181B`, 24 bytes
  of AES-CCM ciphertext (strip a 2-byte UUID header if 26 arrive).
- Standard encrypted MiBeacon frames on service `0xFE95`; decrypted payload
  carries measurement object `0x6E16`. MiBeacon product IDs `0x30D9`,
  `0x3BD5`, `0x48CF` map to MJTZC01YM.
- Decryption (both forms): AES-CCM, key = bindkey, AAD = `0x11`, 32-bit tag.
  For the 0x181B form: nonce = `MAC_reversed(6) || data[2:5] || data[-7:-4]`,
  ciphertext = `data[5:-7]`, MIC = `data[-4:]`.

#### Decrypted measurement word

Little-endian u32 at plaintext bytes 4–7 (byte 3 is a profile id; bytes 0–2
a MiBeacon object header):

| Bits | Field | Scaling |
|------|-------|---------|
| 0–10 | weight raw | /10 → kg |
| 11–17 | heart rate raw | +50 bpm, valid only when raw ∈ 1–126 |
| 18–31 | impedance raw | /10 → Ω |

Two packets per weighing: one with weight + heart rate + one impedance band,
a second with weight = 0 and the other band; aggregate within ~10 s.
`mass==0 && hr==0 && impedance==0` is an idle/stepped-off reset. Sources
**disagree** on which band is the 50 kHz (low) vs 250 kHz (high) reading —
openScale/lswiderski vs xiaomi-ble assign them oppositely; treat band
labelling as medium confidence.

### GATT / history path (Mi Home v2 login)

Auth service `0xFE95` GATT characteristics:

| UUID | Name | Description |
|------|------|-------------|
| `00000010-…-00805f9b34fb` | UPNP | auth command opcodes (0xA2/0x15/0x24/0x13) + result codes |
| `00000019-…-00805f9b34fb` | AVDTP | framed random-key/device-info exchange |
| `0000001a-…-00805f9b34fb` | VEND1A | app→device encrypted (post-login) |
| `0000001b-…-00805f9b34fb` | CMTP | device→app encrypted measurement stream |

Login: exchange 16-byte randoms on AVDTP, derive
`dev_key/app_key/dev_iv/app_iv` via HKDF-SHA256(token,
salt=app_rand‖dev_rand, info="mible-login-info"), verify HMAC-SHA256,
success = `21 00 00 00` on UPNP. Post-login CMTP parcels decrypt to an `0xA0`
marker followed by ASCII CSV: live frames `weight_x10,stable` (~0.3 s
cadence); final 32-field frames carry weight, both impedances, device unix
timestamp, and on-scale profile id — the effective history/record download.

Body composition metrics are computed **client-side** from weight, impedance,
and user profile (sex/age/height); they are estimates, not medical
measurements.

## Tools Used

- openScale 3.x (`MiScaleS400Handler`, `S400Decryptor`, `S400Aggregator`)
- Bluetooth-Devices/xiaomi-ble (`obj6e16` parser, device table)
- nokistin/xiaomi-s400-live (GATT login + CMTP decode, tested on fw 2.1.1_0006)
- dnandha/miauth (Mi Home v2 auth), mnm-matin/miscale, lswiderski/mi-scale-exporter

## References

- [openScale](https://github.com/oliexdev/openScale)
- [xiaomi-ble](https://github.com/Bluetooth-Devices/xiaomi-ble)
- [xiaomi-s400-live](https://github.com/nokistin/xiaomi-s400-live)
- [miauth](https://github.com/dnandha/miauth)
- [Xiaomi-cloud-tokens-extractor](https://github.com/PiotrMachowski/Xiaomi-cloud-tokens-extractor)
- [HA community S400 thread](https://community.home-assistant.io/t/how-to-add-xiaomi-mijia-scale-s400-model-mjtzc01ym-into-home-assisstant/662778)

## Contributors

- Liberated Bread — spec authored from public prior art
