// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// The Linux Bluetooth backend flutter_blue_plus sees: BlueZ for every device
// it can serve, a direct ATT bearer (direct_att_platform.dart) for the ones
// it cannot — decided per device, underneath flutter_blue_plus, so nothing
// above it knows or cares which transport a device is on.
//
// WHY A DEVICE LEAVES BLUEZ
//
// bluetoothd's GATT client opens every LE connection with a Read By Type for
// Server Supported Features (0x2B3A) across the whole handle range, before
// discovery (src/shared/gatt-client.c, read_server_feat — unchanged from
// 5.66 through 5.87). A peripheral that answers that with silence rather than
// an error — the Johnson LDM330 laser meter does, and it is not alone —
// makes bluetoothd wait out the 30 s ATT transaction timeout, shut its ATT
// bearer as the spec requires, and publish the device as resolved with no
// services; the link drops about two seconds later. There is no main.conf
// setting that skips the read, and upstream declined to relax the timeout.
// Android never sends that read to such a device, and every vendor app is
// tested on Android, so the firmware ships.
//
// The router watches every BlueZ service discovery for exactly that
// signature — nothing found (or the link gone) after at least
// [stallThreshold] — and then, inside the same discovery call, takes the
// device over: it opens its own ATT channel (the kernel lets an unprivileged
// process own the ATT fixed channel; bluetoothd then attaches nothing to it),
// walks the table the way Android does, and answers the waiting discovery
// with what it found. flutter_blue_plus never sees a disconnect. Only if the
// walk found real services is the device remembered (DirectAttRegistry), so
// later connections skip the half minute of waiting for BlueZ to give up.
//
// WHAT ELSE IT NORMALISES
//
// Because it is the platform layer anyway, the router also holds Linux to
// the behaviour the iOS and Android plugins have, which RealBleService is
// written against:
// - flutter_blue_plus_linux answers `connect` on an already-connected device
//   with "changed" and no event, so flutter_blue_plus waits out its timeout
//   and then DISCONNECTS the link under its other owner; `disconnect` on a
//   disconnected device likewise waits 35 s. The router answers both "no
//   change" when BlueZ has told it the state already holds.
// - flutter_blue_plus_linux's discovery polls BlueZ with no bound while
//   flutter_blue_plus holds a process-wide lock; a link that drops before
//   BlueZ resolves wedged every Bluetooth call until restart. The router
//   stops waiting when the link drops or after [bluezDiscoveryLimit].
//
// - flutter_blue_plus_linux only reports a device in a scan the moment BlueZ
//   first creates it, so a device BlueZ has kept (any device ever connected
//   through it) never shows up in a scan again. The router re-reports what
//   bluetoothd hears from those while a scan runs (BluezView.sightings).
//
// Scanning, the adapter and bonding stay with BlueZ for every device.
//
// Built to be deleted: when BlueZ tolerates a silent peripheral, remove this
// directory and the install call in ble_provider.dart.

// The router's stream controllers are never closed, on purpose:
// flutter_blue_plus binds to a platform's streams once per process, and a
// platform stream that ends kills its caches for good.
// ignore_for_file: close_sinks

import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter_blue_plus_linux/flutter_blue_plus_linux.dart';
import 'package:flutter_blue_plus_platform_interface/flutter_blue_plus_platform_interface.dart';

import '../../core/log.dart';
import '../settings_store.dart';
import 'att_channel.dart';
import 'bluez_view.dart';
import 'direct_att_platform.dart';
import 'direct_att_registry.dart';

/// What a device last advertised, as the router saw it go past in a scan:
/// the fields spec matching reads, spelt the way RealBleService spells them
/// for the scan list (the advertised name falling back to BlueZ's, 128-bit
/// lower-case service UUIDs, company ids).
typedef BleSighting = ({
  String name,
  List<String> serviceUuids,
  List<int> companyIds,
});

/// Asked at connect, for a device not yet routed direct, whether something
/// the router cannot see — the spec catalogue — says BlueZ cannot drive it.
/// [seen] is its last advertisement, when a scan this run heard one.
typedef DirectAttRouteHint =
    Future<bool> Function(String deviceId, BleSighting? seen);

/// How one BlueZ discovery ended, as far as the router could see.
sealed class _Outcome {
  const _Outcome();
}

class _Result extends _Outcome {
  final BmDiscoverServicesResult result;
  const _Result(this.result);
}

class _Dropped extends _Outcome {
  const _Dropped();
}

class _Threw extends _Outcome {
  final Object error;
  final StackTrace stack;
  const _Threw(this.error, this.stack);
}

class _NoResult extends _Outcome {
  const _NoResult();
}

class _GaveUp extends _Outcome {
  const _GaveUp();
}

/// One BlueZ discovery the router is watching. While it lives, BlueZ's
/// connection events for the device are held rather than forwarded, and its
/// discovery result is captured, so nothing reaches flutter_blue_plus until
/// the router has decided whether the device stays on BlueZ.
class _Arbitration {
  final Stopwatch clock = Stopwatch()..start();
  final List<BmConnectionStateResponse> held = [];
  final Completer<_Outcome> _settled = Completer<_Outcome>();

