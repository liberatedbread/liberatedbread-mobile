// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// R-012: RabbitAirBleControl had no tests at all, and what it does is not
// incidental — it decides which stored key belongs to the purifier in front
// of the user, learns the clock offset every later command is stamped with,
// and files the key under the Thing ID so the LAN path finds the same
// credential later. Each of those is silent when it goes wrong: a wrong key
// simply does not decrypt, a stale offset makes a purifier reject commands it
// would otherwise take, and a missed adoption means the Wi-Fi screen asks for
// a key the app already holds.
import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/models/ble_discovered_service.dart';
import 'package:liberated_bread_mobile/services/rabbit_air_ble_client.dart';
import 'package:liberated_bread_mobile/services/rabbit_air_ble_control.dart';
import 'package:liberated_bread_mobile/services/rabbit_air_key_store.dart';

import '../fakes/fake_spec_codec.dart';
import '../fakes/in_memory_settings_store.dart';

const _rightKey = '00112233445566778899aabbccddeeff';
const _wrongKey = 'ffeeddccbbaa99887766554433221100';
const _deviceId = 'AA:BB:CC:DD:EE:01';

/// A purifier that answers only under [key], the way the real one does: a
/// datagram encrypted with anything else does not decrypt, which is the ONLY
/// signal the app gets that a stored key belongs to a different unit.
class _FakePurifier implements RabbitAirBleClient {
  _FakePurifier({required this.key, this.deviceTsOffset = 0, this.thingId});

  final String key;

  /// How far the purifier's clock is from this phone's, in seconds.
  final int deviceTsOffset;

  /// What cmd 255 reports as `data.name`; null answers with a mac instead.
  final String? thingId;

  final sent = <Map<String, Object?>>[];
  int attaches = 0;

  @override
  Duration get responseTimeout => const Duration(seconds: 7);

  @override
  Future<void> connect(String deviceId) => attach(deviceId);

  @override
  Future<void> attach(
    String deviceId, {
    List<BleDiscoveredService>? services,
  }) async {
    attaches++;
  }

  @override
  Future<void> disconnect() async {}

  @override
  Future<List<int>> sendCommand(List<int> payload) async {
    // The fake codec's "encryption" is `<key>\n<plaintext>` plus 16 bytes.
    final body = utf8.decode(payload.sublist(0, payload.length - 16));
    final split = body.indexOf('\n');
    final usedKey = body.substring(0, split);
    if (usedKey != key) {
      throw const FormatException('does not decrypt under this user key');
    }
    final request =
        jsonDecode(body.substring(split + 1)) as Map<String, Object?>;
    sent.add(request);
    final id = request['id'];
    // The fake renderer spells a state command by NAME ("time_sync"); the
    // Thing ID envelope the control builds by hand uses the wire number.
    final Map<String, Object?> data = switch (request['cmd']) {
      'time_sync' || 9 => {
        'ts': DateTime.now().millisecondsSinceEpoch ~/ 1000 + deviceTsOffset,
      },
      255 => {'name': thingId ?? '', 'mac': 'a1:b2:c3:d4:e5:f6', 'mcu': 24},
      _ => const <String, Object?>{},
    };
    final reply = jsonEncode({'id': id, 'data': data});
    return [...utf8.encode('$key\n$reply'), ...List.filled(16, 0xAB)];
  }
}

RabbitAirBleControl _control(
  _FakePurifier purifier,
  RabbitAirKeyStore store, {
  FakeSpecCodec? codec,
}) => RabbitAirBleControl(
  client: purifier,
  codec: codec ?? FakeSpecCodec(),
  keyStore: store,
  deviceId: _deviceId,
  specYaml: 'yaml',
  random: Random(7),
);

