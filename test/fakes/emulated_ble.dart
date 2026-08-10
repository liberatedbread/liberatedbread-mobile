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

import 'dart:async';

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
  /// writes to subscribe. flutter_blue_plus waits for the write to be confirmed
  /// before `setNotifyValue` resolves.
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
  static const insufficientAuthentication =
      EmulatedGattError(5, 'GATT_INSUFFICIENT_AUTHENTICATION');

  /// ATT error 0x0F: the link is paired but not encrypted to the level the
  /// attribute demands. Reaches the app through the same route as
  /// [insufficientAuthentication] and wants the same recovery.
  static const insufficientEncryption =
      EmulatedGattError(15, 'GATT_INSUFFICIENT_ENCRYPTION');
}

/// A characteristic in an emulated peripheral's GATT table.
class EmulatedCharacteristic {
  final String uuid;

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
  /// platform reports no CCCD. BlueZ, for one, manages the CCCD internally and
  /// never surfaces it — which is the root of the Linux quirk
  /// [isSpuriousLinuxNotifyTimeout] exists for.
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
  })  : value = List<int>.of(value),
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
  String name;
  int rssi;
  bool connectable;

  /// ATT MTU reported once connected. 23 is the BLE floor; real links usually
  /// negotiate higher.
  int mtu;

  final List<EmulatedService> services;

  /// Refuse the next connection with this GATT error, the way a peripheral that
  /// is out of range or already connected elsewhere does.
  EmulatedGattError? connectError;

  /// Answer this many `discoverServices` requests with an EMPTY service list
  /// before answering truthfully.
  ///
  /// This is not a hypothetical: flutter_blue_plus's Linux backend answers
  /// discovery from BlueZ's current object tree without waiting for the
  /// ServicesResolved flag, so a discovery issued right after connect sees
  /// nothing. [nextEmptyDiscoveryRetryDelay] is the app's answer to it, and
  /// this is how a test gets to watch that ladder run.
  int emptyDiscoveries = 0;

  /// Fail `discoverServices` outright.
  EmulatedGattError? discoverError;

  /// Whether a CCCD write is confirmed back to the central.
  ///
  /// Real controllers confirm. flutter_blue_plus_linux does NOT — it applies
  /// the subscription synchronously and never emits the descriptor-written
  /// event flutter_blue_plus is waiting for, so every `setNotifyValue` on Linux
  /// times out AFTER having succeeded. Set false to reproduce that.
  bool confirmsCccdWrites = true;

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
    this.rssi = -55,
    this.connectable = true,
    this.mtu = 23,
    this.requiresPairing = false,
    List<EmulatedService>? services,
  }) : services = services ?? [];

  /// A peripheral shaped like the app's example bulb spec: a vendor control
  /// service (write-without-response command + readable/notifiable state) and a
  /// standard Battery Service.
  factory EmulatedPeripheral.bulb({
    required String id,
    String name = 'ACME_Living_Room',
    int rssi = -45,
    int mtu = 512,
    List<int> state = const [1, 80, 255, 180, 50],
    int batteryLevel = 85,
    bool requiresPairing = false,
  }) {
    return EmulatedPeripheral(
      id: id,
      name: name,
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

  EmulatedCharacteristic? _lookup(Guid service, Guid characteristic) {
    for (final s in services) {
      if (Guid(s.uuid).str128 != service.str128) continue;
      for (final c in s.characteristics) {
        if (Guid(c.uuid).str128 == characteristic.str128) return c;
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
  void dropLink(
      {int reasonCode = 19, String reason = 'REMOTE_USER_TERMINATED'}) {
    if (!_connected) return;
    _adapter?._setConnectionState(this, false,
        reasonCode: reasonCode, reason: reason);
  }

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
        advName: name,
        connectable: connectable,
        txPowerLevel: null,
        appearance: null,
        manufacturerData: const {},
        serviceData: const {},
        serviceUuids: [for (final s in services) Guid(s.uuid)],
        rssi: rssi,
      );

  List<BmBluetoothService> get _gattTable => [
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
                  primaryServiceUuid: null,
                  descriptors: [
                    if (char.exposesCccd)
                      BmBluetoothDescriptor(
                        remoteId: DeviceIdentifier(id),
                        serviceUuid: Guid(service.uuid),
                        characteristicUuid: Guid(char.uuid),
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

  final Map<String, EmulatedPeripheral> _peripherals = {};

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
  Future<void> reset() async {
    for (final peripheral in _peripherals.values) {
      if (peripheral._connected) {
        _setConnectionState(peripheral, false,
            reasonCode: 0, reason: 'test reset');
      }
      // Bond state is cached per remote id inside flutter_blue_plus and read
      // only when it has none, so a device left bonded would still look bonded
      // to the next test that reuses the id. Unbond it out loud.
      if (peripheral.bondState != EmulatedBondState.none) {
        _setBondState(peripheral, EmulatedBondState.none);
      }
    }
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
    _scanning = false;
    adapterState = BmAdapterStateEnum.on;
    await Future<void>.delayed(Duration.zero);
  }

  /// Close the event streams. Only useful at the very end of a test process;
  /// flutter_blue_plus cannot be re-bound to a fresh adapter afterwards.
  Future<void> dispose() async {
    await _adapterStateController.close();
    await _scanController.close();
    await _connectionController.close();
    await _discoverController.close();
    await _charReceivedController.close();
    await _charWrittenController.close();
    await _descWrittenController.close();
    await _mtuController.close();
    await _bondController.close();
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
      scheduleMicrotask(emit);
    } else {
      Timer(latency, emit);
    }
  }

  void _emitAdvertisement(EmulatedPeripheral peripheral) {
    if (!_scanning || _scanController.isClosed) return;
    _scanController.add(BmScanResponse(
      advertisements: [peripheral._advertisement],
      success: true,
      errorCode: 0,
      errorString: '',
    ));
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
    _connectionController.add(BmConnectionStateResponse(
      remoteId: DeviceIdentifier(peripheral.id),
      connectionState: connected
          ? BmConnectionStateEnum.connected
          : BmConnectionStateEnum.disconnected,
      disconnectReasonCode: reasonCode,
      disconnectReasonString: reason,
    ));
  }

  void _setBondState(EmulatedPeripheral peripheral, EmulatedBondState state) {
    final previous = peripheral.bondState;
    peripheral.bondState = state;
    if (_bondController.isClosed) return;
    _bondController.add(BmBondStateResponse(
      remoteId: DeviceIdentifier(peripheral.id),
      bondState: state,
      prevState: previous,
    ));
  }

  void _emitCharacteristicValue(
    EmulatedPeripheral peripheral,
    EmulatedCharacteristic char,
    List<int> value,
  ) {
    if (_charReceivedController.isClosed) return;
    _charReceivedController.add(BmCharacteristicData(
      remoteId: DeviceIdentifier(peripheral.id),
      serviceUuid: _serviceOf(peripheral, char),
      characteristicUuid: Guid(char.uuid),
      primaryServiceUuid: null,
      value: List<int>.of(value),
      success: true,
      errorCode: 0,
      errorString: '',
    ));
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
  Stream<BmBondStateResponse> get onBondStateChanged => _bondController.stream;

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
  ) async =>
      BmBluetoothAdapterState(adapterState: _adapterState);

  @override
  Future<BmDevicesList> getSystemDevices(
          BmSystemDevicesRequest request) async =>
      BmDevicesList(devices: const []);

  @override
  Future<BmDevicesList> getBondedDevices(
          BmBondedDevicesRequest request) async =>
      BmDevicesList(devices: const []);

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
    _scanning = true;
    final failure = scanError;
    if (failure != null) {
      scanError = null;
      _later(() {
        if (_scanController.isClosed) return;
        _scanController.add(BmScanResponse(
          advertisements: const [],
          success: false,
          errorCode: failure.code,
          errorString: failure.message,
        ));
      });
      return true;
    }
    // One advertisement per peripheral, each in its own response — real
    // controllers report advertisements one at a time and flutter_blue_plus is
    // what accumulates them into the list the app sees.
    for (final peripheral in _peripherals.values) {
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
    // skip waiting for a connection event.
    if (peripheral._connected) return false;

    final refusal = peripheral.connectError;
    _later(() {
      if (refusal != null) {
        _setConnectionState(peripheral, false,
            reasonCode: refusal.code, reason: refusal.message);
        return;
      }
      _setConnectionState(peripheral, true);
      // Platforms report the negotiated MTU right after the link comes up;
      // RealBleService.mtu() reads exactly that cached value.
      if (!_mtuController.isClosed) {
        _mtuController.add(BmMtuChangedResponse(
          remoteId: DeviceIdentifier(peripheral.id),
          mtu: peripheral.mtu,
        ));
      }
    });
    return true;
  }

  @override
  Future<bool> disconnect(BmDisconnectRequest request) async {
    platformCalls.add('disconnect:${request.remoteId.str}');
    final peripheral = _peripherals[request.remoteId.str];
    if (peripheral == null || !peripheral._connected) return false;
    _later(() => _setConnectionState(peripheral, false,
        reasonCode: 0, reason: 'local disconnect'));
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
      _mtuController.add(BmMtuChangedResponse(
        remoteId: DeviceIdentifier(peripheral.id),
        mtu: granted,
      ));
    });
    return true;
  }

  @override
  Future<bool> discoverServices(BmDiscoverServicesRequest request) async {
    platformCalls.add('discoverServices:${request.remoteId.str}');
    final peripheral = _peripherals[request.remoteId.str];
    if (peripheral == null) return false;

    final failure = peripheral.discoverError;
    final empty = peripheral.emptyDiscoveries > 0;
    if (empty) peripheral.emptyDiscoveries -= 1;

    _later(() {
      if (_discoverController.isClosed) return;
      _discoverController.add(BmDiscoverServicesResult(
        remoteId: DeviceIdentifier(peripheral.id),
        services: failure != null || empty ? const [] : peripheral._gattTable,
        success: failure == null,
        errorCode: failure?.code ?? 0,
        errorString: failure?.message ?? '',
      ));
    });
    return true;
  }

  @override
  Future<bool> readCharacteristic(BmReadCharacteristicRequest request) async {
    final peripheral = _peripherals[request.remoteId.str];
    final char =
        peripheral?._lookup(request.serviceUuid, request.characteristicUuid);
    if (peripheral == null || char == null) return false;
    platformCalls.add('read:${Guid(char.uuid).str128}');

    final failure = peripheral._pairingBarrier ?? char.readError;
    _later(() {
      if (_charReceivedController.isClosed) return;
      _charReceivedController.add(BmCharacteristicData(
        remoteId: request.remoteId,
        serviceUuid: request.serviceUuid,
        characteristicUuid: request.characteristicUuid,
        primaryServiceUuid: request.primaryServiceUuid,
        value: failure != null ? const [] : List<int>.of(char.value),
        success: failure == null,
        errorCode: failure?.code ?? 0,
        errorString: failure?.message ?? '',
      ));
    });
    return true;
  }

  @override
  Future<bool> writeCharacteristic(BmWriteCharacteristicRequest request) async {
    final peripheral = _peripherals[request.remoteId.str];
    final char =
        peripheral?._lookup(request.serviceUuid, request.characteristicUuid);
    if (peripheral == null || char == null) return false;
    platformCalls.add('write:${Guid(char.uuid).str128}');

    final failure = peripheral._pairingBarrier ?? char.writeError;
    if (failure == null) {
      char.writes
          .add((type: request.writeType, value: List<int>.of(request.value)));
      char.value = List<int>.of(request.value);
    }
    _later(() {
      if (_charWrittenController.isClosed) return;
      _charWrittenController.add(BmCharacteristicData(
        remoteId: request.remoteId,
        serviceUuid: request.serviceUuid,
        characteristicUuid: request.characteristicUuid,
        primaryServiceUuid: request.primaryServiceUuid,
        value: List<int>.of(request.value),
        success: failure == null,
        errorCode: failure?.code ?? 0,
        errorString: failure?.message ?? '',
      ));
    });
    return true;
  }

  @override
  Future<bool> setNotifyValue(BmSetNotifyValueRequest request) async {
    final peripheral = _peripherals[request.remoteId.str];
    final char =
        peripheral?._lookup(request.serviceUuid, request.characteristicUuid);
    if (peripheral == null || char == null) return false;
    platformCalls.add('setNotify:${Guid(char.uuid).str128}=${request.enable}');

    // Subscribing writes the CCCD, so an unpaired link is refused here too —
    // reported as a failed descriptor write, which is how the platform reports
    // it. The subscription does NOT take effect.
    final barrier = peripheral._pairingBarrier;
    if (barrier != null && request.enable) {
      _later(() {
        if (_descWrittenController.isClosed) return;
        _descWrittenController.add(BmDescriptorData(
          remoteId: request.remoteId,
          serviceUuid: request.serviceUuid,
          characteristicUuid: request.characteristicUuid,
          descriptorUuid: Guid(EmulatedUuids.cccd),
          primaryServiceUuid: request.primaryServiceUuid,
          value: const [],
          success: false,
          errorCode: barrier.code,
          errorString: barrier.message,
        ));
      });
      return true;
    }

    char.isNotifying = request.enable;

    // The return value tells flutter_blue_plus whether to wait for a CCCD
    // confirmation at all. A peripheral without a CCCD (or a backend that hides
    // it, as BlueZ does) reports false and the call resolves immediately.
    if (!char.exposesCccd) return false;
    if (!peripheral.confirmsCccdWrites) {
      // Subscription applied, confirmation never sent — the flutter_blue_plus
      // Linux behaviour that makes every setNotifyValue "time out" after having
      // worked.
      return true;
    }
    _later(() {
      if (_descWrittenController.isClosed) return;
      _descWrittenController.add(BmDescriptorData(
        remoteId: request.remoteId,
        serviceUuid: request.serviceUuid,
        characteristicUuid: request.characteristicUuid,
        descriptorUuid: Guid(EmulatedUuids.cccd),
        primaryServiceUuid: request.primaryServiceUuid,
        value: request.enable ? const [1, 0] : const [0, 0],
        success: true,
        errorCode: 0,
        errorString: '',
      ));
    });
    return true;
  }
}