  Future<_Outcome> get settled => _settled.future;

  void settle(_Outcome outcome) {
    if (!_settled.isCompleted) _settled.complete(outcome);
  }
}

/// See the file comment.
final class DirectAttRouter extends FlutterBluePlusPlatform {
  /// The stock backend — BlueZ over D-Bus in production.
  final FlutterBluePlusPlatform inner;
  final DirectAttPlatform direct;
  final DirectAttRegistry registry;

  /// How long a BlueZ discovery that found nothing must have taken to be
  /// read as the silent-probe stall rather than a device with nothing to
  /// offer. The stall takes bluetoothd's 30 s ATT timeout; an honest empty
  /// answer takes milliseconds.
  final Duration stallThreshold;

  /// How long a BlueZ discovery may run before the router stops waiting for
  /// it. Past bluetoothd's own 30 s timeout with margin; a discovery still
  /// open after this is stuck, not slow.
  final Duration bluezDiscoveryLimit;

  /// How long to wait for BlueZ to let a link go when asked to.
  final Duration evictionWait;

  /// How long a hand-over waits for the stalled connection to go away on
  /// its own before asking BlueZ to drop it. bluetoothd shut its ATT bearer
  /// at the timeout, and the kernel drops an ACL nobody holds about two
  /// seconds later (HCI_DISCONN_TIMEOUT).
  final Duration linkReleaseWait;

  /// How many times a hand-over tries to open the direct channel. The
  /// devices this exists for refuse connections while their radio is
  /// changing state, which is exactly what one just did.
  final int handOverAttempts;
  final Duration handOverRetryDelay;

  /// Advertisements from devices BlueZ already knew, which
  /// flutter_blue_plus_linux never reports (see BluezView.sightings) —
  /// listened to only while a scan runs, and merged into its results. Null:
  /// scans are exactly the BlueZ backend's.
  final Stream<BmScanAdvertisement> Function()? knownDeviceSightings;
  StreamSubscription<BmScanAdvertisement>? _sightings;

  /// The spec catalogue's say, consulted by [connect] for any device not yet
  /// routed direct: when it answers true the device is declared in the
  /// registry and goes direct from this first connection — no 32 s stall —
  /// and when it answers false (or nothing, in time) the runtime detection
  /// in [discoverServices] still stands. Set by the app's provider layer,
  /// which owns the catalogue; the router knows nothing about specs.
  DirectAttRouteHint? routeHint;

  /// How long [connect] waits for [routeHint]. Bounded because
  /// flutter_blue_plus holds its process-wide lock around the platform
  /// connect: a slow catalogue must not freeze Bluetooth.
  final Duration routeHintTimeout;

  /// The last advertisement of each device heard this run (bounded: BLE
  /// privacy rotates addresses, and every one would otherwise stay).
  final Map<String, BleSighting> _lastSeen = {};
  static const int _lastSeenCap = 512;

  final Map<String, _Arbitration> _arbitrations = {};
  final Set<String> _handingOver = {};

  /// Bumped by [debugReset], so a hand-over still unwinding from one test
  /// cannot reach into the next one's registry and streams.
  int _epoch = 0;

  /// BlueZ's last word on each device's connection, whether or not it was
  /// forwarded.
  final Map<String, BmConnectionStateEnum> _bluezState = {};
  final Map<String, Completer<void>> _bluezGone = {};

  final List<StreamSubscription<Object?>> _pipes = [];

  final _adapterState = StreamController<BmBluetoothAdapterState>.broadcast();
  final _bondState = StreamController<BmBondStateResponse>.broadcast();
  final _written = StreamController<BmCharacteristicData>.broadcast();
  final _connection = StreamController<BmConnectionStateResponse>.broadcast();
  final _descRead = StreamController<BmDescriptorData>.broadcast();
  final _descWritten = StreamController<BmDescriptorData>.broadcast();
  final _detached = StreamController<BmDetachedFromEngineResponse>.broadcast();
  final _discovered = StreamController<BmDiscoverServicesResult>.broadcast();
  final _mtu = StreamController<BmMtuChangedResponse>.broadcast();
  final _name = StreamController<BmNameChanged>.broadcast();
  final _rssi = StreamController<BmReadRssiResult>.broadcast();
  final _scan = StreamController<BmScanResponse>.broadcast();
  final _servicesReset = StreamController<BmBluetoothDevice>.broadcast();
  final _turnOn = StreamController<BmTurnOnResponse>.broadcast();

