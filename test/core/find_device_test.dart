// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/core/find_device.dart';
import 'package:liberated_bread_mobile/models/ble_discovered_service.dart';
import 'package:liberated_bread_mobile/services/spec_codec.dart';

// -- DTO builders -----------------------------------------------------------

CommandDto _command(
  String name, {
  bool isFixed = true,
  bool isEncodable = true,
}) =>
    CommandDto(
      name: name,
      description: '',
      parameters: const [],
      isFixed: isFixed,
      isEncodable: isEncodable,
    );

DeviceSpecDto _spec({
  required String serviceUuid,
  required String charUuid,
  required List<CommandDto> commands,
}) =>
    DeviceSpecDto(
      deviceName: 'Test Device',
      manufacturer: 'Test Co',
      manufacturerStatus: 'abandoned',
      protocol: 'ble',
      serviceUuids: [serviceUuid],
      entities: const [],
      services: [
        ServiceDto(
          uuid: serviceUuid,
          name: 'Control',
          characteristics: [
            CharacteristicDto(
              uuid: charUuid,
              name: 'Command',
              canRead: false,
              canWrite: true,
              canNotify: false,
              commands: commands,
              formatFields: const [],
            ),
          ],
        ),
      ],
    );

BleDiscoveredService _discovered(
  String serviceUuid,
  String charUuid, {
  bool canWrite = true,
}) =>
    BleDiscoveredService(
      uuid: serviceUuid,
      characteristics: [
        BleDiscoveredCharacteristic(
          uuid: charUuid,
          canRead: false,
          canWrite: canWrite,
          canWriteWithoutResponse: canWrite,
          canNotify: false,
        ),
      ],
    );

const _svc = '0000fff0-0000-1000-8000-00805f9b34fb';
const _chr = '0000fff1-0000-1000-8000-00805f9b34fb';

