// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/providers/ble_provider.dart';
import 'package:liberated_bread_mobile/providers/spec_codec_provider.dart';
import 'package:liberated_bread_mobile/services/ble_service.dart';
import 'package:liberated_bread_mobile/services/spec_codec.dart';
import 'package:liberated_bread_mobile/widgets/typed_command_widget.dart';

import '../fakes/fake_ble_service.dart';
import '../fakes/fake_spec_codec.dart';

const _svc = '03b80e5a-ede8-4b33-a751-6ce34ec4c700';
const _char = '7772e5db-3868-4112-a1a9-f2669d106bf3';

CharacteristicDto _commands(List<CommandDto> commands) => CharacteristicDto(
  uuid: _char,
  name: 'MIDI I/O',
  canRead: false,
  canWrite: true,
  canNotify: true,
  commands: commands,
  formatFields: const [],
);

const _play = CommandDto(
  name: 'transport_play',
  description: 'Play',
  parameters: [],
  isFixed: true,
  isEncodable: true,
  unsupportedEncoding: null,
  advanced: false,
);

const _move = CommandDto(
  name: 'move',
  description: 'Move',
  isFixed: false,
  isEncodable: true,
  unsupportedEncoding: null,
  advanced: false,
  parameters: [
    ParameterDto(name: 'speed', valueType: 'float32', userSettable: true),
  ],
);

Widget _wrap({
  required FakeBleService ble,
  required FakeSpecCodec codec,
  required CharacteristicDto characteristic,
}) => ProviderScope(
  overrides: [
    bleServiceProvider.overrideWithValue(ble),
    specCodecProvider.overrideWithValue(codec),
  ],
  child: MaterialApp(
    home: Scaffold(
      body: TypedCommandWidget(
        deviceId: 'dev',
        serviceUuid: _svc,
        specYaml: 'spec',
        specChar: characteristic,
      ),
    ),
  ),
);

class _FailSecondWrite extends FakeBleService {
  @override
  Future<void> writeCharacteristic(
    String deviceId,
    String serviceUuid,
    String charUuid,
    List<int> value,
  ) async {
    if (writes.isNotEmpty) throw StateError('simulated lost link');
    return super.writeCharacteristic(deviceId, serviceUuid, charUuid, value);
  }
}

/// A stack that can hold other writes back for a run of packets, as the real
/// service does. Records each run it was handed, and refuses every packet
/// from [failFrom] on when set.
class _PacketWriterBle extends FakeBleService implements BlePacketWriter {
  final int? failFrom;
  _PacketWriterBle({this.failFrom});

  final List<List<List<int>>> runs = [];

  @override
  Future<void> writeCharacteristicPackets(
    String deviceId,
    String serviceUuid,
    String charUuid,
    List<List<int>> packets, {
    void Function()? onPacketWritten,
  }) async {
    runs.add(packets);
    for (final packet in packets) {
      if (failFrom != null && writes.length >= failFrom!) {
        throw const BleLinkDroppedException();
      }
      await writeCharacteristic(deviceId, serviceUuid, charUuid, packet);
      onPacketWritten?.call();
    }
  }
}