  DirectAttRouter({
    required this.inner,
    required this.direct,
    required this.registry,
    this.stallThreshold = const Duration(seconds: 20),
    this.bluezDiscoveryLimit = const Duration(seconds: 45),
    this.evictionWait = const Duration(seconds: 5),
    this.linkReleaseWait = const Duration(seconds: 4),
    this.handOverAttempts = 3,
    this.handOverRetryDelay = const Duration(seconds: 1),
    this.knownDeviceSightings,
    this.routeHintTimeout = const Duration(seconds: 2),
  }) {
    // One subscription per source stream, taken now and kept: every
    // decision about an event (forward, drop, hold) is then made once, in
    // one place, rather than separately — and possibly differently — in
    // each of flutter_blue_plus's listeners. flutter_blue_plus_linux's
    // device-level streams follow devices as BlueZ adds and removes them,
    // so one long-lived subscription sees everything a fresh one would.
    // The exception, onCharacteristicReceived, is forwarded per access.
    _pipe(inner.onAdapterStateChanged, _adapterState);
    _pipe(inner.onBondStateChanged, _bondState);
    _pipe(inner.onDetachedFromEngine, _detached);
    _pipe(inner.onNameChanged, _name);
    _listen(inner.onScanResponse, (BmScanResponse response) {
      _remember(response);
      _scan.add(response);
    }, _scan);
    _pipe(inner.onTurnOnResponse, _turnOn);
    _merge(
      inner.onCharacteristicWritten,
      direct.onCharacteristicWritten,
      _written,
      (e) => e.remoteId,
    );
    _merge(
      inner.onDescriptorRead,
      direct.onDescriptorRead,
      _descRead,
      (e) => e.remoteId,
    );
    _merge(
      inner.onDescriptorWritten,
      direct.onDescriptorWritten,
      _descWritten,
      (e) => e.remoteId,
    );
    _merge(inner.onMtuChanged, direct.onMtuChanged, _mtu, (e) => e.remoteId);
    _merge(inner.onReadRssi, direct.onReadRssi, _rssi, (e) => e.remoteId);
    _merge(
      inner.onServicesReset,
      direct.onServicesReset,
      _servicesReset,
      (e) => e.remoteId,
    );
    _listen(inner.onConnectionStateChanged, _onBluezConnection, _connection);
    _pipe(direct.onConnectionStateChanged, _connection);
    // BlueZ's discovery results are never forwarded as they come: each is
    // captured by the discovery that asked for it and re-issued once the
    // router has decided (see discoverServices). One with no discovery
    // waiting is stale — flutter_blue_plus_linux's unbounded poll finishing
    // after the router stopped waiting — and would otherwise overwrite
    // flutter_blue_plus's cached table for the device.
    _listen(inner.onDiscoveredServices, _onBluezDiscovery, _discovered);
    _pipe(direct.onDiscoveredServices, _discovered);
  }

  static String _k(DeviceIdentifier id) =>
      DirectAttRegistry.normalizeDeviceId(id.str);

  /// Whether [id] is served (or being taken over) by the direct path, so
  /// BlueZ's events about it are noise: bluetoothd sees the ACL our socket
  /// holds and reports it as connected and disconnected.
  bool routesDirect(DeviceIdentifier id) =>
      registry.contains(id.str) ||
      _handingOver.contains(_k(id)) ||
      direct.hasLink(id.str);

  bool _onlyDeclared(DeviceIdentifier id) =>
      registry.isOnlyDeclared(id.str) &&
      !_handingOver.contains(_k(id)) &&
      !direct.hasLink(id.str);

  /// Stop routing [deviceId] direct: the forget-device path's half of the
  /// router. A hand-over remembers a device for good (DirectAttRegistry),
  /// and the heuristic behind it cannot tell a one-off slow drop from the
  /// silent-probe stall, so forgetting a device has to clear it — or a
  /// misrouted device stays off BlueZ, with no RSSI, even across a re-save.
  /// A device in `LB_DIRECT_ATT=<mac>` stays forced.
  Future<void> forget(String deviceId) => registry.remove(deviceId);

  void _pipe<T>(Stream<T> source, StreamController<T> into) =>
      _listen(source, into.add, into);

  void _listen<T>(
    Stream<T> source,
    void Function(T) onData,
    StreamController<T> errorsInto,
  ) {
    _pipes.add(
      source.listen(
        onData,
        // Forwarded, not swallowed: without the router the error would
        // have reached flutter_blue_plus from the backend directly.
        onError: errorsInto.addError,
      ),
    );
  }

  void _merge<T>(
    Stream<T> bluez,
    Stream<T> directStream,
    StreamController<T> into,
    DeviceIdentifier Function(T) idOf,
  ) {
    _listen(bluez, (T e) {
      if (!routesDirect(idOf(e))) into.add(e);
    }, into);
    _pipe(directStream, into);
  }