void main() {
  group('estimateDistanceMeters', () {
    test('is 1 m at the measured power', () {
      expect(estimateDistanceMeters(kDefaultMeasuredPower), closeTo(1.0, 1e-9));
    });

    test('is 10 m one decade below the measured power', () {
      // With n = 2.5, one decade of distance is 25 dB of path loss.
      expect(estimateDistanceMeters(kDefaultMeasuredPower - 25),
          closeTo(10.0, 1e-9));
    });

    test('decreases monotonically as the signal strengthens', () {
      double? prev;
      for (var rssi = -100; rssi <= -30; rssi += 5) {
        final d = estimateDistanceMeters(rssi.toDouble());
        if (prev != null) expect(d, lessThan(prev));
        prev = d;
      }
    });
  });

  group('formatApproxDistance', () {
    test('one decimal under 10 m', () {
      expect(formatApproxDistance(1.23), '≈ 1.2 m');
    });

    test('whole meters from 10 m', () {
      expect(formatApproxDistance(12.4), '≈ 12 m');
    });

    test('caps at 20+ m where the model has no resolution', () {
      expect(formatApproxDistance(20.0), '20+ m');
      expect(formatApproxDistance(437.0), '20+ m');
    });
  });

  group('proximityLabel', () {
    test('buckets distances', () {
      expect(proximityLabel(0.3), 'Right here');
      expect(proximityLabel(1.5), 'Very close');
      expect(proximityLabel(4.0), 'Same room');
      expect(proximityLabel(10.0), 'Nearby');
      expect(proximityLabel(30.0), 'Far away');
    });
  });

  group('signalFraction', () {
    test('maps the working RSSI span to 0..1 and clamps beyond it', () {
      expect(signalFraction(-100), 0.0);
      expect(signalFraction(-30), 1.0);
      expect(signalFraction(-65), closeTo(0.5, 1e-9));
      expect(signalFraction(-120), 0.0);
      expect(signalFraction(0), 1.0);
    });
  });

  group('RssiTracker', () {
    test('tracks latest, extremes and count', () {
      final tracker = RssiTracker();
      expect(tracker.hasSamples, isFalse);
      expect(tracker.latest, isNull);
      expect(tracker.estimatedDistanceMeters, isNull);

      tracker
        ..add(-60)
        ..add(-70)
        ..add(-55);
      expect(tracker.latest, -55);
      expect(tracker.strongest, -55);
      expect(tracker.weakest, -70);
      expect(tracker.sampleCount, 3);
      expect(tracker.estimatedDistanceMeters, isNotNull);
    });

    test('smoothing follows new samples without jumping to them', () {
      final tracker = RssiTracker()..add(-60);
      expect(tracker.smoothed, -60.0);
      tracker.add(-80);
      // EMA lands strictly between the previous average and the new sample.
      expect(tracker.smoothed, lessThan(-60));
      expect(tracker.smoothed, greaterThan(-80));
    });

    test('history is capped at historyCapacity, dropping the oldest', () {
      final tracker = RssiTracker();
      for (var i = 0; i < RssiTracker.historyCapacity + 10; i++) {
        tracker.add(-100 + i);
      }
      expect(tracker.history.length, RssiTracker.historyCapacity);
      // Oldest surviving sample is the 11th added; sampleCount keeps counting.
      expect(tracker.history.first, -100 + 10);
      expect(tracker.sampleCount, RssiTracker.historyCapacity + 10);
    });

    test('trend is steady until enough samples arrive', () {
      final tracker = RssiTracker()
        ..add(-60)
        ..add(-50)
        ..add(-40);
      expect(tracker.trend, RssiTrend.steady);
    });

    test('rising signal reads as closer, falling as farther', () {
      final closer = RssiTracker();
      for (final rssi in [-80, -78, -76, -70, -66, -62]) {
        closer.add(rssi);
      }
      expect(closer.trend, RssiTrend.closer);

      final farther = RssiTracker();
      for (final rssi in [-62, -66, -70, -76, -78, -80]) {
        farther.add(rssi);
      }
      expect(farther.trend, RssiTrend.farther);
    });

    test('sub-threshold jitter reads as steady', () {
      final tracker = RssiTracker();
      for (final rssi in [-60, -61, -59, -60, -61, -60]) {
        tracker.add(rssi);
      }
      expect(tracker.trend, RssiTrend.steady);
    });
  });

  group('classifyAlertCommand', () {
    test('recognizes find/sound/flash command names', () {
      expect(classifyAlertCommand('find_me'), FindAlertKind.alert);
      expect(classifyAlertCommand('locate'), FindAlertKind.alert);
      expect(classifyAlertCommand('beep'), FindAlertKind.sound);
      expect(classifyAlertCommand('play_tone'), FindAlertKind.sound);
      expect(classifyAlertCommand('blink_led'), FindAlertKind.flash);
    });

    test('matches whole tokens, not substrings', () {
      // `bring` contains `ring`; token matching must not see it.
      expect(classifyAlertCommand('bring_up'), isNull);
    });

    test('rejects commands that stop or mute an alert', () {
      // ibbq-meat-thermo's silence_alarm STOPS the sound; offering it as a
      // "make it noticeable" button would do the opposite of its label.
      expect(classifyAlertCommand('silence_alarm'), isNull);
      expect(classifyAlertCommand('alarm_off'), isNull);
    });

    test('rejects dangerous commands even with a positive token', () {
      expect(classifyAlertCommand('flash_firmware'), isNull);
    });

    test('does not treat identify/effect-player commands as alerts', () {
      // The OBD2 spec's `identify` is an ATI version query; the LED specs'
      // `play_program`/`music_start` drive displays, not speakers.
      expect(classifyAlertCommand('identify'), isNull);
      expect(classifyAlertCommand('play_program'), isNull);
      expect(classifyAlertCommand('music_start'), isNull);
    });

    test('rejects settings/status queries that merely name an alert', () {
      // The Inkbird BBQ spec's get_* commands are fixed and encodable but
      // only read configuration back — pressing them makes no noise.
      expect(classifyAlertCommand('get_sound_switch'), isNull);
      expect(classifyAlertCommand('get_alarm_mode'), isNull);
      expect(classifyAlertCommand('alarm_status'), isNull);
      expect(classifyAlertCommand('read_tone'), isNull);
    });
  });

  group('humanLabelForCommand', () {
    test('sentence-cases and fixes initialisms', () {
      expect(humanLabelForCommand('find_me'), 'Find me');
      expect(humanLabelForCommand('blink_led'), 'Blink LED');
    });
  });

  group('detectAlertActions', () {
    test('offers the standard Immediate Alert when discovered writable', () {
      final actions = detectAlertActions(
        services: [_discovered(immediateAlertServiceUuid, alertLevelCharUuid)],
      );
      expect(actions, hasLength(1));
      final action = actions.single;
      expect(action.kind, FindAlertKind.alert);
      expect(action.bytes, [0x02]);
      expect(action.stopBytes, [0x00]);
      expect(action.charUuid, alertLevelCharUuid);
      expect(action.commandName, isNull);
    });

    test('skips Immediate Alert when the Alert Level is not writable', () {
      final actions = detectAlertActions(
        services: [
          _discovered(immediateAlertServiceUuid, alertLevelCharUuid,
              canWrite: false),
        ],
      );
      expect(actions, isEmpty);
    });

    test('skips an Alert Level hanging off a non-Immediate-Alert service', () {
      // 0x2A06 under some vendor service is not the standard profile;
      // writing alert levels there would hit an unknown endpoint.
      final actions = detectAlertActions(
        services: [_discovered(_svc, alertLevelCharUuid)],
      );
      expect(actions, isEmpty);
    });

    test('offers fixed encodable spec commands with alerting names', () {
      final actions = detectAlertActions(
        spec: _spec(
          serviceUuid: _svc,
          charUuid: _chr,
          commands: [_command('blink_led'), _command('power_on')],
        ),
        specYaml: 'yaml',
        services: [_discovered(_svc, _chr)],
      );
      expect(actions, hasLength(1));
      final action = actions.single;
      expect(action.kind, FindAlertKind.flash);
      expect(action.label, 'Blink LED');
      expect(action.commandName, 'blink_led');
      expect(action.specYaml, 'yaml');
      expect(action.stopBytes, isNull);
    });

    test('requires the spec characteristic to be discovered and writable', () {
      final spec = _spec(
        serviceUuid: _svc,
        charUuid: _chr,
        commands: [_command('blink_led')],
      );
      expect(
        detectAlertActions(spec: spec, specYaml: 'y', services: const []),
        isEmpty,
      );
      expect(
        detectAlertActions(
          spec: spec,
          specYaml: 'y',
          services: [_discovered(_svc, _chr, canWrite: false)],
        ),
        isEmpty,
      );
      // The characteristic UUID alone is not enough: discovered under a
      // DIFFERENT service than the spec names, it is a different endpoint.
      expect(
        detectAlertActions(
          spec: spec,
          specYaml: 'y',
          services: [
            _discovered('0000eee0-0000-1000-8000-00805f9b34fb', _chr),
          ],
        ),
        isEmpty,
      );
    });

    test(
        'a characteristic UUID duplicated across services binds to the '
        'service the spec names', () {
      const otherSvc = '0000eee0-0000-1000-8000-00805f9b34fb';
      final actions = detectAlertActions(
        spec: _spec(
          serviceUuid: _svc,
          charUuid: _chr,
          commands: [_command('beep')],
        ),
        specYaml: 'yaml',
        // The duplicate under the unrelated service is discovered LAST, so a
        // characteristic-keyed lookup would capture the wrong service.
        services: [_discovered(_svc, _chr), _discovered(otherSvc, _chr)],
      );
      expect(actions, hasLength(1));
      expect(actions.single.serviceUuid, _svc);
    });

    test('skips parameterized and non-encodable commands', () {
      final actions = detectAlertActions(
        spec: _spec(
          serviceUuid: _svc,
          charUuid: _chr,
          commands: [
            _command('blink_led', isFixed: false),
            _command('find_me', isEncodable: false),
          ],
        ),
        specYaml: 'yaml',
        services: [_discovered(_svc, _chr)],
      );
      expect(actions, isEmpty);
    });

    test('a spec command on the Alert Level replaces the generic action', () {
      final actions = detectAlertActions(
        spec: _spec(
          serviceUuid: immediateAlertServiceUuid,
          charUuid: alertLevelCharUuid,
          commands: [_command('find_me')],
        ),
        specYaml: 'yaml',
        services: [_discovered(immediateAlertServiceUuid, alertLevelCharUuid)],
      );
      // Only the spec's command — no duplicate raw Ring alert on the same
      // characteristic.
      expect(actions, hasLength(1));
      expect(actions.single.commandName, 'find_me');
    });

    test('spec commands and Immediate Alert combine across characteristics',
        () {
      final actions = detectAlertActions(
        spec: _spec(
          serviceUuid: _svc,
          charUuid: _chr,
          commands: [_command('beep')],
        ),
        specYaml: 'yaml',
        services: [
          _discovered(_svc, _chr),
          _discovered(immediateAlertServiceUuid, alertLevelCharUuid),
        ],
      );
      expect(actions, hasLength(2));
      expect(actions.first.commandName, 'beep');
      expect(actions.last.bytes, [0x02]);
    });

    test('UUID matching is case-insensitive', () {
      final actions = detectAlertActions(
        spec: _spec(
          serviceUuid: _svc.toUpperCase(),
          charUuid: _chr.toUpperCase(),
          commands: [_command('beep')],
        ),
        specYaml: 'yaml',
        services: [_discovered(_svc, _chr)],
      );
      expect(actions, hasLength(1));
    });
  });
}
