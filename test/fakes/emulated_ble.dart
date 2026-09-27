// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// An in-process emulated BLE controller: virtual peripherals that the REAL
// flutter_blue_plus Dart code — and therefore the real [RealBleService] — talks
// to exactly as it would talk to hardware.
//
// WHY THIS EXISTS
//
// The app has three BLE "devices" available to tests, and until this file there
// were only two:
//
//   1. FakeBleService (test/fakes/fake_ble_service.dart) implements the app's
//      own BleService interface. It is the right tool for widget tests, but it
//      replaces the entire service, so NOTHING in real_ble_service.dart runs.
//   2. MockBleService is demo mode — a product feature, not a test double, and
//      also a BleService implementation, so again real_ble_service.dart is out
//      of the picture.
//   3. This file. It plugs in one layer LOWER, at flutter_blue_plus's own
//      platform seam, so the code under test is the real service, driving the
//      real plugin, against an emulated radio.
//
// That third layer is where the bugs actually were. Everything in
// real_ble_service.dart that could be tested without a radio had already been
// hoisted into top-level pure functions (mapConnectionState, adapterStateError,
// nextEmptyDiscoveryRetryDelay, ScanResultCoalescer...) precisely because the
// class itself was untestable — the ~470 lines of scan/connect/discover/
// read/write/notify plumbing that wire those helpers together ran nowhere but
// on a phone. This makes them runnable on any machine, `flutter test`-fast.
//
// HOW IT WORKS
//
// flutter_blue_plus 1.35 is federated: every platform call goes through
// `FlutterBluePlusPlatform.instance`, and every reply comes back as an event on
// one of that instance's streams. [EmulatedBleAdapter] is such an instance. It
// keeps a set of [EmulatedPeripheral]s and answers requests the way a
// controller does: `connect` returns immediately and the CONNECTED state
// arrives later on `onConnectionStateChanged`, `readCharacteristic` returns and
// the value arrives on `onCharacteristicReceived`, and so on. Request/response
// correlation, the mutexes, the timeouts and the error mapping in
// flutter_blue_plus are all live.
//
// LIFETIME: ONE ADAPTER PER TEST PROCESS
//
// flutter_blue_plus subscribes to the platform's event streams exactly once,
// lazily, in its own `_initFlutterBluePlus()`, and never re-subscribes. So an
// adapter installed per-test would be ignored from the second test onward — its
// events would arrive at nobody. [EmulatedBleAdapter.install] therefore returns
// a process-wide singleton, and [EmulatedBleAdapter.reset] (call it from
// `setUp`) returns it to a clean state between tests, disconnecting anything
// still connected so flutter_blue_plus drops its own per-device caches too.
//
// Every reply the adapter defers — a [EmulatedBleAdapter.latency] timer, a
// late CCCD ack, a scheduled link drop, a discovery held inside its call — is
// tracked, and `reset` cancels or releases all of them. Tests reuse the same
// device ids, so a timer left over from one would land in the next as a
// phantom event for a device that test just set up.

import 'dart:async';

import 'package:flutter/foundation.dart' show FlutterError;

import 'package:flutter_blue_plus_platform_interface/flutter_blue_plus_platform_interface.dart';

/// The radio states an [EmulatedBleAdapter] can be put in.
///
/// An alias, not a new enum: it IS what flutter_blue_plus's platform layer
/// speaks, and re-declaring it would mean a mapping table that could drift.
/// Aliasing lets a test say `EmulatedAdapterState.off` without importing the
/// plugin's platform interface itself.
typedef EmulatedAdapterState = BmAdapterStateEnum;

/// Which ATT write a central used. Aliased for the same reason.
typedef EmulatedWriteType = BmWriteType;

/// Whether the central and the peripheral have paired. Aliased for the same
/// reason.
typedef EmulatedBondState = BmBondStateEnum;

/// Well-known UUIDs used by the emulated devices below, in the 128-bit form
/// flutter_blue_plus normalizes to.
class EmulatedUuids {
  EmulatedUuids._();

  /// Vendor control service, matching the example bulb spec
  /// (vendor/protocol-specs/device-specs/examples/example-bulb.yaml).
  static const controlService = '0000fff0-0000-1000-8000-00805f9b34fb';

  /// Command characteristic: write-without-response only, as most real BLE
  /// control characteristics are.
  static const controlCommand = '0000fff1-0000-1000-8000-00805f9b34fb';

  /// State characteristic: readable and notifiable.
  static const controlState = '0000fff2-0000-1000-8000-00805f9b34fb';

  /// Battery Service / Battery Level (BT SIG).
  static const batteryService = '0000180f-0000-1000-8000-00805f9b34fb';
  static const batteryLevel = '00002a19-0000-1000-8000-00805f9b34fb';

  /// Client Characteristic Configuration Descriptor — the descriptor a central
  /// writes to subscribe. When the platform says it wrote one,
  /// flutter_blue_plus waits for the write to be confirmed before
  /// `setNotifyValue` resolves.
  static const cccd = '00002902-0000-1000-8000-00805f9b34fb';
}

/// A failure the emulated peripheral should answer a request with, instead of
/// data — the GATT error a real peripheral returns for, say, "read not
/// permitted".
class EmulatedGattError {
  final int code;
  final String message;
  const EmulatedGattError(this.code, this.message);

  /// A stand-in for the common "the peripheral refused it" case.
  static const refused = EmulatedGattError(133, 'GATT_ERROR');

  /// ATT error 0x05, what a peripheral answers when the attribute needs an
  /// authenticated (paired) link and the link is not one yet. Android's
  /// GATT_INSUFFICIENT_AUTHENTICATION and Apple's
  /// CBATTError.insufficientAuthentication are both this same ATT code.
  static const insufficientAuthentication = EmulatedGattError(
    5,
    'GATT_INSUFFICIENT_AUTHENTICATION',
  );

  /// ATT error 0x0F: the link is paired but not encrypted to the level the
  /// attribute demands. Reaches the app through the same route as
  /// [insufficientAuthentication] and wants the same recovery.
  static const insufficientEncryption = EmulatedGattError(
    15,
    'GATT_INSUFFICIENT_ENCRYPTION',
  );
}

/// A characteristic in an emulated peripheral's GATT table.
class EmulatedCharacteristic {
  final String uuid;

  /// Which characteristic this is among those sharing [uuid] in the same
  /// service, assigned when the GATT table is built. Counted on the 128-bit
  /// form, so '2a19' and its long spelling are one UUID here, as they are to
  /// flutter_blue_plus's Guid.
  ///
  /// A GATT table may legitimately carry a UUID twice — flutter_blue_plus
  /// 1.35.6 added this so a caller can address the second one. Every
  /// characteristic here gets one, a read, write or subscription reaches the
  /// characteristic whose id it carries, and every response echoes that id,
  /// so a test can stand up a duplicate and prove the app reaches the one it
  /// meant. This is the numbering the platforms intend; note that
  /// flutter_blue_plus_linux 7.0.3 actually reports 0 for every twin (its
  /// identical() check runs against freshly built BlueZ wrappers), so on real
  /// Linux a twin cannot be addressed at all.
  int instanceId = 0;

