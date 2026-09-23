// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/models/radio_band_limits.dart';
import 'package:liberated_bread_mobile/models/radio_channel.dart';
import 'package:liberated_bread_mobile/models/radio_profile.dart';
import 'package:liberated_bread_mobile/models/radio_target.dart';
import 'package:liberated_bread_mobile/providers/channel_plan_provider.dart';
import 'package:liberated_bread_mobile/providers/radio_profile_provider.dart';
import 'package:liberated_bread_mobile/providers/radio_programmer_provider.dart';
import 'package:liberated_bread_mobile/providers/saved_device_provider.dart';
import 'package:liberated_bread_mobile/providers/saved_radio_provider.dart';
import 'package:liberated_bread_mobile/providers/spec_pack_provider.dart';
import 'package:liberated_bread_mobile/screens/radio_device_screen.dart';
import 'package:liberated_bread_mobile/screens/radio_program_screen.dart';
import 'package:liberated_bread_mobile/services/radio_codec.dart';
import 'package:liberated_bread_mobile/services/radio_programmer.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../fakes/fake_codeplug_backup_store.dart';
import '../fakes/fake_radio_programmer.dart';
import '../fakes/in_memory_settings_store.dart';

late SharedPreferences _prefs;

const _ble = RadioTarget(
  transport: RadioTransport.ble,
  id: 'AA:BB:CC:DD:EE:01',
  name: 'Base radio',
);

/// Decodes to whatever the test says. The real decoder is native, and a
/// widget test's fake-async zone never completes a native call.
class _FakeDecoder implements CodeplugDecoder {
  final DecodedChannels result;

  const _FakeDecoder(this.result);

  @override
  Future<DecodedChannels> decode(
          RadioCodeplug codeplug, RadioProfile profile) async =>
      result;
}

class _Harness {
  final FakeRadioProgrammer programmer;
  final FakeCodeplugBackupStore backups;
  final ProviderContainer container;

  _Harness(this.programmer, this.backups, this.container);
}

