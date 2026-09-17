// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// The read/notify/decode loop every sensor and control card sits on. Its
// rules are all about being honest when the device is not cooperating —
// which reading survives a failure, which failure is worth showing, and
// which read must not be attempted at all — so they are worth pinning
// directly rather than through whichever card happens to exercise them.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/models/ble_discovered_service.dart';
import 'package:liberated_bread_mobile/providers/ble_provider.dart';
import 'package:liberated_bread_mobile/providers/spec_codec_provider.dart';
import 'package:liberated_bread_mobile/services/spec_codec.dart';
import 'package:liberated_bread_mobile/widgets/entity_value.dart';

import '../fakes/fake_ble_service.dart';
import '../fakes/fake_spec_codec.dart';

const _svc = '0000fff0-0000-1000-8000-00805f9b34fb';
const _stateChar = '0000fff4-0000-1000-8000-00805f9b34fb';

EntityDto _entity({
  bool canNotify = false,
  bool hasFormat = true,
  String? stateCharacteristic = _stateChar,
}) => EntityDto(
  options: const [],
  name: 'Temperature',
  platform: 'sensor',
  deviceClass: 'temperature',
  unit: 'C',
  stateCharacteristic: stateCharacteristic,
  canNotify: canNotify,
  hasFormat: hasFormat,
  onWhenNonzero: false,
  actions: const [],
  variants: const [],
);

/// A discovered characteristic, so `_seed` can consult the real
/// read/notify flags the way it does on hardware.
BleDiscoveredService _discovered({
  required bool canRead,
  required bool canNotify,
}) => BleDiscoveredService(
  uuid: _svc,
  characteristics: [
    BleDiscoveredCharacteristic(
      uuid: _stateChar,
      canRead: canRead,
      canWrite: false,
      canNotify: canNotify,
    ),
  ],
);

