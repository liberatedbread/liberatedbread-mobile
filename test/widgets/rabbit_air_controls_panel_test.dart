// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// The shared Rabbit Air control surface. Its send discipline is "send, then
// re-poll", and the two halves fail differently: a refused command is "try
// again", a failed re-poll is "it took, but what you see may be stale".
// Telling a user to re-send a command the purifier already accepted is how
// a purifier ends up being told twice.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/providers/spec_codec_provider.dart';
import 'package:liberated_bread_mobile/services/rabbit_air_control_service.dart';
import 'package:liberated_bread_mobile/services/rabbit_air_control_transport.dart';
import 'package:liberated_bread_mobile/services/spec_codec.dart';
import 'package:liberated_bread_mobile/widgets/rabbit_air_controls_panel.dart';

import '../fakes/fake_spec_codec.dart';

/// A scriptable transport: it hands back a key, answers state polls, and can
/// be told to start failing (or to fail only the send) at any point.
class _FakeTransport implements RabbitAirControlTransport {
  String? key = 'abcd';
  String stateReply = '{"data":{"power":1}}';

  /// Thrown by [send] for a COMMAND request (one with a command name).
  Object? sendError;

  /// Thrown by [send] for a STATE request — the re-poll after a send, and
  /// the initial load.
  Object? pollError;

  final List<String> sent = [];
  int _id = 0;

  @override
  Future<String?> userKey() async => key;

  @override
  Future<void> saveUserKey(String value) async => key = value;

  @override
  Future<void> syncClock({
    required String specYaml,
    required String userKey,
  }) async {}

  @override
  int nextRequestId() => ++_id;

  @override
  int deviceTs() => 0;

  @override
  Future<String> send(
    RabbitAirRequestDto request, {
    required String userKey,
  }) async {
    sent.add(request.json);
    if (request.json.contains('"$_stateCommand"')) {
      if (pollError != null) throw pollError!;
      return stateReply;
    }
    if (sendError != null) throw sendError!;
    return '{"data":{}}';
  }
}

const _stateCommand = 'get_state';

const _entity = NetworkEntityDto(
  isInstanced: false,
  name: 'Power',
  platform: 'switch',
  stateCommand: _stateCommand,
  valueField: 'power',
  options: [],
  actions: [
    NetworkActionDto(
      credentials: [],
      instanceParams: [],
      role: 'turn_on',
      transport: 'udp',
      commandName: 'turn_on',
      userParams: [],
      readBack: [],
    ),
    NetworkActionDto(
      credentials: [],
      instanceParams: [],
      role: 'turn_off',
      transport: 'udp',
      commandName: 'turn_off',
      userParams: [],
      readBack: [],
    ),
  ],
);

/// A number entity, which the panel draws with an edit button that opens the
/// Set dialog — the one place a TextEditingController was disposed while the
/// dialog's closing animation was still building its TextField.
const _numberEntity = NetworkEntityDto(
  isInstanced: false,
  name: 'Fan',
  platform: 'number',
  stateCommand: _stateCommand,
  valueField: 'speed',
  options: [],
  actions: [
    NetworkActionDto(
      credentials: [],
      instanceParams: [],
      role: 'set_value',
      transport: 'udp',
      commandName: 'set_value',
      userParams: [],
      readBack: [],
    ),
  ],
);

FakeSpecCodec _codec() => FakeSpecCodec(
  networkReading: (name, returned) => const NetworkReadingDto(
    kind: NetworkReadingKind.onOff,
    isOn: true,
    raw: '1',
  ),
);

Future<void> _pumpPanel(
  WidgetTester tester, {
  required _FakeTransport transport,
  required FakeSpecCodec codec,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [specCodecProvider.overrideWithValue(codec)],
      child: MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: RabbitAirControlsPanel(
              specYaml: 'y',
              entities: const [_entity],
              transport: transport,
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('the Set dialog outlives its own pop animation', (tester) async {
    // _editNumber disposed its TextEditingController the moment showDialog
    // returned, while the dialog's TextField was still in the tree for the
    // exit animation: a focused field schedules a caret frame that touches
    // the disposed controller — a notifyListeners assertion in debug, a
    // use-after-dispose in release. The sibling _promptRabbitAirKey documents
    // exactly why it does NOT dispose; this one did anyway.
    final transport = _FakeTransport();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [specCodecProvider.overrideWithValue(_codec())],
        child: MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: RabbitAirControlsPanel(
                specYaml: 'y',
                entities: const [_numberEntity],
                transport: transport,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Set Fan'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '3');
    await tester.tap(find.text('Send'));
    // Frame by frame through the pop transition: this is where the disposed
    // controller was touched, and pumpAndSettle would skip past the frames
    // that matter.
    for (var i = 0; i < 24; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      expect(
        tester.takeException(),
        isNull,
        reason: 'frame $i of the pop touched the dialog controller',
      );
    }
    await tester.pumpAndSettle();
    expect(transport.sent, isNotEmpty, reason: 'the value was still sent');
  });

  testWidgets('a refused command says the purifier did not take it', (
    tester,
  ) async {
    final transport = _FakeTransport()
      ..sendError = const RabbitAirControlException('refused');
    await _pumpPanel(tester, transport: transport, codec: _codec());

    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();

    expect(find.textContaining('did not accept that'), findsOneWidget);
  });

  testWidgets('a failed re-poll is not reported as a refused command', (
    tester,
  ) async {
    // R-127. The send and the re-poll shared one catch, so a purifier that
    // TOOK the command and then went quiet was reported as one that refused
    // it — advice that is wrong twice over: it did accept it, and trying
    // again sends the command a second time.
    final transport = _FakeTransport();
    final codec = _codec();
    await _pumpPanel(tester, transport: transport, codec: codec);

    // The send itself succeeds; only the re-poll afterwards fails.
    transport.pollError = const RabbitAirControlException('no answer');
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();

    expect(
      codec.renderNetworkRabbitAirCommandCalls.single.commandName,
      'turn_off',
      reason: 'the command went out and was accepted',
    );
    expect(find.textContaining('did not accept that'), findsNothing);
    expect(find.textContaining('could not read back'), findsOneWidget);
  });
}
