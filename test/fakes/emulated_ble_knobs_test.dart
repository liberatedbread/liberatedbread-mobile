// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// The emulated adapter's own knobs, proven against the REAL
// flutter_blue_plus.
//
// test/fakes/emulated_ble.dart is only as good as the claim each knob makes
// about the stack it models. The ones here model flutter_blue_plus_linux
// 7.0.3 on bluetoothd — a discovery that blocks inside the platform call, one
// that never returns, a link dropped with no reason, a link someone else
// opened, the two return values the Linux backend gets wrong — plus readRssi,
// instance ids on duplicate UUIDs, and reset() leaving nothing behind. Each is
// driven through flutter_blue_plus's public API, so what a test here sees is
// what RealBleService, or a platform router beneath it, would see.

import 'dart:async';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_blue_plus_platform_interface/flutter_blue_plus_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';

import 'emulated_ble.dart';

const _id = 'AA:BB:CC:DD:EE:31';
const _otherId = 'AA:BB:CC:DD:EE:32';

/// Timers never fire early, but the stopwatch and the timer round
/// differently; this keeps a lower bound on a blocked call honest without
/// making it flaky.
const _timerSlack = Duration(milliseconds: 5);

Matcher _fbpError(FbpErrorCode code) =>
    isA<FlutterBluePlusException>().having((e) => e.code, 'code', code.index);

