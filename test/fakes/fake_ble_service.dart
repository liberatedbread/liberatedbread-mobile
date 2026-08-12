// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';

import 'package:liberated_bread_mobile/core/constants.dart';
import 'package:liberated_bread_mobile/models/ble_discovered_service.dart';
import 'package:liberated_bread_mobile/models/iot_device.dart';
import 'package:liberated_bread_mobile/services/ble_service.dart';

/// Configurable fake [BleService] for widget/screen tests.
///
/// Each stage of the flow can be independently controlled: the devices
/// emitted by [scan], whether connect/discover/read succeed, and what
/// values reads return.
class FakeBleService implements BleService {
  final List<IoTDevice> devicesToEmit;
  final List<BleDiscoveredService> servicesToReturn;
  final Map<String, List<int>> readValues;
  final Duration scanStepDelay;

  /// Thrown by the next [scan]. Mutable so a test can fail one scan and let
  /// the retry succeed — which is the shape of every recovery the screen has.
  Object? scanError;

  /// Thrown by [connect]. Mutable for the same reason as [scanError].
  Object? connectError;
  final Object? discoverError;
  final Object? readError;

  /// Stream returned by [subscribeCharacteristic]; defaults to an empty stream.
  final Stream<List<int>>? notifyStream;

  /// Stream returned by [connectionState]; defaults to an empty stream. Tests
  /// can supply a controller-backed stream to simulate a mid-session
  /// disconnect.
  final Stream<BleConnectionState>? connectionStateStream;

  /// When set, [connect] awaits this before resolving — lets a test hold a
  /// connect in flight (e.g. to unmount the screen mid-connect).
  final Completer<void>? connectGate;

  /// When set, [discoverServices] awaits this before resolving.
  final Completer<void>? discoverGate;

  /// When set, [scan] stays open after emitting [devicesToEmit], the way the
  /// real continuous scan stays open, until this completes (or the consumer
  /// cancels). A completer's future is not a timer, so a test can end while
  /// the scan is still "running" without tripping the pending-timer check —
  /// which a long [scanStepDelay] hold cannot do.
  final Completer<void>? scanHold;

  /// Returned by [mtu]; the BLE minimum unless a test raises it.
  final int mtuToReturn;

  /// Values [readRssi] returns, consumed in call order; the last value
  /// repeats once the list is exhausted. Empty means a steady -60.
  final List<int> rssiValues;

  /// When set, [readRssi] throws it instead of returning a value.
  final Object? rssiError;

  /// What [adapterReady] returns; defaults to a stream that never emits, so
  /// no widget test gets a surprise auto-resume it did not script.
  final Stream<bool>? adapterReadyStream;

  /// Reads served successfully before [rssiError] starts being thrown. Lets a
  /// test exercise the mid-session transition — samples accumulate, THEN the
  /// link drops — which is the case the signal-lost state exists for.
  /// Defaults to 0: fail from the first read.
  final int rssiErrorAfter;

  /// When set, every [writeCharacteristic] call awaits this before recording,
  /// letting a test hold writes in flight to exercise send serialization.
  final Future<void>? writeGate;

  final List<String> connectedIds = [];
  final List<String> disconnectedIds = [];
  final List<({String deviceId, String charUuid, List<int> value})> writes = [];
  int stopScanCount = 0;
  int rssiReadCount = 0;

  /// Ordered log of connect/disconnect calls (e.g. 'connect:01',
  /// 'disconnect:01'). Lets tests assert the *order* of lifecycle calls, which
  /// call-count lists alone can't capture.
  final List<String> events = [];

  FakeBleService({
    this.devicesToEmit = const [],
    this.servicesToReturn = const [],
    this.readValues = const {},
    this.scanStepDelay = Duration.zero,
    this.scanError,
    this.connectError,
    this.discoverError,
    this.readError,
    this.notifyStream,
    this.connectionStateStream,
    this.connectGate,
    this.discoverGate,
    this.scanHold,
    this.mtuToReturn = 23,
    this.writeGate,
    this.rssiValues = const [],
    this.rssiError,
    this.rssiErrorAfter = 0,
    this.adapterReadyStream,
  });

  @override
  Future<bool> requestPermissions() async => true;

  /// Timeouts [scan] was called with, in order. A null entry is a continuous
  /// scan — which is what the scan screen asks for, and the only way a test can
  /// see that it did.
  final List<Duration?> scanTimeouts = [];

  /// Intensities [scan] was called with, parallel to [scanTimeouts]. How a
  /// test tells an ambient self-start from the burst a Scan press buys.
  final List<ScanIntensity> scanIntensities = [];