  /// Current value. Mutable: writes land here and tests can move it under a
  /// live subscription to simulate a sensor changing.
  List<int> value;

  final bool canRead;
  final bool canWriteWithResponse;
  final bool canWriteWithoutResponse;
  final bool canNotify;
  final bool canIndicate;

  /// Whether the peripheral exposes a CCCD for this characteristic. Defaults to
  /// "yes, if it can notify or indicate", which is what real peripherals do.
  ///
  /// It is settable because the answer decides whether `setNotifyValue` waits
  /// for a confirmation at all: flutter_blue_plus skips the wait when the
  /// platform reports no CCCD write. flutter_blue_plus_linux 7.0.3 always
  /// reports none — it subscribes through BlueZ's StartNotify, which writes
  /// the CCCD itself, and returns false — although BlueZ does list the CCCD
  /// among the characteristic's descriptors (and refuses a D-Bus write to
  /// it). `false` here is the nearest model of that backend: the wait is
  /// skipped, at the cost of the descriptor also missing from discovery.
  final bool exposesCccd;

  /// Answered instead of the value when set.
  EmulatedGattError? readError;

  /// Answered instead of an ack when set.
  EmulatedGattError? writeError;

  /// True once the central has subscribed. Notifications pushed with
  /// [EmulatedPeripheral.pushNotification] are dropped when this is false, as
  /// on real hardware.
  bool isNotifying = false;

  /// Every write the central has sent, in order, with the mode it used. The
  /// mode matters: a write-with-response sent to a characteristic that only
  /// supports write-without-response silently fails on real hardware, which is
  /// why [useWriteWithoutResponse] exists and why this records the type.
  final List<({EmulatedWriteType type, List<int> value})> writes = [];

  EmulatedCharacteristic({
    required this.uuid,
    List<int> value = const [],
    this.canRead = false,
    this.canWriteWithResponse = false,
    this.canWriteWithoutResponse = false,
    this.canNotify = false,
    this.canIndicate = false,
    bool? exposesCccd,
    this.readError,
    this.writeError,
  }) : value = List<int>.of(value),
       exposesCccd = exposesCccd ?? (canNotify || canIndicate);

  BmCharacteristicProperties get _properties => BmCharacteristicProperties(
    broadcast: false,
    read: canRead,
    writeWithoutResponse: canWriteWithoutResponse,
    write: canWriteWithResponse,
    notify: canNotify,
    indicate: canIndicate,
    authenticatedSignedWrites: false,
    extendedProperties: false,
    notifyEncryptionRequired: false,
    indicateEncryptionRequired: false,
  );
}

/// A service in an emulated peripheral's GATT table.
class EmulatedService {
  final String uuid;
  final List<EmulatedCharacteristic> characteristics;

  EmulatedService({required this.uuid, required this.characteristics});
}

/// A virtual BLE peripheral: an advertisement plus a GATT table, with knobs for
/// the failure modes that real peripherals actually exhibit.
class EmulatedPeripheral {
  /// Remote id — a MAC on Android/Linux, a UUID on Apple platforms. Any string
  /// works here; tests use MAC-shaped ones for readability.
  final String id;

  /// What the PLATFORM reports as the peripheral's name — CoreBluetooth's
  /// cached `peripheral.name`, which once any app on the phone has connected
  /// is the GAP Device Name characteristic rather than what is on air.
  String name;

  /// The local name carried in the advertisement itself. Defaults to [name],
  /// as on a fresh Android cache; real devices can advertise something else
  /// entirely (a rebadged bulb whose GAP name is the chipset vendor's), and
  /// that is the case worth emulating. Assign null for an advertisement that
  /// carries no local name at all — a device named only in GATT.
  String? advName;
  int rssi;
  bool connectable;

  /// ATT MTU reported once connected. 23 is the BLE floor; real links usually
  /// negotiate higher.
  int mtu;

  final List<EmulatedService> services;

  /// Refuse the next connection with this GATT error, the way a peripheral that
  /// is out of range or already connected elsewhere does.
  EmulatedGattError? connectError;

  /// Manufacturer payloads in the advertisement, by company id. Mutable so a
  /// test can re-advertise a changed payload — a pixel panel announcing new
  /// dimensions — and see whether the scan emits the change.
  Map<int, List<int>> manufacturerData = const {};

  /// Whether the SYSTEM no longer holds a peripheral object for this id —
  /// CoreBluetooth's `retrievePeripheralsWithIdentifiers:` answering with
  /// nothing.
  ///
  /// This is the Apple-only precondition behind the reconnect path: the
  /// remote id there is a system-minted per-app UUID, not an address, so
  /// after a Bluetooth reset, a reboot of an unbonded device, or an address
  /// rotation, `connect` fails before it reaches the radio with a plain
  /// FlutterError whose message contains "Peripheral not found". A single
  /// advertisement sighting re-registers it, so a scan that HEARS this
  /// peripheral (one carrying its id in `withRemoteIds`, or an open scan)
  /// clears the flag — exactly what the app's targeted rediscovery scan is
  /// for. [advertising] `= false` is the peripheral that stays unheard.
  ///
  /// Not expressible with [connectError]: that is delivered as a connection
  /// -state event with a reason code, which is what a radio-level refusal
  /// looks like. This one is a thrown platform error instead.
  bool unknownToSystem = false;

  /// Whether the peripheral is advertising at all. False is a device that is
  /// off, asleep or out of range: a scan never reports it, so it can never be
  /// rediscovered.
  bool advertising = true;

  /// Answer this many `discoverServices` requests with an EMPTY service list
  /// (a success carrying zero services) before answering truthfully.
  ///
  /// This is not a hypothetical, and on Linux it is bluetoothd's doing, not
  /// the plugin's: flutter_blue_plus_linux 7.0.3 does wait for
  /// ServicesResolved inside the call, but bluetoothd sets ServicesResolved
  /// with ZERO services when its own GATT client gives up — a peripheral
  /// that never answers bluetoothd's Database Hash read stalls it for the
  /// 30 s ATT timeout — and possibly before it has exported the services it
  /// did find. [nextEmptyDiscoveryRetryDelay] is the app's answer to it, and
  /// this is how a test gets to watch that ladder run. Add
  /// [discoveryBlocksFor] and [dropLinkAfterDiscovery] for the whole stall: a
  /// long wait, an empty answer, then the link going down.
  int emptyDiscoveries = 0;

  /// Fail `discoverServices` outright.
  EmulatedGattError? discoverError;

  /// Hold every `discoverServices` call INSIDE the platform call for this
  /// long before answering it.
  ///
  /// That is what flutter_blue_plus_linux 7.0.3 does: it polls BlueZ's
  /// ServicesResolved every 100 ms, with no bound, before returning, while
  /// flutter_blue_plus holds its process-wide "invokeMethod" and "global"
  /// mutexes around the call — so nothing else in the stack runs meanwhile,
  /// and flutter_blue_plus's own 15 s discovery timeout only starts once the
  /// call returns. [EmulatedBleAdapter.latency] cannot stand in for it:
  /// there the call returns at once and only the reply is late, so a long
  /// one surfaces as a flutter_blue_plus TIMEOUT rather than as the late
  /// answer the real stack gives.
  ///
  /// The answer still goes out [EmulatedBleAdapter.latency] after the wait.
  /// A link dropped during the wait does not cancel it; the forever-poll a
  /// real drop mid-poll causes is [discoveryNeverResolves].
  Duration? discoveryBlocksFor;

