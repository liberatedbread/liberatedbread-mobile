// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/models/channel_plan.dart';
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
import 'package:liberated_bread_mobile/services/baofeng_ble_programmer.dart'
    show RadioWritePreflight;
import 'package:liberated_bread_mobile/services/codeplug_backup_store.dart';
import 'package:liberated_bread_mobile/services/radio_codec.dart';
import 'package:liberated_bread_mobile/services/radio_programmer.dart';
import 'package:liberated_bread_mobile/services/saved_radio_store.dart';
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
    RadioCodeplug codeplug,
    RadioProfile profile,
  ) async => result;
}

/// Sends the first blocks of a write, then loses the radio — the link drop
/// that leaves it holding part new, part old.
class _CutOffProgrammer extends FakeRadioProgrammer {
  final Object cutOffWith;

  _CutOffProgrammer(this.cutOffWith);

  Stream<RadioProgressEvent> _cutOff() async* {
    yield const RadioProgressEvent(
      stage: RadioProgressStage.writing,
      message: 'Writing…',
      progress: 0.3,
    );
    throw cutOffWith;
  }

  @override
  Stream<RadioProgressEvent> writeChannels({
    required String deviceId,
    required RadioProfile profile,
    required RadioCodeplug base,
    required List<RadioChannel> channels,
  }) => _cutOff();

  @override
  Stream<RadioProgressEvent> restoreCodeplug({
    required String deviceId,
    required RadioProfile profile,
    required RadioCodeplug codeplug,
  }) => _cutOff();
}

/// A programmer that reads but refuses up front to write, as the Bluetooth
/// one does for a UV-32 (no captured write frame).
class _NoWriteProgrammer extends FakeRadioProgrammer
    implements RadioWritePreflight {
  static const reason =
      'Writing a Baofeng UV-32 over Bluetooth is turned off. Nothing was '
      'written.';

  int preflights = 0;

  @override
  Future<void> checkCanWrite(RadioProfile profile) async {
    preflights++;
    throw const RadioUnsupportedException(reason);
  }
}

/// A read that waits on [readHold]: a session a test can keep running.
class _HeldReadProgrammer extends FakeRadioProgrammer {
  final Completer<void> readHold = Completer<void>();

  @override
  Stream<RadioProgressEvent> readCodeplug({
    required String deviceId,
    required RadioProfile profile,
    required void Function(RadioCodeplug) onResult,
  }) async* {
    await readHold.future;
    yield* super.readCodeplug(
      deviceId: deviceId,
      profile: profile,
      onResult: onResult,
    );
  }
}

/// A backup list that answers only when [listHold] completes, as a slow
/// disk would.
class _SlowListStore extends FakeCodeplugBackupStore {
  final Completer<void> listHold = Completer<void>();

  _SlowListStore({super.existing});

  @override
  Future<List<CodeplugBackup>> list() async {
    await listHold.future;
    return super.list();
  }
}

/// A radio list whose disk write fails, as a full disk or a platform
/// channel error would.
class _FailingSavedRadioStore extends SavedRadioStore {
  _FailingSavedRadioStore(super.prefs);

