// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/models/radio_profile.dart';
import 'package:liberated_bread_mobile/services/baofeng_ble_programmer.dart'
    show baofengUartService;
import 'package:liberated_bread_mobile/services/radio_recognition.dart';

void main() {
  group('isRadioUartService', () {
    test('accepts every spelling a scan reports', () {
      expect(isRadioUartService(baofengUartService), isTrue);
      expect(isRadioUartService(baofengUartService.toUpperCase()), isTrue);
      expect(isRadioUartService('ffe0'), isTrue);
      expect(isRadioUartService('FFE0'), isTrue);
      expect(isRadioUartService('0000ffe0'), isTrue);
    });

    test('rejects its neighbours', () {
      expect(isRadioUartService('ffe1'), isFalse,
          reason: 'the characteristic, not the service');
      expect(
          isRadioUartService('0000180f-0000-1000-8000-00805f9b34fb'), isFalse);
    });
  });

  group('recogniseRadio — the strict test the Nearby list uses', () {
    test('a model name with the programming service is a strong sighting', () {
      final sighting = recogniseRadio(
        name: 'UV-5R Mini',
        serviceUuids: [baofengUartService],
      );
      expect(sighting, isNotNull);
      expect(sighting!.advertisesUart, isTrue);
    });

    test('a model name alone is a sighting, marked weaker', () {
      final sighting = recogniseRadio(name: 'BAOFENG', serviceUuids: const []);
      expect(sighting, isNotNull);
      expect(sighting!.advertisesUart, isFalse);
    });

    test('the programming service alone is not a radio', () {
      // It is the generic HM-10 serial service. LED strips advertise it.
      expect(
        recogniseRadio(
            name: 'LEDBlue-12AB', serviceUuids: [baofengUartService]),
        isNull,
      );
    });

    test('"mini" alone is not a radio', () {
      for (final name in ['MINI', 'Mini Speaker', 'mini-cube']) {
        expect(
          recogniseRadio(name: name, serviceUuids: [baofengUartService]),
          isNull,
          reason: name,
        );
      }
    });

    test('an empty name is not a radio', () {
      expect(
          recogniseRadio(name: '', serviceUuids: [baofengUartService]), isNull);
    });

    test('recognises every spelling the target doc records', () {
      for (final name in [
        'UV-5R Mini',
        'UV5RMINI',
        'uv-5g mini',
        'UV5G',
        'UV-32',
        'uv32',
        'Baofeng',
      ]) {
        expect(recogniseRadio(name: name, serviceUuids: const []), isNotNull,
            reason: name);
      }
    });
  });

  group('what a name suggests', () {
    RadioProfile? suggestion(String name) =>
        recogniseRadio(name: name, serviceUuids: const [])?.nameSuggests;

    test('names the model it spells', () {
      expect(suggestion('UV-5R Mini'), uv5rMiniProfile);
      expect(suggestion('UV5G MINI'), uv5gMiniProfile);
      expect(suggestion('UV-32'), uv32Profile);
    });

    test('suggests nothing when the name does not say which', () {
      expect(suggestion('Baofeng'), isNull);
      expect(suggestion('UV-5R / UV-32 pair'), isNull,
          reason: 'two models named is no model named');
    });

    test('only ever suggests a radio this build programs over Bluetooth', () {
      for (final name in ['UV-5R Mini', 'UV5G', 'UV-32']) {
        final profile = suggestion(name)!;
        expect(profile.programmingFamily, ProgrammingFamily.bleUv17Pro,
            reason: name);
      }
    });
  });

  group('mightBeRadio — the loose test the programming screen uses', () {
    test('accepts the programming service alone', () {
      expect(
        mightBeRadio(name: 'anonymous', serviceUuids: [baofengUartService]),
        isTrue,
      );
    });

    test('accepts anything the strict test accepts', () {
      expect(mightBeRadio(name: 'UV-5R Mini', serviceUuids: const []), isTrue);
    });

    test('still rejects a device with neither', () {
      expect(mightBeRadio(name: 'ACME_Bulb', serviceUuids: const []), isFalse);
    });
  });
}