  /// Never answer `discoverServices`: the platform call neither returns nor
  /// emits.
  ///
  /// flutter_blue_plus_linux 7.0.3's poll when ServicesResolved never turns
  /// true — the link dropped before bluetoothd resolved, which sets the flag
  /// false for good — leaving flutter_blue_plus wedged, mutexes held, for the
  /// rest of the process. Exactly the hazard a guard around that call exists
  /// for. [EmulatedBleAdapter.reset] and
  /// [EmulatedBleAdapter.releaseHungDiscoveries] let such a call return
  /// (still emitting nothing) so the wedge ends with the test.
  bool discoveryNeverResolves = false;

  /// After each discovery answer, drop the link this long later, with the
  /// NULL reason code and string flutter_blue_plus_linux reports for every
  /// disconnect (BlueZ's Connected property carries no reason).
  ///
  /// The tail of bluetoothd's stall: its GATT client gives up and flags the
  /// device resolved while the link is still up, and the kernel drops the
  /// now idle link about 2 s later.
  Duration? dropLinkAfterDiscovery;

  /// Answer `readRssi` with this error string instead of [rssi].
  String? rssiError;

  /// Whether a CCCD write is confirmed back to the central.
  ///
  /// Real controllers confirm. False models a platform that says it wrote
  /// the CCCD — `setNotifyValue` returns true, so flutter_blue_plus waits for
  /// the descriptor-written event — and then never emits that event: the
  /// subscription is live, and the wait times out AFTER it worked. That was
  /// flutter_blue_plus_linux 3.0.2. The 7.0.3 the app ships returns false and
  /// never makes flutter_blue_plus wait (see
  /// [EmulatedCharacteristic.exposesCccd]), but a backend that never confirms
  /// is still the case RealBleService's spurious-timeout tolerance is for.
  bool confirmsCccdWrites = true;

  /// Confirm CCCD writes, but only after this long — a peripheral acking late.
  ///
  /// Real controllers do this on a congested link or a slow peripheral, and
  /// it is the only platform-neutral way to hold an enable IN FLIGHT for a
  /// known window: [confirmsCccdWrites] `= false` also opens a window, but
  /// its length is `RealBleService`'s confirmation timeout, which is 3 s on
  /// Linux and 15 s everywhere else, so a test built on it either fails or
  /// has to skip itself off Linux. Ignored when [confirmsCccdWrites] is
  /// false; null confirms at the adapter's ordinary [EmulatedBleAdapter.latency].
  Duration? cccdConfirmDelay;

  /// Whether this peripheral's attributes demand an authenticated (paired)
  /// link.
  ///
  /// Plenty of BLE devices do — anything with a lock, a payment function or a
  /// vendor that read the security guidelines — and plenty do not. The
  /// difference is invisible until a GATT operation is attempted: the
  /// peripheral advertises, connects and answers service discovery exactly the
  /// same either way, then answers the first read or write with ATT error 0x05
  /// (insufficient authentication) instead of data. That asymmetry is the whole
  /// reason this knob exists — a test that only ever sees pairing-free devices
  /// never finds out what the app says when a real one refuses.
  ///
  /// Set [bondState] to [EmulatedBondState.bonded] (or let the central call
  /// createBond) and the same reads start working.
  bool requiresPairing = false;

  /// Whether an attempt to pair succeeds. False models a user declining the
  /// system pairing dialog, or a wrong PIN.
  bool acceptsPairing = true;

  /// Current bond state between this peripheral and the central.
  EmulatedBondState bondState = EmulatedBondState.none;

  bool _connected = false;
  bool get isConnected => _connected;

  EmulatedBleAdapter? _adapter;

  EmulatedPeripheral({
    required this.id,
    required this.name,
    String? advName,
    this.rssi = -55,
    this.connectable = true,
    this.mtu = 23,
    this.requiresPairing = false,
    List<EmulatedService>? services,
  }) : advName = advName ?? name,
       services = services ?? [];

  /// A peripheral shaped like the app's example bulb spec: a vendor control
  /// service (write-without-response command + readable/notifiable state) and a
  /// standard Battery Service.
  factory EmulatedPeripheral.bulb({
    required String id,
    String name = 'ACME_Living_Room',
    String? advName,
    int rssi = -45,
    int mtu = 512,
    List<int> state = const [1, 80, 255, 180, 50],
    int batteryLevel = 85,
    bool requiresPairing = false,
  }) {
    return EmulatedPeripheral(
      id: id,
      name: name,
      advName: advName,
      rssi: rssi,
      mtu: mtu,
      requiresPairing: requiresPairing,
      services: [
        EmulatedService(
          uuid: EmulatedUuids.controlService,
          characteristics: [
            EmulatedCharacteristic(
              uuid: EmulatedUuids.controlCommand,
              canWriteWithoutResponse: true,
            ),
            EmulatedCharacteristic(
              uuid: EmulatedUuids.controlState,
              value: state,
              canRead: true,
              canNotify: true,
            ),
          ],
        ),
        EmulatedService(
          uuid: EmulatedUuids.batteryService,
          characteristics: [
            EmulatedCharacteristic(
              uuid: EmulatedUuids.batteryLevel,
              value: [batteryLevel],
              canRead: true,
              canNotify: true,
            ),
          ],
        ),
      ],
    );
  }

  /// Find a characteristic by UUID, ignoring case and 16-bit/128-bit form.
  EmulatedCharacteristic? characteristic(String uuid) {
    final wanted = Guid(uuid).str128;
    for (final service in services) {
      for (final char in service.characteristics) {
        if (Guid(char.uuid).str128 == wanted) return char;
      }
    }
    return null;
  }

  /// The error every GATT operation must answer with while this peripheral
  /// insists on a paired link it does not have, or null when operations may
  /// proceed.
  ///
  /// Service discovery deliberately does NOT consult this: on real hardware the
  /// GATT table is readable unencrypted, and it is the first read or write that
  /// gets refused. Testing the refusal anywhere earlier would be testing a
  /// device that does not exist.
  EmulatedGattError? get _pairingBarrier =>
      requiresPairing && bondState != EmulatedBondState.bonded
      ? EmulatedGattError.insufficientAuthentication
      : null;

  /// The characteristic a request addresses: by service and characteristic
  /// UUID, then [instanceId] among that service's same-UUID characteristics.
  ///
  /// Counted here rather than read back from
  /// [EmulatedCharacteristic.instanceId] so the answer does not depend on a
  /// discovery having run first — it is the same numbering [_gattTable]
  /// hands out either way, so a request carrying the id discovery reported
  /// reaches that twin, not the first one.
  EmulatedCharacteristic? _lookup(
    Guid service,
    Guid characteristic,
    int instanceId,
  ) {
    final wanted = characteristic.str128;
    for (final s in services) {
      if (Guid(s.uuid).str128 != service.str128) continue;
      var index = 0;
      for (final c in s.characteristics) {
        if (Guid(c.uuid).str128 != wanted) continue;
        if (index == instanceId) return c;
        index += 1;
      }
    }
    return null;
  }