void main() {
  late EmulatedBleAdapter ble;

  /// [EmulatedBleAdapter.debugHasListeners] as it stood before anything in
  /// this file had called flutter_blue_plus — which binds once per process.
  late bool boundBeforeFirstCall;

  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    ble = EmulatedBleAdapter.install();
    boundBeforeFirstCall = ble.debugHasListeners;
  });

  setUp(() => ble.reset());

  Future<BluetoothDevice> connectTo(String id) async {
    final device = BluetoothDevice.fromId(id);
    await device.connect();
    return device;
  }

  Future<void> disconnectedOf(BluetoothDevice device) => device.connectionState
      .firstWhere((s) => s == BluetoothConnectionState.disconnected)
      .timeout(const Duration(seconds: 1));

  /// Wait until [call] has reached the platform. flutter_blue_plus takes its
  /// "global" mutex and then its "invokeMethod" one on the way in, so a call
  /// started before that has happened would simply go first.
  Future<void> untilCalled(String call) async {
    final waited = Stopwatch()..start();
    while (!ble.platformCalls.contains(call)) {
      if (waited.elapsed > const Duration(seconds: 1)) {
        throw StateError('$call never reached the platform');
      }
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
  }

  test('debugHasListeners reports flutter_blue_plus binding to it', () async {
    expect(
      boundBeforeFirstCall,
      isFalse,
      reason: 'nothing had called flutter_blue_plus when setUpAll ran',
    );
    await FlutterBluePlus.isSupported;
    expect(ble.debugHasListeners, isTrue);
  });

  group('discoveryBlocksFor', () {
    test('holds the platform call, and every other call behind it', () async {
      const block = Duration(milliseconds: 150);
      ble.add(EmulatedPeripheral.bulb(id: _id)).discoveryBlocksFor = block;
      final device = await connectTo(_id);

      final clock = Stopwatch()..start();
      List<BluetoothService>? services;
      final discovery = device.discoverServices().then((s) => services = s);
      await untilCalled('discoverServices:$_id');
      // isSupported takes only flutter_blue_plus's "invokeMethod" mutex, the
      // one held for exactly as long as a platform call runs — so it is
      // stuck here only if the wait is inside the call.
      var supported = false;
      final behind = FlutterBluePlus.isSupported.then((_) => supported = true);

      await Future<void>.delayed(block * 0.5);
      expect(services, isNull);
      expect(supported, isFalse, reason: 'the platform call is still running');

      await discovery;
      expect(clock.elapsed, greaterThanOrEqualTo(block - _timerSlack));
      expect(services!.map((s) => s.uuid.str128), [
        EmulatedUuids.controlService,
        EmulatedUuids.batteryService,
      ]);
      await behind;
      expect(supported, isTrue);
    });

    test('is not what latency does: that returns the call at once', () async {
      // The contrast the knob exists for. A late REPLY frees the platform
      // call immediately; only the answer is outstanding.
      ble.add(EmulatedPeripheral.bulb(id: _id));
      final device = await connectTo(_id);
      ble.latency = const Duration(milliseconds: 150);

      var discovered = false;
      final discovery = device.discoverServices().then(
        (_) => discovered = true,
      );
      await FlutterBluePlus.isSupported.timeout(
        const Duration(milliseconds: 100),
      );
      expect(discovered, isFalse);
      await discovery;
    });

    test(
      'with emptyDiscoveries and dropLinkAfterDiscovery it is '
      "bluetoothd's stall: a long wait, nothing, then the link goes",
      () async {
        const block = Duration(milliseconds: 100);
        ble.add(EmulatedPeripheral.bulb(id: _id))
          ..emptyDiscoveries = 1
          ..discoveryBlocksFor = block
          ..dropLinkAfterDiscovery = const Duration(milliseconds: 30);
        final device = await connectTo(_id);

        final clock = Stopwatch()..start();
        final services = await device.discoverServices();

        expect(
          services,
          isEmpty,
          reason: 'a success with no services in it, not a failure',
        );
        expect(clock.elapsed, greaterThanOrEqualTo(block - _timerSlack));
        expect(
          device.isConnected,
          isTrue,
          reason:
              'the link outlives the empty answer, as it does on bluetoothd',
        );
        await disconnectedOf(device);
        expect(device.disconnectReason?.code, isNull);
      },
    );
  });

  group('discoveryNeverResolves', () {
    test('wedges flutter_blue_plus until reset releases the call', () async {
      ble.add(EmulatedPeripheral.bulb(id: _id)).discoveryNeverResolves = true;
      final device = await connectTo(_id);
      final answers = <BmDiscoverServicesResult>[];
      final sub = ble.onDiscoveredServices.listen(answers.add);

      Object? outcome;
      final discovery = device.discoverServices().then<void>(
        (s) => outcome = s,
        onError: (Object e) => outcome = e,
      );
      await untilCalled('discoverServices:$_id');
      var supported = false;
      final behind = FlutterBluePlus.isSupported.then((_) => supported = true);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(outcome, isNull);
      expect(supported, isFalse, reason: 'the whole stack is behind it');
      expect(ble.hungDiscoveries, 1);

      await ble.reset();
      await discovery;
      await behind;
      expect(
        outcome,
        _fbpError(FbpErrorCode.deviceIsDisconnected),
        reason: 'reset took the link down before letting the call return',
      );
      expect(answers, isEmpty, reason: 'released silently');
      expect(ble.hungDiscoveries, 0);
      await sub.cancel();

      // And flutter_blue_plus is usable again.
      ble.add(EmulatedPeripheral.bulb(id: _id));
      final again = await connectTo(_id);
      expect(await again.discoverServices(), hasLength(2));
    });

    test(
      'releaseHungDiscoveries ends the wedge once the link is gone',
      () async {
        final bulb = ble.add(EmulatedPeripheral.bulb(id: _id))
          ..discoveryNeverResolves = true;
        final device = await connectTo(_id);

        Object? outcome;
        final discovery = device.discoverServices().then<void>(
          (s) => outcome = s,
          onError: (Object e) => outcome = e,
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));
        // The drop that, on real Linux, leaves ServicesResolved false for good.
        bulb.dropLink(reasonCode: null, reason: null);
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(device.isConnected, isFalse);
        expect(
          outcome,
          isNull,
          reason:
              'flutter_blue_plus watches the link only once the call returns, '
              'so a drop alone does not free it',
        );

        // A reconnect queues behind the wedge and never reaches the platform.
        bulb.discoveryNeverResolves = false;
        var reconnected = false;
        final reconnect = device.connect().then((_) => reconnected = true);
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(reconnected, isFalse);
        expect(
          ble.platformCalls.where((c) => c == 'connect:$_id'),
          hasLength(1),
        );

        expect(ble.releaseHungDiscoveries(), 1);
        await discovery;
        expect(outcome, _fbpError(FbpErrorCode.deviceIsDisconnected));
        await reconnect.timeout(const Duration(seconds: 1));
        expect(device.isConnected, isTrue);
        expect(await device.discoverServices(), hasLength(2));
      },
    );
  });

  group('link events', () {
    test('dropLinkAfterDiscovery drops the link after the answer, with the '
        'null reasons flutter_blue_plus_linux reports', () async {
      final bulb = ble.add(EmulatedPeripheral.bulb(id: _id))
        ..dropLinkAfterDiscovery = const Duration(milliseconds: 40);
      final device = await connectTo(_id);
      final events = <BmConnectionStateResponse>[];
      final sub = ble.onConnectionStateChanged.listen(events.add);

      expect(await device.discoverServices(), hasLength(2));
      expect(device.isConnected, isTrue);
      await disconnectedOf(device);
      await sub.cancel();

      final drop = events.single;
      expect(drop.connectionState, BmConnectionStateEnum.disconnected);
      expect(drop.disconnectReasonCode, isNull);
      expect(drop.disconnectReasonString, isNull);
      expect(device.disconnectReason?.code, isNull);
      expect(device.disconnectReason?.description, isNull);
      expect(bulb.isConnected, isFalse);
      expect(ble.platformCalls, isNot(contains('disconnect:$_id')));
    });

    test('dropLink keeps its Android-shaped default reason', () async {
      final bulb = ble.add(EmulatedPeripheral.bulb(id: _id));
      final device = await connectTo(_id);
      // Listening first: a broadcast event reaches only the listeners there
      // when it was added, and dropLink adds it on the spot.
      final gone = disconnectedOf(device);
      bulb.dropLink();
      await gone;
      expect(device.disconnectReason?.code, 19);
      expect(device.disconnectReason?.description, 'REMOTE_USER_TERMINATED');
    });

    test('reportLinkUp and reportLinkDown reach connectionState with no '
        'platform call', () async {
      final bulb = ble.add(EmulatedPeripheral.bulb(id: _id));
      final device = BluetoothDevice.fromId(_id);
      final states = <BluetoothConnectionState>[];
      final sub = device.connectionState.listen(states.add);
      await Future<void>.delayed(Duration.zero);

      bulb.reportLinkUp();
      await Future<void>.delayed(Duration.zero);
      expect(device.isConnected, isTrue);
      expect(bulb.isConnected, isTrue);

      // A link flutter_blue_plus believes in is one it can use.
      final services = await device.discoverServices();
      final state = services
          .expand((s) => s.characteristics)
          .firstWhere((c) => c.uuid == Guid(EmulatedUuids.controlState));
      await state.setNotifyValue(true);
      expect(
        bulb.characteristic(EmulatedUuids.controlState)!.isNotifying,
        isTrue,
      );

      bulb.reportLinkDown();
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();
      expect(device.isConnected, isFalse);
      expect(device.disconnectReason?.code, isNull);
      expect(
        bulb.characteristic(EmulatedUuids.controlState)!.isNotifying,
        isFalse,
        reason: 'a link going down ends its subscriptions',
      );
      expect(states, [
        BluetoothConnectionState.disconnected,
        BluetoothConnectionState.connected,
        BluetoothConnectionState.disconnected,
      ]);
      expect(
        ble.platformCalls.where(
          (c) => c.startsWith('connect:') || c.startsWith('disconnect:'),
        ),
        isEmpty,
      );
    });
  });

  group('flutter_blue_plus_linux quirks', () {
    test('connectReturnsTrueWhenConnected: flutter_blue_plus times out and '
        'disconnects a link that was fine', () async {
      final bulb = ble.add(EmulatedPeripheral.bulb(id: _id));
      final device = await connectTo(_id);
      final request = BmConnectRequest(
        remoteId: const DeviceIdentifier(_id),
        autoConnect: false,
      );
      expect(
        await ble.connect(request),
        isFalse,
        reason: 'off by default: "no change", as iOS and Android answer',
      );

      ble.connectReturnsTrueWhenConnected = true;
      final events = <BmConnectionStateResponse>[];
      final sub = ble.onConnectionStateChanged.listen(events.add);
      expect(await ble.connect(request), isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(events, isEmpty, reason: 'nothing changed, so nothing reported');
      await sub.cancel();

      // What flutter_blue_plus makes of it: a wait for an event that never
      // comes, and then its timeout's cancel — a disconnect.
      await expectLater(
        device.connect(timeout: Duration.zero),
        throwsA(_fbpError(FbpErrorCode.timeout)),
      );
      await Future<void>.delayed(Duration.zero);
      expect(ble.platformCalls.last, 'disconnect:$_id');
      expect(bulb.isConnected, isFalse);
      expect(device.isConnected, isFalse);
    });

    test('disconnectReturnsTrueWhenDisconnected: flutter_blue_plus waits for '
        'an event that never comes', () async {
      ble.add(EmulatedPeripheral.bulb(id: _id));
      final device = BluetoothDevice.fromId(_id);
      final request = BmDisconnectRequest(
        remoteId: const DeviceIdentifier(_id),
      );
      expect(await ble.disconnect(request), isFalse);
      // Off, flutter_blue_plus takes the false as "nothing to wait for".
      await device.disconnect(timeout: 0);

      ble.disconnectReturnsTrueWhenDisconnected = true;
      final events = <BmConnectionStateResponse>[];
      final sub = ble.onConnectionStateChanged.listen(events.add);
      expect(await ble.disconnect(request), isTrue);
      expect(
        await ble.disconnect(
          BmDisconnectRequest(remoteId: const DeviceIdentifier(_otherId)),
        ),
        isFalse,
        reason: 'a device the adapter has never heard of is still unknown',
      );
      await expectLater(
        device.disconnect(timeout: 0),
        throwsA(_fbpError(FbpErrorCode.timeout)),
      );
      await sub.cancel();
      expect(events, isEmpty);
    });
  });

  group('readRssi', () {
    test('answers with the peripheral rssi', () async {
      ble.add(EmulatedPeripheral.bulb(id: _id, rssi: -61));
      final device = await connectTo(_id);
      expect(await device.readRssi(), -61);
      expect(ble.platformCalls, contains('readRssi:$_id'));
    });

    test('rssiError fails it with that string', () async {
      ble.add(EmulatedPeripheral.bulb(id: _id)).rssiError =
          'org.bluez.Error.Failed: Not connected';
      final device = await connectTo(_id);
      await expectLater(
        device.readRssi(),
        throwsA(
          isA<FlutterBluePlusException>().having(
            (e) => e.description,
            'description',
            'org.bluez.Error.Failed: Not connected',
          ),
        ),
      );
    });
  });

  group('instance ids', () {
    test('a read, write or subscription reaches the twin it names', () async {
      final first = EmulatedCharacteristic(
        uuid: EmulatedUuids.controlState,
        value: const [1],
        canRead: true,
        canWriteWithResponse: true,
        canNotify: true,
      );
      final second = EmulatedCharacteristic(
        uuid: EmulatedUuids.controlState,
        value: const [2],
        canRead: true,
        canWriteWithResponse: true,
        canNotify: true,
      );
      ble.add(
        EmulatedPeripheral(
          id: _id,
          name: 'Twin',
          services: [
            EmulatedService(
              uuid: EmulatedUuids.controlService,
              characteristics: [first, second],
            ),
          ],
        ),
      );
      final device = await connectTo(_id);
      final twins = (await device.discoverServices()).single.characteristics;
      expect(twins.map((c) => c.instanceId), [0, 1]);

      expect(await twins[1].read(), [2]);
      expect(await twins[0].read(), [1]);

      await twins[1].write([9]);
      expect(second.value, [9]);
      expect(first.value, [1]);
      expect(first.writes, isEmpty);

      await twins[1].setNotifyValue(true);
      expect(second.isNotifying, isTrue);
      expect(first.isNotifying, isFalse);
    });

    test('a short and a long spelling of one UUID are twins too', () async {
      ble.add(
        EmulatedPeripheral(
          id: _id,
          name: 'Twin',
          services: [
            EmulatedService(
              uuid: EmulatedUuids.controlService,
              characteristics: [
                EmulatedCharacteristic(
                  uuid: EmulatedUuids.controlState,
                  value: const [1],
                  canRead: true,
                ),
                EmulatedCharacteristic(
                  uuid: 'FFF2',
                  value: const [2],
                  canRead: true,
                ),
              ],
            ),
          ],
        ),
      );
      final device = await connectTo(_id);
      final twins = (await device.discoverServices()).single.characteristics;
      expect(twins.map((c) => c.instanceId), [0, 1]);
      expect(await twins[1].read(), [2]);
    });
  });

  group('reset', () {
    test(
      'cancels a scheduled drop, so it never reaches the next test',
      () async {
        final bulb = ble.add(EmulatedPeripheral.bulb(id: _id))
          ..dropLinkAfterDiscovery = const Duration(milliseconds: 60);
        final device = await connectTo(_id);
        await device.discoverServices();

        await ble.reset();
        // The "next test": the same device, the same id, connected afresh —
        // exactly what a stray drop timer would hit.
        bulb.dropLinkAfterDiscovery = null;
        ble.add(bulb);
        await device.connect();
        final events = <BmConnectionStateResponse>[];
        final sub = ble.onConnectionStateChanged.listen(events.add);
        await Future<void>.delayed(const Duration(milliseconds: 150));
        await sub.cancel();

        expect(events, isEmpty);
        expect(bulb.isConnected, isTrue);
        expect(device.isConnected, isTrue);
      },
    );

    test('cancels every other deferred reply and releases a blocked '
        'discovery silently', () async {
      const pending = Duration(milliseconds: 60);
      ble.add(EmulatedPeripheral.bulb(id: _id))
        ..cccdConfirmDelay = pending
        ..discoveryBlocksFor = pending;
      final lamp = ble.add(EmulatedPeripheral.bulb(id: _otherId));
      await connectTo(_id);
      await Future<void>.delayed(Duration.zero);

      // Everything the adapter emits from here is a leak, except the
      // disconnect reset itself sends for the connected bulb.
      final leaks = <String>[];
      var resetDone = false;
      final subs = <StreamSubscription<Object?>>[
        ble.onConnectionStateChanged.listen((e) {
          if (resetDone ||
              e.connectionState != BmConnectionStateEnum.disconnected) {
            leaks.add('${e.connectionState.name} ${e.remoteId}');
          }
        }),
        ble.onDiscoveredServices.listen((e) => leaks.add('discovery')),
        ble.onDescriptorWritten.listen((e) => leaks.add('cccd ack')),
        ble.onReadRssi.listen((e) => leaks.add('rssi')),
        ble.onMtuChanged.listen((e) => leaks.add('mtu')),
      ];

      const remoteId = DeviceIdentifier(_id);
      // A CCCD ack on its own timer.
      expect(
        await ble.setNotifyValue(
          BmSetNotifyValueRequest(
            remoteId: remoteId,
            serviceUuid: Guid(EmulatedUuids.batteryService),
            characteristicUuid: Guid(EmulatedUuids.batteryLevel),
            primaryServiceUuid: null,
            instanceId: 0,
            forceIndications: false,
            enable: true,
          ),
        ),
        isTrue,
      );
      // A discovery held inside its platform call.
      final held = ble.discoverServices(
        BmDiscoverServicesRequest(remoteId: remoteId),
      );
      // A reply on a latency timer.
      ble.latency = pending;
      expect(await ble.readRssi(BmReadRssiRequest(remoteId: remoteId)), isTrue);
      // And one already queued as a microtask: at zero latency this connect
      // answers on the next microtask, which reset() gets to first.
      ble.latency = Duration.zero;
      unawaited(
        ble.connect(
          BmConnectRequest(
            remoteId: const DeviceIdentifier(_otherId),
            autoConnect: false,
          ),
        ),
      );

      await ble.reset();
      resetDone = true;
      expect(await held, isTrue, reason: 'the held call returned');
      await Future<void>.delayed(pending * 2.5);
      for (final sub in subs) {
        await sub.cancel();
      }

      expect(leaks, isEmpty);
      expect(lamp.isConnected, isFalse);
    });

    test('turns the Linux quirks back off', () async {
      ble
        ..connectReturnsTrueWhenConnected = true
        ..disconnectReturnsTrueWhenDisconnected = true;
      await ble.reset();
      expect(ble.connectReturnsTrueWhenConnected, isFalse);
      expect(ble.disconnectReturnsTrueWhenDisconnected, isFalse);
    });
  });
}
