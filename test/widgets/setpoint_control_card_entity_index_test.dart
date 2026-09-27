// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/providers/ble_provider.dart';
import 'package:liberated_bread_mobile/providers/spec_codec_provider.dart';
import 'package:liberated_bread_mobile/services/spec_codec.dart';
import 'package:liberated_bread_mobile/widgets/setpoint_control_card.dart';

import '../fakes/fake_ble_service.dart';
import '../fakes/fake_spec_codec.dart';

const _controlPoint = '00002ad9-0000-1000-8000-00805f9b34fb';

/// The walking pad's FTMS "Target Speed": the SECOND entity of that name in
/// kingsmith-walkingpad.yaml, after the WiLink one.
const _ftmsSpeed = EntityDto(
  options: [],
  name: 'Target Speed',
  platform: 'number',
  unit: 'km/h',
  canNotify: false,
  hasFormat: false,
  onWhenNonzero: false,
  actions: [
    EntityActionDto(
      role: 'set_value',
      serviceUuid: '00001826-0000-1000-8000-00805f9b34fb',
      characteristicUuid: _controlPoint,
      commandName: 'set_target_speed',
      userParams: ['speed'],
    ),
  ],
  setpointMin: 0,
  setpointMax: 12,
  setpointStep: 0.1,
  variants: ['FTMS'],
  entityIndex: 7,
);

void main() {
  testWidgets('a setpoint is encoded against its own entity, not its name', (
    tester,
  ) async {
    // Before, only the name crossed to Rust, which took the FIRST entity so
    // named — the WiLink one — refusing 8 km/h against its max of 6 and
    // encoding anything lower in the wrong dialect.
    final codec = FakeSpecCodec(
      entityWrite: EntityWriteDto(
        serviceUuid: '00001826-0000-1000-8000-00805f9b34fb',
        characteristicUuid: _controlPoint,
        bytes: Uint8List.fromList([0x02, 0x20, 0x03]),
      ),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          bleServiceProvider.overrideWithValue(FakeBleService()),
          specCodecProvider.overrideWithValue(codec),
        ],
        child: const MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: SetpointControlCard(
                deviceId: 'd',
                stateServiceUuid: null,
                entity: _ftmsSpeed,
                specYaml: 'y',
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.drag(find.byType(Slider), const Offset(400, 0));
    await tester.pumpAndSettle();

    expect(codec.encodeEntityValueCalls, hasLength(1));
    expect(codec.encodeEntityValueCalls.single.entityName, 'Target Speed');
    expect(codec.encodeEntityValueIndexes, [7]);
  });
}