  /// Push a notification for [charUuid], as a sensor would.
  ///
  /// Silently dropped when the central has not subscribed or the link is down —
  /// same as the radio. Tests asserting that a subscription is live should
  /// assert on what the app received, not on this call.
  void pushNotification(String charUuid, List<int> value) {
    final char = characteristic(charUuid);
    if (char == null) throw StateError('No such characteristic: $charUuid');
    char.value = List<int>.of(value);
    if (!_connected || !char.isNotifying) return;
    _adapter?._emitCharacteristicValue(this, char, value);
  }

  /// Drop the link from the peripheral's side, the way a device that is
  /// unplugged or walks out of range does.
  ///
  /// The default reason is HCI 0x13, remote user terminated, as Android
  /// reports it. Pass nulls for what flutter_blue_plus_linux reports for
  /// every disconnect.
  void dropLink({
    int? reasonCode = 19,
    String? reason = 'REMOTE_USER_TERMINATED',
  }) {
    if (!_connected) return;
    _adapter?._setConnectionState(
      this,
      false,
      reasonCode: reasonCode,
      reason: reason,
    );
  }

  /// The platform noticing a link it did not open.
  ///
  /// flutter_blue_plus_linux emits `connected` for any device whose BlueZ
  /// Connected property turns true — including a link our own raw L2CAP ATT
  /// socket brought up, which bluetoothd sees as an ACL like any other. So:
  /// no platform call, no MTU report, no reason, just the event.
  ///
  /// Emits unconditionally — a test calls this to stage exactly that event —
  /// and marks the peripheral connected, so [EmulatedBleAdapter.reset]
  /// disconnects it like any other.
  void reportLinkUp() => _adapter?._setConnectionState(this, true);

  /// The counterpart of [reportLinkUp]: a link someone else held went down,
  /// reported with the null reasons flutter_blue_plus_linux gives. Ends
  /// every subscription, as a real drop does. Emits unconditionally too.
  void reportLinkDown() => _adapter?._setConnectionState(this, false);

  /// Advertise once, so a scan in progress sees this device (again).
  ///
  /// Handing the test the trigger — rather than running a timer — is what keeps
  /// scan assertions deterministic: an "advertisement" is a line in the test.
  void advertise({int? rssi}) {
    if (rssi != null) this.rssi = rssi;
    _adapter?._emitAdvertisement(this);
  }

  BmScanAdvertisement get _advertisement => BmScanAdvertisement(
    remoteId: DeviceIdentifier(id),
    platformName: name,
    advName: advName,
    connectable: connectable,
    txPowerLevel: null,
    appearance: null,
    manufacturerData: manufacturerData,
    serviceData: const {},
    serviceUuids: [for (final s in services) Guid(s.uuid)],
    rssi: rssi,
  );

  List<BmBluetoothService> get _gattTable {
    // Numbered per (service, uuid) as the table is built, so a service that
    // declares the same characteristic twice gets 0 and 1 — and the numbers
    // stay put for the peripheral's life, because a subscription addressed to
    // instance 1 has to keep meaning the same attribute. Keyed on the 128-bit
    // form, so a short and a long spelling of one UUID are twins too, and
    // matching what [_lookup] counts.
    for (final service in services) {
      final seen = <String, int>{};
      for (final char in service.characteristics) {
        final key = Guid(char.uuid).str128;
        char.instanceId = seen[key] ?? 0;
        seen[key] = char.instanceId + 1;
      }
    }
    return [
      for (final service in services)
        BmBluetoothService(
          remoteId: DeviceIdentifier(id),
          serviceUuid: Guid(service.uuid),
          // null means "primary". flutter_blue_plus filters discovery results
          // down to primary services, so a non-null value here would make the
          // service vanish from discoverServices().
          primaryServiceUuid: null,
          characteristics: [
            for (final char in service.characteristics)
              BmBluetoothCharacteristic(
                remoteId: DeviceIdentifier(id),
                serviceUuid: Guid(service.uuid),
                characteristicUuid: Guid(char.uuid),
                instanceId: char.instanceId,
                primaryServiceUuid: null,
                descriptors: [
                  if (char.exposesCccd)
                    BmBluetoothDescriptor(
                      remoteId: DeviceIdentifier(id),
                      serviceUuid: Guid(service.uuid),
                      characteristicUuid: Guid(char.uuid),
                      instanceId: char.instanceId,
                      descriptorUuid: Guid(EmulatedUuids.cccd),
                      primaryServiceUuid: null,
                    ),
                ],
                properties: char._properties,
              ),
          ],
        ),
    ];
  }
}

/// An emulated BLE controller, installed as flutter_blue_plus's platform
/// implementation. See the file header for why it is a singleton.
final class EmulatedBleAdapter extends FlutterBluePlusPlatform {
  static EmulatedBleAdapter? _installed;

  /// Install (once per process) and return the emulated controller.
  ///
  /// Safe to call from every `setUpAll`: the second and later calls return the
  /// same instance, which is required — flutter_blue_plus binds to the platform
  /// instance's streams exactly once and would never see a replacement's
  /// events.
  static EmulatedBleAdapter install() {
    final existing = _installed;
    if (existing != null) return existing;
    final adapter = EmulatedBleAdapter._();
    _installed = adapter;
    FlutterBluePlusPlatform.instance = adapter;
    return adapter;
  }

  EmulatedBleAdapter._();

  // Broadcast, because flutter_blue_plus listens to each of these both once at
  // init and again per in-flight request.
  final _adapterStateController =
      StreamController<BmBluetoothAdapterState>.broadcast();
  final _scanController = StreamController<BmScanResponse>.broadcast();
  final _connectionController =
      StreamController<BmConnectionStateResponse>.broadcast();
  final _discoverController =
      StreamController<BmDiscoverServicesResult>.broadcast();
  final _charReceivedController =
      StreamController<BmCharacteristicData>.broadcast();
  final _charWrittenController =
      StreamController<BmCharacteristicData>.broadcast();
  final _descWrittenController = StreamController<BmDescriptorData>.broadcast();
  final _mtuController = StreamController<BmMtuChangedResponse>.broadcast();
  final _bondController = StreamController<BmBondStateResponse>.broadcast();
  final _servicesResetController =
      StreamController<BmBluetoothDevice>.broadcast();
  final _rssiController = StreamController<BmReadRssiResult>.broadcast();

  final Map<String, EmulatedPeripheral> _peripherals = {};

  /// Every Timer this adapter has started and not yet seen fire, so [reset]
  /// can cancel them all.
  final Set<Timer> _timers = {};

  /// Bumped by [reset]. A deferred reply that is not a Timer — a microtask
  /// at zero [latency], or a platform call resuming from an await — checks
  /// it before emitting, so it too dies with the test that scheduled it.
  int _generation = 0;