/// Pump the builder and hand back every value it rendered, in order.
Future<List<EntityLiveValue>> pumpValues(
  WidgetTester tester, {
  required FakeBleService ble,
  required FakeSpecCodec codec,
  required EntityDto entity,
}) async {
  final seen = <EntityLiveValue>[];
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        bleServiceProvider.overrideWithValue(ble),
        specCodecProvider.overrideWithValue(codec),
      ],
      child: MaterialApp(
        home: EntityValueBuilder(
          deviceId: 'd',
          serviceUuid: _svc,
          entity: entity,
          specYaml: 'y',
          builder: (context, value) {
            seen.add(value);
            return const SizedBox.shrink();
          },
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return seen;
}

const _decoded = <DecodedValueDto>[
  DecodedValueDto(
    name: 'temperature',
    valueType: 'int',
    display: '21.5',
    intValue: 215,
    rawNumber: 215.0,
    decodedNumber: 21.5,
    decodedText: '21.5',
    decimals: 1,
    scale: 0.1,
    unit: 'C',
  ),
];

void main() {
  testWidgets('an entity with no format block reports unavailable, not error', (
    tester,
  ) async {
    // A spec gap is not a device failure, and the two read differently to a
    // user: one is "we have not written this down yet", the other is "your
    // device did not answer".
    final ble = FakeBleService();
    final seen = await pumpValues(
      tester,
      ble: ble,
      codec: FakeSpecCodec(),
      entity: _entity(hasFormat: false),
    );

    expect(seen.last.status, EntityValueStatus.unavailable);
    expect(ble.reads, isEmpty, reason: 'nothing to decode, so nothing to read');
  });

  testWidgets('an entity with no state characteristic never reads', (
    tester,
  ) async {
    final ble = FakeBleService();
    final seen = await pumpValues(
      tester,
      ble: ble,
      codec: FakeSpecCodec(),
      entity: _entity(stateCharacteristic: null),
    );

    expect(seen.last.status, EntityValueStatus.unavailable);
    expect(ble.reads, isEmpty);
  });

  testWidgets('a readable characteristic seeds the card from one read', (
    tester,
  ) async {
    final ble = FakeBleService(
      servicesToReturn: [_discovered(canRead: true, canNotify: false)],
      readValues: {
        _stateChar: const [21],
      },
    );
    final seen = await pumpValues(
      tester,
      ble: ble,
      codec: FakeSpecCodec(decoded: _decoded),
      entity: _entity(),
    );

    expect(
      seen.first.status,
      EntityValueStatus.loading,
      reason: 'the first frame renders before the read answers',
    );
    expect(seen.last.status, EntityValueStatus.live);
    expect(seen.last.decodedNumber, 21.5);
    expect(ble.reads, hasLength(1));
  });

  testWidgets('a notify-only characteristic waits instead of reading', (
    tester,
  ) async {
    // Reading a characteristic discovery says is notify-only earns a
    // failure the user cannot act on. Waiting in `loading` is honest —
    // and safe, because a subscription exists to end the wait.
    final notify = StreamController<List<int>>();
    addTearDown(notify.close);
    final ble = FakeBleService(
      servicesToReturn: [_discovered(canRead: false, canNotify: true)],
      notifyStream: notify.stream,
    );
    final seen = await pumpValues(
      tester,
      ble: ble,
      codec: FakeSpecCodec(decoded: _decoded),
      entity: _entity(canNotify: true),
    );

    expect(ble.reads, isEmpty, reason: 'the seed read is skipped');
    expect(seen.last.status, EntityValueStatus.loading);

    // The first notification is what ends the wait.
    notify.add(const [21]);
    await tester.pumpAndSettle();
    expect(seen.last.status, EntityValueStatus.live);
    expect(seen.last.decodedNumber, 21.5);
  });

  testWidgets('a failed read keeps the previous reading on screen', (
    tester,
  ) async {
    // A transient failure must not blank a card that was showing a value:
    // the number the device last reported is still the best thing known.
    final notify = StreamController<List<int>>();
    addTearDown(notify.close);
    final ble = FakeBleService(
      servicesToReturn: [_discovered(canRead: true, canNotify: true)],
      readValues: {
        _stateChar: const [21],
      },
      notifyStream: notify.stream,
    );
    final seen = await pumpValues(
      tester,
      ble: ble,
      codec: FakeSpecCodec(decoded: _decoded),
      entity: _entity(canNotify: true),
    );
    expect(seen.last.status, EntityValueStatus.live);

    // A notification that fails to decode leaves the good value alone.
    notify.addError(Exception('link dropped'));
    await tester.pumpAndSettle();
    expect(
      seen.last.status,
      EntityValueStatus.live,
      reason: 'a dropped notify stream must not overwrite a good reading',
    );
    expect(seen.last.decodedNumber, 21.5);
  });

  testWidgets('a subscription that fails before any value says so', (
    tester,
  ) async {
    // The other half of the same rule: with the seed read skipped, this
    // failure is the card's ONLY signal (a refused CCCD write on a device
    // that wants pairing), so swallowing it would spin forever.
    final ble = FakeBleService(
      servicesToReturn: [_discovered(canRead: false, canNotify: true)],
      notifyStream: Stream<List<int>>.error(Exception('needs pairing')),
    );
    final seen = await pumpValues(
      tester,
      ble: ble,
      codec: FakeSpecCodec(decoded: _decoded),
      entity: _entity(canNotify: true),
    );

    expect(seen.last.status, EntityValueStatus.error);
    expect(seen.last.error, isNotNull);
  });

  testWidgets('a read failure surfaces as an error with the reading kept', (
    tester,
  ) async {
    final ble = FakeBleService(
      servicesToReturn: [_discovered(canRead: true, canNotify: false)],
      readError: Exception('device is asleep'),
    );
    final seen = await pumpValues(
      tester,
      ble: ble,
      codec: FakeSpecCodec(decoded: _decoded),
      entity: _entity(),
    );

    expect(seen.last.status, EntityValueStatus.error);
    expect(seen.last.error, isNotNull);
  });

  testWidgets('disposing cancels the notify subscription', (tester) async {
    // The subscription is a real radio resource on the device; leaking one
    // per card visit ends with a peripheral that stops notifying.
    final notify = StreamController<List<int>>.broadcast();
    addTearDown(notify.close);
    final ble = FakeBleService(
      servicesToReturn: [_discovered(canRead: true, canNotify: true)],
      readValues: {
        _stateChar: const [21],
      },
      notifyStream: notify.stream,
    );
    await pumpValues(
      tester,
      ble: ble,
      codec: FakeSpecCodec(decoded: _decoded),
      entity: _entity(canNotify: true),
    );
    expect(ble.liveSubscriberCount[_stateChar], 1);

    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await tester.pumpAndSettle();

    expect(ble.cancelledSubscriptions, contains(_stateChar));
    expect(ble.liveSubscriberCount[_stateChar], 0);
  });
}