void main() {
  testWidgets('a fragmented command reaches the stack as one run', (
    tester,
  ) async {
    // Packet by packet, a second command tapped mid-send went out between
    // two halves of this one's SysEx. Handed over whole, the stack can keep
    // every other write to the device out of the middle.
    final ble = _PacketWriterBle();
    final codec = FakeSpecCodec(
      encodedWrites: [
        Uint8List.fromList([0x80, 0x80, 0xF0, 0x01]),
        Uint8List.fromList([0x80, 0x02]),
        Uint8List.fromList([0x80, 0x80, 0xF7]),
      ],
    );
    await tester.pumpWidget(
      _wrap(ble: ble, codec: codec, characteristic: _commands(const [_play])),
    );
    await tester.tap(find.widgetWithText(ElevatedButton, 'Transport play'));
    await tester.pumpAndSettle();

    expect(ble.runs, [
      [
        [0x80, 0x80, 0xF0, 0x01],
        [0x80, 0x02],
        [0x80, 0x80, 0xF7],
      ],
    ]);
    expect(find.text('Sent'), findsOneWidget);
  });

  testWidgets('a run cut off partway still says how much was sent', (
    tester,
  ) async {
    final ble = _PacketWriterBle(failFrom: 2);
    final codec = FakeSpecCodec(
      encodedWrites: [
        Uint8List.fromList([1]),
        Uint8List.fromList([2]),
        Uint8List.fromList([3]),
      ],
    );
    await tester.pumpWidget(
      _wrap(ble: ble, codec: codec, characteristic: _commands(const [_play])),
    );
    await tester.tap(find.widgetWithText(ElevatedButton, 'Transport play'));
    await tester.pumpAndSettle();

    expect(ble.runs, hasLength(1));
    expect(
      find.textContaining('Only 2 of 3 packets were sent'),
      findsNWidgets(2),
    );
    expect(find.text('Sent'), findsNothing);
    // A cause written for the user still says why the rest did not go.
    expect(
      find.textContaining(const BleLinkDroppedException().message),
      findsNWidgets(2),
    );
  });

  testWidgets('a run refused at its first packet is a plain refusal', (
    tester,
  ) async {
    // Nothing reached the device, so there is no partial command to warn
    // about: the stack's own words go to the screen.
    final ble = _PacketWriterBle(failFrom: 0);
    final codec = FakeSpecCodec(
      encodedWrites: [
        Uint8List.fromList([1]),
        Uint8List.fromList([2]),
      ],
    );
    await tester.pumpWidget(
      _wrap(ble: ble, codec: codec, characteristic: _commands(const [_play])),
    );
    await tester.tap(find.widgetWithText(ElevatedButton, 'Transport play'));
    await tester.pumpAndSettle();

    expect(find.textContaining('packets were sent'), findsNothing);
    expect(
      find.text(const BleLinkDroppedException().message),
      findsNWidgets(2),
    );
  });

  testWidgets('a fragmented command sends every packet in order', (
    tester,
  ) async {
    final ble = FakeBleService();
    final codec = FakeSpecCodec(
      encodedWrites: [
        Uint8List.fromList([0x80, 0x80, 0xF0, 0x01]),
        Uint8List.fromList([0x80, 0x02]),
        Uint8List.fromList([0x80, 0x80, 0xF7]),
      ],
    );
    await tester.pumpWidget(
      _wrap(ble: ble, codec: codec, characteristic: _commands(const [_play])),
    );
    await tester.tap(find.widgetWithText(ElevatedButton, 'Transport play'));
    await tester.pumpAndSettle();

    expect(ble.writes.map((w) => w.value).toList(), [
      [0x80, 0x80, 0xF0, 0x01],
      [0x80, 0x02],
      [0x80, 0x80, 0xF7],
    ]);
    expect(codec.encodeCalls.single.commandName, 'transport_play');
  });

  testWidgets('a partial packet sequence says exactly how much was sent', (
    tester,
  ) async {
    final ble = _FailSecondWrite();
    final codec = FakeSpecCodec(
      encodedWrites: [
        Uint8List.fromList([1]),
        Uint8List.fromList([2]),
        Uint8List.fromList([3]),
      ],
    );
    await tester.pumpWidget(
      _wrap(ble: ble, codec: codec, characteristic: _commands(const [_play])),
    );
    await tester.tap(find.widgetWithText(ElevatedButton, 'Transport play'));
    await tester.pumpAndSettle();

    expect(ble.writes.single.value, [1]);
    expect(
      find.textContaining('Only 1 of 3 packets were sent'),
      findsNWidgets(2),
    );
    expect(find.text('Sent'), findsNothing);
    // The cause is a StateError: implementation noise, for the log only.
    // It reached the screen as "Cause: Bad state: simulated lost link".
    expect(find.textContaining('Bad state'), findsNothing);
    expect(find.textContaining('simulated lost link'), findsNothing);
  });

  testWidgets('raw float input preserves a negative fractional value', (
    tester,
  ) async {
    final ble = FakeBleService();
    final codec = FakeSpecCodec(encoded: Uint8List.fromList([0x30, 0x32]));
    await tester.pumpWidget(
      _wrap(ble: ble, codec: codec, characteristic: _commands(const [_move])),
    );
    await tester.enterText(find.byType(TextField), '-1.5');
    await tester.tap(find.text('Send'));
    await tester.pumpAndSettle();

    expect(codec.encodeCalls.single.params['speed'], -1.5);
    expect(ble.writes.single.value, [0x30, 0x32]);
  });

  testWidgets('invalid raw float input blocks the write', (tester) async {
    final ble = FakeBleService();
    final codec = FakeSpecCodec(encoded: Uint8List.fromList([0x30, 0x32]));
    await tester.pumpWidget(
      _wrap(ble: ble, codec: codec, characteristic: _commands(const [_move])),
    );
    await tester.enterText(find.byType(TextField), 'not-a-number');
    await tester.tap(find.text('Send'));
    await tester.pumpAndSettle();

    expect(codec.encodeCalls, isEmpty);
    expect(ble.writes, isEmpty);
    expect(find.text('Enter a finite number for Speed.'), findsNWidgets(2));
  });
}