  /// `discoverServices` calls held inside the platform call by
  /// [EmulatedPeripheral.discoveryBlocksFor], each completed true when its
  /// wait is over (answer) or false by [reset] (return silently).
  final Set<Completer<bool>> _blockedDiscoveries = {};

  /// `discoverServices` calls held by
  /// [EmulatedPeripheral.discoveryNeverResolves]. Nothing but a release ever
  /// completes these, and a release always means "return silently".
  final Set<Completer<bool>> _hungDiscoveries = {};

  /// flutter_blue_plus_linux 7.0.3's `connect` on a device that is already
  /// connected: BlueZ's Device1.Connect succeeds at once and the plugin
  /// returns true, so flutter_blue_plus waits for a connection event that
  /// never comes, times out, and then DISCONNECTS the link it was told was
  /// fine. Off, such a connect answers false ("no change"), as iOS and
  /// Android do. [reset] turns it back off.
  bool connectReturnsTrueWhenConnected = false;

  /// flutter_blue_plus_linux 7.0.3's `disconnect` on a known device that is
  /// not connected: Device1.Disconnect succeeds at once and the plugin
  /// returns true, so flutter_blue_plus waits its whole disconnect timeout
  /// (35 s by default) for an event that never comes. Off, such a disconnect
  /// answers false. [reset] turns it back off.
  bool disconnectReturnsTrueWhenDisconnected = false;

  /// Whether flutter_blue_plus has bound to this adapter: its one-time init
  /// subscribes to the connection-state stream and never lets go, so a
  /// listener there means the binding has happened and is permanent.
  ///
  /// For a harness that installs a different platform instance on top of
  /// this one — that only works BEFORE the binding, since flutter_blue_plus
  /// would keep its bookkeeping on whichever instance it bound to first.
  bool get debugHasListeners => _connectionController.hasListener;

  /// How many `discoverServices` calls
  /// [EmulatedPeripheral.discoveryNeverResolves] is holding right now.
  int get hungDiscoveries => _hungDiscoveries.length;

  /// Let every `discoverServices` call held by
  /// [EmulatedPeripheral.discoveryNeverResolves] return, still emitting
  /// nothing. Returns how many were released.
  ///
  /// flutter_blue_plus then waits for the answer that was never sent, so
  /// release once the link is down — flutter_blue_plus then fails the call
  /// at once as "device is disconnected" — or it keeps its "global" mutex for
  /// its full discovery timeout.
  int releaseHungDiscoveries() => _release(_hungDiscoveries);

  int _release(Set<Completer<bool>> held) {
    final count = held.length;
    for (final call in held) {
      if (!call.isCompleted) call.complete(false);
    }
    held.clear();
    return count;
  }

  BmAdapterStateEnum _adapterState = BmAdapterStateEnum.on;

  bool _scanning = false;

  /// Injected failure for the NEXT `startScan`, delivered the way the platform
  /// delivers one: as an unsuccessful scan response.
  EmulatedGattError? scanError;

  /// Injected REFUSAL of the next `startScan` — the request never starts a
  /// scan at all, as when Android answers `startScan` with an error string.
  ///
  /// Distinct from [scanError], and the distinction matters: a refusal
  /// propagates out of `FlutterBluePlus.startScan` itself, which unwinds its
  /// own scan state on the way, so the caller is left with no scan running
  /// rather than a running scan that reported a failure.
  Object? startScanRefusal;

  /// Requests seen, newest last. Lets a test assert that the app stopped a
  /// native scan, or connected exactly once.
  final List<String> platformCalls = [];

  /// Settings the most recent `startScan` was asked for.
  ///
  /// The shape of a scan is as load-bearing as its results: without continuous
  /// updates a real controller reports each device once and then suppresses it,
  /// which no amount of listening on this side can undo.
  BmScanSettings? lastScanSettings;

  /// How long the emulated controller takes to answer. Zero keeps tests fast;
  /// raise it to open a window where a request is genuinely in flight.
  Duration latency = Duration.zero;

  /// The radio's power/authorization state. Assigning emits the change, so
  /// flutter_blue_plus's cached `adapterStateNow` follows it.
  BmAdapterStateEnum get adapterState => _adapterState;
  set adapterState(BmAdapterStateEnum state) {
    _adapterState = state;
    _adapterStateController.add(BmBluetoothAdapterState(adapterState: state));
  }

  /// Register a peripheral so scans can find it. Returns it for chaining.
  EmulatedPeripheral add(EmulatedPeripheral peripheral) {
    peripheral._adapter = this;
    _peripherals[peripheral.id] = peripheral;
    return peripheral;
  }

  EmulatedPeripheral? peripheral(String id) => _peripherals[id];

  /// Return the controller to a clean slate between tests.
  ///
  /// Disconnects anything still connected FIRST and lets the events drain,
  /// because flutter_blue_plus keeps its own per-device caches (connection
  /// state, last characteristic values, subscriptions) and clears them on the
  /// disconnect event — not on anything this file can call directly.
  ///
  /// A WIDGET TEST MUST STILL DISPOSE ITS TREE BEFORE THE TEST BODY ENDS —
  /// `await tester.pumpWidget(const SizedBox.shrink())` and a few pumps — and
  /// this cannot do it for you. A screen that owns a connection disconnects in
  /// `dispose()`, and if that lands after the last pump, the reply is never
  /// delivered and never awaited: flutter_blue_plus is left waiting for a
  /// disconnect event forever while HOLDING its internal per-operation mutex,
  /// and the NEXT test's `connect()` — which takes that same mutex first thing
  /// — blocks until its own timeout. The symptom is a later test that hangs on
  /// a connect that worked fine when the file ran it alone.
  ///
  /// Every reply still pending from the previous test is cancelled before
  /// anything else happens, and every `discoverServices` call held inside
  /// the platform ([EmulatedPeripheral.discoveryBlocksFor],
  /// [EmulatedPeripheral.discoveryNeverResolves]) returns without answering.
  Future<void> reset() async {
    // First, before anything can fire: nothing the previous test scheduled
    // may emit from here on. Cancelling covers the timers; the generation
    // covers a microtask already queued and a call resuming from an await.
    _cancelPending();
    for (final peripheral in _peripherals.values) {
      if (peripheral._connected) {
        _setConnectionState(
          peripheral,
          false,
          reasonCode: 0,
          reason: 'test reset',
        );
      }
      // Bond state is cached per remote id inside flutter_blue_plus and read
      // only when it has none, so a device left bonded would still look bonded
      // to the next test that reuses the id. Unbond it out loud.
      if (peripheral.bondState != EmulatedBondState.none) {
        _setBondState(peripheral, EmulatedBondState.none);
      }
    }
    // After the disconnects are queued: flutter_blue_plus starts waiting for
    // a discovery answer only once the platform call returns, and by then it
    // has seen the device go, so it fails the call at once rather than
    // holding its "global" mutex for its discovery timeout.
    _release(_blockedDiscoveries);
    _release(_hungDiscoveries);
    // Two turns of the event loop: one to deliver the disconnects, one for the
    // `Future.delayed(Duration.zero)` flutter_blue_plus itself schedules when
    // it tears down delayed subscriptions.
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    _peripherals.clear();
    platformCalls.clear();
    lastScanSettings = null;
    scanError = null;
    startScanRefusal = null;
    latency = Duration.zero;
    connectReturnsTrueWhenConnected = false;
    disconnectReturnsTrueWhenDisconnected = false;
    _scanning = false;
    adapterState = BmAdapterStateEnum.on;
    await Future<void>.delayed(Duration.zero);
  }

