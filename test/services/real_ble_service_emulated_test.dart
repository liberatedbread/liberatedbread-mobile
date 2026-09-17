// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// RealBleService, end to end, against emulated peripherals.
//
// Everything here runs the SHIPPING service: real_ble_service.dart driving the
// real flutter_blue_plus, with test/fakes/emulated_ble.dart standing in for the
// radio at flutter_blue_plus's own platform seam. The only thing that isn't
// real is the hardware.
//
// The companion suite real_ble_service_mapping_test.dart covers the pure
// helpers (adapterStateError, nextEmptyDiscoveryRetryDelay, the coalescer, ...)
// in isolation. This one covers the plumbing that CALLS them — the part that,
// before the emulated adapter existed, only ever ran on a phone.

import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter_blue_plus/flutter_blue_plus.dart'
    show AndroidScanMode, FlutterBluePlus;
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/models/iot_device.dart';
import 'package:liberated_bread_mobile/services/ble_service.dart';
import 'package:liberated_bread_mobile/services/real_ble_service.dart';

import '../fakes/emulated_ble.dart';

/// Short enough to keep the suite fast, long enough that an advertisement
/// pushed from a test lands inside the window.
const _scanWindow = Duration(milliseconds: 300);

const _bulbId = 'AA:BB:CC:DD:EE:01';

/// On a macOS host RealBleService takes its Apple branches, and mtu() then
/// waits [RealBleService.appleMtuSettle] for a link that never reports one.
/// Real devices report within a few ticks; the emulated adapter reports at
/// connect, so anything left waiting is a device that has none at all.
const _testMtuSettle = Duration(milliseconds: 50);
const _lampId = 'AA:BB:CC:DD:EE:02';

/// A device whose characteristics demand an authenticated link — a lock is the
/// canonical example, and the class of device the app must not simply report
/// as broken.
const _lockId = 'AA:BB:CC:DD:EE:03';