  void _remember(BmScanResponse response) {
    for (final ad in response.advertisements) {
      final k = _k(ad.remoteId);
      final previous = _lastSeen.remove(k);
      if (_lastSeen.length >= _lastSeenCap) {
        _lastSeen.remove(_lastSeen.keys.first);
      }
      final advertised = ad.advName ?? '';
      final platform = ad.platformName ?? '';
      _lastSeen[k] = (
        // A nameless ADV_IND after a scan response keeps the name that
        // response gave: replacing it with '' left the route hint nothing to
        // match the catalogue on.
        name: advertised.isNotEmpty
            ? advertised
            : platform.isNotEmpty
            ? platform
            : (previous?.name ?? ''),
        serviceUuids: [
          for (final uuid in ad.serviceUuids) uuid.str128.toLowerCase(),
        ],
        companyIds: ad.manufacturerData.keys.toList(),
      );
    }
  }

  /// Ask [routeHint] about [id] and declare it when the catalogue says so.
  Future<void> _consultRouteHint(DeviceIdentifier id) async {
    final hint = routeHint;
    if (hint == null) return;
    final bool? declared;
    try {
      // Through then<bool?>: a hint whose future is narrower at runtime (an
      // `async => throw` closure is a Future<Never>) would otherwise fail
      // timeout()'s own type check for the onTimeout value, and orphan its
      // error. A timeout is no answer (null), not a no.
      declared = await hint(id.str, _lastSeen[_k(id)])
          .then<bool?>((answer) => answer)
          .timeout(routeHintTimeout, onTimeout: () => null);
    } catch (e) {
      Log.ble.debug('route hint for $id failed', error: e);
      return;
    }
    // No answer keeps whatever routing the device already has: a slow
    // catalogue must not flip a declared device back onto BlueZ's stall.
    if (declared == null) return;
    if (!declared) {
      if (registry.isDeclared(id.str)) {
        registry.undeclare(id.str);
        Log.ble.info(
          'the spec catalogue no longer says BlueZ cannot drive $id; '
          'connecting it through BlueZ again',
        );
      }
      return;
    }
    if (registry.isDeclared(id.str)) return;
    registry.declare(id.str);
    Log.ble.info(
      'the spec catalogue says BlueZ cannot drive $id; connecting it over a '
      'direct ATT channel from the start',
    );
  }

  void _onBluezConnection(BmConnectionStateResponse e) {
    final k = _k(e.remoteId);
    _bluezState[k] = e.connectionState;
    if (e.connectionState == BmConnectionStateEnum.disconnected) {
      _bluezGone.remove(k)?.complete();
    }
    final arbitration = _arbitrations[k];
    if (arbitration != null) {
      arbitration.held.add(e);
      if (e.connectionState == BmConnectionStateEnum.disconnected) {
        arbitration.settle(const _Dropped());
      }
      return;
    }
    if (routesDirect(e.remoteId)) {
      Log.ble.debug(
        'ignoring BlueZ reporting ${e.remoteId} '
        '${e.connectionState.name}: the direct ATT path owns that link',
      );
      return;
    }
    _connection.add(e);
  }

  void _onBluezDiscovery(BmDiscoverServicesResult e) {
    final arbitration = _arbitrations[_k(e.remoteId)];
    if (arbitration == null) {
      Log.ble.debug(
        'dropping a BlueZ discovery result for ${e.remoteId} that nothing '
        'is waiting for',
      );
      return;
    }
    arbitration.settle(_Result(e));
  }

  // ---- streams ----------------------------------------------------------

  @override
  Stream<BmBluetoothAdapterState> get onAdapterStateChanged =>
      _adapterState.stream;
  @override
  Stream<BmBondStateResponse> get onBondStateChanged => _bondState.stream;
  @override
  Stream<BmCharacteristicData> get onCharacteristicWritten => _written.stream;
  @override
  Stream<BmConnectionStateResponse> get onConnectionStateChanged =>
      _connection.stream;
  @override
  Stream<BmDescriptorData> get onDescriptorRead => _descRead.stream;
  @override
  Stream<BmDescriptorData> get onDescriptorWritten => _descWritten.stream;
  @override
  Stream<BmDetachedFromEngineResponse> get onDetachedFromEngine =>
      _detached.stream;
  @override
  Stream<BmDiscoverServicesResult> get onDiscoveredServices =>
      _discovered.stream;
  @override
  Stream<BmMtuChangedResponse> get onMtuChanged => _mtu.stream;
  @override
  Stream<BmNameChanged> get onNameChanged => _name.stream;
  @override
  Stream<BmReadRssiResult> get onReadRssi => _rssi.stream;
  @override
  Stream<BmScanResponse> get onScanResponse => _scan.stream;
  @override
  Stream<BmBluetoothDevice> get onServicesReset => _servicesReset.stream;
  @override
  Stream<BmTurnOnResponse> get onTurnOnResponse => _turnOn.stream;

