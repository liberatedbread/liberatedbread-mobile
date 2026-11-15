# Truma iNet X / iNet X Pro — Strict Read-Only

> **Status**: Spec available; untested on a bonded panel
> **Protocol**: BLE GATT, framed CBOR
> **Manufacturer**: Truma Gerätetechnik GmbH & Co. KG

## Scope and safety

The iNet X panel is a local BLE gateway to vehicle appliances. This spec is
limited to **topology and conditional telemetry**. Heating, cooling, hot water,
fans, pumps, switches, timers, fault resets, configuration, firmware and bond
management are excluded.

**Read-only still requires GATT writes** to announce and issue read requests.
The general community client's default discovery also emits
`client-system-time` and `client-last-message`; those change client state and
are not passive. Omit both, all `{tn,pn,v}` setters, measurement triggers and
install/demo operations. The reduced sequence still needs an owner-panel test.

The legacy **iNet Box** is a different protocol:
[ASCII `TRBT:` over Nordic UART](truma-inet-box.md). Never send one system's
frames to the other.

## Identity, pairing and recovery

| Role | UUID |
|---|---|
| Advertised service | `fc310001-f3b2-11e8-8eb2-f2801f1b9fd1` |
| Main service | `fc314000-f3b2-11e8-8eb2-f2801f1b9fd1` |
| Control | `fc314001-f3b2-11e8-8eb2-f2801f1b9fd1` |
| Request/write | `fc314002-f3b2-11e8-8eb2-f2801f1b9fd1` |
| Data/notification | `fc314003-f3b2-11e8-8eb2-f2801f1b9fd1` |
| Optional additional notification | `fc314004-f3b2-11e8-8eb2-f2801f1b9fd1` |
| Software revision | `00002a28-0000-1000-8000-00805f9b34fb` |

The name prefix is `Truma iNetX`, possibly only in a scan response. Community
evidence reports a rapidly rotating resolvable private address: **do not persist
the MAC or weaken host privacy**.

Pairing is reported as Just Works, accepted only in the panel's add-device mode,
with about four bond slots. Open that mode on the panel, scan by name/service,
bond, then subscribe to control and data. No passkey is reported. This was not
replayed by the project.

Rejoin with an existing bond and rediscover by name/service rather than MAC. A
new client needs a free add-device slot. Do not clear bonds or factory reset to
make telemetry work; no reset or standalone-unpair procedure is established.
Host-specific Linux/ESPHome reports are troubleshooting evidence, not a blanket
claim that an adapter cannot work.

## Frame format

All multi-byte header integers are little-endian; CBOR has its own encoding.

| Offset | Size | Meaning |
|---:|---:|---|
| 0 | 2 | Target address/group |
| 2 | 2 | Source address/group |
| 4 | 2 | Declared body length |
| 6 | 2 | Operation |
| 8 | 8 | Sequence |
| 16 | 2 | Flags |
| 18 | variable | CBOR value when present |

Use the observed formulas:

```text
bodyLength = 1 + 8 + 2 + cborLength
physicalFrameLength = bodyLength + 7
```

Validate the complete physical length and header before decoding CBOR. A CBOR
decoder's offset search is not frame validation.

Useful read envelopes:

- **Protocol version**, operation 1: 25-byte request
  `0000ffff12000100000000000000000001c1a1627076820501`. The response supplies
  `pv` and assigned client `addr`; retain that source address for the session.
- **Topic registration**, operation 3, flags `0002`: send the four concrete
  `{tn: [...]}` batches below with target zero and the learned source.
- **Device list**, operation 2, flags `0001`: 18-byte header without CBOR.
  Substitute the learned client source into `source_lo` and `source_hi` at
  offset 2, little-endian, rather than sending a fixed `ffff` source. A reply
  may be `[0, {Devices: [group, ...]}]`.
- **Group read**, operation 3, flags `0004`: template
  `000000050b00030000000000000000000400`; replace target at offset 0 and
  learned client source at offset 2, both little-endian.

### Topic registration batches

The strict-read wire sequence expands to protocol version → **four registration
requests** → device list → one group read per discovered group. Each request is
a definite-length CBOR map with text key `tn` and an array of exact-case UTF-8
topic strings:

```text
1. AirCirculation, AirCooling, AirHeating, DeviceManagement, EnergySrc,
   ErrorReset, FreshWater, GasBtl, GasControl, GreyWater
2. Identify, L1Bat, L2Bat, LinePower, MobileIdentity, PowerSupply,
   RoomClimate, Switches, Temperature, Transfer
3. VBat, WaterHeating, AmbientLight, Panel, BatteryMngmt, Install, Connect,
   TimerConfig, BleDeviceManagement, BluetoothDevice
4. System, Resources, PowerMgmt
```