  /// Close the event streams. Only useful at the very end of a test process;
  /// flutter_blue_plus cannot be re-bound to a fresh adapter afterwards.
  Future<void> dispose() async {
    _cancelPending();
    _release(_blockedDiscoveries);
    _release(_hungDiscoveries);
    await _adapterStateController.close();
    await _scanController.close();
    await _connectionController.close();
    await _discoverController.close();
    await _charReceivedController.close();
    await _charWrittenController.close();
    await _descWrittenController.close();
    await _mtuController.close();
    await _bondController.close();
    await _servicesResetController.close();
    await _rssiController.close();
  }

  /// The peripheral republished its GATT table — what CoreBluetooth reports
  /// as `didModifyServices` and the darwin plugin forwards as OnServicesReset.
  /// Nothing here changes the emulated table; the point is what the service
  /// does with its cache when told.
  void pushServicesReset(String deviceId) {
    if (_servicesResetController.isClosed) return;
    _servicesResetController.add(
      BmBluetoothDevice(
        remoteId: DeviceIdentifier(deviceId),
        platformName: _peripherals[deviceId]?.name,
      ),
    );
  }

  // ── event plumbing ────────────────────────────────────────────────────────

  /// Deliver [emit] after [latency], the way a controller answers a request
  /// asynchronously rather than inline. Never awaited by the caller: the point
  /// is that the platform call returns BEFORE its reply arrives, which is what
  /// makes flutter_blue_plus's request/response correlation run for real.
  ///
  /// Asynchronous delivery is also why a widget test must tear its tree down
  /// while it can still pump — see the note on [reset].
  void _later(void Function() emit) {
    if (latency == Duration.zero) {
      final generation = _generation;
      scheduleMicrotask(() {
        if (generation == _generation) emit();
      });
    } else {
      _startTimer(latency, emit);
    }
  }

  /// Run [fire] after [delay] on a Timer [reset] can cancel. Every timer this
  /// adapter starts goes through here.
  void _startTimer(Duration delay, void Function() fire) {
    final generation = _generation;
    late final Timer timer;
    timer = Timer(delay, () {
      _timers.remove(timer);
      if (generation == _generation) fire();
    });
    _timers.add(timer);
  }

  /// Cancel every pending timer and orphan every other deferred reply.
  void _cancelPending() {
    _generation += 1;
    for (final timer in _timers) {
      timer.cancel();
    }
    _timers.clear();
  }

  void _emitAdvertisement(EmulatedPeripheral peripheral) {
    if (!_scanning || _scanController.isClosed) return;
    _scanController.add(
      BmScanResponse(
        advertisements: [peripheral._advertisement],
        success: true,
        errorCode: 0,
        errorString: '',
      ),
    );
  }

  void _setConnectionState(
    EmulatedPeripheral peripheral,
    bool connected, {
    int? reasonCode,
    String? reason,
  }) {
    peripheral._connected = connected;
    if (!connected) {
      for (final service in peripheral.services) {
        for (final char in service.characteristics) {
          char.isNotifying = false;
        }
      }
    }
    if (_connectionController.isClosed) return;
    _connectionController.add(
      BmConnectionStateResponse(
        remoteId: DeviceIdentifier(peripheral.id),
        connectionState: connected
            ? BmConnectionStateEnum.connected
            : BmConnectionStateEnum.disconnected,
        disconnectReasonCode: reasonCode,
        disconnectReasonString: reason,
      ),
    );
  }

  void _setBondState(EmulatedPeripheral peripheral, EmulatedBondState state) {
    final previous = peripheral.bondState;
    peripheral.bondState = state;
    if (_bondController.isClosed) return;
    _bondController.add(
      BmBondStateResponse(
        remoteId: DeviceIdentifier(peripheral.id),
        bondState: state,
        prevState: previous,
      ),
    );
  }

  void _emitCharacteristicValue(
    EmulatedPeripheral peripheral,
    EmulatedCharacteristic char,
    List<int> value,
  ) {
    if (_charReceivedController.isClosed) return;
    _charReceivedController.add(
      BmCharacteristicData(
        remoteId: DeviceIdentifier(peripheral.id),
        serviceUuid: _serviceOf(peripheral, char),
        characteristicUuid: Guid(char.uuid),
        instanceId: char.instanceId,
        primaryServiceUuid: null,
        value: List<int>.of(value),
        success: true,
        errorCode: 0,
        errorString: '',
      ),
    );
  }

  Guid _serviceOf(EmulatedPeripheral peripheral, EmulatedCharacteristic char) {
    for (final service in peripheral.services) {
      if (service.characteristics.contains(char)) return Guid(service.uuid);
    }
    throw StateError('Characteristic ${char.uuid} belongs to no service');
  }

  // ── FlutterBluePlusPlatform ───────────────────────────────────────────────

  @override
  Stream<BmBluetoothAdapterState> get onAdapterStateChanged =>
      _adapterStateController.stream;

  @override
  Stream<BmScanResponse> get onScanResponse => _scanController.stream;

  @override
  Stream<BmConnectionStateResponse> get onConnectionStateChanged =>
      _connectionController.stream;

  @override
  Stream<BmDiscoverServicesResult> get onDiscoveredServices =>
      _discoverController.stream;

  @override
  Stream<BmCharacteristicData> get onCharacteristicReceived =>
      _charReceivedController.stream;

  @override
  Stream<BmCharacteristicData> get onCharacteristicWritten =>
      _charWrittenController.stream;

  @override
  Stream<BmDescriptorData> get onDescriptorWritten =>
      _descWrittenController.stream;

  @override
  Stream<BmMtuChangedResponse> get onMtuChanged => _mtuController.stream;

  @override
  Stream<BmBluetoothDevice> get onServicesReset =>
      _servicesResetController.stream;

  @override
  Stream<BmBondStateResponse> get onBondStateChanged => _bondController.stream;

  @override
  Stream<BmReadRssiResult> get onReadRssi => _rssiController.stream;

  @override
  Future<BmBondStateResponse> getBondState(BmBondStateRequest request) async {
    final peripheral = _peripherals[request.remoteId.str];
    return BmBondStateResponse(
      remoteId: request.remoteId,
      bondState: peripheral?.bondState ?? EmulatedBondState.none,
      prevState: null,
    );
  }