  /// Per access, unlike the rest: flutter_blue_plus_linux builds this
  /// stream over the characteristics BlueZ has published AT THE TIME OF THE
  /// CALL, so a subscription taken before a device's services resolved
  /// would never carry its notifications. flutter_blue_plus asks afresh
  /// for every `onValueReceived`, and so does this.
  @override
  Stream<BmCharacteristicData> get onCharacteristicReceived =>
      Stream.multi((controller) {
        final fromBluez = inner.onCharacteristicReceived
            .where((e) => !routesDirect(e.remoteId))
            .listen(controller.add, onError: controller.addError);
        final fromDirect = direct.onCharacteristicReceived.listen(
          controller.add,
          onError: controller.addError,
        );
        controller.onCancel = () =>
            Future.wait([fromBluez.cancel(), fromDirect.cancel()]);
      });

  // ---- adapter, scanning, bonding: BlueZ's, for every device ------------

  @override
  Future<bool> isSupported(BmIsSupportedRequest request) =>
      inner.isSupported(request);
  @override
  Future<BmBluetoothAdapterName> getAdapterName(
    BmBluetoothAdapterNameRequest request,
  ) => inner.getAdapterName(request);
  @override
  Future<BmBluetoothAdapterState> getAdapterState(
    BmBluetoothAdapterStateRequest request,
  ) => inner.getAdapterState(request);
  @override
  Future<bool> setLogLevel(BmSetLogLevelRequest request) =>
      inner.setLogLevel(request);
  @override
  Future<bool> setOptions(BmSetOptionsRequest request) =>
      inner.setOptions(request);
  @override
  Future<bool> startScan(BmScanSettings request) async {
    // Listening BEFORE the scan starts: bluetoothd sends a kept device's
    // first update the moment discovery hears it, and after that only when
    // its signal moves by 8 dB or more — a watcher that subscribed after
    // StartDiscovery returned could miss the only sighting of the scan.
    _watchSightings(request);
    try {
      return await inner.startScan(request);
    } catch (_) {
      await _sightings?.cancel();
      _sightings = null;
      rethrow;
    }
  }

  @override
  Future<bool> stopScan(BmStopScanRequest request) async {
    await _sightings?.cancel();
    _sightings = null;
    return inner.stopScan(request);
  }

  /// Merge known-device sightings into the scan [settings] started. BlueZ
  /// itself applies the service filter (a device that does not match is
  /// never updated, so never sighted); the remote-id filter is applied here,
  /// as flutter_blue_plus_linux leaves it to no one.
  void _watchSightings(BmScanSettings settings) {
    final source = knownDeviceSightings;
    unawaited(_sightings?.cancel());
    _sightings = null;
    if (source == null) return;
    final ids = {
      for (final id in settings.withRemoteIds)
        DirectAttRegistry.normalizeDeviceId(id),
    };
    _sightings = source().listen((advertisement) {
      if (ids.isNotEmpty && !ids.contains(_k(advertisement.remoteId))) return;
      final response = BmScanResponse(
        advertisements: [advertisement],
        success: true,
        errorCode: 0,
        errorString: '',
      );
      _remember(response);
      _scan.add(response);
    }, onError: (Object e) => Log.ble.debug('sightings ended', error: e));
  }

  @override
  Future<bool> turnOn(BmTurnOnRequest request) => inner.turnOn(request);
  @override
  Future<bool> turnOff(BmTurnOffRequest request) => inner.turnOff(request);
  @override
  Future<BmDevicesList> getSystemDevices(BmSystemDevicesRequest request) =>
      inner.getSystemDevices(request);
  @override
  Future<BmDevicesList> getBondedDevices(BmBondedDevicesRequest request) =>
      inner.getBondedDevices(request);
  @override
  Future<PhySupport> getPhySupport(PhySupportRequest request) =>
      inner.getPhySupport(request);
  // Pairing is the controller's, whichever path carries the ATT traffic.
  @override
  Future<BmBondStateResponse> getBondState(BmBondStateRequest request) =>
      inner.getBondState(request);
  @override
  Future<bool> createBond(BmCreateBondRequest request) =>
      inner.createBond(request);
  @override
  Future<bool> removeBond(BmRemoveBondRequest request) =>
      inner.removeBond(request);

  // ---- per device ---------------------------------------------------------

  @override
  Future<bool> connect(BmConnectRequest request) async {
    await registry.ready;
    // A device routed direct only on the catalogue's word is asked again:
    // otherwise a spec choice the user corrected mid-run kept it off BlueZ
    // (no RSSI, no Find Device) until the app restarted.
    if (!routesDirect(request.remoteId) || _onlyDeclared(request.remoteId)) {
      await _consultRouteHint(request.remoteId);
    }
    if (routesDirect(request.remoteId)) {
      // A reconnect straight after our own disconnect would join the ACL
      // the kernel keeps for about two seconds after the socket closes, and
      // repeat the MTU exchange on it (once per connection, says the spec).
      // bluetoothd, which reports every ACL, says when it is gone. Waiting
      // also lets go of a link BlueZ opened on its own before EBUSY does.
      if (!direct.hasLink(request.remoteId.str)) {
        await _awaitBluezRelease(request.remoteId);
      }
      return direct.connect(request);
    }
    if (_bluezState[_k(request.remoteId)] == BmConnectionStateEnum.connected) {
      // Already up: "no change", as iOS and Android answer. See the file
      // comment for what flutter_blue_plus_linux's "changed" costs.
      return false;
    }
    return inner.connect(request);
  }

