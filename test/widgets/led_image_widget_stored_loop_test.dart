// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// The stored-animation loop's housekeeping: the notify subscription it holds
// (R-114), the replay-strip entries it invalidates (R-115), the in-app cycle
// timer that must stop when something else takes the panel (R-116), and the
// busy flag that keeps other link operations off the characteristics while a
// replay/pin re-uploads frames (R-117).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/providers/ble_provider.dart';
import 'package:liberated_bread_mobile/providers/saved_device_provider.dart'
    show sharedPreferencesProvider;
import 'package:liberated_bread_mobile/providers/spec_codec_provider.dart';
import 'package:liberated_bread_mobile/services/spec_codec.dart';
import 'package:liberated_bread_mobile/widgets/led_image_widget.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../fakes/fake_ble_service.dart';
import '../fakes/fake_spec_codec.dart';

const _spec = ImageUploadDto(
  handler: 'daniao_ddp',
  encodable: true,
  format: 'rgb888',
  maxWidth: 4,
  maxHeight: 4,
  resolutionDeviceReported: false,
  animation: true,
);

const _stored = StoredUploadDto(containerFormat: 'daniao_amx', encodable: true);

late SharedPreferences _prefs;

Widget _wrap(
  Widget child, {
  required FakeBleService ble,
  required FakeSpecCodec codec,
}) => ProviderScope(
  overrides: [
    bleServiceProvider.overrideWithValue(ble),
    specCodecProvider.overrideWithValue(codec),
    sharedPreferencesProvider.overrideWithValue(_prefs),
  ],
  child: MaterialApp(
    home: Scaffold(
      body: SingleChildScrollView(child: SizedBox(width: 300, child: child)),
    ),
  ),
);

Widget _editor({
  required FakeBleService ble,
  required FakeSpecCodec codec,
  ImageUploadDto spec = _spec,
  String yaml = 'yaml',
}) => _wrap(
  LedImageWidget(
    key: const ValueKey('led-image-editor'),
    deviceId: 'AA:BB',
    imageUpload: spec,
    storedUpload: _stored,
    specYaml: yaml,
  ),
  ble: ble,
  codec: codec,
);

Future<void> _scrollAndTap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pump();
  await tester.tap(finder);
}

/// Bounded settle: the in-app loop cycle is a periodic timer, so the tests
/// below never use pumpAndSettle after an animation has been stored.
Future<void> _pumpFor(WidgetTester tester, Duration d) async {
  await tester.pump();
  await tester.pump(d);
  await tester.pump();
}

/// Animation mode with two frames on the canvas.
Future<void> _twoFrames(WidgetTester tester) async {
  await _scrollAndTap(tester, find.text('Animation'));
  await tester.pump();
  await _scrollAndTap(tester, find.byTooltip('Add frame'));
  await tester.pump();
}

/// Open the save dialog, optionally name the design and pick a kind, and
/// press Save. Returns with the save just started (one pump).
Future<void> _startSave(
  WidgetTester tester, {
  String? name,
  String? kind,
}) async {
  await _scrollAndTap(tester, find.text('Save to device'));
  await _pumpFor(tester, const Duration(milliseconds: 300));
  if (kind != null) {
    await tester.tap(find.text(kind));
    await tester.pump();
  }
  if (name != null) {
    await tester.enterText(find.byKey(const Key('stored-name-field')), name);
  }
  await tester.tap(find.widgetWithText(FilledButton, 'Save'));
  await tester.pump();
}

/// Walk an in-flight two-frame animation upload through the notify path:
/// the 3 s diy-clear window (plus any remove_app pacing), one commit
/// verdict per frame, then the 3 s effect-list read. Ends with the loop
/// started and the in-app cycle ticking.
Future<void> _driveTwoFrameUpload(
  WidgetTester tester,
  StreamController<List<int>> notify,
) async {
  await _pumpFor(tester, const Duration(seconds: 3));
  await _pumpFor(tester, const Duration(seconds: 1)); // remove_app pacing
  for (var i = 0; i < 2; i++) {
    notify.add(const [1]);
    await tester.pump();
    await tester.pump();
  }
  await _pumpFor(tester, const Duration(seconds: 3));
}