/// Mounts the screen — directly, or behind a launcher page when the test
/// needs somewhere to navigate back to.
Future<_Harness> _pump(
  WidgetTester tester, {
  RadioTarget target = _ble,
  RadioProfile? initialProfile,
  FakeRadioProgrammer? programmer,
  FakeCodeplugBackupStore? backups,
  DecodedChannels decoded = const DecodedChannels(channels: [], hadGaps: false),
  InMemorySettingsStore? settings,
  bool behindLauncher = false,
}) async {
  // Tall enough that every action tile is built: the list is lazy.
  tester.view.physicalSize = const Size(1200, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final prog = programmer ?? FakeRadioProgrammer();
  final store = backups ?? FakeCodeplugBackupStore();
  final screen =
      RadioDeviceScreen(target: target, initialProfile: initialProfile);
  await tester.pumpWidget(ProviderScope(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(_prefs),
      prefsSettingsStoreProvider
          .overrideWith((ref) async => settings ?? InMemorySettingsStore()),
      // One fake behind both transports: which one a target reaches is the
      // provider's business, tested with it.
      radioProgrammerProvider.overrideWithValue(prog),
      serialRadioProgrammerProvider.overrideWithValue(prog),
      codeplugBackupStoreProvider.overrideWithValue(store),
      codeplugDecoderProvider.overrideWithValue(_FakeDecoder(decoded)),
    ],
    child: MaterialApp(
      home: behindLauncher
          ? Builder(
              builder: (context) => Scaffold(
                body: Center(
                  child: TextButton(
                    onPressed: () => Navigator.of(context)
                        .push(MaterialPageRoute<void>(builder: (_) => screen)),
                    child: const Text('open'),
                  ),
                ),
              ),
            )
          : screen,
    ),
  ));
  await tester.pumpAndSettle();
  if (behindLauncher) {
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }
  final container =
      ProviderScope.containerOf(tester.element(find.byType(RadioDeviceScreen)));
  return _Harness(prog, store, container);
}

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    _prefs = await SharedPreferences.getInstance();
  });

  group('what it shows', () {
    testWidgets('which radio, over what, and the model it opens on',
        (tester) async {
      await _pump(tester, initialProfile: uv5gMiniProfile);

      expect(find.text('Base radio'), findsWidgets);
      expect(find.textContaining('Bluetooth'), findsWidgets);
      expect(find.textContaining(_ble.id), findsOneWidget);
      expect(find.text(uv5gMiniProfile.displayName), findsOneWidget);
      // Honest about what it cannot know.
      expect(find.textContaining('It cannot be asked'), findsOneWidget);
    });

    testWidgets('a suggested model this link cannot program is passed over',
        (tester) async {
      // The UV-5R is a cable radio; over Bluetooth the screen falls back to
      // the Radio tab's radio, which by default is the UV-5R Mini.
      await _pump(tester, initialProfile: uv5rProfile);
      expect(find.text(uv5rMiniProfile.displayName), findsOneWidget);
      expect(find.text(uv5rProfile.displayName), findsNothing);
    });

    testWidgets('an unconfirmed model says so', (tester) async {
      await _pump(tester, initialProfile: uv32Profile);
      expect(find.text('Not yet confirmed on this model'), findsOneWidget);
    });

    testWidgets(
        'a cable radio opens on a cable model, and says what the check '
        'will show', (tester) async {
      await _pump(
        tester,
        target: const RadioTarget(
            transport: RadioTransport.usb, id: '/dev/ttyUSB0', name: ''),
      );
      // The Radio tab's Bluetooth radio is passed over for one a cable
      // programs.
      expect(find.text(uv5rProfile.displayName), findsOneWidget);
      expect(find.textContaining('firmware it reports'), findsOneWidget);
      expect(find.text('Check it answers'), findsOneWidget);
    });

    testWidgets('offers to make this the Radio tab\'s radio when it is not',
        (tester) async {
      final harness = await _pump(tester, initialProfile: uv5gMiniProfile);

      await tester.tap(find.text('Use for suggestions and new plans'));
      await tester.pumpAndSettle();

      final selected = harness.container.read(selectedRadioProfileProvider);
      expect(selected.valueOrNull, uv5gMiniProfile);
      expect(find.text('Use for suggestions and new plans'), findsNothing);
    });

    testWidgets('picking another model changes what the actions use',
        (tester) async {
      await _pump(tester);
      await tester.tap(find.text('Radio model'));
      await tester.pumpAndSettle();

      // Only the models this link can program are offered.
      expect(find.text(uv5rProfile.displayName), findsNothing);
      await tester.tap(find.text(uv32Profile.displayName).last);
      await tester.pumpAndSettle();

      expect(find.text(uv32Profile.displayName), findsOneWidget);
      expect(find.text('Not yet confirmed on this model'), findsOneWidget);
    });
  });

  group('check it answers', () {
    testWidgets('asks, reports no more than it learned, and saves the radio',
        (tester) async {
      final harness = await _pump(tester);

      await tester.tap(find.text('Check it answers'));
      await tester.pumpAndSettle();

      expect(harness.programmer.identifyCalls, 1);
      expect(harness.programmer.deviceIds, [_ble.id]);
      expect(find.textContaining('confirms the family rather than'),
          findsOneWidget);
      final saved = harness.container.read(savedRadiosProvider).single;
      expect(saved.target, _ble);
      expect(saved.radioProfileId, uv5rMiniProfile.id);
      // Saved radios get a way to be forgotten.
      expect(find.byTooltip('Forget this radio'), findsOneWidget);
    });

    testWidgets('a radio that does not answer is not saved', (tester) async {
      final harness = await _pump(
        tester,
        programmer: FakeRadioProgrammer(error: const RadioTimeoutException()),
      );

      await tester.tap(find.text('Check it answers'));
      await tester.pumpAndSettle();

      expect(find.textContaining('stopped responding'), findsWidgets);
      expect(harness.container.read(savedRadiosProvider), isEmpty);
    });

    testWidgets('a programmer that cannot drive the model is not asked',
        (tester) async {
      final harness = await _pump(tester,
          programmer: FakeRadioProgrammer(supported: false));

      await tester.tap(find.text('Check it answers'));
      await tester.pumpAndSettle();

      expect(harness.programmer.identifyCalls, 0);
      expect(find.textContaining('cannot program that radio'), findsOneWidget);
    });
  });

  group('reading into a plan', () {
    const channels = [
      RadioChannel(name: 'ONE', rxFreqHz: 146520000, txFreqHz: 146520000),
      RadioChannel(name: 'TWO', rxFreqHz: 446000000, txFreqHz: 446000000),
    ];

    testWidgets('keeps the read as a backup and makes the plan',
        (tester) async {
      final harness = await _pump(
        tester,
        decoded: const DecodedChannels(channels: channels, hadGaps: false),
      );

      await tester.tap(find.text('Read its channels into a new plan'));
      await tester.pumpAndSettle();

      expect(harness.backups.saved, hasLength(1));
      final plan = harness.container.read(channelPlansProvider).single;
      expect(plan.name, 'From Base radio');
      expect([for (final c in plan.channels) c.name], ['ONE', 'TWO']);
      expect(plan.radioProfileId, uv5rMiniProfile.id);
      expect(find.textContaining('2 channels read into'), findsOneWidget);
      expect(find.text('Open plan'), findsOneWidget);
      expect(find.textContaining('closed up'), findsNothing);
    });

    testWidgets('says so when the radio had gaps a plan cannot keep',
        (tester) async {
      await _pump(
        tester,
        decoded: const DecodedChannels(channels: channels, hadGaps: true),
      );

      await tester.tap(find.text('Read its channels into a new plan'));
      await tester.pumpAndSettle();

      expect(find.textContaining('closed up'), findsOneWidget);
    });
  });

  group('restoring', () {
    RadioCodeplug backup(int fill, DateTime at) => RadioCodeplug(
          modelId: uv5rMiniProfile.id,
          image: Uint8List(0x8240)..fillRange(0, 16, fill),
          readAt: at,
        );

    testWidgets('reads and saves the radio first, then puts the copy back',
        (tester) async {
      final chosen = backup(0xAB, DateTime(2026, 9, 1, 9, 30));
      final harness = await _pump(
        tester,
        backups: FakeCodeplugBackupStore(existing: [chosen]),
      );

      await tester.tap(find.text('Restore a backup'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('2026-09-01 09:30'));
      await tester.pumpAndSettle();

      expect(find.text('Restore to Base radio?'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Restore'));
      await tester.pumpAndSettle();

      expect(harness.programmer.readCalls, 1,
          reason: 'what is on the radio now is read before it is replaced');
      expect(harness.backups.saved, hasLength(1),
          reason: '...and saved, so the restore can itself be undone');
      expect(harness.programmer.restored.single.image, chosen.image);
      expect(find.textContaining('restored'), findsOneWidget);
    });

    testWidgets('restores the oldest of a full set of backups', (tester) async {
      // Saving the pre-restore read prunes the model's oldest backup. When
      // the backup being restored IS the oldest, it has to be loaded first —
      // the other order deletes it and then fails to read it.
      final oldest = backup(0xAB, DateTime(2026, 9, 1, 0, 0));
      final harness = await _pump(
        tester,
        backups: FakeCodeplugBackupStore(
          keepPerModel: 10,
          existing: [
            oldest,
            for (var i = 1; i < 10; i++) backup(i, DateTime(2026, 9, 1, i)),
          ],
        ),
      );

      await tester.tap(find.text('Restore a backup'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.text('2026-09-01 00:00'), 80,
          scrollable: find.byType(Scrollable).last);
      await tester.tap(find.text('2026-09-01 00:00'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Restore'));
      await tester.pumpAndSettle();

      expect(harness.programmer.restored.single.image, oldest.image);
      expect(find.textContaining('restored'), findsOneWidget);
    });

    testWidgets('cancelling the confirmation touches nothing', (tester) async {
      final harness = await _pump(
        tester,
        backups: FakeCodeplugBackupStore(
            existing: [backup(1, DateTime(2026, 9, 1, 9, 30))]),
      );

      await tester.tap(find.text('Restore a backup'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('2026-09-01 09:30'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();

      expect(harness.programmer.readCalls, 0);
      expect(harness.programmer.restored, isEmpty);
    });

    testWidgets('only offers backups of this model', (tester) async {
      await _pump(
        tester,
        backups: FakeCodeplugBackupStore(existing: [
          RadioCodeplug(
            modelId: uv32Profile.id,
            image: Uint8List(8),
            readAt: DateTime(2026, 9, 1),
          ),
        ]),
      );

      await tester.tap(find.text('Restore a backup'));
      await tester.pumpAndSettle();

      expect(find.textContaining('No backups of a Baofeng UV-5R Mini'),
          findsOneWidget);
    });
  });

  group('writing a plan', () {
    testWidgets('with no plans, says where plans come from', (tester) async {
      await _pump(tester);
      await tester.tap(find.text('Write a channel plan'));
      await tester.pumpAndSettle();
      expect(find.textContaining('No channel plans yet'), findsOneWidget);
    });

    testWidgets('hands the chosen plan and this radio to the program screen',
        (tester) async {
      final harness = await _pump(tester);
      await harness.container.read(channelPlansProvider.notifier).create(
            name: 'Local repeaters',
            radioProfileId: uv5rMiniProfile.id,
          );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Write a channel plan'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Local repeaters'));
      await tester.pumpAndSettle();

      final program =
          tester.widget<RadioProgramScreen>(find.byType(RadioProgramScreen));
      expect(program.target, _ble);
      expect(program.plan.name, 'Local repeaters');
      expect(program.profile, uv5rMiniProfile);
    });
  });

  testWidgets('forgetting a saved radio removes it and leaves', (tester) async {
    final harness = await _pump(tester, behindLauncher: true);
    await harness.container
        .read(savedRadiosProvider.notifier)
        .touch(target: _ble, seenAt: DateTime(2026, 9, 1));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Forget this radio'));
    await tester.pumpAndSettle();

    expect(harness.container.read(savedRadiosProvider), isEmpty);
    expect(find.byType(RadioDeviceScreen), findsNothing);
    expect(find.textContaining('Removed Base radio'), findsOneWidget);
  });

  testWidgets('will not be left while a session is running', (tester) async {
    final hold = Completer<void>();
    final programmer = FakeRadioProgrammer()..hold = hold;
    await _pump(tester, programmer: programmer, behindLauncher: true);

    await tester.tap(find.text('Check it answers'));
    await tester.pump();
    expect(find.text('Asking the radio to answer…'), findsOneWidget);

    await tester.pageBack();
    await tester.pump();

    expect(find.byType(RadioDeviceScreen), findsOneWidget);
    expect(find.textContaining('Wait for the radio to finish'), findsOneWidget);

    hold.complete();
    await tester.pumpAndSettle();
    expect(
        find.textContaining('confirms the family rather than'), findsOneWidget);
  });

  group('transmit limits', () {
    const cable = RadioTarget(
      transport: RadioTransport.usb,
      id: '/dev/ttyUSB0',
      name: 'UV-5R',
    );
    final widened = RadioBandLimits.widenedFor(uv5rProfile)!;

    /// Tick the acknowledgement and confirm it.
    Future<void> acknowledge(WidgetTester tester) async {
      expect(find.text('Widen the transmit range?'), findsOneWidget);
      await tester.tap(find.byType(CheckboxListTile));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Enable'));
      await tester.pumpAndSettle();
    }

    InMemorySettingsStore kept(RadioBandLimits limits) =>
        InMemorySettingsStore({
          OriginalBandLimitsNotifier.key: jsonEncode({
            uv5rProfile.id: OriginalBandLimits(
              limits: limits,
              readAt: DateTime(2026, 9, 20, 14, 2),
            ).toJson(),
          }),
          TxUnlockNotifier.key: jsonEncode({uv5rProfile.id: true}),
        });

    testWidgets(
        'a cable radio that stores them offers to widen them, and says it '
        'is unconfirmed', (tester) async {
      await _pump(tester, target: cable);
      expect(find.text('Widen its transmit limits'), findsOneWidget);
      expect(find.textContaining('To VHF 130–179 MHz and UHF 400–520 MHz'),
          findsOneWidget);
      expect(find.textContaining('Not yet confirmed on a real radio'),
          findsOneWidget);
      expect(find.text('Put back its original transmit limits'), findsNothing,
          reason: 'nothing has been kept to put back');
    });

    testWidgets('a radio with none to set offers nothing', (tester) async {
      await _pump(tester);
      expect(find.text('Widen its transmit limits'), findsNothing);
    });

    testWidgets('widening asks first, and a cancel touches nothing',
        (tester) async {
      final harness = await _pump(tester, target: cable);
      await tester.tap(find.text('Widen its transmit limits'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(harness.programmer.readCalls, 0);
      expect(harness.programmer.writtenLimits, isEmpty);
    });

    testWidgets(
        'widening backs the radio up, keeps what it had, writes, and turns '
        'the wider suggestions on', (tester) async {
      final harness = await _pump(tester, target: cable);
      await tester.tap(find.text('Widen its transmit limits'));
      await tester.pumpAndSettle();
      await acknowledge(tester);

      expect(harness.backups.saved, hasLength(1));
      expect(harness.programmer.writtenLimits, [widened]);
      expect(harness.programmer.deviceIds.toSet(), {cable.id});
      expect(find.textContaining('Widened to VHF 130–179 MHz'), findsOneWidget);
      expect(find.textContaining('It had VHF 136–174 MHz'), findsOneWidget);

      final kept = await harness.container
          .read(originalBandLimitsProvider.future)
          .then((all) => all[uv5rProfile.id]);
      expect(kept!.limits, stockBandLimits);
      final unlocks = await harness.container.read(txUnlockProvider.future);
      expect(unlocks[uv5rProfile.id], isTrue);
      // And the way back is on offer.
      expect(
          find.text('Put back its original transmit limits'), findsOneWidget);
    });

    testWidgets('a radio already that wide is left as it is', (tester) async {
      final programmer = FakeRadioProgrammer()..bandLimits = widened;
      final harness =
          await _pump(tester, target: cable, programmer: programmer);
      await tester.tap(find.text('Widen its transmit limits'));
      await tester.pumpAndSettle();
      await acknowledge(tester);

      expect(programmer.writtenLimits, isEmpty);
      expect(find.textContaining('already VHF 130–179 MHz'), findsOneWidget);
      expect(await harness.container.read(originalBandLimitsProvider.future),
          isEmpty,
          reason: 'widened limits are not the ones to go back to');
    });

    testWidgets(
        'a write that fails says so, and still keeps what the radio had',
        (tester) async {
      final programmer = FakeRadioProgrammer()
        ..limitWriteError = const RadioProtocolException(
            'The radio does not hold what was written at 0x1fc0. Restore '
            'your backup before using it.');
      final harness =
          await _pump(tester, target: cable, programmer: programmer);
      await tester.tap(find.text('Widen its transmit limits'));
      await tester.pumpAndSettle();
      await acknowledge(tester);

      expect(find.textContaining('Restore your backup'), findsWidgets);
      expect(harness.backups.saved, hasLength(1));
      final kept = await harness.container
          .read(originalBandLimitsProvider.future)
          .then((all) => all[uv5rProfile.id]);
      expect(kept!.limits, stockBandLimits);
      final unlocks = await harness.container.read(txUnlockProvider.future);
      expect(unlocks[uv5rProfile.id], isNot(isTrue),
          reason: 'suggestions stay narrow until the radio is widened');
    });

    testWidgets(
        'putting them back asks, backs up, writes what was kept, and turns '
        'the wider suggestions off', (tester) async {
      final programmer = FakeRadioProgrammer()..bandLimits = widened;
      final harness = await _pump(tester,
          target: cable,
          programmer: programmer,
          settings: kept(stockBandLimits));
      expect(find.textContaining('VHF 136–174 MHz and UHF 400–520 MHz: what'),
          findsOneWidget);

      await tester.tap(find.text('Put back its original transmit limits'));
      await tester.pumpAndSettle();
      expect(find.text('Put back its transmit limits?'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Put back'));
      await tester.pumpAndSettle();

      expect(harness.backups.saved, hasLength(1));
      expect(programmer.writtenLimits, [stockBandLimits]);
      expect(
          find.textContaining('Put back to VHF 136–174 MHz'), findsOneWidget);
      final unlocks = await harness.container.read(txUnlockProvider.future);
      expect(unlocks[uv5rProfile.id], isFalse);
    });

    testWidgets('a cancelled put-back touches nothing', (tester) async {
      final harness =
          await _pump(tester, target: cable, settings: kept(stockBandLimits));
      await tester.tap(find.text('Put back its original transmit limits'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(harness.programmer.readCalls, 0);
      expect(harness.programmer.writtenLimits, isEmpty);
    });
  });
}