void main() {
  late EmulatedBleAdapter ble;
  late RealBleService service;

  setUpAll(() {
    RealBleService.appleMtuSettle = _testMtuSettle;
    TestWidgetsFlutterBinding.ensureInitialized();
    ble = EmulatedBleAdapter.install();
  });

  setUp(() async {
    await ble.reset();
    service = RealBleService();
  });

  /// Run a scan to completion, returning everything it emitted. [during] runs
  /// once the scan is under way, which is where a test pushes extra
  /// advertisements or drops the link.
  Future<List<IoTDevice>> runScan({
    Duration timeout = _scanWindow,
    Future<void> Function()? during,
  }) async {
    final seen = <IoTDevice>[];
    final finished = Completer<void>();
    final sub = service
        .scan(timeout: timeout)
        .listen(
          seen.add,
          onError: finished.completeError,
          onDone: () {
            if (!finished.isCompleted) finished.complete();
          },
        );
    if (during != null) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await during();
    }
    try {
      await finished.future;
    } finally {
      await sub.cancel();
    }
    return seen;
  }

  group('scan', () {
    test(
      'reports an advertising peripheral with its name, rssi and id',
      () async {
        ble.add(EmulatedPeripheral.bulb(id: _bulbId, name: 'ACME_Bulb'));

        final found = await runScan();

        expect(found, hasLength(1));
        expect(found.single.id, _bulbId);
        expect(found.single.name, 'ACME_Bulb');
        expect(found.single.rssi, -45);
        expect(found.single.isConnectable, isTrue);
      },
    );

    test('reports every peripheral in range', () async {
      ble.add(EmulatedPeripheral.bulb(id: _bulbId, name: 'ACME_Bulb'));
      ble.add(
        EmulatedPeripheral.bulb(id: _lampId, name: 'ACME_Lamp', rssi: -70),
      );

      final found = await runScan();

      expect(found.map((d) => d.name).toSet(), {'ACME_Bulb', 'ACME_Lamp'});
    });

    test(
      'does not re-emit a device whose advertisement is unchanged',
      () async {
        final bulb = ble.add(
          EmulatedPeripheral.bulb(id: _bulbId, name: 'ACME_Bulb'),
        );

        // flutter_blue_plus hands the app the FULL accumulated result list on
        // every advertisement, so without coalescing this scan would emit the
        // bulb four times and reset its discoveredAt each time.
        final found = await runScan(
          during: () async {
            bulb.advertise();
            bulb.advertise();
            bulb.advertise();
          },
        );

        expect(found, hasLength(1));
      },
    );

    test(
      're-emits on an rssi change, keeping the first-seen timestamp',
      () async {
        final bulb = ble.add(
          EmulatedPeripheral.bulb(id: _bulbId, name: 'ACME_Bulb'),
        );

        final found = await runScan(
          during: () async {
            bulb.advertise(rssi: -30);
          },
        );

        expect(found, hasLength(2));
        expect(found.map((d) => d.rssi), [-45, -30]);
        expect(found[1].discoveredAt, found[0].discoveredAt);
      },
    );

    test(
      'raises BlePermissionDeniedException when the adapter is unauthorized',
      () async {
        ble.adapterState = EmulatedAdapterState.unauthorized;
        ble.add(EmulatedPeripheral.bulb(id: _bulbId));

        await expectLater(
          service.scan(timeout: _scanWindow),
          emitsError(isA<BlePermissionDeniedException>()),
        );
        // The refusal happens before the radio is ever asked to scan.
        expect(ble.platformCalls, isNot(contains('startScan')));
      },
    );

    test('raises BleUnavailableException when the radio is off', () async {
      ble.adapterState = EmulatedAdapterState.off;

      await expectLater(
        service.scan(timeout: _scanWindow),
        emitsError(isA<BleUnavailableException>()),
      );
    });

    group('adapter state still settling (F-002)', () {
      // CoreBluetooth reports `unknown` until its state callback fires, and
      // on a first launch that callback waits for the user to answer the
      // system Bluetooth prompt. The scan has to wait with it: the first
      // answer is not an answer.
      test('waits for the platform to report a state, then scans', () async {
        ble.add(EmulatedPeripheral.bulb(id: _bulbId, name: 'ACME_Bulb'));
        ble.adapterState = EmulatedAdapterState.unknown;

        final found = await runScan(
          during: () async {
            expect(
              ble.platformCalls,
              isNot(contains('startScan')),
              reason: 'nothing may start until the state has settled',
            );
            ble.adapterState = EmulatedAdapterState.on;
          },
        );

        expect(found.map((d) => d.name), ['ACME_Bulb']);
      });

      test(
        'a Deny answered after the prompt is a denial, not a dead radio',
        () async {
          // The broken path this pins: judged early, the scan reported
          // "Bluetooth is turned off" — and the later `unauthorized` reached a
          // scan that had already given up, so the settings shortcut never
          // appeared.
          ble.adapterState = EmulatedAdapterState.unknown;
          unawaited(
            Future<void>.delayed(const Duration(milliseconds: 30), () {
              ble.adapterState = EmulatedAdapterState.unauthorized;
            }),
          );

          await expectLater(
            service.scan(timeout: _scanWindow),
            emitsError(isA<BlePermissionDeniedException>()),
          );
          expect(ble.platformCalls, isNot(contains('startScan')));
        },
      );

      test('turningOn is waited out the same way', () async {
        ble.add(EmulatedPeripheral.bulb(id: _bulbId));
        ble.adapterState = EmulatedAdapterState.turningOn;

        final found = await runScan(
          during: () async => ble.adapterState = EmulatedAdapterState.on,
        );

        expect(found, hasLength(1));
      });

      test('a state that never settles is reported as unavailable', () async {
        service.adapterSettleWindow = const Duration(milliseconds: 100);
        ble.adapterState = EmulatedAdapterState.unknown;

        await expectLater(
          service.scan(timeout: _scanWindow),
          emitsError(isA<BleUnavailableException>()),
        );
      });
    });

    group('device name (F-022)', () {
      test('prefers the advertised local name to the platform cache', () async {
        // CoreBluetooth's platformName is `peripheral.name`: a system-wide
        // cache that, once any app has connected, holds the GAP Device Name
        // rather than what is on air. A rebadged bulb advertises the brand
        // its spec's local_name_prefix names; its GAP name is the chipset's.
        ble.add(
          EmulatedPeripheral.bulb(
            id: _bulbId,
            name: 'Nordic_Blinky',
            advName: 'LEDBLE-TEST',
          ),
        );

        final found = await runScan();

        expect(found.single.name, 'LEDBLE-TEST');
      });

      test(
        'falls back to the platform name when nothing is advertised',
        () async {
          final bulb = ble.add(
            EmulatedPeripheral.bulb(id: _bulbId, name: 'Nordic_Blinky'),
          );
          bulb.advName = null;

          final found = await runScan();

          expect(found.single.name, 'Nordic_Blinky');
        },
      );
    });

    test('each advertisement is delivered on its own (F-020)', () async {
      // fbp's default hands every listener a fresh copy of EVERYTHING found so
      // far on every advertisement, and the listener walked it: O(devices) per
      // sighting, which in a dense room was most of the scan's UI-isolate
      // time. One-by-one delivery is the setting that makes a sighting cost
      // one coalescer lookup — observable only at fbp's own stream.
      ble.add(EmulatedPeripheral.bulb(id: _bulbId));
      ble.add(EmulatedPeripheral.bulb(id: _lampId));
      final batchSizes = <int>[];
      final tap = FlutterBluePlus.scanResults.listen(
        (results) => batchSizes.add(results.length),
      );
      addTearDown(tap.cancel);

      final found = await runScan();

      expect(found.map((d) => d.id), containsAll([_bulbId, _lampId]));
      expect(batchSizes, isNotEmpty);
      expect(
        batchSizes.where((n) => n > 1),
        isEmpty,
        reason: 'an accumulated list means every sighting re-walks the room',
      );
    });

    test('surfaces a platform scan failure on the stream', () async {
      ble.scanError = const EmulatedGattError(
        2,
        'SCAN_FAILED_APPLICATION_REGISTRATION_FAILED',
      );

      await expectLater(
        service.scan(timeout: _scanWindow),
        emitsError(isA<Object>()),
      );
    });

    test('stops the native scan when the consumer cancels early', () async {
      ble.add(EmulatedPeripheral.bulb(id: _bulbId));

      final sub = service
          .scan(timeout: const Duration(seconds: 30))
          .listen((_) {});
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await sub.cancel();
      // Cancellation runs through onCancel asynchronously.
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(ble.platformCalls, contains('stopScan'));
    });

    test('a cancel during setup leaves nothing scanning', () async {
      // Setup is a chain of awaits (permissions, adapter state, teardown of a
      // previous scan) and a cancel can land inside it — the scan screen does
      // exactly this if a tab switch follows arrival closely enough. There is
      // no subscription to cancel yet at that point, so without an explicit
      // check the setup runs to completion and starts a scan with no listener:
      // for a continuous scan, one with no window to expire and nothing left
      // holding a handle to stop it.
      ble.add(EmulatedPeripheral.bulb(id: _bulbId));

      final sub = service.scan(timeout: null).listen((_) {});
      await sub.cancel(); // before the setup closure gets anywhere
      await Future<void>.delayed(const Duration(milliseconds: 60));

      final started = ble.platformCalls.where((c) => c == 'startScan').length;
      final stopped = ble.platformCalls.where((c) => c == 'stopScan').length;
      expect(
        stopped,
        greaterThanOrEqualTo(started),
        reason:
            'every scan this started must have been stopped again; '
            'calls were ${ble.platformCalls}',
      );
    });

    test(
      'a second scan tears the first one down instead of stacking',
      () async {
        ble.add(EmulatedPeripheral.bulb(id: _bulbId));

        final first = service
            .scan(timeout: const Duration(seconds: 30))
            .listen((_) {});
        await Future<void>.delayed(const Duration(milliseconds: 20));

        final second = await runScan();

        expect(
          second,
          hasLength(1),
          reason: 'the new scan still finds the bulb',
        );
        expect(
          ble.platformCalls.where((c) => c == 'startScan').length,
          2,
          reason: 'each scan starts the radio exactly once',
        );
        await first.cancel();
      },
    );

    test('a fresh scan does not resurface the previous scan results', () async {
      final bulb = ble.add(EmulatedPeripheral.bulb(id: _bulbId));
      expect(await runScan(), hasLength(1));

      // flutter_blue_plus replays its last accumulated result list to every new
      // listener, and only clears it inside startScan. Without the guard in
      // scan(), this second scan's first event is the PREVIOUS scan's list —
      // the bulb at its old -45 — followed by the genuine -30 advertisement.
      bulb.rssi = -30;
      final second = await runScan();

      expect(
        second.map((d) => d.rssi),
        [-30],
        reason: 'one fresh advertisement, not a stale replay before it',
      );
    });

    test(
      'asks the platform to keep reporting a device it already saw',
      () async {
        // Without continuousUpdates, Android suppresses same-payload
        // advertisements and Apple platforms coalesce duplicates: a device would
        // be reported once and then never again, leaving "still here" and
        // "switched off an hour ago" indistinguishable.
        ble.add(EmulatedPeripheral.bulb(id: _bulbId));

        await runScan();

        expect(ble.lastScanSettings?.continuousUpdates, isTrue);
        expect(ble.lastScanSettings?.continuousDivisor, continuousScanDivisor);
      },
    );

    test('an ambient scan asks Android for the balanced duty cycle', () async {
      // The energy dial: a scan the app starts by itself must not pin the
      // radio to continuous listening the way the pre-dial default did.
      ble.add(EmulatedPeripheral.bulb(id: _bulbId));
      service.isApple = false;

      final sub = service
          .scan(timeout: null, intensity: ScanIntensity.ambient)
          .listen((_) {});
      addTearDown(sub.cancel);
      await Future<void>.delayed(const Duration(milliseconds: 30));

      expect(
        ble.lastScanSettings?.androidScanMode,
        AndroidScanMode.balanced.value,
      );
      expect(
        ble.lastScanSettings?.continuousDivisor,
        1,
        reason:
            'the duty cycle already thinned receptions; the divisor on '
            'top would double a sleepy sensor\'s reception gaps',
      );
    });

    test(
      'on Apple the ambient scan thins at the divisor instead (F-020)',
      () async {
        // No scan-mode knob on Apple platforms, so the divisor is the only
        // thinning there is — and undivided, the always-on ambient scan shipped
        // twice the channel traffic of the burst it is meant to be cheaper than.
        ble.add(EmulatedPeripheral.bulb(id: _bulbId));
        service.isApple = true;

        final ambient = service
            .scan(timeout: null, intensity: ScanIntensity.ambient)
            .listen((_) {});
        addTearDown(ambient.cancel);
        await Future<void>.delayed(const Duration(milliseconds: 30));
        expect(
          ble.lastScanSettings?.continuousDivisor,
          appleAmbientScanDivisor,
        );

        final active = service
            .scan(timeout: null, intensity: ScanIntensity.active)
            .listen((_) {});
        addTearDown(active.cancel);
        await Future<void>.delayed(const Duration(milliseconds: 30));
        expect(ble.lastScanSettings?.continuousDivisor, continuousScanDivisor);
      },
    );

    test('a re-sighting moves lastSeen but not discoveredAt', () async {
      final bulb = ble.add(
        EmulatedPeripheral.bulb(id: _bulbId, name: 'ACME_Bulb'),
      );

      final found = await runScan(
        during: () async {
          await Future<void>.delayed(const Duration(milliseconds: 30));
          bulb.advertise(rssi: -30);
        },
      );

      expect(found, hasLength(2));
      expect(
        found[1].discoveredAt,
        found[0].discoveredAt,
        reason: 'advertising again does not make a device newly discovered',
      );
      expect(
        found[1].lastSeen.isAfter(found[0].lastSeen),
        isTrue,
        reason: 'but it does make it freshly seen',
      );
    });

    test('stopScan ends an in-progress scan', () async {
      ble.add(EmulatedPeripheral.bulb(id: _bulbId));

      var closed = false;
      final sub = service
          .scan(timeout: const Duration(seconds: 30))
          .listen((_) {}, onDone: () => closed = true);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      await service.stopScan();
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(ble.platformCalls, contains('stopScan'));
      expect(
        closed,
        isTrue,
        reason:
            'the app-facing stream must finish, not hang open for the '
            'remaining 30s of the requested window',
      );
      await sub.cancel();
    });
  });

  // A scan with no timeout is what the scan screen runs: it is not a window
  // with an answer at the end, it is a live picture of what is on air.
  group('continuous scan', () {
    /// Start one, collecting what it reports. Cancelled on teardown.
    ({List<IoTDevice> seen, List<Object> errors, List<bool> done})
    startContinuous() {
      final seen = <IoTDevice>[];
      final errors = <Object>[];
      final done = <bool>[];
      final sub = service
          .scan(timeout: null)
          .listen(seen.add, onError: errors.add, onDone: () => done.add(true));
      addTearDown(sub.cancel);
      return (seen: seen, errors: errors, done: done);
    }

    test('reports a device that only turns up later', () async {
      // The whole point: a bounded scan answers "what was advertising during
      // those 30 seconds", and a device plugged in afterwards never appears.
      final result = startContinuous();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(result.seen, isEmpty);

      ble
          .add(EmulatedPeripheral.bulb(id: _bulbId, name: 'Late Bulb'))
          .advertise();
      await Future<void>.delayed(const Duration(milliseconds: 30));

      expect(result.seen.map((d) => d.name), ['Late Bulb']);
      expect(result.done, isEmpty, reason: 'the scan is still running');
    });

    test('stays open long past a bounded scan\'s window', () async {
      ble.add(EmulatedPeripheral.bulb(id: _bulbId));
      final result = startContinuous();

      // The 5s belt-and-braces timeout that ends a bounded scan must not be
      // armed here; nothing may close this stream on a timer.
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(result.done, isEmpty);
      expect(result.errors, isEmpty);
    });

    test('stopScan ends it, stream and all', () async {
      ble.add(EmulatedPeripheral.bulb(id: _bulbId));
      final result = startContinuous();
      await Future<void>.delayed(const Duration(milliseconds: 30));

      await service.stopScan();
      await Future<void>.delayed(const Duration(milliseconds: 30));

      expect(ble.platformCalls, contains('stopScan'));
      expect(
        result.done,
        [true],
        reason:
            'a scan with no window of its own has to be told it is over, '
            'or its consumer waits on a stream nothing will feed again',
      );
    });

    test(
      'the radio being switched off surfaces as an actionable error',
      () async {
        // A scan meant to run all session has to notice the radio going dark
        // under it, rather than sitting there claiming to search.
        ble.add(EmulatedPeripheral.bulb(id: _bulbId));
        final result = startContinuous();
        await Future<void>.delayed(const Duration(milliseconds: 30));

        ble.adapterState = EmulatedAdapterState.off;
        await Future<void>.delayed(const Duration(milliseconds: 30));

        expect(result.errors.single, isA<BleUnavailableException>());
        expect(result.done, [true]);
      },
    );

    test('a refused refresh recovers on the retry, not a quarter of an hour '
        'later', () async {
      // fbp stops the running scan BEFORE starting its replacement, and unwinds
      // its own state if that start is refused — so a failed refresh leaves
      // nothing scanning at all. Waiting out the full interval would mean a tab
      // saying "searching" over a dark radio for fifteen minutes.
      service.continuousScanRefreshInterval = const Duration(milliseconds: 40);
      service.continuousScanRetryInterval = const Duration(milliseconds: 40);
      final result = startContinuous();
      await Future<void>.delayed(const Duration(milliseconds: 20));

      // The refresh that fires next is refused by the platform.
      ble.startScanRefusal = Exception('startScan refused');
      await Future<void>.delayed(const Duration(milliseconds: 60));

      // Prove the recovery by what it is for: a device that starts advertising
      // after the failed refresh still has to reach the app.
      ble
          .add(EmulatedPeripheral.bulb(id: _bulbId, name: 'After The Failure'))
          .advertise();
      await Future<void>.delayed(const Duration(milliseconds: 120));

      expect(result.seen.map((d) => d.name), contains('After The Failure'));
      expect(
        result.done,
        isEmpty,
        reason: 'a refresh failure does not end the scan the user sees',
      );
    });

    test('a stop meant for the previous scan cannot close its replacement', () async {
      // The shape the scan screen produces whenever a stop is followed closely
      // by a start: a tab switched away from and back, a device screen popped.
      // The old scan is cancelled, stopScan() is still in flight, and the
      // replacement starts inside that window.
      //
      // Honesty about what this pins: it exercises the sequence, not the
      // interleaving. stopScan() now claims the active scan BEFORE awaiting the
      // platform, so a scan installed during that await can never be torn down
      // on behalf of one that is already over — but flutter_blue_plus's scan
      // mutex and its synchronous isScanning bookkeeping keep the emulated
      // adapter from landing on the exact interleaving that used to break, so
      // this passes with the capture in either position. It is here to hold the
      // contract, not to prove the race.
      ble.add(EmulatedPeripheral.bulb(id: _bulbId));
      final first = service.scan(timeout: null).listen((_) {});
      await Future<void>.delayed(const Duration(milliseconds: 30));
      await first.cancel();

      ble.latency = const Duration(milliseconds: 60);
      final stopping = service.stopScan();
      final second = startContinuous();
      await stopping;
      await Future<void>.delayed(const Duration(milliseconds: 120));

      expect(
        second.done,
        isEmpty,
        reason: 'the replacement scan belongs to nobody but its own caller',
      );
      expect(second.errors, isEmpty);
    });

    test(
      'a teardown during an in-flight refresh does not revive the scan',
      () async {
        // Cancelling the refresh Timer cannot reach a callback that has already
        // fired and is awaiting startScan. Without a teardown check inside the
        // callback, that restart completes AFTER the consumer cancelled — and
        // then reschedules itself, leaving a radio scanning forever for nobody.
        service.continuousScanRefreshInterval = const Duration(
          milliseconds: 40,
        );
        ble.add(EmulatedPeripheral.bulb(id: _bulbId));
        final result = startContinuous();
        await Future<void>.delayed(const Duration(milliseconds: 20));

        // Slow the platform down so the next refresh is mid-startScan when the
        // teardown lands.
        ble.latency = const Duration(milliseconds: 60);
        await Future<void>.delayed(const Duration(milliseconds: 40));
        await service.stopScan();
        ble.latency = Duration.zero;

        // Let the in-flight restart finish and any (buggy) reschedule fire.
        await Future<void>.delayed(const Duration(milliseconds: 150));
        final startsAfterSettle = ble.platformCalls
            .where((c) => c == 'startScan')
            .length;
        await Future<void>.delayed(const Duration(milliseconds: 150));

        expect(
          ble.platformCalls.where((c) => c == 'startScan').length,
          startsAfterSettle,
          reason: 'no further restarts once the scan is over',
        );
        final calls = ble.platformCalls;
        expect(
          calls.lastIndexOf('stopScan'),
          greaterThan(calls.lastIndexOf('startScan')),
          reason:
              'whatever the in-flight restart revived was put back down; '
              'calls were $calls',
        );
        expect(result.done, [true]);
      },
    );

    test('restarts the platform scan so it cannot go opportunistic', () async {
      // Android downgrades a scan that has been running for 30 minutes to
      // opportunistic — callbacks still registered, radio no longer driven.
      // Restarting inside that window is what keeps a long scan real.
      service.continuousScanRefreshInterval = const Duration(milliseconds: 40);
      ble.add(EmulatedPeripheral.bulb(id: _bulbId));
      final result = startContinuous();

      await Future<void>.delayed(const Duration(milliseconds: 140));

      expect(
        ble.platformCalls.where((c) => c == 'startScan').length,
        greaterThan(2),
      );
      expect(
        result.done,
        isEmpty,
        reason: 'refreshing is invisible to the consumer',
      );
      expect(result.errors, isEmpty);
    });
  });

  group('adapterReady', () {
    test('replays the current state, then follows transitions', () async {
      final events = <bool>[];
      final sub = service.adapterReady().listen(events.add);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(
        events,
        [true],
        reason:
            'the current answer must arrive without waiting for a '
            'transition, or a listener attached while the radio is off '
            'would wait forever to learn that',
      );

      ble.adapterState = EmulatedAdapterState.off;
      await Future<void>.delayed(const Duration(milliseconds: 20));
      ble.adapterState = EmulatedAdapterState.on;
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(events, [true, false, true]);
      await sub.cancel();
    });

    test('unauthorized reads as not ready, same as off', () async {
      // The screen must not auto-resume into a permission refusal: granting
      // one means leaving the app, which the lifecycle path already covers.
      final events = <bool>[];
      final sub = service.adapterReady().listen(events.add);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      ble.adapterState = EmulatedAdapterState.unauthorized;
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(events, [true, false]);
      await sub.cancel();
    });
  });

  group('adapterUnauthorized', () {
    test('replays the current answer, then follows the grant', () async {
      // A Deny on the iOS prompt arrives as a transition, possibly long after
      // the scan that raised the prompt — and a revoke in Settings later
      // still. The screen needs to hear both as "permission needed".
      final events = <bool>[];
      final sub = service.adapterUnauthorized().listen(events.add);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(events, [false]);

      ble.adapterState = EmulatedAdapterState.unauthorized;
      await Future<void>.delayed(const Duration(milliseconds: 20));
      ble.adapterState = EmulatedAdapterState.on;
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(events, [false, true, false]);
      await sub.cancel();
    });

    test('a dark radio is not a denial', () async {
      final events = <bool>[];
      final sub = service.adapterUnauthorized().listen(events.add);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      ble.adapterState = EmulatedAdapterState.off;
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(events, [false]);
      await sub.cancel();
    });
  });

  group('connect', () {
    group('adapter state (F-023)', () {
      // With the radio off the platform refuses the connect with a plugin
      // error the UI cannot tell from a device out of range, so Reconnect
      // after a Control Centre toggle told the user to move closer.
      test('refuses while the radio is off, and says so', () async {
        ble.add(EmulatedPeripheral.bulb(id: _bulbId));
        ble.adapterState = EmulatedAdapterState.off;

        await expectLater(
          service.connect(_bulbId),
          throwsA(isA<BleUnavailableException>()),
        );
        expect(ble.platformCalls, isNot(contains('connect:$_bulbId')));
      });

      test('a permission refusal is reported as one', () async {
        ble.add(EmulatedPeripheral.bulb(id: _bulbId));
        ble.adapterState = EmulatedAdapterState.unauthorized;

        await expectLater(
          service.connect(_bulbId),
          throwsA(isA<BlePermissionDeniedException>()),
        );
        expect(ble.platformCalls, isNot(contains('connect:$_bulbId')));
      });

      test('waits for a settling state, like scan does', () async {
        // A saved device opened cold on iOS: the connect must wait for the
        // permission prompt to be answered, not fail underneath it.
        final bulb = ble.add(EmulatedPeripheral.bulb(id: _bulbId));
        ble.adapterState = EmulatedAdapterState.unknown;
        unawaited(
          Future<void>.delayed(const Duration(milliseconds: 30), () {
            ble.adapterState = EmulatedAdapterState.on;
          }),
        );

        await service.connect(_bulbId);

        expect(bulb.isConnected, isTrue);
      });

      test('a state that never settles refuses the connect', () async {
        ble.add(EmulatedPeripheral.bulb(id: _bulbId));
        service.adapterSettleWindow = const Duration(milliseconds: 100);
        ble.adapterState = EmulatedAdapterState.unknown;

        await expectLater(
          service.connect(_bulbId),
          throwsA(isA<BleUnavailableException>()),
        );
      });
    });

    test('connects and reports the connection state', () async {
      ble.add(EmulatedPeripheral.bulb(id: _bulbId));

      final states = <BleConnectionState>[];
      final sub = service.connectionState(_bulbId).listen(states.add);

      await service.connect(_bulbId);
      await service.disconnect(_bulbId);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await sub.cancel();

      expect(states, contains(BleConnectionState.connected));
      expect(states.last, BleConnectionState.disconnected);
    });

    test('throws when the peripheral refuses the connection', () async {
      final bulb = ble.add(EmulatedPeripheral.bulb(id: _bulbId));
      bulb.connectError = EmulatedGattError.refused;

      await expectLater(service.connect(_bulbId), throwsA(isA<Exception>()));
      expect(bulb.isConnected, isFalse);
    });

    test(
      'disconnecting an already-disconnected device is a no-op, not a throw',
      () async {
        ble.add(EmulatedPeripheral.bulb(id: _bulbId));
        await service.disconnect(_bulbId);
      },
    );

    test('reports the negotiated MTU once connected', () async {
      ble.add(EmulatedPeripheral.bulb(id: _bulbId, mtu: 247));
      await service.connect(_bulbId);

      expect(await service.mtu(_bulbId), 247);
    });

    test(
      'falls back to the 23-byte BLE floor for an unconnected device',
      () async {
        expect(await service.mtu('FF:FF:FF:FF:FF:FF'), 23);
      },
    );
  });

  // The Apple-only reconnect path (R-008). The remote id on Apple platforms
  // is a system-minted UUID, not an address, so a saved device the system has
  // forgotten fails before the radio is touched with "Peripheral not found" —
  // and the saved-devices screen went straight to connect() with no scan, so
  // the user was told to move closer, which cannot help. These run on every
  // host because the platform answer is injected, not read: on CI (all Linux)
  // the whole sequence would otherwise be dead code.
  group('Apple identifier rediscovery (R-008)', () {
    setUp(() {
      service.isApple = true;
      appleRediscoveryWindow = const Duration(milliseconds: 120);
    });
    tearDown(() => appleRediscoveryWindow = const Duration(seconds: 6));

    test('scans for a forgotten peripheral, then connects', () async {
      final bulb = ble.add(EmulatedPeripheral.bulb(id: _bulbId))
        ..unknownToSystem = true;

      await service.connect(_bulbId);

      expect(bulb.isConnected, isTrue);
      // Connect, a targeted scan, then connect again — in that order.
      expect(
        ble.platformCalls.where(
          (c) => c == 'connect:$_bulbId' || c == 'startScan',
        ),
        ['connect:$_bulbId', 'startScan', 'connect:$_bulbId'],
      );
      expect(ble.lastScanSettings?.withRemoteIds, [_bulbId]);
    });

    test('stops the rediscovery scan before connecting again', () async {
      ble.add(EmulatedPeripheral.bulb(id: _bulbId)).unknownToSystem = true;

      await service.connect(_bulbId);

      final calls = ble.platformCalls;
      expect(calls, contains('stopScan'));
      // The scan must be over before the second attempt: an iOS scan left
      // running through a connect is the battery cost the ambient scan is
      // tuned to avoid, and fbp refuses some operations mid-scan.
      expect(
        calls.indexOf('stopScan'),
        lessThan(calls.lastIndexOf('connect:$_bulbId')),
      );
    });

    test(
      'a peripheral that never advertises is reported as unheard, not far away',
      () async {
        // Powered off, asleep, or out of range: no sighting, so the system
        // cannot re-register it however close the user stands.
        ble.add(EmulatedPeripheral.bulb(id: _bulbId))
          ..unknownToSystem = true
          ..advertising = false;

        await expectLater(
          service.connect(_bulbId),
          throwsA(isA<BleDeviceUnheardException>()),
        );
        expect(ble.platformCalls, contains('startScan'));
        expect(ble.platformCalls, contains('stopScan'));
      },
    );

    test('does not scan on a non-Apple platform', () async {
      // Android resolves an address without the system's help, so a scan here
      // would add seconds to every reconnect for nothing.
      service.isApple = false;
      ble.add(EmulatedPeripheral.bulb(id: _bulbId)).unknownToSystem = true;

      await expectLater(service.connect(_bulbId), throwsA(isA<Object>()));
      expect(ble.platformCalls, isNot(contains('startScan')));
    });

    test('a peripheral the system still knows connects without a scan', () {
      ble.add(EmulatedPeripheral.bulb(id: _bulbId));

      return service.connect(_bulbId).then((_) {
        expect(ble.platformCalls, isNot(contains('startScan')));
      });
    });
  });

  group('discoverServices', () {
    test('maps the GATT table, including per-mode write properties', () async {
      ble.add(EmulatedPeripheral.bulb(id: _bulbId));
      await service.connect(_bulbId);

      final services = await service.discoverServices(_bulbId);

      expect(services.map((s) => s.uuid), [
        EmulatedUuids.controlService,
        EmulatedUuids.batteryService,
      ]);

      final command = services.first.characteristics.firstWhere(
        (c) => c.uuid == EmulatedUuids.controlCommand,
      );
      expect(command.canWrite, isTrue);
      expect(command.canWriteWithResponse, isFalse);
      expect(command.canWriteWithoutResponse, isTrue);
      expect(command.canRead, isFalse);

      final state = services.first.characteristics.firstWhere(
        (c) => c.uuid == EmulatedUuids.controlState,
      );
      expect(state.canRead, isTrue);
      expect(state.canNotify, isTrue);
      expect(state.canWrite, isFalse);
    });

    test(
      'a service declaring one uuid twice yields two characteristics',
      () async {
        // GATT permits it and real devices do it (a strip with two identical
        // channel characteristics). flutter_blue_plus could not address the
        // second until 1.35.6 gave each an instance id; before the bump the two
        // were indistinguishable and a read of either could answer from the
        // wrong one.
        final twin = EmulatedPeripheral(
          id: _bulbId,
          name: 'Twin',
          services: [
            EmulatedService(
              uuid: EmulatedUuids.controlService,
              characteristics: [
                EmulatedCharacteristic(
                  uuid: EmulatedUuids.controlCommand,
                  value: const [1],
                  canRead: true,
                ),
                EmulatedCharacteristic(
                  uuid: EmulatedUuids.controlCommand,
                  value: const [2],
                  canRead: true,
                ),
              ],
            ),
          ],
        );
        ble.add(twin);
        await service.connect(_bulbId);

        final services = await service.discoverServices(_bulbId);

        final chars = services.single.characteristics
            .where((c) => c.uuid == EmulatedUuids.controlCommand)
            .toList();
        expect(
          chars,
          hasLength(2),
          reason: 'both attributes have to survive discovery to be addressable',
        );
        expect(twin.services.single.characteristics.map((c) => c.instanceId), [
          0,
          1,
        ]);
      },
    );

    test('retries a discovery that comes back empty', () async {
      final bulb = ble.add(EmulatedPeripheral.bulb(id: _bulbId));
      // The BlueZ ServicesResolved race: the first discovery after connect sees
      // an unpopulated object tree.
      bulb.emptyDiscoveries = 1;
      await service.connect(_bulbId);

      final services = await service.discoverServices(_bulbId);

      expect(services, hasLength(2));
      expect(
        ble.platformCalls.where((c) => c.startsWith('discoverServices')).length,
        2,
      );
    });

    test(
      'a services-changed event from the platform drops the cached table',
      () async {
        // CoreBluetooth delivers didModifyServices whether or not the app
        // subscribed to Service Changed; the darwin plugin forwards it as
        // OnServicesReset and fbp clears its own cache. Ours was cleared only
        // in disconnect(), so a peripheral that republished its table after
        // pairing left the service walking stale handles until the user
        // disconnected by hand.
        ble.add(EmulatedPeripheral.bulb(id: _bulbId));
        await service.connect(_bulbId);
        await service.discoverServices(_bulbId);
        await service.discoverServices(_bulbId);
        expect(
          ble.platformCalls.where((c) => c == 'discoverServices:$_bulbId'),
          hasLength(1),
          reason: 'the second call is served from the cache',
        );

        ble.pushServicesReset(_bulbId);
        await Future<void>.delayed(Duration.zero);
        await service.discoverServices(_bulbId);
        expect(
          ble.platformCalls.where((c) => c == 'discoverServices:$_bulbId'),
          hasLength(2),
          reason: 'after the reset the table must be rediscovered',
        );
      },
    );

    test('caches the tree so later reads do not re-discover', () async {
      ble.add(EmulatedPeripheral.bulb(id: _bulbId));
      await service.connect(_bulbId);

      await service.discoverServices(_bulbId);
      await service.discoverServices(_bulbId);
      await service.readCharacteristic(
        _bulbId,
        EmulatedUuids.batteryService,
        EmulatedUuids.batteryLevel,
      );

      expect(
        ble.platformCalls.where((c) => c.startsWith('discoverServices')).length,
        1,
      );
    });

    test('re-discovers after a disconnect', () async {
      ble.add(EmulatedPeripheral.bulb(id: _bulbId));
      await service.connect(_bulbId);
      await service.discoverServices(_bulbId);

      await service.disconnect(_bulbId);
      await service.connect(_bulbId);
      await service.discoverServices(_bulbId);

      expect(
        ble.platformCalls.where((c) => c.startsWith('discoverServices')).length,
        2,
      );
    });

    test(
      'gives up after the retry ladder and caches the empty verdict',
      () async {
        final bulb = ble.add(EmulatedPeripheral.bulb(id: _bulbId));
        // Never resolves. This is the one deliberately slow test in the file: the
        // ladder in nextEmptyDiscoveryRetryDelay is 200+400+800+1600+3200ms by
        // design, and walking it is the only way to prove that the empty result
        // is cached rather than re-laddered on every later call.
        bulb.emptyDiscoveries = 1000;
        await service.connect(_bulbId);

        expect(await service.discoverServices(_bulbId), isEmpty);
        expect(
          ble.platformCalls
              .where((c) => c.startsWith('discoverServices'))
              .length,
          6,
          reason: 'one attempt plus five retries',
        );

        expect(await service.discoverServices(_bulbId), isEmpty);
        expect(
          ble.platformCalls
              .where((c) => c.startsWith('discoverServices'))
              .length,
          6,
          reason: 'the settled verdict is cached, not re-laddered',
        );
      },
      timeout: const Timeout(Duration(seconds: 60)),
    );

    test('throws when the peripheral fails discovery outright', () async {
      final bulb = ble.add(EmulatedPeripheral.bulb(id: _bulbId));
      bulb.discoverError = EmulatedGattError.refused;
      await service.connect(_bulbId);

      await expectLater(
        service.discoverServices(_bulbId),
        throwsA(isA<Exception>()),
      );
    });
  });

  group('read and write', () {
    setUp(() async {
      ble.add(EmulatedPeripheral.bulb(id: _bulbId));
      await service.connect(_bulbId);
    });

    test('reads the peripheral value', () async {
      expect(
        await service.readCharacteristic(
          _bulbId,
          EmulatedUuids.batteryService,
          EmulatedUuids.batteryLevel,
        ),
        [85],
      );
    });

    test('reads what a later write left behind', () async {
      await service.writeCharacteristic(
        _bulbId,
        EmulatedUuids.controlService,
        EmulatedUuids.controlState,
        [0, 10, 1, 2, 3],
      );

      expect(
        await service.readCharacteristic(
          _bulbId,
          EmulatedUuids.controlService,
          EmulatedUuids.controlState,
        ),
        [0, 10, 1, 2, 3],
      );
    });

    test(
      'writes without response to a characteristic that supports no other mode',
      () async {
        await service.writeCharacteristic(
          _bulbId,
          EmulatedUuids.controlService,
          EmulatedUuids.controlCommand,
          [0x01, 0x02],
        );

        final command = ble
            .peripheral(_bulbId)!
            .characteristic(EmulatedUuids.controlCommand)!;
        expect(command.writes, hasLength(1));
        expect(command.writes.single.value, [0x01, 0x02]);
        expect(
          command.writes.single.type,
          EmulatedWriteType.withoutResponse,
          reason:
              'a with-response write to this characteristic would be '
              'silently dropped by real hardware',
        );
      },
    );

    test(
      'prefers an acknowledged write when the characteristic supports it',
      () async {
        final peripheral = ble.peripheral(_bulbId)!;
        peripheral.services.first.characteristics.add(
          EmulatedCharacteristic(
            uuid: '0000fff3-0000-1000-8000-00805f9b34fb',
            canWriteWithResponse: true,
            canWriteWithoutResponse: true,
          ),
        );
        // Re-discover so the new characteristic is in the service's cache.
        await service.disconnect(_bulbId);
        await service.connect(_bulbId);
        await service.discoverServices(_bulbId);

        await service.writeCharacteristic(
          _bulbId,
          EmulatedUuids.controlService,
          '0000fff3-0000-1000-8000-00805f9b34fb',
          [7],
        );

        final char = peripheral.characteristic(
          '0000fff3-0000-1000-8000-00805f9b34fb',
        )!;
        expect(char.writes.single.type, EmulatedWriteType.withResponse);
      },
    );

    test('surfaces a read the peripheral refuses', () async {
      ble
              .peripheral(_bulbId)!
              .characteristic(EmulatedUuids.batteryLevel)!
              .readError =
          EmulatedGattError.refused;

      await expectLater(
        service.readCharacteristic(
          _bulbId,
          EmulatedUuids.batteryService,
          EmulatedUuids.batteryLevel,
        ),
        throwsA(isA<Exception>()),
      );
    });

    test('surfaces a write the peripheral refuses', () async {
      ble
              .peripheral(_bulbId)!
              .characteristic(EmulatedUuids.controlCommand)!
              .writeError =
          EmulatedGattError.refused;

      await expectLater(
        service.writeCharacteristic(
          _bulbId,
          EmulatedUuids.controlService,
          EmulatedUuids.controlCommand,
          [1],
        ),
        throwsA(isA<Exception>()),
      );
    });

    test(
      'throws for a characteristic the peripheral does not expose',
      () async {
        await expectLater(
          service.readCharacteristic(
            _bulbId,
            EmulatedUuids.controlService,
            '0000dead-0000-1000-8000-00805f9b34fb',
          ),
          throwsA(isA<StateError>()),
        );
      },
    );
  });

  group('subscribeCharacteristic', () {
    test('delivers notifications the peripheral pushes', () async {
      final bulb = ble.add(EmulatedPeripheral.bulb(id: _bulbId));
      await service.connect(_bulbId);

      final received = <List<int>>[];
      final sub = service
          .subscribeCharacteristic(
            _bulbId,
            EmulatedUuids.batteryService,
            EmulatedUuids.batteryLevel,
          )
          .listen(received.add);

      // Give setNotifyValue (and its CCCD confirmation) time to complete before
      // the peripheral starts pushing — a real one would drop notifications
      // sent before the subscription is live, and so does the emulator.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      bulb.pushNotification(EmulatedUuids.batteryLevel, [84]);
      bulb.pushNotification(EmulatedUuids.batteryLevel, [83]);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(received, [
        [84],
        [83],
      ]);

      await sub.cancel();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(
        ble.platformCalls,
        contains('setNotify:${EmulatedUuids.batteryLevel}=false'),
        reason: 'cancelling the stream must stop the peripheral pushing',
      );
    });

    test('a second subscriber keeps notifications alive when the first '
        'cancels', () async {
      // Issue #29: six sensor tiles and the raw service card all subscribe to
      // one combined-packet characteristic, and the panel's ListView disposes
      // children scrolled out of cache. The CCCD must only be disabled when
      // the LAST subscriber goes away.
      final bulb = ble.add(EmulatedPeripheral.bulb(id: _bulbId));
      await service.connect(_bulbId);

      final first = service
          .subscribeCharacteristic(
            _bulbId,
            EmulatedUuids.batteryService,
            EmulatedUuids.batteryLevel,
          )
          .listen((_) {});
      final received = <List<int>>[];
      final second = service
          .subscribeCharacteristic(
            _bulbId,
            EmulatedUuids.batteryService,
            EmulatedUuids.batteryLevel,
          )
          .listen(received.add);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      // The enable is shared, not repeated per subscriber.
      expect(
        ble.platformCalls.where(
          (c) => c == 'setNotify:${EmulatedUuids.batteryLevel}=true',
        ),
        hasLength(1),
        reason: 'two subscribers should share one CCCD enable',
      );

      await first.cancel();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(
        ble.platformCalls,
        isNot(contains('setNotify:${EmulatedUuids.batteryLevel}=false')),
        reason: 'the second subscriber still wants notifications',
      );

      // And they still flow.
      bulb.pushNotification(EmulatedUuids.batteryLevel, [70]);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(received, [
        [70],
      ]);

      await second.cancel();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(
        ble.platformCalls,
        contains('setNotify:${EmulatedUuids.batteryLevel}=false'),
        reason: 'the last cancel is the one that quiets the peripheral',
      );
    });

    test('a cancel parked on an in-flight enable never disables a successor '
        'subscription', () async {
      // The freeze issue #29's refcount exists to prevent, through a second
      // door: A cancels while its shared enable is still in flight, the
      // deferred disable parks on that enable, B re-subscribes meanwhile.
      // The disable must yield to B's fresh share instead of landing last
      // and silencing it.
      final bulb = ble.add(EmulatedPeripheral.bulb(id: _bulbId));
      // A peripheral that acks its CCCD writes late: every enable stays in
      // flight for this long, which is the window under test. A late ack —
      // not a withheld one — because a withheld ack resolves only at the
      // service's confirmation timeout, which is 3 s on Linux and 15 s
      // elsewhere, and this test used to be built on the Linux figure: on a
      // macOS host B's enable was still queued behind A's at the 7 s mark
      // and the assertion below failed on every run.
      const ackDelay = Duration(milliseconds: 1500);
      bulb.cccdConfirmDelay = ackDelay;
      await service.connect(_bulbId);

      final first = service
          .subscribeCharacteristic(
            _bulbId,
            EmulatedUuids.batteryService,
            EmulatedUuids.batteryLevel,
          )
          .listen((_) {});
      await Future<void>.delayed(const Duration(milliseconds: 100));
      // Cancel while the enable is mid-flight; do not await — the release
      // itself is what parks on the enable.
      unawaited(first.cancel());
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final received = <List<int>>[];
      final second = service
          .subscribeCharacteristic(
            _bulbId,
            EmulatedUuids.batteryService,
            EmulatedUuids.batteryLevel,
          )
          .listen(received.add);

      // Both enables ride out their ack delays (they serialize on fbp's
      // operation mutex), plus slack.
      await Future<void>.delayed(ackDelay * 2 + const Duration(seconds: 1));
      expect(
        ble.platformCalls.where(
          (c) => c == 'setNotify:${EmulatedUuids.batteryLevel}=false',
        ),
        isEmpty,
        reason: "A's deferred disable must yield to B's live share",
      );

      bulb.pushNotification(EmulatedUuids.batteryLevel, [61]);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(received, [
        [61],
      ]);
      await second.cancel();
    });

    test(
      'a subscription abandoned before its enable writes no CCCD at all',
      () async {
        // Cancelling before the characteristic lookup finishes must abort the
        // shared enable: a CCCD write (and on pairing-required peripherals,
        // the system pairing dialog behind it) for zero subscribers is pure
        // harm.
        ble.add(EmulatedPeripheral.bulb(id: _bulbId));
        await service.connect(_bulbId);

        final sub = service
            .subscribeCharacteristic(
              _bulbId,
              EmulatedUuids.batteryService,
              EmulatedUuids.batteryLevel,
            )
            .listen((_) {});
        // Cancel in the same turn, before discovery's microtask confirmation
        // can complete the lookup.
        await sub.cancel();
        await Future<void>.delayed(const Duration(milliseconds: 100));

        expect(
          ble.platformCalls.where((c) => c.startsWith('setNotify:')),
          isEmpty,
          reason: 'nobody was left to enable notifications for',
        );
      },
    );

    test('a redundant connect keeps live shares, and connection claims keep '
        'the link up until the last owner leaves', () async {
      // flutter_blue_plus no-ops connect() on an open link, so CCCD state
      // survives — live shares must too. And with two claims on the link
      // (device screen + group run), the first disconnect must not tear it
      // down under the other.
      final bulb = ble.add(EmulatedPeripheral.bulb(id: _bulbId));
      await service.connect(_bulbId);

      final received = <List<int>>[];
      final sub = service
          .subscribeCharacteristic(
            _bulbId,
            EmulatedUuids.batteryService,
            EmulatedUuids.batteryLevel,
          )
          .listen(received.add);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      await service.connect(_bulbId); // second owner, same open link
      await service.disconnect(_bulbId); // first owner leaves

      expect(
        ble.platformCalls.where((c) => c.startsWith('disconnect:')),
        isEmpty,
        reason: 'one owner remains; the link must stay up',
      );
      bulb.pushNotification(EmulatedUuids.batteryLevel, [58]);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(received, [
        [58],
      ], reason: 'the share survived the redundant connect');

      await sub.cancel();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(
        ble.platformCalls,
        contains('setNotify:${EmulatedUuids.batteryLevel}=false'),
        reason: 'the share was not orphaned: last cancel still disables',
      );

      await service.disconnect(_bulbId); // last owner leaves
      expect(
        ble.platformCalls.where((c) => c.startsWith('disconnect:')),
        isNotEmpty,
      );
    });

    test('a connect issued while the first is still in flight does not '
        'expire the shares that first owner goes on to install', () async {
      // Both connects are issued while the device is down. With a pre-await
      // isConnected snapshot, both would read "this call turned the link
      // over" — and whichever resumed second would expire the notify shares
      // the first owner had installed on the (single, shared) link by then.
      // Connects serialize per device instead, so the second call observes
      // the link the first established and leaves its shares alone.
      final bulb = ble.add(EmulatedPeripheral.bulb(id: _bulbId));
      final first = service.connect(_bulbId);
      final second = service.connect(_bulbId);
      await first;

      final received = <List<int>>[];
      final sub = service
          .subscribeCharacteristic(
            _bulbId,
            EmulatedUuids.batteryService,
            EmulatedUuids.batteryLevel,
          )
          .listen(received.add);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await second;

      bulb.pushNotification(EmulatedUuids.batteryLevel, [42]);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(received, [
        [42],
      ], reason: 'the trailing connect must not have expired the share');
      expect(
        ble.platformCalls.where(
          (c) => c == 'setNotify:${EmulatedUuids.batteryLevel}=true',
        ),
        hasLength(1),
        reason: 'one live share, enabled once — never expired and redone',
      );

      // Both queued connects took a claim: the first release keeps the link.
      await sub.cancel();
      await service.disconnect(_bulbId);
      expect(
        ble.platformCalls.where((c) => c.startsWith('disconnect:')),
        isEmpty,
        reason: 'the second (serialized) connect still owns a claim',
      );
      await service.disconnect(_bulbId);
      expect(
        ble.platformCalls.where((c) => c.startsWith('disconnect:')),
        isNotEmpty,
      );
    });

    test('a reconnect enables notifications afresh even with a stale '
        'subscription open', () async {
      // A subscription from a previous link that was never cancelled must
      // neither satisfy the new link's enable (CCCD state died with the old
      // connection) nor, when finally cancelled, disable notifications under
      // the new link's subscribers.
      final bulb = ble.add(EmulatedPeripheral.bulb(id: _bulbId));
      await service.connect(_bulbId);
      final stale = service
          .subscribeCharacteristic(
            _bulbId,
            EmulatedUuids.batteryService,
            EmulatedUuids.batteryLevel,
          )
          .listen((_) {});
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await service.disconnect(_bulbId);

      await service.connect(_bulbId);
      final received = <List<int>>[];
      final fresh = service
          .subscribeCharacteristic(
            _bulbId,
            EmulatedUuids.batteryService,
            EmulatedUuids.batteryLevel,
          )
          .listen(received.add);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(
        ble.platformCalls.where(
          (c) => c == 'setNotify:${EmulatedUuids.batteryLevel}=true',
        ),
        hasLength(2),
        reason: 'the new link needs its own CCCD enable',
      );

      // The stale handle finally goes away; the fresh subscriber must not
      // lose its stream over it.
      await stale.cancel();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(
        ble.platformCalls.where(
          (c) => c == 'setNotify:${EmulatedUuids.batteryLevel}=false',
        ),
        isEmpty,
        reason: 'a dead share never writes into the new connection',
      );
      bulb.pushNotification(EmulatedUuids.batteryLevel, [66]);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(received, [
        [66],
      ]);

      await fresh.cancel();
    });

    test(
      'drops notifications sent after the subscription is torn down',
      () async {
        final bulb = ble.add(EmulatedPeripheral.bulb(id: _bulbId));
        await service.connect(_bulbId);

        final received = <List<int>>[];
        final sub = service
            .subscribeCharacteristic(
              _bulbId,
              EmulatedUuids.batteryService,
              EmulatedUuids.batteryLevel,
            )
            .listen(received.add);
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await sub.cancel();
        await Future<void>.delayed(const Duration(milliseconds: 20));

        bulb.pushNotification(EmulatedUuids.batteryLevel, [80]);
        await Future<void>.delayed(const Duration(milliseconds: 20));

        expect(received, isEmpty);
      },
    );

    test(
      'subscribes without waiting when the peripheral exposes no CCCD',
      () async {
        // BlueZ manages the CCCD internally and never exposes it as a descriptor.
        final bulb = ble.add(
          EmulatedPeripheral(
            id: _bulbId,
            name: 'No CCCD',
            services: [
              EmulatedService(
                uuid: EmulatedUuids.batteryService,
                characteristics: [
                  EmulatedCharacteristic(
                    uuid: EmulatedUuids.batteryLevel,
                    value: const [90],
                    canRead: true,
                    canNotify: true,
                    exposesCccd: false,
                  ),
                ],
              ),
            ],
          ),
        );
        await service.connect(_bulbId);

        final received = <List<int>>[];
        final sub = service
            .subscribeCharacteristic(
              _bulbId,
              EmulatedUuids.batteryService,
              EmulatedUuids.batteryLevel,
            )
            .listen(received.add);
        await Future<void>.delayed(const Duration(milliseconds: 50));
        bulb.pushNotification(EmulatedUuids.batteryLevel, [89]);
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await sub.cancel();

        expect(received, [
          [89],
        ]);
      },
    );

    test(
      'errors the stream for a characteristic that does not exist',
      () async {
        ble.add(EmulatedPeripheral.bulb(id: _bulbId));
        await service.connect(_bulbId);

        await expectLater(
          service.subscribeCharacteristic(
            _bulbId,
            EmulatedUuids.controlService,
            '0000dead-0000-1000-8000-00805f9b34fb',
          ),
          emitsError(isA<StateError>()),
        );
      },
    );

    test(
      'keeps the subscription alive when the Linux backend never confirms '
      'the CCCD write',
      () async {
        // flutter_blue_plus_linux applies StartNotify synchronously and never
        // emits the descriptor-written event flutter_blue_plus waits for, so
        // every setNotifyValue times out AFTER succeeding. isSpuriousLinuxNotify-
        // Timeout is what turns that into a warning instead of a dead
        // subscription — this is that path, running for real.
        final bulb = ble.add(EmulatedPeripheral.bulb(id: _bulbId));
        bulb.confirmsCccdWrites = false;
        await service.connect(_bulbId);

        final received = <List<int>>[];
        final sub = service
            .subscribeCharacteristic(
              _bulbId,
              EmulatedUuids.batteryService,
              EmulatedUuids.batteryLevel,
            )
            .listen(received.add);

        // The service shortens the Linux confirmation wait to 3s; wait it out.
        await Future<void>.delayed(const Duration(milliseconds: 3500));
        bulb.pushNotification(EmulatedUuids.batteryLevel, [77]);
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await sub.cancel();

        expect(received, [
          [77],
        ]);
      },
      timeout: const Timeout(Duration(seconds: 30)),
      // The tolerance is deliberately Linux-only (see
      // isSpuriousLinuxNotifyTimeout), so on any other host this same setup
      // correctly produces a failed subscription instead.
      skip: Platform.isLinux
          ? null
          : 'the spurious-timeout tolerance only applies on Linux',
    );
  });

  group('recentNotifications', () {
    test(
      'buffers pushes so a late subscriber can still recover them',
      () async {
        // The point of the ring: a device that announces itself ONCE on connect
        // (the SmartDawn curtain's panel size) pushes before the widget that
        // wants it exists. Whoever was subscribed at the time captures it.
        final bulb = ble.add(EmulatedPeripheral.bulb(id: _bulbId));
        await service.connect(_bulbId);

        final sub = service
            .subscribeCharacteristic(
              _bulbId,
              EmulatedUuids.batteryService,
              EmulatedUuids.batteryLevel,
            )
            .listen((_) {});
        await Future<void>.delayed(const Duration(milliseconds: 50));
        bulb.pushNotification(EmulatedUuids.batteryLevel, [84]);
        bulb.pushNotification(EmulatedUuids.batteryLevel, [83]);
        await Future<void>.delayed(const Duration(milliseconds: 20));

        expect(
          service.recentNotifications(
            _bulbId,
            EmulatedUuids.batteryService,
            EmulatedUuids.batteryLevel,
          ),
          [
            [84],
            [83],
          ],
        );

        await sub.cancel();
      },
    );

    test(
      'one push is buffered once however many subscribers share it',
      () async {
        // The ring is filled from the SHARED enable, not from each subscriber's
        // listener. Recording per subscriber would enter one physical push N
        // times and evict the buffer N times faster — on a characteristic with
        // several cards on it, the connect-time push this exists to recover
        // would be gone before anyone asked for it.
        final bulb = ble.add(EmulatedPeripheral.bulb(id: _bulbId));
        await service.connect(_bulbId);

        final first = service
            .subscribeCharacteristic(
              _bulbId,
              EmulatedUuids.batteryService,
              EmulatedUuids.batteryLevel,
            )
            .listen((_) {});
        final second = service
            .subscribeCharacteristic(
              _bulbId,
              EmulatedUuids.batteryService,
              EmulatedUuids.batteryLevel,
            )
            .listen((_) {});
        await Future<void>.delayed(const Duration(milliseconds: 50));
        bulb.pushNotification(EmulatedUuids.batteryLevel, [84]);
        await Future<void>.delayed(const Duration(milliseconds: 20));

        expect(
          service.recentNotifications(
            _bulbId,
            EmulatedUuids.batteryService,
            EmulatedUuids.batteryLevel,
          ),
          [
            [84],
          ],
        );

        await first.cancel();
        await second.cancel();
      },
    );

    test('a released characteristic stops filling the ring', () async {
      // The recorder rides the share, so the last cancel must take it with
      // it — a recorder outliving its subscribers would keep buffering for a
      // characteristic nobody is watching.
      final bulb = ble.add(EmulatedPeripheral.bulb(id: _bulbId));
      await service.connect(_bulbId);

      final sub = service
          .subscribeCharacteristic(
            _bulbId,
            EmulatedUuids.batteryService,
            EmulatedUuids.batteryLevel,
          )
          .listen((_) {});
      await Future<void>.delayed(const Duration(milliseconds: 50));
      bulb.pushNotification(EmulatedUuids.batteryLevel, [84]);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await sub.cancel();
      await Future<void>.delayed(const Duration(milliseconds: 20));

      bulb.pushNotification(EmulatedUuids.batteryLevel, [83]);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(
        service.recentNotifications(
          _bulbId,
          EmulatedUuids.batteryService,
          EmulatedUuids.batteryLevel,
        ),
        [
          [84],
        ],
        reason: 'the push after the last cancel must not be buffered',
      );
    });

    test('disconnecting clears the buffer', () async {
      // The ring is per-connection: a stale push replayed into the next link
      // would size a canvas from the previous device's answer.
      final bulb = ble.add(EmulatedPeripheral.bulb(id: _bulbId));
      await service.connect(_bulbId);

      final sub = service
          .subscribeCharacteristic(
            _bulbId,
            EmulatedUuids.batteryService,
            EmulatedUuids.batteryLevel,
          )
          .listen((_) {});
      await Future<void>.delayed(const Duration(milliseconds: 50));
      bulb.pushNotification(EmulatedUuids.batteryLevel, [84]);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await sub.cancel();

      await service.disconnect(_bulbId);

      expect(
        service.recentNotifications(
          _bulbId,
          EmulatedUuids.batteryService,
          EmulatedUuids.batteryLevel,
        ),
        isEmpty,
      );
    });

    test(
      'a dropped link does not carry its pushes into the reconnect',
      () async {
        // The buffer is per-connection, and a link the peripheral drops never
        // reaches disconnect() — so the clear has to ride the same link-turnover
        // path the notify shares do, or a reconnect starts holding the previous
        // link's pushes as if the device had just sent them.
        final bulb = ble.add(EmulatedPeripheral.bulb(id: _bulbId));
        await service.connect(_bulbId);

        final sub = service
            .subscribeCharacteristic(
              _bulbId,
              EmulatedUuids.batteryService,
              EmulatedUuids.batteryLevel,
            )
            .listen((_) {});
        await Future<void>.delayed(const Duration(milliseconds: 50));
        bulb.pushNotification(EmulatedUuids.batteryLevel, [84]);
        await Future<void>.delayed(const Duration(milliseconds: 20));

        bulb.dropLink();
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await sub.cancel();

        await service.connect(_bulbId);

        expect(
          service.recentNotifications(
            _bulbId,
            EmulatedUuids.batteryService,
            EmulatedUuids.batteryLevel,
          ),
          isEmpty,
        );
      },
    );
  });

  group('link loss', () {
    test(
      'a peripheral that drops the link is reported as disconnected',
      () async {
        final bulb = ble.add(EmulatedPeripheral.bulb(id: _bulbId));
        await service.connect(_bulbId);

        final states = <BleConnectionState>[];
        final sub = service.connectionState(_bulbId).listen(states.add);
        bulb.dropLink();
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await sub.cancel();

        expect(states.last, BleConnectionState.disconnected);
      },
    );

    test('reads after a link loss fail rather than hanging', () async {
      final bulb = ble.add(EmulatedPeripheral.bulb(id: _bulbId));
      await service.connect(_bulbId);
      await service.discoverServices(_bulbId);

      bulb.dropLink();
      await Future<void>.delayed(const Duration(milliseconds: 20));

      await expectLater(
        service.readCharacteristic(
          _bulbId,
          EmulatedUuids.batteryService,
          EmulatedUuids.batteryLevel,
        ),
        throwsA(isA<Exception>()),
      );
    });
  });

  // Two devices, identical up to the moment data is asked for. Everything
  // before that — advertising, connecting, service discovery — behaves the
  // same on both, which is exactly why a suite that only ever exercises open
  // devices never learns what the app says to the other kind.
  group('pairing', () {
    Future<void> openAndDiscover(String id) async {
      await service.connect(id);
      await service.discoverServices(id);
    }

    test('a device that needs no pairing is readable straight away', () async {
      ble.add(EmulatedPeripheral.bulb(id: _bulbId));
      await openAndDiscover(_bulbId);

      expect(
        await service.readCharacteristic(
          _bulbId,
          EmulatedUuids.batteryService,
          EmulatedUuids.batteryLevel,
        ),
        [85],
      );
      expect(
        ble.platformCalls,
        isNot(contains('createBond:$_bulbId')),
        reason: 'nothing refused anything, so nothing should ask to pair',
      );
    });

    test('a device that needs pairing still connects and discovers', () async {
      ble.add(EmulatedPeripheral.bulb(id: _lockId, requiresPairing: true));
      await service.connect(_lockId);

      // The GATT table is readable on an unencrypted link, so this must NOT
      // fail. A device whose services never appeared would look broken rather
      // than unpaired, and the user would have no idea what to do about it.
      expect(await service.discoverServices(_lockId), hasLength(2));
    });

    test('a read from an unpaired device asks the user to pair', () async {
      ble.add(EmulatedPeripheral.bulb(id: _lockId, requiresPairing: true));
      await openAndDiscover(_lockId);

      await expectLater(
        service.readCharacteristic(
          _lockId,
          EmulatedUuids.batteryService,
          EmulatedUuids.batteryLevel,
        ),
        throwsA(isA<BlePairingRequiredException>()),
      );
    });

    test('a write to an unpaired device asks the user to pair', () async {
      ble.add(EmulatedPeripheral.bulb(id: _lockId, requiresPairing: true));
      await openAndDiscover(_lockId);

      await expectLater(
        service.writeCharacteristic(
          _lockId,
          EmulatedUuids.controlService,
          EmulatedUuids.controlCommand,
          [1, 1],
        ),
        throwsA(isA<BlePairingRequiredException>()),
      );
    });

    test('subscribing to an unpaired device asks the user to pair', () async {
      ble.add(EmulatedPeripheral.bulb(id: _lockId, requiresPairing: true));
      await openAndDiscover(_lockId);

      // The CCCD is an attribute like any other, so enabling notifications is
      // refused the same way — and a spec-declared sensor reaches the device
      // through exactly this call.
      await expectLater(
        service.subscribeCharacteristic(
          _lockId,
          EmulatedUuids.batteryService,
          EmulatedUuids.batteryLevel,
        ),
        emitsError(isA<BlePairingRequiredException>()),
      );
    });

    test('the same read succeeds once the device is bonded', () async {
      final lock = ble.add(
        EmulatedPeripheral.bulb(id: _lockId, requiresPairing: true),
      );
      await openAndDiscover(_lockId);

      await expectLater(
        service.readCharacteristic(
          _lockId,
          EmulatedUuids.batteryService,
          EmulatedUuids.batteryLevel,
        ),
        throwsA(isA<BlePairingRequiredException>()),
      );

      // What accepting the system pairing dialog amounts to.
      lock.bondState = EmulatedBondState.bonded;

      expect(
        await service.readCharacteristic(
          _lockId,
          EmulatedUuids.batteryService,
          EmulatedUuids.batteryLevel,
        ),
        [85],
      );
    });

    test('a bonded pairing-required device behaves like an open one', () async {
      final lock = ble.add(
        EmulatedPeripheral.bulb(id: _lockId, requiresPairing: true),
      );
      lock.bondState = EmulatedBondState.bonded;
      await openAndDiscover(_lockId);

      await service.writeCharacteristic(
        _lockId,
        EmulatedUuids.controlService,
        EmulatedUuids.controlCommand,
        [1, 1],
      );
      expect(
        lock.characteristic(EmulatedUuids.controlCommand)!.writes,
        hasLength(1),
      );

      final received = <List<int>>[];
      final sub = service
          .subscribeCharacteristic(
            _lockId,
            EmulatedUuids.batteryService,
            EmulatedUuids.batteryLevel,
          )
          .listen(received.add);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      lock.pushNotification(EmulatedUuids.batteryLevel, [84]);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await sub.cancel();

      expect(received, [
        [84],
      ]);
    });
  });
}