  @override
  Future<bool> createBond(BmCreateBondRequest request) async {
    platformCalls.add('createBond:${request.remoteId.str}');
    final peripheral = _peripherals[request.remoteId.str];
    if (peripheral == null) return false;
    // false means "no change" — flutter_blue_plus then skips the wait, which is
    // what an already-bonded device should produce.
    if (peripheral.bondState == EmulatedBondState.bonded) return false;

    _setBondState(peripheral, EmulatedBondState.bonding);
    _later(() {
      // Rejection lands back on `none`, which is what the platform reports when
      // the user dismisses the pairing dialog or the PIN is wrong;
      // flutter_blue_plus turns that into a createBond failure.
      _setBondState(
        peripheral,
        peripheral.acceptsPairing
            ? EmulatedBondState.bonded
            : EmulatedBondState.none,
      );
    });
    return true;
  }

  @override
  Future<bool> removeBond(BmRemoveBondRequest request) async {
    platformCalls.add('removeBond:${request.remoteId.str}');
    final peripheral = _peripherals[request.remoteId.str];
    if (peripheral == null || peripheral.bondState == EmulatedBondState.none) {
      return false;
    }
    _later(() => _setBondState(peripheral, EmulatedBondState.none));
    return true;
  }

  @override
  Future<bool> isSupported(BmIsSupportedRequest request) async => true;

  @override
  Future<bool> setLogLevel(BmSetLogLevelRequest request) async => true;

  @override
  Future<bool> setOptions(BmSetOptionsRequest request) async => true;

  @override
  Future<BmBluetoothAdapterState> getAdapterState(
    BmBluetoothAdapterStateRequest request,
  ) async => BmBluetoothAdapterState(adapterState: _adapterState);

  @override
  Future<BmDevicesList> getSystemDevices(
    BmSystemDevicesRequest request,
  ) async => BmDevicesList(devices: const []);

  @override
  Future<BmDevicesList> getBondedDevices(
    BmBondedDevicesRequest request,
  ) async => BmDevicesList(devices: const []);

  @override
  Future<bool> startScan(BmScanSettings request) async {
    platformCalls.add('startScan');
    lastScanSettings = request;
    final refusal = startScanRefusal;
    if (refusal != null) {
      startScanRefusal = null;
      _scanning = false;
      throw refusal;
    }
    // Honour [latency] like stopScan does, so a test can hold a start
    // genuinely in flight and interleave something else with it — the shape
    // of every teardown-races-restart bug.
    if (latency > Duration.zero) {
      final generation = _generation;
      await Future<void>.delayed(latency);
      // A reset landed while this start was in flight: the scan belonged to
      // the test that asked for it, and must not start hearing the devices
      // the next test registered.
      if (generation != _generation) return true;
    }
    _scanning = true;
    final failure = scanError;
    if (failure != null) {
      scanError = null;
      _later(() {
        if (_scanController.isClosed) return;
        _scanController.add(
          BmScanResponse(
            advertisements: const [],
            success: false,
            errorCode: failure.code,
            errorString: failure.message,
          ),
        );
      });
      return true;
    }
    // One advertisement per peripheral, each in its own response — real
    // controllers report advertisements one at a time and flutter_blue_plus is
    // what accumulates them into the list the app sees.
    //
    // A scan filtered to specific remote ids hears only those, as the
    // platforms do; an unfiltered scan hears everything, which is what every
    // other test here asks for.
    final wanted = request.withRemoteIds.toSet();
    for (final peripheral in _peripherals.values) {
      if (!peripheral.advertising) continue;
      if (wanted.isNotEmpty && !wanted.contains(peripheral.id)) continue;
      // Hearing a peripheral is what re-registers it with the system, which
      // is the whole reason the app scans before a second connect attempt.
      peripheral.unknownToSystem = false;
      _later(() => _emitAdvertisement(peripheral));
    }
    return true;
  }

  @override
  Future<bool> stopScan(BmStopScanRequest request) async {
    platformCalls.add('stopScan');
    _scanning = false;
    // Honour [latency] the way the request-carrying calls do, so a test can
    // hold a stop genuinely in flight and run something else during it. Skipped
    // entirely at zero so the default timing of every other test is unchanged.
    if (latency > Duration.zero) await Future<void>.delayed(latency);
    return true;
  }

  @override
  Future<bool> connect(BmConnectRequest request) async {
    platformCalls.add('connect:${request.remoteId.str}');
    final peripheral = _peripherals[request.remoteId.str];
    if (peripheral == null) {
      // Nothing there to answer — the same silence a connect to a device that
      // has gone away produces, which flutter_blue_plus turns into a timeout.
      return true;
    }
    // false means "no state change", which is flutter_blue_plus's signal to
    // skip waiting for a connection event. The Linux backend says true and
    // then has nothing to report — see [connectReturnsTrueWhenConnected].
    if (peripheral._connected) return connectReturnsTrueWhenConnected;

    // The system cannot resolve the identifier, so nothing is attempted on
    // air. flutter_blue_plus_darwin surfaces this as a plain FlutterError
    // with code `connect` (FlutterBluePlusPlugin.m), not a typed error — the
    // app matches on the message, so the message is what matters here.
    if (peripheral.unknownToSystem) {
      throw FlutterError(
        'FlutterBluePlus: connect: Peripheral not found (${peripheral.id})',
      );
    }

    final refusal = peripheral.connectError;
    _later(() {
      if (refusal != null) {
        _setConnectionState(
          peripheral,
          false,
          reasonCode: refusal.code,
          reason: refusal.message,
        );
        return;
      }
      _setConnectionState(peripheral, true);
      // Platforms report the negotiated MTU right after the link comes up;
      // RealBleService.mtu() reads exactly that cached value.
      if (!_mtuController.isClosed) {
        _mtuController.add(
          BmMtuChangedResponse(
            remoteId: DeviceIdentifier(peripheral.id),
            mtu: peripheral.mtu,
          ),
        );
      }
    });
    return true;
  }

  @override
  Future<bool> disconnect(BmDisconnectRequest request) async {
    platformCalls.add('disconnect:${request.remoteId.str}');
    final peripheral = _peripherals[request.remoteId.str];
    if (peripheral == null) return false;
    if (!peripheral._connected) return disconnectReturnsTrueWhenDisconnected;
    _later(
      () => _setConnectionState(
        peripheral,
        false,
        reasonCode: 0,
        reason: 'local disconnect',
      ),
    );
    return true;
  }

  @override
  Future<bool> requestMtu(BmMtuChangeRequest request) async {
    final peripheral = _peripherals[request.remoteId.str];
    if (peripheral == null) return false;
    // A peripheral grants at most what it supports, never more than asked.
    final granted = request.mtu < peripheral.mtu ? request.mtu : peripheral.mtu;
    _later(() {
      if (_mtuController.isClosed) return;
      _mtuController.add(
        BmMtuChangedResponse(
          remoteId: DeviceIdentifier(peripheral.id),
          mtu: granted,
        ),
      );
    });
    return true;
  }

