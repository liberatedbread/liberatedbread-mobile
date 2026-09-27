# The Linux direct ATT path

On Linux, `lib/services/direct_att/` lets the app drive BLE peripherals that
bluetoothd cannot enumerate, by owning their ATT bearer itself. It sits
*underneath* flutter_blue_plus, so everything above it — RealBleService,
every screen, every spec-driven control — is the same code that runs on an
iPhone or an Android phone. It is scoped to the devices that need it, and it
is built to be deleted.

## Why

bluetoothd's GATT client opens every LE connection with an Exchange MTU and
then a Read By Type for **Server Supported Features (0x2B3A)** across the
whole handle range, before primary service discovery
(`src/shared/gatt-client.c`, `read_server_feat`; byte-identical from 5.66
through 5.87). A peripheral that answers that with *silence* instead of an
error — the Johnson LDM330 laser meter does, and bluez/bluez#2486 is a
SwitchBot tripping over the same request — makes bluetoothd wait out the 30 s
ATT transaction timeout, shut its bearer as the spec requires, and publish the
device as "resolved" with no services. The link drops about two seconds
later. Every client layered on bluetoothd inherits that: flutter_blue_plus's
Linux backend, bleak, `bluetoothctl`.

Nothing in `main.conf` skips the read (`[GATT] Cache = no` only skips the
Database Hash read, 0x2B2A, which a first connection never sends anyway), and
upstream declined to relax the timeout: a March 2026 series that stopped it
disconnecting was turned down as non-compliant ("if you are suggesting that we
sacrifice compliance for compatibility, we will need a configuration
setting"). Android never sends 0x2B3A to such a device — its robust-caching
and EATT heuristics skip peers that report an old LMP version, which is what
these modules report — so the firmware ships, tested against Android.

The kernel lets an unprivileged process open the ATT fixed channel (L2CAP
CID 4) itself. When our channel exists before the link comes up, bluetoothd's
listener is never given one ("client fixed channels should override server
ones", `net/bluetooth/l2cap_core.c`), so no bluetoothd GATT client or server
attaches, and the bearer is ours: we simply never send the request the device
ignores.

## How it fits

```
RealBleService                      shared, byte-for-byte, with iOS/Android
flutter_blue_plus 1.36.8            shared
FlutterBluePlusPlatform.instance
 ├─ iOS / Android / macOS           the stock plugin, untouched
 └─ Linux: DirectAttRouter          direct_att_router.dart
     ├─ BlueZ (flutter_blue_plus_linux) — every device by default,
     │     plus scanning, the adapter and pairing for all of them
     └─ DirectAttPlatform            direct_att_platform.dart — devices in
           │                          DirectAttRegistry
           └─ AttClient over AttChannel (an L2CAP socket via dart:ffi)
```

flutter_blue_plus is federated: every call goes through
`FlutterBluePlusPlatform.instance`, and every answer comes back as an event.
`installDirectAttRouter()` (called by `bleServiceProvider` before
RealBleService exists, because flutter_blue_plus binds to the instance's
streams once) wraps the stock BlueZ instance in the router. A no-op anywhere
but Linux.

- `att_pdu.dart` — the ATT PDUs a client sends and receives. Pure.
- `att_channel.dart` — the bearer. `L2capAttChannel` is an `AF_BLUETOOTH`
  `SOCK_SEQPACKET` socket on CID 4 over `dart:ffi` (connect and receive on a
  worker isolate), with cancellable connects and `BT_SECURITY` elevation.
- `att_client.dart` — a generic GATT client: one request in flight, stray
  responses dropped, timeouts close the bearer (the spec's rule), the
  discovery walk Android uses (minus its Include probe), long reads and
  writes, indications confirmed, encryption raised on demand when an
  attribute asks for it (as BlueZ, Android and iOS all do), and a minimal ATT
  *server* — because on our bearer nobody else answers the peer's own
  requests.
- `direct_att_platform.dart` — a flutter_blue_plus backend over those clients,
  written to flutter_blue_plus's contract: the same correlation fields, the
  same event-before-return discipline as the BlueZ backend, and errors in the
  shapes RealBleService already classifies on every platform (an ATT code for
  "pair first", flutter_blue_plus's timeout for "the device did not answer", a
  disconnect for a lost link). Its discovery table looks like BlueZ's and
  CoreBluetooth's: primary services, Generic Access/Attribute hidden, twins
  numbered by instanceId, CCCDs listed so `isNotifying` works.
- `direct_att_router.dart` — routing, the hand-over, and the filtering of
  bluetoothd's commentary on links it does not own.
- `direct_att_registry.dart` — which devices are routed direct.

## When a device goes direct

The router watches every BlueZ service discovery. The stall has an
unmistakable signature: nothing found, or the link gone, after at least
`stallThreshold` (20 s); an honest empty answer takes milliseconds, and the
stall takes bluetoothd's 30 s timeout. On that signature, inside the same
discovery call, the router:

1. stops forwarding bluetoothd's events about the device,
2. waits for the stalled connection to go away — the kernel drops it about
   two seconds after bluetoothd shuts its bearer, and BlueZ is asked if it
   does not. Never on that connection: bluetoothd already exchanged MTU on
   it (the spec allows one exchange per connection) and left a request
   unanswered on it,
3. opens a direct ATT channel on a fresh connection (retried: these devices
   refuse connections while their radio is changing state),
4. walks the table, subscribing to Service Changed as bluetoothd would, and
5. if it found any service an app could use, remembers the device and
   answers the waiting discovery with the direct table.

flutter_blue_plus — and so RealBleService and the screen — never sees a
disconnect; the discovery just took half a minute. If the direct walk finds
nothing either, the tentative link is dropped, bluetoothd's view is replayed,
and nothing is remembered. A remembered device goes direct from its first
connect afterwards.

## When the catalogue already knows

A spec can say so outright: `device.host_compatibility` in the protocol-specs
catalogue records, per host stack, whether its own GATT client can drive the
device — and for the LDM330, that BlueZ cannot (`status: incompatible`,
`workaround: raw_att`). Rust carries that to Dart as the spec identity's
`bluezRawAtt` (only for a claim about the whole device, not one variant), and
at `connect()` the router asks `specDeclaresDirectAttProvider` about any
device it has not already routed:

- a spec the app already ties to the device decides — the user's choice,
  then the one saved with the device;
- otherwise its last advertisement (or the name it was saved under) is
  matched as the scan list matches it, and only a confident match on which
  every equally good spec agrees counts.

A yes declares the device in the registry for this run (never stored: the
claim is re-derived each time, so a corrected spec takes effect) and it goes
direct from its first connection, skipping the stall entirely. A no, an
error, or no answer within two seconds leaves the runtime detection above in
charge. The router knows nothing about specs; the provider knows nothing
about ATT.

## Overrides

`LB_DIRECT_ATT=<mac>[,<mac>...]` routes those devices direct from the start
(skipping the first-contact stall). `LB_DIRECT_ATT=off` does not install the
router at all — every device on the stock BlueZ backend, including the fixes
in the next section — which is also the way around a bug in the router
itself.

## What the router also fixes for every device

Being the platform layer, the router holds Linux to the behaviour the phone
plugins have, which RealBleService is written against:

- `connect` on an already-connected device answers "no change" (the BlueZ
  backend said "changed" and sent no event, so flutter_blue_plus timed out and
  then *disconnected* the link under its other owner);
- `disconnect` on a dropped device answers "no change" (it used to wait 35 s);
- a BlueZ discovery that never resolves — its backend polls with no bound
  while flutter_blue_plus holds a process-wide lock, so a link lost before
  resolution wedged every Bluetooth call until restart — is abandoned when the
  link drops or after `bluezDiscoveryLimit` (45 s);
- a scan reports devices BlueZ already knows. flutter_blue_plus_linux builds
  scan results from BlueZ creating a device object, and bluetoothd keeps
  every device that was ever connected or paired, so such a device — every
  direct-ATT device among them — never showed up in a scan again. While a
  scan runs, the router's own BlueZ client (`bluez_view.dart`, which also
  answers the direct path's address-type lookups) turns what bluetoothd hears
  from those devices back into scan results.

## What it does not do

- **RSSI while connected.** It needs an HCI socket, which is root's; the Find
  Device view reports signal lost for direct devices.
- **Initiate pairing from nothing.** Encryption is raised when the device asks
  for it (Insufficient Authentication/Encryption), exactly as on a phone; that
  goes through bluetoothd's agent, so a Just Works pairing needs one registered
  (a desktop session has one; a bare `bluetoothctl` host may show
  `Pairable: no` and refuse). Stored bonds are used without prompting. A
  pairing that fails ends the link (the kernel offers no way back from a
  half-raised socket), and the operation reports "pair first", as on a
  phone.
- **Anything off Linux.** The router is never installed there.

One Linux papercut it leaves alone: RealBleService treats a reported MTU of
23 right after connect as "unknown" and assumes 512, for BlueZ and direct
links alike.

## Testing

- `test/fakes/fake_att_channel.dart` — a scripted, spec-compliant ATT
  peripheral (queued writes, security levels, peer-initiated requests, Service
  Changed, pipelining and oversize-PDU detection), with the LDM330's table —
  checked handle for handle against `captures/jlx/setup-and-capture.pcapng` —
  as one preset that keeps its silence on 0x2B3A/0x2B2A.
- `test/fakes/routed_ble.dart` — the shipping Linux stack with no radio: the
  real flutter_blue_plus bound to the real router, in front of the emulated
  BlueZ (`emulated_ble.dart`, which can now block, hang and drop discovery the
  way bluetoothd does) and the scripted ATT peers.
- `test/services/direct_att/` — the codec, the client, the platform against
  flutter_blue_plus's public API, the router end to end through
  RealBleService, and the registry.
- `test/services/direct_att/bluez_view_virtual_test.dart` — the scan fix and
  the address-type lookup against the REAL package:bluez and
  flutter_blue_plus_linux, over the virtual BlueZ with devices it already
  keeps (`test/fixtures/virtual_ble/known_devices.json`); run through
  `scripts/linux-virtual-ble.sh` (Linux CI does), skipped otherwise.
- `test/services/real_ble_service_routed_test.dart` — the whole existing
  RealBleService suite, unmodified, through the router: proof that a device
  BlueZ can serve loses nothing.
- `test/live/direct_att_live_test.dart` — hardware probes through the app's
  real stack; they scan for the device first when bluetoothd has never seen
  it, so wake it before starting. Any device:
  `LB_LIVE_BLE=1 LB_LIVE_BLE_ID=<mac> flutter test test/live/direct_att_live_test.dart --plain-name 'any device'`;
  the laser meter end to end: add `LB_LIVE_LDM330=1` and `--plain-name LDM330`.
  Add `LB_DIRECT_ATT=<mac>` to skip the first-contact stall.

## Removing it

When BlueZ can enumerate these devices (a configuration setting, or a
`read_server_feat` that tolerates silence): delete `lib/services/direct_att/`,
the `installDirectAttRouter` call in `ble_provider.dart`, the tests and fakes
named above, and this file, and move `ffi`, `bluez`,
`flutter_blue_plus_linux` and `flutter_blue_plus_platform_interface` back to
wherever nothing else needs them. The preference key
`ble.linux.direct_att_devices` can be left to rot.