  @override
  Future<bool> disconnect(BmDisconnectRequest request) async {
    await registry.ready;
    // Never BlueZ for a direct device: Device1.Disconnect drops the whole
    // ACL, which is the one our socket is using.
    if (routesDirect(request.remoteId)) return direct.disconnect(request);
    if (_bluezState[_k(request.remoteId)] ==
        BmConnectionStateEnum.disconnected) {
      return false;
    }
    return inner.disconnect(request);
  }

  @override
  Future<bool> discoverServices(BmDiscoverServicesRequest request) async {
    await registry.ready;
    final id = request.remoteId;
    if (routesDirect(id)) return direct.discoverServices(request);
    final k = _k(id);
    final arbitration = _Arbitration();
    _arbitrations[k] = arbitration;
    final watchdog = Timer(
      bluezDiscoveryLimit,
      () => arbitration.settle(const _GaveUp()),
    );
    try {
      unawaited(
        inner.discoverServices(request).then(
          (answered) {
            // flutter_blue_plus_linux emits its result before returning;
            // other backends may emit just after. A backend that says it
            // did not answer at all gets one turn of the event loop for a
            // straggler before the router stops waiting.
            if (!answered) {
              Timer(Duration.zero, () => arbitration.settle(const _NoResult()));
            }
          },
          onError: (Object e, StackTrace s) => arbitration.settle(_Threw(e, s)),
        ),
      );
      final outcome = await arbitration.settled;
      final took = arbitration.clock.elapsed;
      final stalled =
          took >= stallThreshold &&
          switch (outcome) {
            _Result(:final result) =>
              !result.success || result.services.isEmpty,
            _Dropped() || _GaveUp() => true,
            _NoResult() || _Threw() => false,
          };
      if (stalled && await _handOver(id, took, outcome, arbitration)) {
        return true;
      }
      // Stays on BlueZ: flutter_blue_plus hears what BlueZ said, in order —
      // and hears it BEFORE this call returns. Its guard against a lost
      // link subscribes the moment the call returns, seeded from its cached
      // connection state; a replayed disconnect still in flight then is in
      // neither place, and the discovery would wait out its whole timeout
      // holding flutter_blue_plus's global lock (see
      // DirectAttPlatform._afterLinkLoss). Every hop is a microtask; a zero
      // timer runs after them.
      arbitration.held.forEach(_connection.add);
      if (arbitration.held.isNotEmpty) {
        await Future<void>.delayed(Duration.zero);
      }
      switch (outcome) {
        case _Result(:final result):
          _discovered.add(result);
        case _Dropped():
          // The disconnect just replayed is the answer.
          break;
        case _GaveUp():
          Log.ble.warning(
            'BlueZ had not resolved the services of $id after '
            '${took.inSeconds}s; giving up on this discovery',
          );
          _discovered.add(
            BmDiscoverServicesResult(
              remoteId: id,
              services: const [],
              success: false,
              errorCode: 0,
              errorString:
                  'BlueZ did not finish resolving services within '
                  '${bluezDiscoveryLimit.inSeconds}s',
            ),
          );
        case _NoResult():
          _discovered.add(
            BmDiscoverServicesResult(
              remoteId: id,
              services: const [],
              success: false,
              errorCode: 0,
              errorString: 'BlueZ returned no discovery result',
            ),
          );
        case _Threw(:final error, :final stack):
          Error.throwWithStackTrace(error, stack);
      }
      return true;
    } finally {
      watchdog.cancel();
      if (identical(_arbitrations[k], arbitration)) _arbitrations.remove(k);
    }
  }