  @override
  Future<List<SavedRadio>> save(SavedRadio radio) async =>
      throw StateError('disk full');
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
  String? planId,
  bool behindLauncher = false,
  SavedRadioStore Function(SharedPreferences prefs)? savedRadioStore,
  BackupFirmwareCheck? firmwareCheck,
}) async {
  // Tall enough that every action tile is built: the list is lazy.
  tester.view.physicalSize = const Size(1200, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final prog = programmer ?? FakeRadioProgrammer();
  final store = backups ?? FakeCodeplugBackupStore();
  final screen = RadioDeviceScreen(
    target: target,
    initialProfile: initialProfile,
    planId: planId,
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(_prefs),
        if (savedRadioStore != null)
          savedRadioStoreProvider.overrideWithValue(savedRadioStore(_prefs)),
        prefsSettingsStoreProvider.overrideWith(
          (ref) async => settings ?? InMemorySettingsStore(),
        ),
        // One fake behind both transports: which one a target reaches is the
        // provider's business, tested with it.
        radioProgrammerProvider.overrideWithValue(prog),
        serialRadioProgrammerProvider.overrideWithValue(prog),
        codeplugBackupStoreProvider.overrideWithValue(store),
        codeplugDecoderProvider.overrideWithValue(_FakeDecoder(decoded)),
        // The real check is native; one that is never expected to run
        // fails the test loudly rather than hanging it. A StateError, not
        // fail(): the screen catches Exceptions (an unreadable backup), and
        // fail()'s TestFailure is one, so it was swallowed and never failed.
        backupFirmwareCheckProvider.overrideWithValue(
          firmwareCheck ??
              (modelId, image) async =>
                  throw StateError('firmware of a $modelId backup was checked'),
        ),
      ],
      child: MaterialApp(
        home: behindLauncher
            ? Builder(
                builder: (context) => Scaffold(
                  body: Center(
                    child: TextButton(
                      onPressed: () => Navigator.of(
                        context,
                      ).push(MaterialPageRoute<void>(builder: (_) => screen)),
                      child: const Text('open'),
                    ),
                  ),
                ),
              )
            : screen,
      ),
    ),
  );
  await tester.pumpAndSettle();
  if (behindLauncher) {
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }
  final container = ProviderScope.containerOf(
    tester.element(find.byType(RadioDeviceScreen)),
  );
  return _Harness(prog, store, container);
}

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    _prefs = await SharedPreferences.getInstance();
  });

  group('what it shows', () {
    testWidgets('which radio, over what, and the model it opens on', (
      tester,
    ) async {
      await _pump(tester, initialProfile: uv5gMiniProfile);

      expect(find.text('Base radio'), findsWidgets);
      expect(find.textContaining('Bluetooth'), findsWidgets);
      expect(find.textContaining(_ble.id), findsOneWidget);
      expect(find.text(uv5gMiniProfile.displayName), findsOneWidget);
      // Honest about what it cannot know.
      expect(find.textContaining('It cannot be asked'), findsOneWidget);
    });

    testWidgets('a suggested model this link cannot program is passed over', (
      tester,
    ) async {
      // The UV-5R is a cable radio; over Bluetooth the screen falls back to
      // the Radio tab's radio, which by default is the UV-5R Mini.
      await _pump(tester, initialProfile: uv5rProfile);
      expect(find.text(uv5rMiniProfile.displayName), findsOneWidget);
      expect(find.text(uv5rProfile.displayName), findsNothing);
    });

    testWidgets('the model saved for this radio outranks a suggested one', (
      tester,
    ) async {
      // Callers suggest a guess from the advert name, or a plan's model.
      // Ranked above the user's own choice, a UV-32 reopened as a Mini
      // and a completed session saved the guess over the choice.
      await SavedRadioStore(_prefs).save(
        SavedRadio(
          transport: _ble.transport,
          id: _ble.id,
          name: _ble.name,
          lastSeen: DateTime(2026, 9, 1),
          radioProfileId: uv32Profile.id,
        ),
      );
      await _pump(tester, initialProfile: uv5gMiniProfile);

      expect(find.text(uv32Profile.displayName), findsOneWidget);
      expect(find.text(uv5gMiniProfile.displayName), findsNothing);
    });

    testWidgets('an unconfirmed model says so', (tester) async {
      await _pump(tester, initialProfile: uv32Profile);
      expect(find.text('Not yet confirmed on this model'), findsOneWidget);
    });

    testWidgets('a cable radio opens on a cable model, and says what the check '
        'will show', (tester) async {
      await _pump(
        tester,
        target: const RadioTarget(
          transport: RadioTransport.usb,
          id: '/dev/ttyUSB0',
          name: '',
        ),
      );
      // The Radio tab's Bluetooth radio is passed over for one a cable
      // programs.
      expect(find.text(uv5rProfile.displayName), findsOneWidget);
      expect(find.textContaining('firmware it reports'), findsOneWidget);
      expect(find.text('Check it answers'), findsOneWidget);
    });

    testWidgets('offers to make this the Radio tab\'s radio when it is not', (
      tester,
    ) async {
      final harness = await _pump(tester, initialProfile: uv5gMiniProfile);

      await tester.tap(find.text('Use for suggestions and new plans'));
      await tester.pumpAndSettle();

      final selected = harness.container.read(selectedRadioProfileProvider);
      expect(selected.valueOrNull, uv5gMiniProfile);
      expect(find.text('Use for suggestions and new plans'), findsNothing);
    });

    testWidgets('picking another model changes what the actions use', (
      tester,
    ) async {
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
    testWidgets('asks, reports no more than it learned, and saves the radio', (
      tester,
    ) async {
      final harness = await _pump(tester);

      await tester.tap(find.text('Check it answers'));
      await tester.pumpAndSettle();

      expect(harness.programmer.identifyCalls, 1);
      expect(harness.programmer.deviceIds, [_ble.id]);
      expect(
        find.textContaining('confirms the family rather than'),
        findsOneWidget,
      );
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

    testWidgets('a programmer that cannot drive the model is not asked', (
      tester,
    ) async {
      final harness = await _pump(
        tester,
        programmer: FakeRadioProgrammer(supported: false),
      );

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

    testWidgets('keeps the read as a backup and makes the plan', (
      tester,
    ) async {
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

    testWidgets('says so when the radio had gaps a plan cannot keep', (
      tester,
    ) async {
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

    testWidgets('reads and saves the radio first, then puts the copy back', (
      tester,
    ) async {
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

      expect(
        harness.programmer.readCalls,
        1,
        reason: 'what is on the radio now is read before it is replaced',
      );
      expect(
        harness.backups.saved,
        hasLength(1),
        reason: '...and saved, so the restore can itself be undone',
      );
      expect(harness.programmer.restored.single.image, chosen.image);
      expect(find.textContaining('restored'), findsOneWidget);
    });

    testWidgets('restores the backup the pre-restore save prunes', (
      tester,
    ) async {
      // With a full set on disk -- the model's oldest plus its newest ten --
      // saving the pre-restore read prunes the second-oldest, the first
      // past the newest ten that the real store keeps. When that is the one
      // being restored it has to be loaded first: the other order deletes
      // it and then fails to read it.
      final oldest = backup(0x01, DateTime(2026, 9, 1, 0, 0));
      final pruned = backup(0xAB, DateTime(2026, 9, 1, 1, 0));
      final harness = await _pump(
        tester,
        backups: FakeCodeplugBackupStore(
          prunes: true,
          existing: [
            oldest,
            pruned,
            for (var i = 2; i < 11; i++) backup(i, DateTime(2026, 9, 1, i)),
          ],
        ),
      );

      await tester.tap(find.text('Restore a backup'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('2026-09-01 01:00'),
        80,
        scrollable: find.byType(Scrollable).last,
      );
      await tester.tap(find.text('2026-09-01 01:00'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Restore'));
      await tester.pumpAndSettle();

      expect(harness.programmer.restored.single.image, pruned.image);
      expect(find.textContaining('restored'), findsOneWidget);
      final left = await harness.backups.list();
      expect(
        left.map((b) => b.takenAt),
        isNot(contains(pruned.readAt)),
        reason:
            'the save did prune the restored backup, so the order was '
            'what saved it',
      );
      expect(left.last.takenAt, oldest.readAt, reason: 'never the oldest');
    });

    testWidgets('cancelling the confirmation touches nothing', (tester) async {
      final harness = await _pump(
        tester,
        backups: FakeCodeplugBackupStore(
          existing: [backup(1, DateTime(2026, 9, 1, 9, 30))],
        ),
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

    testWidgets('a radio this link cannot write is refused before the read', (
      tester,
    ) async {
      // Old code asked no one: it confirmed, connected, read and backed the
      // radio up, and only the write itself then failed.
      final harness = await _pump(
        tester,
        programmer: _NoWriteProgrammer(),
        backups: FakeCodeplugBackupStore(
          existing: [backup(1, DateTime(2026, 9, 1, 9, 30))],
        ),
      );

      await tester.tap(find.text('Restore a backup'));
      await tester.pumpAndSettle();

      expect((harness.programmer as _NoWriteProgrammer).preflights, 1);
      expect(find.text('2026-09-01 09:30'), findsNothing);
      expect(find.text('Restore to Base radio?'), findsNothing);
      expect(find.textContaining('turned off'), findsWidgets);
      expect(harness.programmer.readCalls, 0);
      expect(harness.programmer.deviceIds, isEmpty);
      expect(harness.programmer.restored, isEmpty);
    });

    testWidgets('a second restore started while one runs is not sent', (
      tester,
    ) async {
      // Regression: _session had no re-entry guard, and _restore awaits the
      // backup list before its sheet opens, with every tile still enabled.
      // Two taps in that window stacked two sheets; answering both started
      // two sessions on one link, the first's teardown cutting the second
      // off mid-write.
      final programmer = _HeldReadProgrammer();
      final store = _SlowListStore(
        existing: [backup(1, DateTime(2026, 9, 1, 9, 30))],
      );
      final harness = await _pump(
        tester,
        programmer: programmer,
        backups: store,
      );

      await tester.tap(find.text('Restore a backup'));
      await tester.pump();
      await tester.tap(find.text('Restore a backup'));
      await tester.pump();
      store.listHold.complete();
      await tester.pumpAndSettle();

      // Two sheets, one over the other. Answer the top one...
      await tester.tap(find.text('2026-09-01 09:30').last);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Restore'));
      await tester.pump();
      expect(harness.programmer.readCalls, 0, reason: 'read is held open');
      // ...then, with that session running, the one beneath. (Its progress
      // bar never settles, so the routes are pumped a fixed time.)
      await tester.pump(const Duration(milliseconds: 500));
      await tester.tap(find.text('2026-09-01 09:30').last);
      await tester.pump(const Duration(milliseconds: 500));
      await tester.tap(find.widgetWithText(FilledButton, 'Restore'));
      await tester.pump(const Duration(milliseconds: 500));

      programmer.readHold.complete();
      await tester.pumpAndSettle();

      expect(harness.programmer.readCalls, 1);
      expect(harness.programmer.restored, hasLength(1));
      expect(harness.backups.saved, hasLength(1));
    });

    testWidgets('one cut off part way says the radio may be half written, '
        'and names the copy taken before it', (tester) async {
      final harness = await _pump(
        tester,
        programmer: _CutOffProgrammer(const RadioTimeoutException()),
        backups: FakeCodeplugBackupStore(
          existing: [backup(1, DateTime(2026, 9, 1, 9, 30))],
        ),
      );

      await tester.tap(find.text('Restore a backup'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('2026-09-01 09:30'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Restore'));
      await tester.pumpAndSettle();

      expect(harness.backups.saved, hasLength(1));
      // The fake store names its second backup (index 1) this way.
      expect(
        find.textContaining(
          'may now hold part of the write and part of what was there '
          'before. Try again, or put back uv-5r-mini_1.bin',
        ),
        findsWidgets,
      );
    });

    group('a UV-82HP backed up while it could only be read as a UV-5R', () {
      const cable = RadioTarget(
        transport: RadioTransport.usb,
        id: '/dev/ttyUSB0',
        name: 'Cable radio',
      );
      // Byte 0 stands in for the firmware string: 0x82 says N82-3, anything
      // else a UV-5R's. Only a UV-82HP may be programmed as one, and
      // nothing else as it, as uv5r::check_firmware decides.
      Future<bool> fits(String modelId, Uint8List image) async =>
          (image[0] == 0x82) == (modelId == uv82hpProfile.id);
      RadioCodeplug savedAsUv5r(int firmware) => RadioCodeplug(
        modelId: uv5rProfile.id,
        image: Uint8List(0x1808)..[0] = firmware,
        readAt: DateTime(2026, 9, 1, 9, 30),
      );

      // Regression: the list kept only backups filed under the chosen
      // model. Under the UV-82HP the HP's old 'uv5r' backups were hidden
      // ("No backups of a Baofeng UV-82HP"); under the UV-5R the model
      // check refused the radio before the pre-restore read.
      testWidgets('is offered, and restored, as the UV-82HP', (tester) async {
        final old = savedAsUv5r(0x82);
        final harness = await _pump(
          tester,
          target: cable,
          initialProfile: uv82hpProfile,
          backups: FakeCodeplugBackupStore(existing: [old]),
          firmwareCheck: fits,
        );

        await tester.tap(find.text('Restore a backup'));
        await tester.pumpAndSettle();
        expect(find.textContaining('saved as the Baofeng UV-5R'), findsOne);
        await tester.tap(find.text('2026-09-01 09:30'));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(FilledButton, 'Restore'));
        await tester.pumpAndSettle();

        expect(harness.programmer.restored.single.image, old.image);
        expect(
          harness.backups.saved.single.modelId,
          uv82hpProfile.id,
          reason: 'the safety copy is filed under the model it is',
        );
        expect(find.textContaining('restored'), findsOneWidget);
      });

      testWidgets('a UV-5R\'s own backup is not offered for a UV-82HP', (
        tester,
      ) async {
        await _pump(
          tester,
          target: cable,
          initialProfile: uv82hpProfile,
          backups: FakeCodeplugBackupStore(existing: [savedAsUv5r(0x5)]),
          firmwareCheck: fits,
        );

        await tester.tap(find.text('Restore a backup'));
        await tester.pumpAndSettle();

        expect(
          find.textContaining('No backups of a Baofeng UV-82HP'),
          findsOneWidget,
        );
      });
    });

    testWidgets('only offers backups of this model', (tester) async {
      await _pump(
        tester,
        backups: FakeCodeplugBackupStore(
          existing: [
            RadioCodeplug(
              modelId: uv32Profile.id,
              image: Uint8List(8),
              readAt: DateTime(2026, 9, 1),
            ),
          ],
        ),
      );

      await tester.tap(find.text('Restore a backup'));
      await tester.pumpAndSettle();

      expect(
        find.textContaining('No backups of a Baofeng UV-5R Mini'),
        findsOneWidget,
      );
    });
  });

  group('writing a plan', () {
    const channels = [
      RadioChannel(name: 'W1AW', rxFreqHz: 146940000, txFreqHz: 146340000),
      RadioChannel(name: 'SIMPLEX', rxFreqHz: 146520000, txFreqHz: 146520000),
    ];

    /// A saved plan, there before the screen opens.
    Future<void> seedPlan() async {
      final now = DateTime(2026, 9, 1);
      SharedPreferences.setMockInitialValues({
        'radio_channel_plans_v1': jsonEncode([
          ChannelPlan(
            id: 'plan-1',
            name: 'Local repeaters',
            radioProfileId: uv5rMiniProfile.id,
            channels: channels,
            createdAt: now,
            modifiedAt: now,
          ).toJson(),
        ]),
      });
      _prefs = await SharedPreferences.getInstance();
    }

    Future<void> pickAndConfirm(WidgetTester tester) async {
      await tester.tap(find.text('Write a channel plan'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Local repeaters'));
      await tester.pumpAndSettle();
      expect(find.text('Write to Base radio?'), findsOneWidget);
    }

    testWidgets('with no plans, says where plans come from', (tester) async {
      await _pump(tester);
      await tester.tap(find.text('Write a channel plan'));
      await tester.pumpAndSettle();
      expect(find.textContaining('No channel plans yet'), findsOneWidget);
    });

    testWidgets('asks first, and a cancel touches nothing', (tester) async {
      await seedPlan();
      final harness = await _pump(tester);
      await pickAndConfirm(tester);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(harness.programmer.readCalls, 0);
      expect(harness.programmer.written, isEmpty);
      expect(harness.backups.saved, isEmpty);
    });

    testWidgets('a radio this link cannot write is refused before the read', (
      tester,
    ) async {
      // Old code confirmed, connected, read and backed the radio up; only
      // the write then failed, with Rust's error text.
      await seedPlan();
      final harness = await _pump(tester, programmer: _NoWriteProgrammer());
      await tester.tap(find.text('Write a channel plan'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Local repeaters'));
      await tester.pumpAndSettle();

      expect(find.text('Write to Base radio?'), findsNothing);
      expect(find.textContaining('turned off'), findsWidgets);
      expect(harness.programmer.readCalls, 0);
      expect(harness.programmer.deviceIds, isEmpty);
      expect(harness.programmer.written, isEmpty);
      expect(harness.backups.saved, isEmpty);
    });

    testWidgets('reads and backs up before it writes, to this radio', (
      tester,
    ) async {
      await seedPlan();
      final harness = await _pump(tester);
      await pickAndConfirm(tester);
      await tester.tap(find.widgetWithText(FilledButton, 'Write'));
      await tester.pumpAndSettle();

      expect(harness.programmer.readCalls, 1);
      expect(harness.backups.saved, hasLength(1));
      expect(harness.programmer.written.single, channels);
      expect(harness.programmer.deviceIds.toSet(), {_ble.id});
      expect(
        find.textContaining('2 channels from "Local repeaters" written'),
        findsOneWidget,
      );
      expect(find.textContaining('is saved as'), findsOneWidget);
    });

    testWidgets('a radio list that cannot be saved does not undo the write', (
      tester,
    ) async {
      // The list save ran inside the session's try: a failure there, after
      // a verified write, showed "The radio did not finish." and dropped
      // the line naming the backup.
      await seedPlan();
      final harness = await _pump(
        tester,
        savedRadioStore: _FailingSavedRadioStore.new,
      );
      await pickAndConfirm(tester);
      await tester.tap(find.widgetWithText(FilledButton, 'Write'));
      await tester.pumpAndSettle();

      expect(harness.programmer.written.single, channels);
      expect(find.textContaining('is saved as'), findsOneWidget);
      expect(find.textContaining('did not finish'), findsNothing);
    });

    testWidgets('a channel this radio cannot tune is refused before a read', (
      tester,
    ) async {
      // 46.940 is 146.940 with a digit dropped. It used to be written as a
      // channel the radio cannot use; out of the encoder's range, it failed
      // only after the read and backup, as "The radio did not finish."
      final now = DateTime(2026, 9, 1);
      SharedPreferences.setMockInitialValues({
        'radio_channel_plans_v1': jsonEncode([
          ChannelPlan(
            id: 'typo',
            name: 'Typo',
            radioProfileId: uv5rMiniProfile.id,
            channels: const [
              RadioChannel(
                name: 'OK',
                rxFreqHz: 146520000,
                txFreqHz: 146520000,
              ),
              RadioChannel(
                name: 'W1AW',
                rxFreqHz: 46940000,
                txFreqHz: 46340000,
              ),
            ],
            createdAt: now,
            modifiedAt: now,
          ).toJson(),
        ]),
      });
      _prefs = await SharedPreferences.getInstance();
      final harness = await _pump(tester, planId: 'typo');

      await tester.tap(find.widgetWithText(FilledButton, 'Write'));
      await tester.pumpAndSettle();

      expect(find.text('Write to Base radio?'), findsNothing);
      expect(
        find.textContaining('Channel 2 of "Typo" (W1AW): Receive 46.940 MHz'),
        findsOneWidget,
      );
      expect(
        find.textContaining('Nothing was read or written'),
        findsOneWidget,
      );
      expect(harness.programmer.readCalls, 0);
      expect(harness.backups.saved, isEmpty);
    });

    testWidgets('a failed read writes nothing, and says so', (tester) async {
      await seedPlan();
      final harness = await _pump(
        tester,
        programmer: FakeRadioProgrammer(
          error: const RadioTimeoutException('The radio stopped answering.'),
        ),
      );
      await pickAndConfirm(tester);
      await tester.tap(find.widgetWithText(FilledButton, 'Write'));
      await tester.pumpAndSettle();

      expect(harness.programmer.written, isEmpty);
      expect(harness.backups.saved, isEmpty);
      expect(find.textContaining('stopped answering'), findsWidgets);
    });

    testWidgets('cut off part way, says so and names the backup', (
      tester,
    ) async {
      // Regression: a link lost mid-write showed only "The radio stopped
      // responding… try again", with nothing about the mixed old and new
      // memory it may have left, or the copy saved seconds before.
      await seedPlan();
      final harness = await _pump(
        tester,
        programmer: _CutOffProgrammer(const RadioTimeoutException()),
      );
      await pickAndConfirm(tester);
      await tester.tap(find.widgetWithText(FilledButton, 'Write'));
      await tester.pumpAndSettle();

      expect(harness.backups.saved, hasLength(1));
      final error = tester
          .widgetList<Text>(find.textContaining('stopped responding'))
          .first
          .data!;
      expect(error, contains('may now hold part of the write'));
      expect(error, contains('uv-5r-mini_0.bin'));
      expect(error, contains('"Restore a backup"'));
    });

    testWidgets('a refused block names the backup without repeating the '
        'warning its own text gives', (tester) async {
      await seedPlan();
      await _pump(
        tester,
        programmer: _CutOffProgrammer(
          const RadioProtocolException('Partly written; restore your backup.'),
        ),
      );
      await pickAndConfirm(tester);
      await tester.tap(find.widgetWithText(FilledButton, 'Write'));
      await tester.pumpAndSettle();

      expect(
        find.textContaining(
          'The copy taken just before the write is uv-5r-mini_0.bin',
        ),
        findsWidgets,
      );
      expect(find.textContaining('may now hold part'), findsNothing);
    });

    // Regression: the Bluetooth programmer's mid-write timeout already said
    // the radio may be partly written and to restore the backup, and the
    // screen appended its own copy of that warning — the user read it twice.
    // Each transport's programmer now throws RadioTimeoutException.midWrite
    // (tested with each programmer); the screen adds only the backup's name.
    for (final (target, profile, backupName) in [
      (_ble, uv5rMiniProfile, '${uv5rMiniProfile.id}_0.bin'),
      (
        const RadioTarget(
          transport: RadioTransport.usb,
          id: '/dev/ttyUSB0',
          name: 'Cable radio',
        ),
        uv5rProfile,
        '${uv5rProfile.id}_0.bin',
      ),
    ]) {
      testWidgets('a ${target.transport.name} radio lost mid-write gives the '
          'warning once, and names the backup', (tester) async {
        final now = DateTime(2026, 9, 1);
        SharedPreferences.setMockInitialValues({
          'radio_channel_plans_v1': jsonEncode([
            ChannelPlan(
              id: 'plan-1',
              name: 'Local repeaters',
              radioProfileId: profile.id,
              channels: channels,
              createdAt: now,
              modifiedAt: now,
            ).toJson(),
          ]),
        });
        _prefs = await SharedPreferences.getInstance();
        final harness = await _pump(
          tester,
          target: target,
          initialProfile: profile,
          planId: 'plan-1',
          programmer: _CutOffProgrammer(RadioTimeoutException.midWrite(0x1000)),
        );
        await tester.tap(find.widgetWithText(FilledButton, 'Write'));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(FilledButton, 'Write').last);
        await tester.pumpAndSettle();

        expect(harness.backups.saved, hasLength(1));
        final error = tester
            .widgetList<Text>(find.textContaining('stopped responding'))
            .first
            .data!;
        expect(error, contains('while writing 0x1000'));
        expect('may now hold'.allMatches(error), hasLength(1), reason: error);
        expect('partly written'.allMatches(error), hasLength(1));
        expect(find.textContaining('part of the write'), findsNothing);
        expect(find.textContaining('Try again'), findsNothing);
        expect(
          error,
          contains('The copy taken just before the write is $backupName'),
        );
        expect(error, contains('"Restore a backup"'));
      });
    }

    testWidgets('a failed read adds nothing about a partial write', (
      tester,
    ) async {
      await seedPlan();
      await _pump(
        tester,
        programmer: FakeRadioProgrammer(error: const RadioTimeoutException()),
      );
      await pickAndConfirm(tester);
      await tester.tap(find.widgetWithText(FilledButton, 'Write'));
      await tester.pumpAndSettle();

      expect(find.textContaining('stopped responding'), findsWidgets);
      expect(find.textContaining('part of the write'), findsNothing);
    });

    group('a plan too big for the radio', () {
      // A UV-5R Mini plan (999 slots) on a cable UV-5R (128). It used to be
      // read and backed up, and only then refused by the encoder as "The
      // radio did not finish."
      const cable = RadioTarget(
        transport: RadioTransport.usb,
        id: '/dev/ttyUSB0',
        name: 'UV-5R',
      );

      Future<void> seedBigPlan() async {
        final now = DateTime(2026, 9, 1);
        SharedPreferences.setMockInitialValues({
          'radio_channel_plans_v1': jsonEncode([
            ChannelPlan(
              id: 'big',
              name: 'Everything',
              radioProfileId: uv5rMiniProfile.id,
              channels: [
                for (var i = 0; i < 129; i++)
                  RadioChannel(
                    name: 'CH$i',
                    rxFreqHz: 146000000 + i * 12500,
                    txFreqHz: 146000000 + i * 12500,
                  ),
              ],
              createdAt: now,
              modifiedAt: now,
            ).toJson(),
          ]),
        });
        _prefs = await SharedPreferences.getInstance();
      }

      testWidgets('is refused before anything is read, naming both counts', (
        tester,
      ) async {
        await seedBigPlan();
        final harness = await _pump(
          tester,
          target: cable,
          initialProfile: uv5rProfile,
          planId: 'big',
        );
        expect(find.text(uv5rProfile.displayName), findsOneWidget);

        await tester.tap(find.widgetWithText(FilledButton, 'Write'));
        await tester.pumpAndSettle();

        expect(find.text('Write to UV-5R?'), findsNothing);
        expect(
          find.textContaining(
            '"Everything" has 129 channels; a ${uv5rProfile.displayName} '
            'holds 128',
          ),
          findsOneWidget,
        );
        expect(harness.programmer.readCalls, 0);
        expect(harness.backups.saved, isEmpty);
        expect(harness.programmer.written, isEmpty);
      });

      testWidgets('is shown but cannot be picked from the list', (
        tester,
      ) async {
        await seedBigPlan();
        final harness = await _pump(
          tester,
          target: cable,
          initialProfile: uv5rProfile,
        );
        await tester.tap(find.text('Write a channel plan'));
        await tester.pumpAndSettle();

        expect(
          find.textContaining('129 channels · this radio holds 128'),
          findsOneWidget,
        );
        await tester.tap(find.text('Everything'));
        await tester.pumpAndSettle();
        expect(find.text('Write to UV-5R?'), findsNothing);
        expect(harness.programmer.readCalls, 0);
      });
    });

    testWidgets('opened to take a plan, offers it first', (tester) async {
      await seedPlan();
      final harness = await _pump(tester, planId: 'plan-1');
      expect(find.text('Write "Local repeaters"'), findsOneWidget);

      await tester.tap(find.widgetWithText(FilledButton, 'Write'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Write').last);
      await tester.pumpAndSettle();

      expect(harness.programmer.written.single, channels);
    });

    testWidgets('a plan that has gone is simply not offered', (tester) async {
      await _pump(tester, planId: 'plan-deleted');
      expect(find.textContaining('Write "'), findsNothing);
      expect(find.text('Write a channel plan'), findsOneWidget);
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
    // Asked first, as every other forget in the app is.
    expect(find.text('Forget Base radio?'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Forget'));
    await tester.pumpAndSettle();

    expect(harness.container.read(savedRadiosProvider), isEmpty);
    expect(find.byType(RadioDeviceScreen), findsNothing);
    expect(find.textContaining('Removed Base radio'), findsOneWidget);
  });

  testWidgets('a cancelled forget keeps the radio and the screen', (
    tester,
  ) async {
    final harness = await _pump(tester, behindLauncher: true);
    await harness.container
        .read(savedRadiosProvider.notifier)
        .touch(target: _ble, seenAt: DateTime(2026, 9, 1));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Forget this radio'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();

    expect(harness.container.read(savedRadiosProvider), hasLength(1));
    expect(find.byType(RadioDeviceScreen), findsOneWidget);
    expect(find.textContaining('Removed'), findsNothing);
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
      find.textContaining('confirms the family rather than'),
      findsOneWidget,
    );
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
      'is unconfirmed',
      (tester) async {
        await _pump(tester, target: cable);
        expect(find.text('Widen its transmit limits'), findsOneWidget);
        expect(
          find.textContaining('To VHF 130–179 MHz and UHF 400–520 MHz'),
          findsOneWidget,
        );
        expect(
          find.textContaining('Not yet confirmed on a real radio'),
          findsOneWidget,
        );
        expect(
          find.text('Put back its original transmit limits'),
          findsNothing,
          reason: 'nothing has been kept to put back',
        );
      },
    );

    testWidgets('a radio with none to set offers nothing', (tester) async {
      await _pump(tester);
      expect(find.text('Widen its transmit limits'), findsNothing);
    });

    testWidgets('widening asks first, and a cancel touches nothing', (
      tester,
    ) async {
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
      'the wider suggestions on',
      (tester) async {
        final harness = await _pump(tester, target: cable);
        await tester.tap(find.text('Widen its transmit limits'));
        await tester.pumpAndSettle();
        await acknowledge(tester);

        expect(harness.backups.saved, hasLength(1));
        expect(harness.programmer.writtenLimits, [widened]);
        expect(harness.programmer.deviceIds.toSet(), {cable.id});
        expect(
          find.textContaining('Widened to VHF 130–179 MHz'),
          findsOneWidget,
        );
        expect(find.textContaining('It had VHF 136–174 MHz'), findsOneWidget);

        final kept = await harness.container
            .read(originalBandLimitsProvider.future)
            .then((all) => all[uv5rProfile.id]);
        expect(kept!.limits, stockBandLimits);
        final unlocks = await harness.container.read(txUnlockProvider.future);
        expect(unlocks[uv5rProfile.id], isTrue);
        // And the way back is on offer.
        expect(
          find.text('Put back its original transmit limits'),
          findsOneWidget,
        );
      },
    );

    testWidgets('a radio already that wide is left as it is', (tester) async {
      final programmer = FakeRadioProgrammer()..bandLimits = widened;
      final harness = await _pump(
        tester,
        target: cable,
        programmer: programmer,
      );
      await tester.tap(find.text('Widen its transmit limits'));
      await tester.pumpAndSettle();
      await acknowledge(tester);

      expect(programmer.writtenLimits, isEmpty);
      expect(find.textContaining('already VHF 130–179 MHz'), findsOneWidget);
      expect(
        await harness.container.read(originalBandLimitsProvider.future),
        isEmpty,
        reason: 'widened limits are not the ones to go back to',
      );
    });

    testWidgets(
      'a write that fails says so, and still keeps what the radio had',
      (tester) async {
        final programmer = FakeRadioProgrammer()
          ..limitWriteError = const RadioProtocolException(
            'The radio does not hold what was written at 0x1fc0. Restore '
            'your backup before using it.',
          );
        final harness = await _pump(
          tester,
          target: cable,
          programmer: programmer,
        );
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
        expect(
          unlocks[uv5rProfile.id],
          isNot(isTrue),
          reason: 'suggestions stay narrow until the radio is widened',
        );
      },
    );

    testWidgets(
      'putting them back asks, backs up, writes what was kept, and turns '
      'the wider suggestions off',
      (tester) async {
        final programmer = FakeRadioProgrammer()..bandLimits = widened;
        final harness = await _pump(
          tester,
          target: cable,
          programmer: programmer,
          settings: kept(stockBandLimits),
        );
        expect(
          find.textContaining('VHF 136–174 MHz and UHF 400–520 MHz: what'),
          findsOneWidget,
        );

        await tester.tap(find.text('Put back its original transmit limits'));
        await tester.pumpAndSettle();
        expect(find.text('Put back its transmit limits?'), findsOneWidget);
        await tester.tap(find.widgetWithText(FilledButton, 'Put back'));
        await tester.pumpAndSettle();

        expect(harness.backups.saved, hasLength(1));
        expect(programmer.writtenLimits, [stockBandLimits]);
        expect(
          find.textContaining('Put back to VHF 136–174 MHz'),
          findsOneWidget,
        );
        final unlocks = await harness.container.read(txUnlockProvider.future);
        expect(unlocks[uv5rProfile.id], isFalse);
      },
    );

    testWidgets('a cancelled put-back touches nothing', (tester) async {
      final harness = await _pump(
        tester,
        target: cable,
        settings: kept(stockBandLimits),
      );
      await tester.tap(find.text('Put back its original transmit limits'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(harness.programmer.readCalls, 0);
      expect(harness.programmer.writtenLimits, isEmpty);
    });

    // Regression: a UV-82HP shown the record kept under 'uv5r' called it
    // "what a Baofeng UV-82HP held", though it may be a real UV-5R's.
    testWidgets('a UV-82HP says whose record it borrows from the UV-5R', (
      tester,
    ) async {
      await _pump(
        tester,
        target: cable,
        initialProfile: uv82hpProfile,
        settings: kept(stockBandLimits),
      );
      expect(
        find.textContaining('what a radio widened as the Baofeng UV-5R'),
        findsOneWidget,
      );
      expect(
        find.textContaining('before the Baofeng UV-82HP was a model'),
        findsOneWidget,
      );
      expect(find.textContaining('what a Baofeng UV-82HP held'), findsNothing);

      await tester.tap(find.text('Put back its original transmit limits'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('what a radio widened as the Baofeng UV-5R'),
        findsNWidgets(2),
        reason: 'the confirmation says whose limits they are too',
      );
    });

    testWidgets('a UV-82HP with its own record names itself', (tester) async {
      await _pump(
        tester,
        target: cable,
        initialProfile: uv82hpProfile,
        settings: InMemorySettingsStore({
          OriginalBandLimitsNotifier.key: jsonEncode({
            uv5rProfile.id: OriginalBandLimits(
              limits: widened,
              readAt: DateTime(2026, 9, 20, 14, 2),
            ).toJson(),
            uv82hpProfile.id: OriginalBandLimits(
              limits: stockBandLimits,
              readAt: DateTime(2026, 9, 21, 8, 0),
            ).toJson(),
          }),
        }),
      );
      expect(
        find.textContaining(
          'VHF 136–174 MHz and UHF 400–520 MHz: what a Baofeng UV-82HP held',
        ),
        findsOneWidget,
      );
      expect(find.textContaining('widened as the'), findsNothing);

      await tester.tap(find.text('Put back its original transmit limits'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('what a Baofeng UV-82HP held'),
        findsNWidgets(2),
        reason: 'the confirmation names the model too',
      );
    });

    // Regression: whose a record was got worked out again after lookup
    // picked it, re-walking the ids by identity, and fell through to the
    // profile's own name on a miss. The matched id decides it now.
    test('only a record under the profile\'s own id is called its own', () {
      expect(
        whoseOriginalLimits(uv82hpProfile.id, uv82hpProfile),
        startsWith('what a Baofeng UV-82HP held'),
      );
      final borrowed = whoseOriginalLimits(uv5rProfile.id, uv82hpProfile);
      expect(borrowed, startsWith('what a radio widened as the Baofeng UV-5R'));
      expect(borrowed, isNot(contains('what a Baofeng UV-82HP held')));
      expect(
        whoseOriginalLimits('gone-model', uv82hpProfile),
        startsWith('what a radio widened as the gone-model'),
      );
    });
  });
}
