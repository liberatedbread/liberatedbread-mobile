// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// The HT-W01 settings screen: settings read and written through the client,
// and no control for the reset, the restart or the Wi-Fi channel, which are
// listed as refused instead.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/models/network_device.dart';
import 'package:liberated_bread_mobile/providers/network_control_provider.dart';
import 'package:liberated_bread_mobile/providers/saved_device_provider.dart';
import 'package:liberated_bread_mobile/screens/ht_w01_screen.dart';
import 'package:liberated_bread_mobile/services/ht_w01_client.dart';
import 'package:liberated_bread_mobile/src/rust/api/ht_w01_api.dart';
import 'package:liberated_bread_mobile/src/rust/protocol/ht_w01.dart';
import 'package:liberated_bread_mobile/src/rust/protocol/readonly.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Fake implements HtW01Client {
  final calls = <String>[];

  @override
  List<HtW01PaletteDto> palettes() => const [
    HtW01PaletteDto(value: 1, name: 'white hot'),
    HtW01PaletteDto(value: 4, name: 'ironbow'),
  ];

  @override
  Future<List<ReadOnlyCommandDto>> commandPolicy(String specYaml) async =>
      const [
        ReadOnlyCommandDto(name: 'set_palette', sent: true),
        ReadOnlyCommandDto(
          name: 'action_reset_config',
          sent: false,
          refusal: 'Not sent by this app: the spec cannot say what it resets.',
        ),
      ];

  @override
  Future<HtW01Settings> readSettings() async {
    calls.add('read');
    return const HtW01Settings(
      palette: 4,
      range: HtW01Range.small,
      emissivityHundredths: 95,
      answered: 3,
    );
  }

  @override
  Future<HtW01Ack> setPalette(int value) async {
    calls.add('palette $value');
    return const HtW01Ack(answered: true);
  }

  @override
  Future<HtW01Ack> setMeasuringRange(HtW01Range range) async {
    calls.add('range ${range.name}');
    return const HtW01Ack(answered: false);
  }

  @override
  Future<HtW01Ack> setEmissivity(int hundredths) async {
    calls.add('emissivity $hundredths');
    return const HtW01Ack(answered: true);
  }

  @override
  Future<HtW01Ack> refreshShutter() async {
    calls.add('shutter');
    return const HtW01Ack(answered: true);
  }
}

void main() {
  Future<void> pump(WidgetTester tester, _Fake client) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          htW01ClientFactoryProvider.overrideWithValue((_, _) => client),
        ],
        child: MaterialApp(
          home: HtW01Screen(
            device: NetworkDevice(
              host: '192.168.1.10',
              name: 'HT-W01-ABCD',
              sources: const {NetworkDiscoverySource.lanProbe},
              discoveredAt: DateTime(2026),
            ),
            controls: const NetworkControls(
              specYaml: 'ht_w01',
              entities: [],
              htW01Settings: true,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('reads settings and writes the ones it offers', (tester) async {
    final client = _Fake();
    await pump(tester, client);
    expect(client.calls, isEmpty, reason: 'nothing is sent unasked');

    await tester.tap(find.text('Read settings'));
    await tester.pumpAndSettle();
    expect(find.text('Palette: ironbow'), findsOneWidget);
    expect(find.widgetWithText(TextField, '0.95'), findsOneWidget);

    await tester.tap(find.text('white hot'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Large, 120 to 550 °C'));
    await tester.pumpAndSettle();
    expect(find.textContaining('sent nothing back'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '0.90');
    await tester.tap(find.text('Set'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Refresh shutter'));
    await tester.pumpAndSettle();
    expect(client.calls, [
      'read',
      'palette 1',
      'range large',
      'emissivity 90',
      'shutter',
    ]);
  });

  testWidgets('an emissivity out of range is not sent', (tester) async {
    final client = _Fake();
    await pump(tester, client);
    await tester.enterText(find.byType(TextField), '1.5');
    await tester.tap(find.text('Set'));
    await tester.pumpAndSettle();
    expect(client.calls, isEmpty);
    expect(find.textContaining('0.00 to 1.00'), findsWidgets);
  });

  testWidgets('offers no reset, restart or channel, and lists the reset as '
      'refused', (tester) async {
    await pump(tester, _Fake());
    for (final word in ['Reset', 'Restart', 'Reboot', 'channel']) {
      expect(
        find.widgetWithText(ButtonStyleButton, word),
        findsNothing,
        reason: word,
      );
      expect(find.widgetWithText(ChoiceChip, word), findsNothing);
    }
    await tester.tap(find.text('Commands in the device spec'));
    await tester.pumpAndSettle();
    expect(find.text('action_reset_config'), findsOneWidget);
    expect(find.textContaining('cannot say what it resets'), findsOneWidget);
  });
}
