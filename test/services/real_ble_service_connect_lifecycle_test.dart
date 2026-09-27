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

  test('disconnect during a pending connect does not wait for it', () async {
    // fbp's default disconnect(queue: true) waits on the process-wide
    // "global" mutex, which a pending connect() holds until the peripheral
    // answers or 15 s pass. So a screen left during "Connecting..." could
    // not cancel anything, and the next device's connect queued behind the
    // abandoned one. The emulated peripheral answers after [latency]; a
    // queued disconnect would take at least that long.
    const answerAfter = Duration(milliseconds: 1500);
    ble.add(EmulatedPeripheral.bulb(id: _bulbId));
    ble.latency = answerAfter;
    final connecting = service
        .connect(_bulbId)
        .then<Object?>((_) => null, onError: (Object e) => e);
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(ble.platformCalls, contains('connect:$_bulbId'));

    final stopwatch = Stopwatch()..start();
    await service.disconnect(_bulbId);
    stopwatch.stop();

    expect(
      stopwatch.elapsed,
      lessThan(const Duration(milliseconds: 1000)),
      reason: 'the cancel must jump the queue the pending connect holds',
    );
    expect(ble.platformCalls, contains('disconnect:$_bulbId'));

    // The emulator does not model the cancel, so its connect still lands;
    // release that link so reset() starts from nothing.
    await connecting;
    ble.latency = Duration.zero;
    await service.disconnect(_bulbId);
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
