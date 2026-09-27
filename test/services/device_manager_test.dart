// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/models/iot_device.dart';
import 'package:liberated_bread_mobile/services/device_manager.dart';

void main() {
  late DeviceManager manager;
  setUp(() {
    manager = DeviceManager();
  });

  /// A fixed instant to age devices against, so nothing here depends on how
  /// long the test itself took.
  final now = DateTime(2026, 8, 10, 12);

  IoTDevice makeDevice({
    String id = 'AA:BB:CC:DD:EE:FF',
    int rssi = -50,
    Duration ago = Duration.zero,
  }) {
    return IoTDevice(
      id: id,
      name: 'Test',
      rssi: rssi,
      isConnectable: true,
      discoveredAt: now.subtract(ago),
      lastSeen: now.subtract(ago),
    );
  }

  group('DeviceManager', () {
    test('starts empty', () {
      expect(manager.count, equals(0));
    });

    test('addOrUpdate adds a new device', () {
      manager.addOrUpdate(makeDevice());
      expect(manager.count, equals(1));
    });

    test('addOrUpdate updates existing device', () {
      manager.addOrUpdate(makeDevice(rssi: -80));
      manager.addOrUpdate(makeDevice(rssi: -40));
      expect(manager.count, equals(1));
      expect(manager.devices.first.rssi, equals(-40));
    });

    test('addOrUpdate keeps the advertised manufacturer data', () {
      // A rebuild that drops this is invisible until something reads it: a
      // pixel panel advertises its true width/height in these bytes, and a
      // device is re-advertised every heartbeat — so keeping it only on the
      // FIRST sighting means the editor never sees it in practice and sizes
      // the canvas from a guess instead.
      const payload = {
        0x61EA: [3, 232, 0, 100, 20, 20],
      };
      manager.addOrUpdate(
        IoTDevice(
          id: 'AA:BB:CC:DD:EE:FF',
          name: 'Test',
          rssi: -60,
          isConnectable: true,
          discoveredAt: now,
          manufacturerData: payload,
        ),
      );
      manager.addOrUpdate(
        IoTDevice(
          id: 'AA:BB:CC:DD:EE:FF',
          name: 'Test',
          rssi: -40,
          isConnectable: true,
          discoveredAt: now,
          manufacturerData: payload,
        ),
      );

      expect(manager.getById('AA:BB:CC:DD:EE:FF')!.manufacturerData, payload);
    });

    test('devices sorted by signal strength', () {
      manager.addOrUpdate(makeDevice(id: '1', rssi: -80));
      manager.addOrUpdate(makeDevice(id: '2', rssi: -40));
      manager.addOrUpdate(makeDevice(id: '3', rssi: -60));
      expect(manager.devices[0].id, equals('2'));
      expect(manager.devices[2].id, equals('1'));
    });

    test('addOrUpdate keeps the session\'s first discoveredAt', () {
      // Each scan invocation stamps first-seen from its own start, and the
      // scan restarts routinely (burst downshift, tab return, resume). Taking
      // the restarted scan's stamp would re-order same-band rows by
      // post-restart arrival — the reshuffle the discoveredAt tie-break
      // exists to prevent.
      final first = makeDevice(rssi: -60);
      manager.addOrUpdate(first);
      final rediscovered = IoTDevice(
        id: first.id,
        name: 'Test',
        rssi: -40,
        isConnectable: true,
        discoveredAt: now.add(const Duration(minutes: 2)),
        lastSeen: now.add(const Duration(minutes: 2)),
      );
      manager.addOrUpdate(rediscovered);

      final kept = manager.getById(first.id)!;
      expect(
        kept.discoveredAt,
        first.discoveredAt,
        reason: 'a restart does not make a known device newly discovered',
      );
      expect(kept.rssi, -40, reason: 'everything else is the fresh sighting');
      expect(kept.lastSeen, rediscovered.lastSeen);
    });

    test('getById returns null when not found', () {
      expect(manager.getById('nope'), isNull);
    });

    test('clear removes all', () {
      manager.addOrUpdate(makeDevice(id: '1'));
      manager.addOrUpdate(makeDevice(id: '2'));
      manager.clear();
      expect(manager.count, equals(0));
    });
  });

  group('freshness', () {
    test('a device just heard from is neither stale nor gone', () {
      final device = makeDevice();
      expect(manager.isStale(device, now), isFalse);
      expect(manager.isGone(device, now), isFalse);
    });

    test('a device quiet for less than the threshold is still live', () {
      // BLE advertising is lossy and sleepy sensors are slow; a short silence
      // must not put a warning on a device that is plainly still there.
      final device = makeDevice(ago: DeviceManager.staleAfter * 0.5);
      expect(manager.isStale(device, now), isFalse);
    });

    test('a device quiet past the threshold is stale but kept', () {
      final device = makeDevice(ago: DeviceManager.staleAfter);
      manager.addOrUpdate(device);

      expect(manager.isStale(device, now), isTrue);
      expect(manager.isGone(device, now), isFalse);
      expect(manager.forgetGone(now), isFalse);
      expect(
        manager.getById(device.id),
        isNotNull,
        reason: 'a warning, not an eviction: it is probably still there',
      );
    });

    test('a device quiet past forgetAfter is dropped', () {
      manager.addOrUpdate(
        makeDevice(id: 'ghost', ago: DeviceManager.forgetAfter),
      );
      manager.addOrUpdate(makeDevice(id: 'keeper'));

      expect(manager.forgetGone(now), isTrue);
      expect(
        manager.getById('ghost'),
        isNull,
        reason: 'a tap on it could only end in a connect timeout',
      );
      expect(manager.getById('keeper'), isNotNull);
    });

    test('forgetGone reports nothing to do when everything is fresh', () {
      manager.addOrUpdate(makeDevice(id: '1'));
      manager.addOrUpdate(makeDevice(id: '2'));
      // The scan screen repaints on true, so a tick that changed nothing must
      // not claim it did.
      expect(manager.forgetGone(now), isFalse);
      expect(manager.count, 2);
    });

    test('being heard again clears the warning', () {
      manager.addOrUpdate(
        makeDevice(id: 'blinky', ago: DeviceManager.staleAfter),
      );
      expect(manager.staleIds(now), {'blinky'});

      manager.addOrUpdate(makeDevice(id: 'blinky'));
      expect(manager.staleIds(now), isEmpty);
    });

    test('staleIds names exactly the devices past the threshold', () {
      manager.addOrUpdate(makeDevice(id: 'live'));
      manager.addOrUpdate(
        makeDevice(id: 'quiet', ago: DeviceManager.staleAfter),
      );
      manager.addOrUpdate(
        makeDevice(id: 'quieter', ago: DeviceManager.staleAfter * 2),
      );

      expect(manager.staleIds(now), {'quiet', 'quieter'});
    });

    test('the stale threshold sits well inside the forget one', () {
      // The two exist to say different things; collapsing them would mean a
      // device vanishing the moment it was flagged, with nothing to notice.
      expect(DeviceManager.staleAfter, lessThan(DeviceManager.forgetAfter));
    });
  });

  group('listening', () {
    // Silence is evidence only while something could have heard it. These pin
    // the pause/resume arithmetic the scan screen leans on when the user
    // presses Stop, switches tabs or backgrounds the app: before it, every
    // row went "Not seen for 45s" within a minute of the radio going off.
    const id = 'AA:BB:CC:DD:EE:FF';
    // How long the device had been silent when listening stopped.
    const accrued = Duration(seconds: 10);
    final stoppedAt = now.add(accrued);
    // With [accrued] already on the clock, how much more listening it takes
    // to reach each threshold. Exact: the thresholds are inclusive.
    final moreUntilStale = DeviceManager.staleAfter - accrued;
    final moreUntilGone = DeviceManager.forgetAfter - accrued;
    const second = Duration(seconds: 1);

    test('silence does not accrue while nothing is listening', () {
      final device = makeDevice(id: id);
      manager.addOrUpdate(device);
      manager.listening(false, stoppedAt);

      final fiveMinutesOn = stoppedAt.add(const Duration(minutes: 5));
      expect(manager.isListening, isFalse);
      expect(manager.isStale(device, fiveMinutesOn), isFalse);
      expect(manager.isGone(device, fiveMinutesOn), isFalse);
      expect(
        manager.ageOf(device, fiveMinutesOn),
        accrued,
        reason: 'the clock stands where listening stopped',
      );
    });

    test('ages carry on from where they stood when listening resumes', () {
      manager.addOrUpdate(makeDevice(id: id));
      manager.listening(false, stoppedAt);
      final resumedAt = stoppedAt.add(const Duration(minutes: 5));
      manager.listening(true, resumedAt);
      expect(manager.isListening, isTrue);

      // Read back: the resume restamps the device, and the shifted copy is
      // the one whose age is right.
      final device = manager.getById(id)!;
      expect(manager.ageOf(device, resumedAt), accrued);
      expect(
        manager.isStale(device, resumedAt.add(moreUntilStale - second)),
        isFalse,
      );
      expect(
        manager.isStale(device, resumedAt.add(moreUntilStale)),
        isTrue,
        reason: '10s before the pause plus 80s after it is the 90s threshold',
      );
      expect(
        manager.isGone(device, resumedAt.add(moreUntilGone - second)),
        isFalse,
      );
      expect(manager.isGone(device, resumedAt.add(moreUntilGone)), isTrue);
    });

    test('staleIds and forgetGone read the frozen clock too', () {
      // These are what the screen's clock tick calls, so a freeze the
      // per-device checks honoured but these did not would still evict the
      // whole list during a phone call.
      manager.addOrUpdate(makeDevice(id: id));
      manager.listening(false, stoppedAt);

      final anHourOn = stoppedAt.add(const Duration(hours: 1));
      expect(manager.staleIds(anHourOn), isEmpty);
      expect(manager.forgetGone(anHourOn), isFalse);
      expect(manager.count, 1);

      manager.listening(true, anHourOn);
      expect(manager.staleIds(anHourOn.add(moreUntilStale - second)), isEmpty);
      expect(manager.staleIds(anHourOn.add(moreUntilStale)), {id});
      expect(manager.forgetGone(anHourOn.add(moreUntilGone - second)), isFalse);
      expect(manager.forgetGone(anHourOn.add(moreUntilGone)), isTrue);
      expect(manager.count, 0);
    });

    test('repeating a stop or a start changes nothing', () {
      // The screen reaches both from several directions: a burst downshift
      // restarts a scan that never stopped, and a stop can be the user's, the
      // lifecycle's and the stream's own onDone in quick succession.
      manager.addOrUpdate(makeDevice(id: id));
      manager.listening(false, stoppedAt);
      // A later second stop must not move the freeze point forward...
      manager.listening(false, stoppedAt.add(const Duration(minutes: 1)));
      final resumedAt = stoppedAt.add(const Duration(minutes: 2));
      manager.listening(true, resumedAt);
      // ...and a second start must not shift the stamps a second time.
      manager.listening(true, resumedAt.add(const Duration(minutes: 1)));

      final device = manager.getById(id)!;
      expect(
        manager.isStale(device, resumedAt.add(moreUntilStale - second)),
        isFalse,
      );
      expect(manager.isStale(device, resumedAt.add(moreUntilStale)), isTrue);
    });

    test('a device heard during a pause is fresh when listening resumes', () {
      // Nothing the screen does — its stop cancels delivery first — but the
      // API allows it, and shifting such a stamp by the whole pause would
      // date it past the resume.
      manager.addOrUpdate(makeDevice(id: id));
      manager.listening(false, stoppedAt);
      final heardAt = stoppedAt.add(const Duration(minutes: 1));
      manager.addOrUpdate(
        IoTDevice(
          id: id,
          name: 'Test',
          rssi: -50,
          isConnectable: true,
          discoveredAt: heardAt,
          lastSeen: heardAt,
        ),
      );
      final resumedAt = stoppedAt.add(const Duration(minutes: 5));
      manager.listening(true, resumedAt);

      expect(manager.getById(id)!.lastSeen, resumedAt);
      expect(manager.ageOf(manager.getById(id)!, resumedAt), Duration.zero);
    });

    test('a resume leaves discoveredAt alone', () {
      // The first sighting is the list's ordering tie-break, and it is a fact
      // about the session — only lastSeen is a claim about silence.
      final device = makeDevice(id: id);
      manager.addOrUpdate(device);
      manager.listening(false, stoppedAt);
      manager.listening(true, stoppedAt.add(const Duration(minutes: 5)));

      expect(manager.getById(id)!.discoveredAt, device.discoveredAt);
    });
  });
}