void main() {
  late InMemorySettingsStore settings;
  late RabbitAirKeyStore store;

  setUp(() {
    settings = InMemorySettingsStore();
    store = RabbitAirKeyStore(settings);
  });

  group('userKey', () {
    test('tries every stored key and keeps the one that decrypts', () async {
      // Keys accumulate: one per purifier the user has set up, all in the
      // same store, and nothing but an exchange says which is which.
      await store.saveUserKey('ble-OTHER', _wrongKey);
      await store.saveUserKey('ble-$_deviceId', _rightKey);
      final purifier = _FakePurifier(key: _rightKey);

      expect(await _control(purifier, store).userKey(), _rightKey);
    });

    test('a purifier none of the stored keys open answers null', () async {
      await store.saveUserKey('ble-OTHER', _wrongKey);
      final purifier = _FakePurifier(key: _rightKey);

      expect(
        await _control(purifier, store).userKey(),
        isNull,
        reason:
            'the caller then asks the user for the key, rather than '
            'sending commands that cannot arrive',
      );
    });

    test('the key that worked is reused without another exchange', () async {
      await store.saveUserKey('ble-$_deviceId', _rightKey);
      final purifier = _FakePurifier(key: _rightKey);
      final control = _control(purifier, store);

      await control.userKey();
      final afterFirst = purifier.sent.length;
      await control.userKey();

      expect(purifier.sent.length, afterFirst);
    });
  });

  group('syncClock', () {
    test(
      'stamps later commands with the purifier\'s clock, not the phone\'s',
      () async {
        // A purifier rejects a command whose timestamp is too far from its own
        // clock, and the two drift — so the offset learned here is what makes
        // every later command acceptable.
        final purifier = _FakePurifier(key: _rightKey, deviceTsOffset: 900);
        final control = _control(purifier, store);

        await control.syncClock(specYaml: 'yaml', userKey: _rightKey);

        final phoneNow = DateTime.now().millisecondsSinceEpoch ~/ 1000;
        expect(control.deviceTs(), closeTo(phoneNow + 900, 2));
      },
    );

    test(
      'a failed exchange drops the offset so the next one re-syncs',
      () async {
        final purifier = _FakePurifier(key: _rightKey, deviceTsOffset: 900);
        final control = _control(purifier, store);
        await control.syncClock(specYaml: 'yaml', userKey: _rightKey);

        // The wrong key does not decrypt, which is what a dropped link or a
        // re-paired purifier looks like from here.
        await expectLater(
          control.syncClock(specYaml: 'yaml', userKey: _wrongKey),
          throwsA(isA<Object>()),
        );

        final phoneNow = DateTime.now().millisecondsSinceEpoch ~/ 1000;
        expect(
          control.deviceTs(),
          closeTo(phoneNow, 2),
          reason: 'a stale offset is worse than none: it stamps every command',
        );
      },
    );
  });

  group('adopting the Thing ID', () {
    test(
      'files the key under the id the LAN path will look it up by',
      () async {
        final purifier = _FakePurifier(key: _rightKey, thingId: 'abc123_0000');
        final control = _control(purifier, store);

        await control.syncClock(specYaml: 'yaml', userKey: _rightKey);
        // Adoption is fire-and-forget, so let it land.
        await Future<void>.delayed(const Duration(milliseconds: 20));

        expect(
          await store.userKey('abc123_0000'),
          _rightKey,
          reason: 'the Wi-Fi screen finds this purifier by its Thing ID',
        );
      },
    );

    test(
      'a unit with no Thing ID is filed under its derived hostname',
      () async {
        // Local-only provisioning leaves data.name empty; the purifier is then
        // reachable as RabbitAir-<WIFI MAC>.local, which is what mDNS reports.
        final purifier = _FakePurifier(key: _rightKey);
        final control = _control(purifier, store);

        await control.syncClock(specYaml: 'yaml', userKey: _rightKey);
        await Future<void>.delayed(const Duration(milliseconds: 20));

        final filed = await settings.readAll();
        expect(
          filed.keys.where((k) => k.startsWith('rabbitair.RabbitAir-')),
          isNotEmpty,
          reason: 'filed under the hostname derived from the reported mac',
        );
      },
    );

    test('a purifier that refuses cmd 255 keeps its BLE-scoped key', () async {
      // Best-effort by design: losing the adoption costs the LAN path a
      // lookup, not this session.
      final purifier = _FakePurifier(key: _rightKey, thingId: '');
      final control = _control(purifier, store);
      await store.saveUserKey('ble-$_deviceId', _rightKey);

      await control.syncClock(specYaml: 'yaml', userKey: _rightKey);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(await store.userKey('ble-$_deviceId'), _rightKey);
    });
  });

  test('attach happens once, however many commands are sent', () async {
    final purifier = _FakePurifier(key: _rightKey);
    final control = _control(purifier, store);

    await control.syncClock(specYaml: 'yaml', userKey: _rightKey);
    await control.syncClock(specYaml: 'yaml', userKey: _rightKey);

    expect(purifier.attaches, 1);
  });
}