  @override
  Future<bool> discoverServices(BmDiscoverServicesRequest request) async {
    platformCalls.add('discoverServices:${request.remoteId.str}');
    final peripheral = _peripherals[request.remoteId.str];
    if (peripheral == null) return false;

    if (peripheral.discoveryNeverResolves) {
      // Held until a release, which only ever means "return, say nothing".
      // Checked before the knobs below so a hung call consumes no answer.
      final hung = Completer<bool>();
      _hungDiscoveries.add(hung);
      await hung.future;
      return true;
    }

    final failure = peripheral.discoverError;
    final empty = peripheral.emptyDiscoveries > 0;
    if (empty) peripheral.emptyDiscoveries -= 1;

    final blockFor = peripheral.discoveryBlocksFor;
    if (blockFor != null) {
      // Awaited HERE, inside the platform call, which is the whole point:
      // flutter_blue_plus holds its mutexes until this returns.
      final held = Completer<bool>();
      _blockedDiscoveries.add(held);
      _startTimer(blockFor, () {
        if (!held.isCompleted) held.complete(true);
      });
      final answer = await held.future;
      _blockedDiscoveries.remove(held);
      if (!answer) return true;
    }

    _later(() {
      if (_discoverController.isClosed) return;
      _discoverController.add(
        BmDiscoverServicesResult(
          remoteId: DeviceIdentifier(peripheral.id),
          services: failure != null || empty ? const [] : peripheral._gattTable,
          success: failure == null,
          errorCode: failure?.code ?? 0,
          errorString: failure?.message ?? '',
        ),
      );
      final dropAfter = peripheral.dropLinkAfterDiscovery;
      if (dropAfter != null) {
        _startTimer(
          dropAfter,
          () => peripheral.dropLink(reasonCode: null, reason: null),
        );
      }
    });
    return true;
  }

  @override
  Future<bool> readCharacteristic(BmReadCharacteristicRequest request) async {
    final peripheral = _peripherals[request.remoteId.str];
    final char = peripheral?._lookup(
      request.serviceUuid,
      request.characteristicUuid,
      request.instanceId,
    );
    if (peripheral == null || char == null) return false;
    platformCalls.add('read:${Guid(char.uuid).str128}');

    final failure = peripheral._pairingBarrier ?? char.readError;
    _later(() {
      if (_charReceivedController.isClosed) return;
      _charReceivedController.add(
        BmCharacteristicData(
          remoteId: request.remoteId,
          serviceUuid: request.serviceUuid,
          characteristicUuid: request.characteristicUuid,
          instanceId: request.instanceId,
          primaryServiceUuid: request.primaryServiceUuid,
          value: failure != null ? const [] : List<int>.of(char.value),
          success: failure == null,
          errorCode: failure?.code ?? 0,
          errorString: failure?.message ?? '',
        ),
      );
    });
    return true;
  }

  @override
  Future<bool> writeCharacteristic(BmWriteCharacteristicRequest request) async {
    final peripheral = _peripherals[request.remoteId.str];
    final char = peripheral?._lookup(
      request.serviceUuid,
      request.characteristicUuid,
      request.instanceId,
    );
    if (peripheral == null || char == null) return false;
    platformCalls.add('write:${Guid(char.uuid).str128}');

    final failure = peripheral._pairingBarrier ?? char.writeError;
    if (failure == null) {
      char.writes.add((
        type: request.writeType,
        value: List<int>.of(request.value),
      ));
      char.value = List<int>.of(request.value);
    }
    _later(() {
      if (_charWrittenController.isClosed) return;
      _charWrittenController.add(
        BmCharacteristicData(
          remoteId: request.remoteId,
          serviceUuid: request.serviceUuid,
          characteristicUuid: request.characteristicUuid,
          instanceId: request.instanceId,
          primaryServiceUuid: request.primaryServiceUuid,
          value: List<int>.of(request.value),
          success: failure == null,
          errorCode: failure?.code ?? 0,
          errorString: failure?.message ?? '',
        ),
      );
    });
    return true;
  }

  @override
  Future<bool> setNotifyValue(BmSetNotifyValueRequest request) async {
    final peripheral = _peripherals[request.remoteId.str];
    final char = peripheral?._lookup(
      request.serviceUuid,
      request.characteristicUuid,
      request.instanceId,
    );
    if (peripheral == null || char == null) return false;
    platformCalls.add('setNotify:${Guid(char.uuid).str128}=${request.enable}');

    // Subscribing writes the CCCD, so an unpaired link is refused here too —
    // reported as a failed descriptor write, which is how the platform reports
    // it. The subscription does NOT take effect.
    final barrier = peripheral._pairingBarrier;
    if (barrier != null && request.enable) {
      _later(() {
        if (_descWrittenController.isClosed) return;
        _descWrittenController.add(
          BmDescriptorData(
            remoteId: request.remoteId,
            serviceUuid: request.serviceUuid,
            characteristicUuid: request.characteristicUuid,
            instanceId: request.instanceId,
            descriptorUuid: Guid(EmulatedUuids.cccd),
            primaryServiceUuid: request.primaryServiceUuid,
            value: const [],
            success: false,
            errorCode: barrier.code,
            errorString: barrier.message,
          ),
        );
      });
      return true;
    }

    char.isNotifying = request.enable;

    // The return value tells flutter_blue_plus whether to wait for a CCCD
    // confirmation at all. A peripheral without a CCCD (or a backend that
    // writes it itself and says so, as flutter_blue_plus_linux 7.0.3 does)
    // reports false and the call resolves immediately.
    if (!char.exposesCccd) return false;
    if (!peripheral.confirmsCccdWrites) {
      // Subscription applied, confirmation never sent: flutter_blue_plus
      // waits until its own timeout, then reports a failure for a
      // subscription that is live — see [confirmsCccdWrites].
      return true;
    }
    void confirm() {
      if (_descWrittenController.isClosed) return;
      _descWrittenController.add(
        BmDescriptorData(
          remoteId: request.remoteId,
          serviceUuid: request.serviceUuid,
          characteristicUuid: request.characteristicUuid,
          instanceId: request.instanceId,
          descriptorUuid: Guid(EmulatedUuids.cccd),
          primaryServiceUuid: request.primaryServiceUuid,
          value: request.enable ? const [1, 0] : const [0, 0],
          success: true,
          errorCode: 0,
          errorString: '',
        ),
      );
    }

    final delay = peripheral.cccdConfirmDelay;
    if (delay != null) {
      _startTimer(delay, confirm);
    } else {
      _later(confirm);
    }
    return true;
  }

  /// Answers with [EmulatedPeripheral.rssi], or fails with
  /// [EmulatedPeripheral.rssiError].
  ///
  /// flutter_blue_plus waits for an `onReadRssi` event whatever this returns,
  /// so the answer always comes — without it a readRssi would sit out its
  /// 15 s timeout holding the "global" mutex. The error code is 0 because
  /// that is what flutter_blue_plus_linux reports for any failure; only the
  /// string carries information.
  @override
  Future<bool> readRssi(BmReadRssiRequest request) async {
    platformCalls.add('readRssi:${request.remoteId.str}');
    final peripheral = _peripherals[request.remoteId.str];
    if (peripheral == null) return false;
    _later(() {
      if (_rssiController.isClosed) return;
      final failure = peripheral.rssiError;
      _rssiController.add(
        BmReadRssiResult(
          remoteId: request.remoteId,
          rssi: failure != null ? 0 : peripheral.rssi,
          success: failure == null,
          errorCode: 0,
          errorString: failure ?? '',
        ),
      );
    });
    return true;
  }
}
