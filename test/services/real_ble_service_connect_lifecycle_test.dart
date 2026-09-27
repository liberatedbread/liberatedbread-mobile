// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// RealBleService's connect lifecycle against the emulated adapter: leaving a
// connect that has not resolved, and a link that goes during discovery.
// Kept apart from real_ble_service_emulated_test.dart because these hold
// flutter_blue_plus's global mutex on purpose, and a slip here should not
// stall that suite's later connects.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/services/ble_service.dart';
import 'package:liberated_bread_mobile/services/real_ble_service.dart';

import '../fakes/emulated_ble.dart';

const _bulbId = 'AA:BB:CC:DD:EE:01';

void main() {
  late EmulatedBleAdapter ble;
  late RealBleService service;

  setUpAll(() {
    RealBleService.appleMtuSettle = const Duration(milliseconds: 50);
    TestWidgetsFlutterBinding.ensureInitialized();
    ble = EmulatedBleAdapter.install();
  });

  setUp(() async {
    await ble.reset();
    service = RealBleService();
  });

  test('a release with no claim leaves a pending connect alone', () async {
    // disconnect() with no claim fell through to fbp's queue-jumping
    // platform disconnect, which cancels whatever connect is running. A
    // stale release — an owner whose claim the link-drop watcher had
    // already expired, or a group run that timed out its own connect —
    // failed another owner's connect that way. Backing out of a pending
    // connect is cancelConnect's job, and it checks the connect is the
    // caller's own. Fails on the old code: the platform disconnect ran and
    // the pending connect was the one it cancelled.
    ble.add(EmulatedPeripheral.bulb(id: _bulbId));
    ble.latency = const Duration(milliseconds: 300);
    final connecting = service.connect(_bulbId);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(ble.platformCalls, contains('connect:$_bulbId'));

    await service.disconnect(_bulbId);
    expect(ble.platformCalls, isNot(contains('disconnect:$_bulbId')));

    // The connect lands with its claim, and its owner's release is the
    // one that drops the link.
    await connecting;
    ble.latency = Duration.zero;
    await service.disconnect(_bulbId);
    expect(ble.platformCalls, contains('disconnect:$_bulbId'));
  });

  group('cancelConnect', () {
    test('with no claims, cancels the pending connect promptly', () async {
      // The caller that backs out of "Connecting..." has nothing to
      // release, but the platform connect it started still holds fbp's
      // global mutex. With nobody else on the device, cancelling it is safe
      // and must jump that queue the way disconnect() does.
      const answerAfter = Duration(milliseconds: 1500);
      ble.add(EmulatedPeripheral.bulb(id: _bulbId));
      ble.latency = answerAfter;
      final connecting = service
          .connect(_bulbId)
          .then<Object?>((_) => null, onError: (Object e) => e);
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(ble.platformCalls, contains('connect:$_bulbId'));

      final stopwatch = Stopwatch()..start();
      await service.cancelConnect(_bulbId);
      stopwatch.stop();

      expect(stopwatch.elapsed, lessThan(const Duration(milliseconds: 1000)));
      expect(ble.platformCalls, contains('disconnect:$_bulbId'));

      // As above, the emulator's connect still lands; release it.
      await connecting;
      ble.latency = Duration.zero;
      await service.disconnect(_bulbId);
    });

    test('leaves a link another owner holds, claim and all', () async {
      // A group run (or a device client) is connected; a device screen
      // opens on the same peripheral and is left while its connect is
      // pending. disconnect() there removed the group run's only claim and
      // dropped its link.
      final bulb = ble.add(EmulatedPeripheral.bulb(id: _bulbId));
      await service.connect(_bulbId); // the other owner's claim
      ble.platformCalls.clear();

      var secondResolved = false;
      final second = service.connect(_bulbId).whenComplete(() {
        secondResolved = true;
      });
      expect(secondResolved, isFalse, reason: 'the second connect is pending');
      await service.cancelConnect(_bulbId);
      await second;

      expect(ble.platformCalls, isNot(contains('disconnect:$_bulbId')));
      expect(bulb.isConnected, isTrue);

      // Two claims now (the other owner's and the second connect's): the
      // first release keeps the link, the last one drops it.
      await service.disconnect(_bulbId);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(ble.platformCalls, isNot(contains('disconnect:$_bulbId')));
      expect(bulb.isConnected, isTrue);
      await service.disconnect(_bulbId);
      expect(ble.platformCalls, contains('disconnect:$_bulbId'));
    });

    test('stops a connect still waiting for the adapter to settle', () async {
      // No platform connect exists yet, so the platform disconnect has
      // nothing to end — and the attempt used to start one after the
      // caller had left, holding fbp's global mutex for up to 15 s. Fails
      // on the old code: the connect reached the platform once the
      // adapter settled.
      ble.add(EmulatedPeripheral.bulb(id: _bulbId));
      ble.adapterState = EmulatedAdapterState.unknown;
      final connecting = service
          .connect(_bulbId)
          .then<Object?>((_) => null, onError: (Object e) => e);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      await service.cancelConnect(_bulbId);
      ble.adapterState = EmulatedAdapterState.on;

      expect(await connecting, isA<BleConnectCancelledException>());
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(ble.platformCalls, isNot(contains('connect:$_bulbId')));
    });

    test('stops an Apple reconnect between its two attempts', () async {
      // A saved device CoreBluetooth has forgotten: the first attempt
      // fails at once, then a rediscovery scan runs before a second one.
      // A cancel during that scan found no platform connect to end, and the
      // second attempt ran after the screen had gone. Fails on the old
      // code: two platform connects, and the bulb ends up connected.
      service.isApple = true;
      appleRediscoveryWindow = const Duration(seconds: 2);
      addTearDown(() => appleRediscoveryWindow = const Duration(seconds: 6));
      final bulb = ble.add(EmulatedPeripheral.bulb(id: _bulbId))
        ..unknownToSystem = true;
      final stopwatch = Stopwatch()..start();
      final connecting = service
          .connect(_bulbId)
          .then<Object?>((_) => null, onError: (Object e) => e);
      while (!ble.platformCalls.contains('startScan')) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }

      await service.cancelConnect(_bulbId);

      expect(await connecting, isA<BleConnectCancelledException>());
      expect(
        stopwatch.elapsed,
        lessThan(const Duration(milliseconds: 1500)),
        reason: 'the cancel must not wait the rediscovery window out',
      );
      expect(
        ble.platformCalls.where((c) => c == 'connect:$_bulbId'),
        hasLength(1),
      );
      expect(ble.platformCalls, contains('stopScan'));
      expect(bulb.isConnected, isFalse);
    });

    test('a later connect to the same device is not cancelled', () async {
      // The cancel belongs to one attempt: a connect started after it
      // must run normally.
      ble.add(EmulatedPeripheral.bulb(id: _bulbId));
      ble.adapterState = EmulatedAdapterState.unknown;
      final first = service
          .connect(_bulbId)
          .then<Object?>((_) => null, onError: (Object e) => e);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await service.cancelConnect(_bulbId);
      ble.adapterState = EmulatedAdapterState.on;
      expect(await first, isA<BleConnectCancelledException>());

      await service.connect(_bulbId);
      expect(ble.platformCalls, contains('connect:$_bulbId'));
      await service.disconnect(_bulbId);
    });

    test('does not cancel a connect someone else has queued', () async {
      // Two callers connecting to an idle device: cancelling the platform
      // attempt for one would fail the other's too.
      ble.add(EmulatedPeripheral.bulb(id: _bulbId));
      ble.latency = const Duration(milliseconds: 300);
      final first = service.connect(_bulbId);
      final second = service.connect(_bulbId);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await service.cancelConnect(_bulbId);
      await first;
      await second;
      expect(ble.platformCalls, isNot(contains('disconnect:$_bulbId')));
      ble.latency = Duration.zero;
      await service.disconnect(_bulbId);
      await service.disconnect(_bulbId);
    });
  });

  test(
    'a connect nobody answers ends in a TimeoutException',
    () async {
      // fbp's own timeout arrived as a FlutterBluePlusException, which the
      // device screen could only render as "Could not connect — move
      // closer" and never retried. Typed as dart:async's TimeoutException,
      // the screen can tell "no answer yet" apart and keep trying. Nothing
      // is registered at this id, so the platform never answers and the
      // real 15 s attempt runs out.
      const ghost = 'AA:BB:CC:DD:EE:99';
      await expectLater(
        service.connect(ghost),
        throwsA(
          isA<TimeoutException>().having(
            (e) => e.duration,
            'duration',
            connectTimeoutAttempt,
          ),
        ),
      );
    },
    timeout: const Timeout(Duration(seconds: 40)),
  );

  group('a link that goes during discovery', () {
    test('mid-discovery, it surfaces as BleLinkDroppedException', () async {
      // The GVH5075 closes an idle link ~12 s after connecting, and a slow
      // discovery can be where that lands. fbp reports it as its own
      // "Device is disconnected", which the device screen could only word
      // as "Could not connect to this device".
      final bulb = ble.add(EmulatedPeripheral.bulb(id: _bulbId));
      await service.connect(_bulbId);
      ble.latency = const Duration(milliseconds: 500);
      final discovery = service.discoverServices(_bulbId);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      bulb.dropLink();

      await expectLater(discovery, throwsA(isA<BleLinkDroppedException>()));
      ble.latency = Duration.zero;
    });

    test('already gone at the start, it is the same typed drop', () async {
      final bulb = ble.add(EmulatedPeripheral.bulb(id: _bulbId));
      await service.connect(_bulbId);
      bulb.dropLink();
      await Future<void>.delayed(const Duration(milliseconds: 20));

      await expectLater(
        service.discoverServices(_bulbId),
        throwsA(isA<BleLinkDroppedException>()),
      );
    });
  });
}