  /// Take [id] over from BlueZ in the middle of the discovery that just
  /// stalled. Returns whether it worked. If not, nothing about the device
  /// has changed: [arbitration] is left holding only what BlueZ said about
  /// ITS link, for the caller to replay.
  Future<bool> _handOver(
    DeviceIdentifier id,
    Duration took,
    _Outcome outcome,
    _Arbitration arbitration,
  ) async {
    final k = _k(id);
    Log.ble.warning(
      'BlueZ spent ${took.inSeconds}s on $id and '
      '${outcome is _Result ? 'found no services' : 'lost the link'}: the '
      'signature of a peripheral that ignores the Server Supported Features '
      'probe bluetoothd opens every connection with. Taking the device over '
      'on a direct ATT channel.',
    );
    _handingOver.add(k);
    final epoch = _epoch;
    bool reset() => epoch != _epoch;
    var tookOver = false;
    // Where bluetoothd's commentary on OUR link starts: it sees the ACL the
    // direct socket makes and reports it. Held like the rest while this
    // runs, but it is not BlueZ's history, and a fallback must not replay
    // it (the app would see a link come back that the router then closes).
    var ours = arbitration.held.length;
    BmConnectionStateEnum? bluezBefore = _bluezState[k];
    try {
      // A discovery BlueZ never finished means bluetoothd's GATT client
      // still holds the bearer, and the link will not go by itself.
      await _awaitBluezRelease(id, evictAtOnce: outcome is _GaveUp);
      if (reset()) return false;
      ours = arbitration.held.length;
      bluezBefore = _bluezState[k];
      for (var attempt = 1; ; attempt++) {
        if (await direct.takeOver(id)) break;
        if (reset()) return false;
        // Retries are for a connect that did not come up. One that came up
        // and then went quiet (an unanswered MTU exchange) will not do
        // better on a second try, and each try costs a request timeout
        // inside flutter_blue_plus's lock.
        final cameUp = direct.lastAttemptCameUp(id.str);
        if (attempt >= handOverAttempts || cameUp) {
          Log.ble.warning(
            'could not open a direct ATT channel to $id '
            '($attempt attempt(s)'
            '${cameUp ? '; the link came up and then failed' : ''})',
          );
          return false;
        }
        Log.ble.info(
          'direct ATT channel to $id not up (attempt $attempt); retrying',
        );
        await Future<void>.delayed(handOverRetryDelay);
        // The failed attempt's ACL can outlive its socket by two seconds;
        // the retry must not join it.
        await _awaitBluezRelease(id);
        if (reset()) return false;
      }
      final services = await direct.discoverForHandOver(
        id,
        publishFailure: false,
      );
      if (reset()) return false;
      if (services == null || services.isEmpty) {
        Log.ble.warning(
          'the direct ATT walk of $id found nothing an app could use either; '
          'leaving the device on BlueZ',
        );
        return false;
      }
      await registry.add(id.str);
      Log.ble.info(
        '$id is now driven over a direct ATT channel '
        '(${services.length} service(s)); remembered for next time',
      );
      direct.publishDiscovery(id, services);
      tookOver = true;
      return true;
    } catch (e) {
      Log.ble.warning('taking $id over failed', error: e);
      return false;
    } finally {
      if (!tookOver) await direct.abandon(id);
      if (!tookOver && !reset()) {
        arbitration.held.removeRange(ours, arbitration.held.length);
        // BlueZ's word on its own link, not on the ACL just abandoned:
        // otherwise a connect in the next two seconds is answered "no
        // change" for a link that is on its way down.
        if (bluezBefore == null) {
          _bluezState.remove(k);
        } else {
          _bluezState[k] = bluezBefore;
        }
      }
      if (!reset()) _handingOver.remove(k);
    }
  }

  /// Wait for BlueZ's link to [id] to be gone before the direct path opens
  /// its own. Never start over on the stalled connection: bluetoothd has
  /// already exchanged MTU on it (which the spec allows once per
  /// connection) and left a request unanswered on it, and the peer's ATT
  /// server may stay wedged for the rest of it. bluetoothd shut its bearer
  /// at the timeout, so the kernel lets the ACL go by itself within about
  /// two seconds; if it has not by [linkReleaseWait], BlueZ is asked.
  Future<void> _awaitBluezRelease(
    DeviceIdentifier id, {
    bool evictAtOnce = false,
  }) async {
    final k = _k(id);
    if (_bluezState[k] != BmConnectionStateEnum.connected) return;
    if (evictAtOnce) return evictFromBluez(id.str);
    final gone = (_bluezGone[k] ??= Completer<void>()).future;
    var released = true;
    await gone.timeout(linkReleaseWait, onTimeout: () => released = false);
    if (!released) await evictFromBluez(id.str);
  }

  /// Ask BlueZ to let go of [deviceId]'s link, and wait (up to
  /// [evictionWait]) until it says it has. The direct path calls this when
  /// the kernel keeps refusing it the ATT channel because bluetoothd holds
  /// one — a device BlueZ connected on its own, say.
  Future<void> evictFromBluez(String deviceId) async {
    final k = DirectAttRegistry.normalizeDeviceId(deviceId);
    Log.ble.info('asking BlueZ to release its link to $deviceId');
    final gone = (_bluezGone[k] ??= Completer<void>()).future;
    try {
      // In BlueZ's own spelling: flutter_blue_plus_linux looks the device
      // up by an equality that is case-sensitive in practice.
      await inner.disconnect(
        BmDisconnectRequest(remoteId: DeviceIdentifier(k)),
      );
    } catch (e) {
      Log.ble.debug('BlueZ disconnect of $deviceId failed', error: e);
    }
    if (_bluezState[k] != BmConnectionStateEnum.connected) return;
    await gone.timeout(evictionWait, onTimeout: () {});
  }

  @override
  Future<bool> readCharacteristic(BmReadCharacteristicRequest request) =>
      routesDirect(request.remoteId)
      ? direct.readCharacteristic(request)
      : inner.readCharacteristic(request);