int _playEffectCount(FakeSpecCodec codec) =>
    codec.encodeCalls.where((c) => c.commandName == 'play_effect').length;

/// A codec whose frame encode can be made to fail AFTER a save succeeded —
/// the fake's own `encodeStoredError` is fixed at construction.
class _LaterFailingCodec extends FakeSpecCodec {
  Object? failStoredImageWith;

  @override
  Future<StoredUploadPlanDto> encodeStoredImage({
    required String specYaml,
    int? maxWrite,
    required int width,
    required int height,
    required List<int> rgb,
    required String name,
    required int cid,
    required int timeSecs,
    required String scroll,
    required int speed,
    required int sequence,
  }) async {
    if (failStoredImageWith != null) throw failStoredImageWith!;
    return super.encodeStoredImage(
      specYaml: specYaml,
      maxWrite: maxWrite,
      width: width,
      height: height,
      rgb: rgb,
      name: name,
      cid: cid,
      timeSecs: timeSecs,
      scroll: scroll,
      speed: speed,
      sequence: sequence,
    );
  }
}

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    _prefs = await SharedPreferences.getInstance();
  });

  group('R-114: the loop upload releases its notify subscription', () {
    testWidgets('after an animation save nothing is left subscribed', (
      tester,
    ) async {
      final notify = StreamController<List<int>>.broadcast();
      addTearDown(notify.close);
      final ble = FakeBleService(notifyStream: notify.stream);
      final codec = FakeSpecCodec()..storedResponseChar = 'notify';
      await tester.pumpWidget(_editor(ble: ble, codec: codec));

      await _twoFrames(tester);
      await _startSave(tester);
      await _driveTwoFrameUpload(tester, notify);
      expect(find.textContaining('cycling 2 frames'), findsOneWidget);

      // The save subscribed exactly once and cancelled that subscription.
      // Before the fix the asBroadcastStream wrapper kept the BLE stream
      // open after its last listener left, so the interest was never
      // released and the count stayed at 1 per save.
      expect(ble.subscriptions.where((c) => c == 'notify'), hasLength(1));
      expect(
        ble.liveSubscriberCount['notify'],
        0,
        reason: 'the CCCD interest must be released once the loop is up',
      );
      expect(ble.cancelledSubscriptions, contains('notify'));

      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('a replay does not accumulate a second one', (tester) async {
      final notify = StreamController<List<int>>.broadcast();
      addTearDown(notify.close);
      final ble = FakeBleService(notifyStream: notify.stream);
      final codec = FakeSpecCodec()..storedResponseChar = 'notify';
      await tester.pumpWidget(_editor(ble: ble, codec: codec));

      await _twoFrames(tester);
      await _startSave(tester);
      await _driveTwoFrameUpload(tester, notify);
      final baseCid = codec.encodeStoredCalls.first.cid;
      // Let the save's snackbar expire so the replay's is the visible one.
      await _pumpFor(tester, const Duration(seconds: 5));

      await _scrollAndTap(tester, find.byKey(Key('saved-design-$baseCid')));
      await _driveTwoFrameUpload(tester, notify);
      expect(find.textContaining('Playing'), findsOneWidget);

      expect(ble.subscriptions.where((c) => c == 'notify'), hasLength(2));
      expect(
        ble.cancelledSubscriptions.where((c) => c == 'notify'),
        hasLength(2),
        reason: 'every subscription the loop path opens is closed again',
      );
      expect(ble.liveSubscriberCount['notify'], 0);

      await tester.pumpWidget(const SizedBox.shrink());
    });
  });

  group('R-115: a stored animation wipes the other designs', () {
    testWidgets('the picture entries it removed leave the replay strip', (
      tester,
    ) async {
      final notify = StreamController<List<int>>.broadcast();
      addTearDown(notify.close);
      final ble = FakeBleService(notifyStream: notify.stream);
      final codec = FakeSpecCodec()..storedResponseChar = 'notify';
      await tester.pumpWidget(_editor(ble: ble, codec: codec));

      // Store a picture first.
      await _startSave(tester, name: 'Logo');
      await _pumpFor(tester, const Duration(milliseconds: 50));
      notify.add(const [1]); // the commit verdict
      await _pumpFor(tester, const Duration(milliseconds: 50));
      await _pumpFor(tester, const Duration(seconds: 3)); // list diagnostic
      expect(find.widgetWithText(ActionChip, 'Logo'), findsOneWidget);
      final logoCid = codec.encodeStoredCalls.single.cid;

      // The device now lists that picture as a user (diy) effect.
      codec.effectListEntries = [
        EffectEntryDto(cid: logoCid, slot: 1, type: 3, diy: 1),
      ];

      // Store an animation: the dialog says what it is about to do...
      await _twoFrames(tester);
      await _scrollAndTap(tester, find.text('Save to device'));
      await _pumpFor(tester, const Duration(milliseconds: 300));
      expect(find.byKey(const Key('stored-animation-note')), findsOneWidget);
      expect(
        find.textContaining('clears the device\'s other saved designs'),
        findsOneWidget,
      );
      await tester.enterText(
        find.byKey(const Key('stored-name-field')),
        'Loop',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pump();
      // ...and the effect-list reply during the clear window names Logo.
      notify.add(const [2]);
      await tester.pump();
      await _driveTwoFrameUpload(tester, notify);
      expect(find.textContaining('cycling 2 frames'), findsOneWidget);

      // Logo was removed from the device to scope the loop, so its entry —
      // which carries no pixels to put it back — must be gone from the
      // strip rather than left to "play" a cid the device no longer has.
      expect(codec.encodeRemoveAppCalls, [logoCid]);
      expect(find.widgetWithText(ActionChip, 'Logo'), findsNothing);
      expect(find.widgetWithText(ActionChip, 'Loop'), findsOneWidget);
      // The animation's own chips carry the same warning.
      final chip = tester.widget<ActionChip>(
        find.widgetWithText(ActionChip, 'Loop'),
      );
      expect(chip.tooltip, contains('clears the device\'s other saved'));

      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('an animation whose pixels were kept survives the wipe', (
      tester,
    ) async {
      // Its frames are wiped too, but replay RE-UPLOADS them, so the entry
      // stays truthful and must stay listed.
      final notify = StreamController<List<int>>.broadcast();
      addTearDown(notify.close);
      final ble = FakeBleService(notifyStream: notify.stream);
      final codec = FakeSpecCodec()..storedResponseChar = 'notify';
      await tester.pumpWidget(_editor(ble: ble, codec: codec));

      await _twoFrames(tester);
      await _startSave(tester, name: 'First');
      await _driveTwoFrameUpload(tester, notify);
      final firstCids = [for (final c in codec.encodeStoredCalls) c.cid];
      expect(firstCids, hasLength(2));
      codec.effectListEntries = [
        for (final cid in firstCids)
          EffectEntryDto(cid: cid, slot: 1, type: 3, diy: 1),
      ];

      // Different content, so a different design: paint a pixel.
      final grid = find.byKey(const Key('led-image-grid'));
      await tester.ensureVisible(grid);
      await tester.pump();
      await tester.tapAt(tester.getTopLeft(grid) + const Offset(4, 4));
      await tester.pump();
      await _startSave(tester, name: 'Second');
      notify.add(const [2]);
      await tester.pump();
      await _driveTwoFrameUpload(tester, notify);

      expect(
        codec.encodeRemoveAppCalls,
        containsAll(firstCids),
        reason: 'the first loop\'s frames were cleared off the device',
      );
      expect(find.widgetWithText(ActionChip, 'First'), findsOneWidget);
      expect(find.widgetWithText(ActionChip, 'Second'), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
    });
  });

  group('R-116: the in-app loop cycle stops when something else plays', () {
    testWidgets('saving a picture over a running loop stops the ticks', (
      tester,
    ) async {
      final codec = FakeSpecCodec();
      final ble = FakeBleService();
      await tester.pumpWidget(_editor(ble: ble, codec: codec));

      await _twoFrames(tester);
      await _startSave(tester);
      await _pumpFor(tester, const Duration(seconds: 2));
      expect(_playEffectCount(codec), greaterThan(0), reason: 'cycling');

      // Now store the current frame as a picture: one more stored encode,
      // and the fixed-autorun pin only a single design gets.
      await _startSave(tester, kind: 'Picture');
      await _pumpFor(tester, const Duration(milliseconds: 300));
      expect(codec.encodeStoredCalls, hasLength(3));
      expect(codec.encodeAutorunModeCalls, [0]);

      // Nothing may follow the picture's play: a `play_effect` tick would
      // swap the panel back to a loop frame under the "now playing" toast.
      final ticks = _playEffectCount(codec);
      final writes = ble.writes.length;
      await _pumpFor(tester, const Duration(seconds: 2));
      expect(_playEffectCount(codec), ticks);
      expect(ble.writes.length, writes);

      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('clearing the device designs stops the ticks', (tester) async {
      final codec = FakeSpecCodec();
      final ble = FakeBleService();
      await tester.pumpWidget(_editor(ble: ble, codec: codec));

      await _twoFrames(tester);
      await _startSave(tester);
      await _pumpFor(tester, const Duration(seconds: 2));
      expect(_playEffectCount(codec), greaterThan(0));

      await _scrollAndTap(
        tester,
        find.byKey(const Key('clear-device-designs')),
      );
      await _pumpFor(tester, const Duration(milliseconds: 300));
      await tester.tap(find.widgetWithText(FilledButton, 'Clear'));
      await _pumpFor(tester, const Duration(milliseconds: 300));
      expect(find.byType(ActionChip), findsNothing);

      // The cids the cycle addressed no longer exist; no more play_effect.
      final ticks = _playEffectCount(codec);
      final writes = ble.writes.length;
      await _pumpFor(tester, const Duration(seconds: 2));
      expect(_playEffectCount(codec), ticks);
      expect(ble.writes.length, writes);

      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('a spec swapped underneath stops the ticks', (tester) async {
      const other = ImageUploadDto(
        handler: 'daniao_ddp',
        encodable: true,
        format: 'rgb888',
        maxWidth: 8,
        maxHeight: 2,
        resolutionDeviceReported: false,
        animation: true,
      );
      final codec = FakeSpecCodec();
      final ble = FakeBleService();
      await tester.pumpWidget(_editor(ble: ble, codec: codec));

      await _twoFrames(tester);
      await _startSave(tester);
      await _pumpFor(tester, const Duration(seconds: 2));
      expect(_playEffectCount(codec), greaterThan(0));

      await tester.pumpWidget(
        _editor(ble: ble, codec: codec, spec: other, yaml: 'yaml-b'),
      );
      await tester.pump();

      // The loop was set up under the old spec; its cids and slots mean
      // nothing encoded through the new one.
      final ticks = _playEffectCount(codec);
      await _pumpFor(tester, const Duration(seconds: 2));
      expect(_playEffectCount(codec), ticks);

      await tester.pumpWidget(const SizedBox.shrink());
    });
  });

  group('R-117: replay and pin of an animation are busy operations', () {
    Future<void> saveLoop(
      WidgetTester tester,
      StreamController<List<int>> notify,
    ) async {
      await _twoFrames(tester);
      await _startSave(tester);
      await _driveTwoFrameUpload(tester, notify);
      expect(find.textContaining('cycling 2 frames'), findsOneWidget);
      // Let that snackbar go so the replay's is the one asserted on.
      await _pumpFor(tester, const Duration(seconds: 5));
    }

    void expectBusy(WidgetTester tester) {
      // Every control that shares the link is gated on _saving: the Save
      // button shows its progress label, Stream/Send and the chips are
      // disabled. Before the fix all of them stayed live for the many
      // seconds the frames took to re-upload.
      expect(find.text('Saving…'), findsOneWidget);
      expect(find.text('Save to device'), findsNothing);
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Stream to device'),
            )
            .onPressed,
        isNull,
      );
      for (final chip in tester.widgetList<ActionChip>(
        find.byType(ActionChip),
      )) {
        expect(chip.onPressed, isNull);
      }
      expect(
        tester
            .widget<IconButton>(find.byKey(const Key('clear-device-designs')))
            .onPressed,
        isNull,
      );
    }

    testWidgets('replaying a stored animation disables the editor until '
        'its frames are back on the device', (tester) async {
      final notify = StreamController<List<int>>.broadcast();
      addTearDown(notify.close);
      final ble = FakeBleService(notifyStream: notify.stream);
      final codec = FakeSpecCodec()..storedResponseChar = 'notify';
      await tester.pumpWidget(_editor(ble: ble, codec: codec));
      await saveLoop(tester, notify);
      final baseCid = codec.encodeStoredCalls.first.cid;

      await _scrollAndTap(tester, find.byKey(Key('saved-design-$baseCid')));
      await _pumpFor(tester, const Duration(seconds: 1)); // mid diy-clear
      expectBusy(tester);

      await _driveTwoFrameUpload(tester, notify);
      expect(find.textContaining('Playing'), findsOneWidget);
      expect(find.text('Save to device'), findsOneWidget);
      expect(find.text('Saving…'), findsNothing);
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Stream to device'),
            )
            .onPressed,
        isNotNull,
      );

      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('pinning a stored animation as default does the same', (
      tester,
    ) async {
      final notify = StreamController<List<int>>.broadcast();
      addTearDown(notify.close);
      final ble = FakeBleService(notifyStream: notify.stream);
      final codec = FakeSpecCodec()..storedResponseChar = 'notify';
      await tester.pumpWidget(_editor(ble: ble, codec: codec));
      await saveLoop(tester, notify);
      final baseCid = codec.encodeStoredCalls.first.cid;

      await _scrollAndTap(tester, find.byKey(Key('saved-default-$baseCid')));
      await _pumpFor(tester, const Duration(seconds: 1));
      expectBusy(tester);

      await _driveTwoFrameUpload(tester, notify);
      expect(find.textContaining('as the device default'), findsOneWidget);
      expect(find.text('Save to device'), findsOneWidget);
      expect(codec.encodeAutorunModeCalls, contains(1));

      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('a failed replay still hands the editor back', (tester) async {
      final notify = StreamController<List<int>>.broadcast();
      addTearDown(notify.close);
      final ble = FakeBleService(notifyStream: notify.stream);
      final codec = _LaterFailingCodec()..storedResponseChar = 'notify';
      await tester.pumpWidget(_editor(ble: ble, codec: codec));
      await saveLoop(tester, notify);
      final baseCid = codec.encodeStoredCalls.first.cid;

      // The re-upload's first encode throws.
      codec.failStoredImageWith = StateError('link dropped');
      await _scrollAndTap(tester, find.byKey(Key('saved-design-$baseCid')));
      await _pumpFor(tester, const Duration(milliseconds: 300));

      expect(find.textContaining('Could not replay'), findsOneWidget);
      expect(find.text('Save to device'), findsOneWidget);
      expect(find.text('Saving…'), findsNothing);

      await tester.pumpWidget(const SizedBox.shrink());
    });
  });
}
