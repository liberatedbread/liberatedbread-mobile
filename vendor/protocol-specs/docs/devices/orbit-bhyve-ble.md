# Orbit B-hyve Bluetooth Hose and XD Timers

> **Status**: Spec Available (unverified)
> **Protocol**: BLE
> **Manufacturer**: Orbit Irrigation Products
> **Manufacturer Status**: Active. The per-mesh key comes from the Orbit cloud, once.

## Overview

These are battery valve timers that screw onto an outdoor tap: the HT25 and
HT31 have one outlet, and the "XD" HT32A and HT34/HT34A have two and four. The
B-hyve app drives them directly over BLE. Every timer on an account mesh shares
one AES-128 **network key**, which the Orbit cloud generated when the mesh was
created. With that key, a local client can start and stop watering and read
status and battery entirely over BLE, and the cloud is never contacted again.

The models fall into two wire families. Both use the same GATT service and the
same cipher:

| Family | Models | Frame magic | Inner message |
|--------|--------|-------------|---------------|
| Mesh | HT25-0000 (fw 0041, 0085) | `0x10` | Binary: `[mesh id LE16][type][msg id LE16][body]`, no CRC |
| Protobuf | HT25G2-0001, HT25A-0001, HT25-0001, HT31-0001, HT32A-0001, HT34A-0001, HT34-0001 | `0x11` | `aa 77 5a 0f [len LE16][protobuf][CRC-16/XMODEM LE]` |

The hardware string in the owner's account record selects the family: HT25…
ending in `-0000` is the mesh family, and everything else is protobuf. The
advertisement does not reveal the family.

## Initial Setup

| Property | Value |
|----------|-------|
| Setup required | Yes. The owner exports the mesh key once. |
| Method | `cloud_account` (one-time export), then local BLE only |
| Advertised | Service `0000fe32-0000-1000-8000-00805f9b34fb` (the BH1 hub uses it too) |
| MAC prefix | `44:67:55` (Orbit Irrigation OUI; medium confidence) |
| Passphrase protection | not_applicable |
| Confidence | medium (two independent open-source clients) |

**Cloud dependence.** The owner signs in to their own Orbit account once and
copies these values into the local client:

- the mesh `network_key`: base64 from the cloud, stored as 32 hex characters;
- each timer's BLE address and hardware string;
- for HT25-0000 only, the timer's own `mesh_device_id` and the hub's.

The upstream integration reads them from `https://api.orbitbhyve.com/v1`:
`POST /session`, `GET /devices`, then `GET /meshes/{mesh_id}` (newer accounts
use `/network_topologies/{mesh_id}`). On a rooted Android phone, the key can
also be read from the B-hyve app's cache. If the cloud disappears before the
key has been exported, no public method recovers it.

**The key is a per-user secret.** It opens every valve on the account. Every
key and id in this repository is invented.

**Factory reset**: not documented by either source.

## Pairing

| Property | Value |
|----------|-------|
| Pairing required | No |
| Security mode | `app_layer` (mesh key + per-session AES handshake) |
| Bonding | `none` |
| One central at a time | Yes. Close the B-hyve app so it releases the timer. |
| Confidence | medium |

## Protocol Summary

| UUID | Name | Description |
|------|------|-------------|
| `0000fe32-0000-1000-8000-00805f9b34fb` | Service | |
| `00006c71-fe32-4f58-8b78-98e42b2c047f` | Handshake | Write 20 bytes, read 20 bytes, once per connection |
| `00006c72-fe32-4f58-8b78-98e42b2c047f` | Command | Encrypted frames, host to device |
| `00006c73-fe32-4f58-8b78-98e42b2c047f` | Reply | Encrypted frames, notify |
| `00006c76-fe32-4f58-8b78-98e42b2c047f` | (unused) | Refuses writes; leave it alone |

**Session.** Subscribe to `6c73`. Then write 20 random bytes `C` (with
`C[11] = 0`) to `6c71` and read 20 bytes `D` back. Set
`S = D[0:4] || C[4:20]`. The nonce is `S[0:12]`. The host-to-device counter is
`S[12:16]` and the device-to-host counter is `S[16:20]`, both uint32 LE.

**Keystream.** Each block is `AES-128-ECB(key, nonce || ctr LE32)`, and the
counter increments once per 16-byte block. A frame consumes `ceil(len/16)`
counter values, and the next frame continues from there. The two directions
use independent counters.

**Frame.** `[magic][len][ciphertext][trailer LE16]`, where the trailer is
`(magic + len + sum(plaintext)) mod 65536`. The trailer is computed over the
*plaintext*.

**Commands** (application plaintext before wrapping):

| Command | Family | Plaintext |
|---------|--------|-----------|
| Start zone *n* for *s* seconds | protobuf | `72 0b 08 02 12 07 1a 05 08 <n-1> 10 <s varint>` (*s* 128–16383) |
| Stop | protobuf | `72 04 08 02 12 00`. On HT25A-0001 this frame **starts** a run, so use the next row. |
| Controller off / auto | protobuf | `72 04 08 00 12 00` / `72 04 08 01 12 00` |
| Status / battery request | protobuf | `7a 00` / `ea 02 00` |
| Start / stop | HT25-0000 | `<mesh LE16> b6 0d 40 04 <s LE16> 00 00 00 00` / `<mesh LE16> b7 0d 40 02 00 00 00` |
| Health (battery) | HT25-0000 | `<mesh LE16> 03 03 40 00 00 00 00 00 00 00`. The reply has battery mV at offset 9, LE16. |

Each HT25-0000 watering command needs a seven-frame init earlier in the same
connection: set the clock, read status, health and info, write its own mesh
id, write the hub's mesh id, then set the clock again.

`scripts/test_orbit_bhyve_ble_spec.py` transcribes the handshake, keystream,
trailer and inner CRC. It reproduces every frame vector in the spec, which uses
an invented key, and checks the CRC rule against four plaintext requests
published upstream.

See `device-specs/devices/orbit-bhyve-ble.yaml` for the full machine-readable
spec.

## Known gaps

- The schema has no framing scheme for this envelope. Every command needs a
  handler that implements it.
- Protobuf-family status and battery come back as protobuf, so no sensor is
  bound for those models.
- The sources disagree on whether the device enforces the outer trailer.
- The upstream authors warn against firmware updates, because the protocol may
  change.

## References

- [ljmerza/orbit-bhyve-ble](https://github.com/ljmerza/orbit-bhyve-ble) (MIT)
- [wxfield/Orbit_B-Hyve_4Port_Controller](https://github.com/wxfield/Orbit_B-Hyve_4Port_Controller) (MIT)
- [Home Assistant forum announcement](https://community.home-assistant.io/t/local-only-orbit-b-hyve-integration-for-home-assistant-over-bluetooth-le/1028201)
