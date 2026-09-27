// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/core/find_device.dart' show signalBars;
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

  group('signal band', () {
    // The band a row is drawn in and sorted by is the manager's judgement of
    // the device's signal, not the latest reading's. Banding the reading
    // flipped a device hovering around a boundary between bands on every
    // advertisement, and its row jumped a group each time — the row under a
    // finger changing between deciding to tap and tapping (seen on an
    // iPhone).
    const id = 'AA:BB:CC:DD:EE:FF';
    const second = Duration(seconds: 1);

    /// A sighting of [deviceId] at [rssi], stamped [at].
    IoTDevice heard(int rssi, DateTime at, {String deviceId = id}) => IoTDevice(
      id: deviceId,
      name: 'Test',
      rssi: rssi,
      isConnectable: true,
      discoveredAt: at,
      lastSeen: at,
    );

    /// The band [id] is currently held in.
    int band() => manager.signalBandOf(manager.getById(id)!);

    test('the first sighting classifies outright', () {
      // A new row appears where it belongs, not at the bottom until the
      // dwell has passed.
      for (final (rssi, expected) in const [
        (-50, 4),
        (-60, 4),
        (-61, 3),
        (-70, 3),
        (-71, 2),
        (-80, 2),
        (-81, 1),
      ]) {
        final fresh = DeviceManager();
        fresh.addOrUpdate(heard(rssi, now));
        expect(
          fresh.signalBandOf(fresh.getById(id)!),
          expected,
          reason: '$rssi dBm is the reading\'s own band from the first packet',
        );
      }
    });

    test('an untracked device bands its own reading', () {
      expect(manager.signalBandOf(heard(-75, now)), signalBars(-75));
    });

    test('a reading hovering around a boundary keeps one band', () {
      // -71 and -69 on alternate advertisements: the same device, not
      // moving, read either side of the -70 boundary. Two bars, then three,
      // then two — and a row trading places with every band-2 neighbour.
      for (var i = 0; i < 20; i++) {
        final rssi = i.isEven ? -71 : -69;
        manager.addOrUpdate(heard(rssi, now.add(second * i)));
        expect(
          band(),
          2,
          reason:
              'sighting $i read $rssi dBm (band ${signalBars(rssi)}) and the '
              'band must not follow it',
        );
      }
    });

    test('the band it keeps is the one the first sighting gave it', () {
      // The same hover, first heard on the other side of the boundary: it
      // is held at three bars, not two. Hysteresis has no opinion about
      // which side is right, only that nothing moves without evidence.
      for (var i = 0; i < 20; i++) {
        manager.addOrUpdate(heard(i.isEven ? -69 : -71, now.add(second * i)));
        expect(band(), 3);
      }
    });

    test('a reading settled past the margin moves the band', () {
      manager.addOrUpdate(heard(-71, now));
      expect(band(), 2);

      // One reading five dB up is a packet, not a move.
      manager.addOrUpdate(heard(-65, now.add(second)));
      expect(band(), 2, reason: 'one reading is not a move');

      // Sustained, the average follows it past -66 — four dB over the -70
      // boundary — and the band goes up. Well inside ten seconds: a first
      // classification starts no dwell, so a device whose first packet was
      // a weak one corrects itself as soon as the readings justify it.
      final bands = <int>[];
      for (var i = 2; i <= 8; i++) {
        manager.addOrUpdate(heard(-65, now.add(second * i)));
        bands.add(band());
      }
      expect(bands.last, 3);
      expect(
        bands,
        isNot(contains(4)),
        reason: 'a -65 reading is three bars, and the average never more',
      );
      expect(bands.skip(bands.indexOf(3)).every((b) => b == 3), isTrue);
    });

    test('a walk away descends a band at a time, each held for the dwell', () {
      // Readings every second, four at each step of a walk out of the room.
      // The average trails the reading, so the band changes lag the walk:
      // what matters is that they come one at a time, downwards, and never
      // closer together than the dwell.
      final changes = <({Duration at, int band})>[];
      var t = Duration.zero;
      void walk(int rssi, int sightings) {
        for (var i = 0; i < sightings; i++) {
          manager.addOrUpdate(heard(rssi, now.add(t)));
          if (changes.isEmpty || changes.last.band != band()) {
            changes.add((at: t, band: band()));
          }
          t += second;
        }
      }

      for (final level in const [-58, -62, -68, -75, -83]) {
        walk(level, 4);
      }
      walk(-90, 12);

      expect(changes.first, (at: Duration.zero, band: 4));
      expect(changes.last.band, 1);
      for (var i = 1; i < changes.length; i++) {
        expect(
          changes[i].band,
          changes[i - 1].band - 1,
          reason: 'a walk away is one band at a time',
        );
        // From the second change on: the entry before the first is the
        // initial classification, which starts no dwell.
        if (i < 2) continue;
        expect(
          changes[i].at - changes[i - 1].at,
          greaterThanOrEqualTo(DeviceManager.signalBandDwell),
          reason: 'a band that just changed is held for the dwell',
        );
      }
      // The dwell did the holding: by the time each of the last two changes
      // was allowed, the average had been calling for it for seconds.
      expect(
        changes[2].at - changes[1].at,
        DeviceManager.signalBandDwell,
        reason: 'the drop to two bars was waiting on the dwell',
      );
      expect(changes[3].at - changes[2].at, DeviceManager.signalBandDwell);
    });

    test('the dwell starts at the first change, not the first sighting', () {
      manager.addOrUpdate(heard(-71, now));
      // A strong second reading moves the band at once...
      manager.addOrUpdate(heard(-50, now.add(second)));
      expect(band(), 3, reason: 'nothing holds a first classification');
      // ...and THAT change is held for the dwell, however loud the device
      // now reads.
      for (var i = 2; i <= 10; i++) {
        manager.addOrUpdate(heard(-50, now.add(second * i)));
        expect(band(), 3, reason: 'only ${i - 1}s since the band changed');
      }
      manager.addOrUpdate(heard(-50, now.add(second * 11)));
      expect(band(), 4);
    });

    test('a pause does not count towards the dwell', () {
      // The dwell is time the reading had to settle in, and a pause — the
      // radio off — is not that. Counted on the wall clock, a band that
      // changed just before a phone call would be free to change again the
      // moment listening resumed, on whatever the first packet said.
      manager.addOrUpdate(heard(-58, now));
      manager.addOrUpdate(heard(-95, now.add(second)));
      expect(band(), 3);
      manager.listening(false, now.add(second * 2));
      manager.listening(true, now.add(second * 61));

      // 61s on the wall clock, 2s of listening.
      manager.addOrUpdate(heard(-95, now.add(second * 62)));
      expect(band(), 3, reason: '2s of listening since the change');
      // 11s of listening.
      manager.addOrUpdate(heard(-95, now.add(second * 71)));
      expect(band(), 2);
    });

    test('a device dropped and heard again starts from its new reading', () {
      // Its readings from before it went quiet are history: averaging them
      // in would start its row in a band it is no longer in, and hold it
      // there for the dwell.
      manager.addOrUpdate(heard(-50, now));
      expect(manager.forgetGone(now.add(DeviceManager.forgetAfter)), isTrue);
      manager.addOrUpdate(heard(-85, now.add(DeviceManager.forgetAfter)));
      expect(band(), 1);

      manager.remove(id);
      manager.addOrUpdate(heard(-50, now));
      expect(band(), 4);

      manager.clear();
      manager.addOrUpdate(heard(-85, now));
      expect(band(), 1);
    });

    test('each device is judged on its own readings', () {
      manager.addOrUpdate(heard(-50, now));
      manager.addOrUpdate(heard(-85, now, deviceId: 'other'));
      expect(band(), 4);
      expect(manager.signalBandOf(manager.getById('other')!), 1);
    });
  });
}