  @override
  Future<bool> writeCharacteristic(BmWriteCharacteristicRequest request) =>
      routesDirect(request.remoteId)
      ? direct.writeCharacteristic(request)
      : inner.writeCharacteristic(request);

  @override
  Future<bool> setNotifyValue(BmSetNotifyValueRequest request) =>
      routesDirect(request.remoteId)
      ? direct.setNotifyValue(request)
      : inner.setNotifyValue(request);

  @override
  Future<bool> readDescriptor(BmReadDescriptorRequest request) =>
      routesDirect(request.remoteId)
      ? direct.readDescriptor(request)
      : inner.readDescriptor(request);

  @override
  Future<bool> writeDescriptor(BmWriteDescriptorRequest request) =>
      routesDirect(request.remoteId)
      ? direct.writeDescriptor(request)
      : inner.writeDescriptor(request);

  @override
  Future<bool> readRssi(BmReadRssiRequest request) =>
      routesDirect(request.remoteId)
      ? direct.readRssi(request)
      : inner.readRssi(request);

  @override
  Future<bool> requestMtu(BmMtuChangeRequest request) =>
      routesDirect(request.remoteId)
      ? direct.requestMtu(request)
      : inner.requestMtu(request);

  @override
  Future<bool> clearGattCache(BmClearGattCacheRequest request) =>
      routesDirect(request.remoteId)
      ? direct.clearGattCache(request)
      : inner.clearGattCache(request);

  @override
  Future<bool> requestConnectionPriority(BmConnectionPriorityRequest request) =>
      routesDirect(request.remoteId)
      ? Future.value(false)
      : inner.requestConnectionPriority(request);

  @override
  Future<bool> setPreferredPhy(BmPreferredPhy request) =>
      routesDirect(request.remoteId)
      ? Future.value(false)
      : inner.setPreferredPhy(request);

  /// Forget in-flight routing state and close every direct link, reporting
  /// each as disconnected. For tests, which share one router per file.
  Future<void> debugReset() async {
    _epoch++;
    _lastSeen.clear();
    await _sightings?.cancel();
    _sightings = null;
    for (final arbitration in _arbitrations.values) {
      arbitration.settle(const _NoResult());
    }
    _arbitrations.clear();
    _handingOver.clear();
    _bluezState.clear();
    for (final gone in _bluezGone.values) {
      gone.complete();
    }
    _bluezGone.clear();
    await direct.debugReset();
  }
}

/// Put the router under flutter_blue_plus, on Linux, once.
///
/// Must run before flutter_blue_plus's first platform call — flutter_blue_plus
/// binds to the instance's streams exactly once — which is why
/// bleServiceProvider calls it before building RealBleService, the only code
/// that talks to flutter_blue_plus. A no-op (returning null) anywhere but
/// Linux, when `LB_DIRECT_ATT=off`, and when the installed backend is not the
/// stock BlueZ one (a test's emulated adapter); idempotent.
///
/// `LB_DIRECT_ATT=<mac>[,<mac>...]` routes those devices direct from the
/// first connection, for a user who already knows BlueZ cannot enumerate
/// them.
DirectAttRouter? installDirectAttRouter(
  Future<SettingsStore> store, {
  Map<String, String>? environment,
}) {
  if (!Platform.isLinux) return null;
  final setting = (environment ?? Platform.environment)['LB_DIRECT_ATT']
      ?.trim();
  if (setting?.toLowerCase() == 'off') {
    Log.ble.info('LB_DIRECT_ATT=off: every device stays on BlueZ');
    return null;
  }
  final FlutterBluePlusPlatform current;
  try {
    current = FlutterBluePlusPlatform.instance;
  } on UnsupportedError {
    return null;
  }
  if (current is DirectAttRouter) return current;
  if (current is! FlutterBluePlusLinux) return null;
  final forced = <String>[];
  for (final entry in (setting ?? '').split(',')) {
    final id = entry.trim();
    if (id.isEmpty) continue;
    try {
      bdaddrBytes(id);
      forced.add(id);
    } on ArgumentError {
      Log.ble.warning('LB_DIRECT_ATT: "$id" is not a Bluetooth address');
    }
  }
  final bluez = BluezView();
  late final DirectAttRouter router;
  final direct = DirectAttPlatform(
    const L2capAttChannelFactory(),
    isRandomAddress: bluez.isRandom,
    onBusy: (id) => router.evictFromBluez(id),
  );
  router = DirectAttRouter(
    inner: current,
    direct: direct,
    registry: DirectAttRegistry(store, forced: forced),
    knownDeviceSightings: bluez.sightings,
  );
  FlutterBluePlusPlatform.instance = router;
  // Connected now, not at the first scan: its object cache has to be in
  // place before that scan's first sighting arrives.
  unawaited(bluez.warmUp());
  Log.ble.info(
    'Linux Bluetooth: BlueZ, with a direct ATT path for peripherals it '
    'cannot enumerate'
    '${forced.isEmpty ? '' : ' (forced for ${forced.join(', ')})'}',
  );
  return router;
}