For broad discovery, send all four batches in order; `Devices` supplies source
group IDs, not topic names. For selected telemetry, use nonempty exact-case
subsets in order, split into requests of at most ten names. The ten-name limit
is reported, not independently boundary-tested. An empty array is not an
all-topics wildcard, and topic names do not determine group routing.

For the fourth batch, the 32-byte CBOR body is
`a162746e836653797374656d695265736f757263657369506f7765724d676d74`. With
invented assigned source `0x1234`, the complete 50-byte request is
`000034122b00030000000000000000000200a162746e836653797374656d695265736f757263657369506f7765724d676d74`;
announce it on control as `01 32 00`. All four CBOR literals and the frame
vector are reproduced by `scripts/test_truma_inet_specs.py`. These are
source-derived reported findings, not a hardware-validated strict-read sequence.

## Control exchange and fragmentation

1. Subscribe to control and data.
2. Announce on control: `01 <length_lo> <length_hi>`.
3. Wait for `81 00`, then write the complete request on request.
4. Wait for `f0 01` acceptance. This is transport progress, not a setting change.
5. On control `83 <length_lo> <length_hi>`, send `03 00`.
6. Reassemble data notifications to the announced length. Responses may queue,
   and a new frame can begin while older responses drain.
7. Acknowledge each flushed response with `f0 01`.

Do not rely only on the upstream trailing-fragment heuristic: a short first
fragment can be mistaken for trailing data after a completed response. Use
announced lengths and explicit frame state, then test real ATT/MTU splits.

## Telemetry model

Responses can be a record or `[context, record]`, with `topics`, `tn`, `pn`,
`v`, `type`, `min`, `max`, `enum`, `avail`/`a`, `perm` and `Devices`. Retain
**(source group, topic, parameter)** with every reading. Availability and
permission metadata do not prove hardware absence or authorize actuation.

Topic/group hints are not universal: heating often appears at `0201`,
tanks/switches at `0405`, room climate at `0101`, while one air conditioner
appeared at `0406`. Discover `Devices` and refresh device-supplied enums/ranges.

| Candidate | Reported meaning | Caveat |
|---|---|---|
| `AirHeating.Temp`, `WaterHeating.Temp` | Temperature | One example uses tenths of a degree C and rejects 65535; not universal |
| `FreshWater.Level`, `GreyWater.Level` | Tank level | Percent where supported; measurement-trigger writes excluded |
| `VBat.Voltage`, `L1Bat.Voltage` | Starter/leisure voltage | Retain source group |
| `LinePower.Plugged`, `System.Plugged` | Shore power | Different publishers can both report |
| `AirCirculation.FanLevel` | Fan level | Reported 0–10; read-only here |
| `AirHeating.Active`, `AirCooling.Active` | Running state | Type 105: 0 off, 1 running, 2 standby; do not apply to type 107 |
| `System.FlameStatus` | Heating activity | Follows gas or electric heat |
| `GasBtl.FillLevelW` | Gas contents | Kilograms on one reported LevelControl installation |
| `GasBtl.RemTime` | Unresolved raw value | Keep unitless; remaining-time interpretation not substantiated |

Redact `CertThumb`, `Muid`, `SerialNr`, `UniqueID`, `UserName`, `Uuid`, real
MACs, labels, raw identity responses and account data from diagnostics.

## Firmware and remaining validation

Vendor documentation says the app is required for panel updates. No update
transport is specified here. The first-generation operating guide reports a
fallback to the last installed software after an update failure, but wrong-image
and interrupted-transfer behavior still needs model-specific evidence.

Open items are live pairing/encryption, Panel 1/Panel 2 inventory, completeness
of the reduced strict-read sequence, ATT/MTU fragmentation, per-parameter
scales/sentinels and optional remote-module behavior. Upstream build/lint/70
tests and nine synthetic transport checks passed; they are not hardware proof.

## References

- [Official iNet X System product information](https://portal.truma.com/wp-content/uploads/2025/01/truma-operating-systems-product-information-inet-x-system-panel-0125-oem-int.pdf)
- [iNet X / iNet X Pro operating instructions](https://www.truma.com/download/inet-x-panel-inet-x-pro-panel-operating-instructions-3/?wpdmdl=51078)
- [`node-red-contrib-truma-inetx` at `004a8327`](https://github.com/node-red-contrib/node-red-contrib-truma-inetx/tree/004a83270721f1a89ed409e91a67e831ad04a98a)
- [`hass-truma-inetx` at `08daf61c`](https://github.com/rpodgorny/hass-truma-inetx/tree/08daf61c2845ab10a6b1e5b92b4308ee0812a156)