  // Matches the fixed RealBleService contract: devices stream in during the
  // scan window and the stream closes only when the window ends (here: when
  // there is nothing left to emit) — never early with results still pending.
  //
  // A continuous scan (timeout: null) ends here too, once the fake has emitted
  // everything it was given. The real service would keep the stream open, but a
  // widget test that pumps until quiet cannot wait on a stream that never
  // finishes, and every state this fake drives is reachable either way.
  @override
  Stream<IoTDevice> scan({
    Duration? timeout =
        const Duration(seconds: AppConstants.defaultScanDuration),
    ScanIntensity intensity = ScanIntensity.active,
  }) async* {
    scanTimeouts.add(timeout);
    scanIntensities.add(intensity);
    if (scanError != null) throw scanError!;
    for (final d in devicesToEmit) {
      if (scanStepDelay > Duration.zero) {
        await Future<void>.delayed(scanStepDelay);
      }
      yield d;
    }
    if (scanHold != null) await scanHold!.future;
  }

  @override
  Future<void> stopScan() async {
    stopScanCount++;
  }

  @override
  Stream<bool> adapterReady() =>
      adapterReadyStream ?? const Stream<bool>.empty();

  @override
  Future<void> connect(String deviceId) async {
    if (connectGate != null) await connectGate!.future;
    if (connectError != null) throw connectError!;
    connectedIds.add(deviceId);
    events.add('connect:$deviceId');
  }

  @override
  Future<void> disconnect(String deviceId) async {
    disconnectedIds.add(deviceId);
    events.add('disconnect:$deviceId');
  }

  @override
  Stream<BleConnectionState> connectionState(String deviceId) =>
      connectionStateStream ?? const Stream.empty();

  @override
  Future<List<BleDiscoveredService>> discoverServices(String deviceId) async {
    if (discoverGate != null) await discoverGate!.future;
    if (discoverError != null) throw discoverError!;
    return servicesToReturn;
  }

  @override
  Future<List<int>> readCharacteristic(
    String deviceId,
    String serviceUuid,
    String charUuid,
  ) async {
    if (readError != null) throw readError!;
    return readValues[charUuid.toLowerCase()] ?? const [0];
  }

  @override
  Future<void> writeCharacteristic(
    String deviceId,
    String serviceUuid,
    String charUuid,
    List<int> value,
  ) async {
    if (writeGate != null) await writeGate;
    writes.add((deviceId: deviceId, charUuid: charUuid, value: value));
  }

  /// Every characteristic [subscribeCharacteristic] was called for, in order.
  ///
  /// The real service now REFERENCE COUNTS notify enable/disable per
  /// characteristic (issue #29): concurrent subscriptions share one CCCD
  /// enable, and only the last cancel disables. Duplicates here are therefore
  /// normal for widgets that share a characteristic; [liveSubscriberCount]
  /// answers "how many are on this characteristic right now".
  final List<String> subscriptions = [];

  /// Every characteristic whose notify stream was cancelled, in order.
  ///
  /// Under the real service's refcounting, a cancel only reaches the
  /// peripheral (`setNotifyValue(false)`) when it is the LAST subscriber's —
  /// a test that needs "nothing muted this characteristic for the remaining
  /// widgets" asserts [liveSubscriberCount] stays above zero rather than
  /// this list staying empty. This list still records every stream-level
  /// cancel. With the default done-immediately empty [notifyStream] the
  /// listener's auto-cancel lands here too, so tests that hold a
  /// subscription open supply a stream that stays open (e.g. a broadcast
  /// controller's).
  final List<String> cancelledSubscriptions = [];

  /// Live subscriptions per characteristic UUID (listened minus cancelled),
  /// the fake's view of the real service's per-characteristic interest count.
  final Map<String, int> liveSubscriberCount = {};

  @override
  Stream<List<int>> subscribeCharacteristic(
    String deviceId,
    String serviceUuid,
    String charUuid,
  ) {
    subscriptions.add(charUuid);
    final source = notifyStream ?? const Stream<List<int>>.empty();
    final controller = StreamController<List<int>>();
    StreamSubscription<List<int>>? sub;
    controller.onListen = () {
      liveSubscriberCount[charUuid] = (liveSubscriberCount[charUuid] ?? 0) + 1;
      sub = source.listen(
        controller.add,
        onError: controller.addError,
        onDone: () {
          if (!controller.isClosed) controller.close();
        },
      );
    };
    controller.onCancel = () async {
      cancelledSubscriptions.add(charUuid);
      liveSubscriberCount[charUuid] = (liveSubscriberCount[charUuid] ?? 1) - 1;
      await sub?.cancel();
    };
    return controller.stream;
  }

  @override
  Future<int> mtu(String deviceId) async => mtuToReturn;

  @override
  Future<int> readRssi(String deviceId) async {
    rssiReadCount++;
    if (rssiError != null && rssiReadCount > rssiErrorAfter) throw rssiError!;
    if (rssiValues.isEmpty) return -60;
    return rssiValues[(rssiReadCount - 1).clamp(0, rssiValues.length - 1)];
  }
}
