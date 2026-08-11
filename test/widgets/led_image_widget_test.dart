// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/providers/ble_provider.dart';
import 'package:liberated_bread_mobile/providers/spec_codec_provider.dart';
import 'package:liberated_bread_mobile/services/spec_codec.dart';
import 'package:liberated_bread_mobile/widgets/led_image_widget.dart';

import '../fakes/fake_ble_service.dart';
import '../fakes/fake_spec_codec.dart';

const _encodableSpec = ImageUploadDto(
  handler: 'daniao_ddp',
  encodable: true,
  format: 'rgb888',
  maxWidth: 4,
  maxHeight: 4,
  resolutionDeviceReported: false,
  animation: true,
);

Widget _wrap(
  Widget child, {
  required FakeBleService ble,
  required FakeSpecCodec codec,
}) =>
    ProviderScope(
      overrides: [
        bleServiceProvider.overrideWithValue(ble),
        specCodecProvider.overrideWithValue(codec),
      ],
      child: MaterialApp(
        home: Scaffold(
          // Narrow column: the grid is width-square, so an unconstrained
          // 800px test surface would push every control below the fold.
          body: SingleChildScrollView(
            child: SizedBox(width: 300, child: child),
          ),
        ),
      ),
    );

/// Scroll [finder] into view, then tap it — the editor column is taller than
/// the test viewport.
Future<void> _scrollAndTap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pump();
  await tester.tap(finder);
}

void main() {
  group('writePayloadForMtu', () {
    test('sizes a genuinely tiny link to the 20-byte BLE floor', () {
      // A reported 23 is trusted: on Android it means requestMtu(512) was
      // refused, so writes must be sized for the real link and the image
      // encoder gets to reject with its actionable MTU message. The one
      // platform whose report lies (flutter_blue_plus_linux) is corrected in
      // RealBleService.mtu(), not here.
      expect(writePayloadForMtu(23), 20);
      expect(writePayloadForMtu(0), 20);
    });

    test('uses a real negotiated MTU minus the 3-byte ATT header', () {
      expect(writePayloadForMtu(512), 509);
      expect(writePayloadForMtu(247), 244);
    });

    test('caps at the 512-byte attribute maximum', () {
      expect(writePayloadForMtu(9999), 512);
    });
  });

  group('quantizeFrame', () {
    Uint8List frameOf(List<int> packed) {
      final out = Uint8List(packed.length * 3);
      for (var i = 0; i < packed.length; i++) {
        out[i * 3] = (packed[i] >> 16) & 0xFF;
        out[i * 3 + 1] = (packed[i] >> 8) & 0xFF;
        out[i * 3 + 2] = packed[i] & 0xFF;
      }
      return out;
    }

    Set<int> distinct(Uint8List rgb) => {
          for (var i = 0; i < rgb.length; i += 3)
            (rgb[i] << 16) | (rgb[i + 1] << 8) | rgb[i + 2],
        };

    // 16 grays, 0x000000 through 0xFFFFFF in 0x111111 steps.
    final grays = [for (var i = 0; i < 16; i++) i * 0x111111];

    test('a frame already within the palette keeps its identity', () {
      final frame = frameOf(grays);
      expect(identical(quantizeFrame(frame), frame), isTrue,
          reason: 'no copy, no remap — the common case costs one count pass');
    });

    test('a 17th colour merges into its nearest kept neighbour', () {
      // Every gray appears twice; the near-black 0x101010 once, so it is the
      // colour dropped — and 0x111111 is its nearest survivor.
      final frame = frameOf([...grays, ...grays, 0x101010]);
      final out = quantizeFrame(frame);
      final colors = distinct(out);
      expect(colors.length, lessThanOrEqualTo(maxFrameColors));
      expect(colors, isNot(contains(0x101010)));
      final last = out.sublist(out.length - 3);
      expect(last, [0x11, 0x11, 0x11],
          reason: 'the dropped pixel takes its nearest kept colour');
    });

    test('the protected colour survives even as the least used', () {
      // One freshly painted red pixel on a full 16-gray canvas: red is the
      // rarest colour, but it is the stroke the user just made, so it must
      // win and a gray must merge instead.
      final frame = frameOf([...grays, ...grays, 0xFF0000]);
      final out = quantizeFrame(frame, protect: 0xFF0000);
      final colors = distinct(out);
      expect(colors.length, lessThanOrEqualTo(maxFrameColors));
      expect(colors, contains(0xFF0000));
      expect(out.sublist(out.length - 3), [0xFF, 0x00, 0x00]);
    });
  });

  group('resizeFrame', () {
    test('growing pads with black and keeps the drawing top-left', () {
      final src = Uint8List.fromList([1, 2, 3, 4, 5, 6]); // 2x1
      final out = resizeFrame(src, 2, 1, 3, 2);
      expect(out.length, 3 * 2 * 3);
      expect(out.sublist(0, 6), [1, 2, 3, 4, 5, 6]);
      expect(out.sublist(6), everyElement(0));
    });

    test('shrinking crops without touching surviving pixels', () {
      // 2x2 with distinct per-pixel values.
      final src = Uint8List.fromList([
        1, 1, 1, 2, 2, 2, //
        3, 3, 3, 4, 4, 4,
      ]);
      final out = resizeFrame(src, 2, 2, 1, 1);
      expect(out, [1, 1, 1]);
    });
  });

  group('initialCanvasSize', () {
    test('defaults to 16 within the platform bound', () {
      expect(initialCanvasSize(255), 16);
      expect(initialCanvasSize(null), 16);
    });

    test('a tiny bound clamps the default', () {
      expect(initialCanvasSize(5), 5);
    });
  });

  group('parseCanvasSize', () {
    test('accepts any in-range size, not just presets', () {
      // Real panels report sizes like 25x50; forcing a preset would shear
      // every transmitted row.
      expect(parseCanvasSize('25', max: 255), 25);
      expect(parseCanvasSize(' 50 ', max: 255), 50);
    });

    test('clamps to 1..max', () {
      expect(parseCanvasSize('0', max: 255), 1);
      expect(parseCanvasSize('999', max: 255), 255);
      expect(parseCanvasSize('999', max: null), 255);
    });

    test('non-numeric input returns null (keep the previous size)', () {
      expect(parseCanvasSize('abc', max: 255), isNull);
      expect(parseCanvasSize('', max: 255), isNull);
    });
  });

  group('frameIntervalBoundsMs', () {
    test('defaults when the spec is silent', () {
      const spec = ImageUploadDto(
        encodable: true,
        resolutionDeviceReported: false,
        animation: true,
      );
      final bounds = frameIntervalBoundsMs(spec);
      expect(bounds.min, 50);
      expect(bounds.max, 2000);
      expect(bounds.initial, 200);
    });

    test('spec-declared limits win and the initial clamps into range', () {
      const spec = ImageUploadDto(
        encodable: true,
        resolutionDeviceReported: false,
        animation: true,
        minFrameIntervalMs: 100,
        defaultFrameIntervalMs: 40,
      );
      final bounds = frameIntervalBoundsMs(spec);
      expect(bounds.min, 100);
      expect(bounds.initial, 100);
    });
  });

  testWidgets('painting a pixel and sending encodes + writes the plan',
      (tester) async {
    final codec = FakeSpecCodec(
      imagePlan: ImageWritePlanDto(
        serviceUuid: 'svc-uuid',
        writes: [
          ImageWriteDto(
              characteristicUuid: 'chr-uuid',
              bytes: Uint8List.fromList([1, 2])),
          ImageWriteDto(
              characteristicUuid: 'chr-uuid',
              bytes: Uint8List.fromList([3, 4])),
        ],
        nextFrameIndex: 2,
      ),
    );
    final ble = FakeBleService();
    await tester.pumpWidget(_wrap(
      const LedImageWidget(
        deviceId: 'AA:BB',
        imageUpload: _encodableSpec,
        specYaml: 'yaml',
      ),
      ble: ble,
      codec: codec,
    ));

    // Paint the top-left cell: tap inside the first grid cell.
    final grid = find.byKey(const Key('led-image-grid'));
    expect(grid, findsOneWidget);
    await tester.tapAt(tester.getTopLeft(grid) + const Offset(4, 4));
    await tester.pump();

    await _scrollAndTap(tester, find.text('Send to device'));
    await tester.pumpAndSettle();

    // The codec saw a 4x4 RGB frame with the default red in pixel (0,0)...
    expect(codec.encodeImageCalls, hasLength(1));
    final call = codec.encodeImageCalls.single;
    expect(call.width, 4);
    expect(call.height, 4);
    expect(call.rgb.length, 4 * 4 * 3);
    expect(call.rgb.sublist(0, 3), isNot([0, 0, 0]),
        reason: 'painted pixel must not stay black');
    expect(call.rgb.sublist(3), everyElement(0),
        reason: 'unpainted pixels stay black');
    // ...sized for the 20-byte floor because the fake reports MTU 23 and the
    // widget trusts the service's answer (the Linux mtuNow quirk is corrected
    // inside RealBleService.mtu(), not here)...
    expect(call.maxPayloadPerWrite, 20);
    // ...and both plan writes went to the plan's service/characteristic.
    expect(ble.writes, hasLength(2));
    expect(ble.writes[0].charUuid, 'chr-uuid');
    expect(ble.writes[0].value, [1, 2]);
    expect(ble.writes[1].value, [3, 4]);
  });

  group('save to device (stored microapp)', () {
    const encodableStored = StoredUploadDto(
      containerFormat: 'daniao_amx',
      encodable: true,
    );

    testWidgets('no Save button when the device declares no storage',
        (tester) async {
      await tester.pumpWidget(_wrap(
        const LedImageWidget(
          deviceId: 'AA:BB',
          imageUpload: _encodableSpec,
          specYaml: 'yaml',
        ),
        ble: FakeBleService(),
        codec: FakeSpecCodec(),
      ));
      expect(find.text('Save to device'), findsNothing);
    });

    testWidgets('no Save button when the container format is not encodable',
        (tester) async {
      await tester.pumpWidget(_wrap(
        const LedImageWidget(
          deviceId: 'AA:BB',
          imageUpload: _encodableSpec,
          storedUpload:
              StoredUploadDto(containerFormat: 'daniao_amx', encodable: false),
          specYaml: 'yaml',
        ),
        ble: FakeBleService(),
        codec: FakeSpecCodec(),
      ));
      expect(find.text('Save to device'), findsNothing);
    });

    testWidgets('saving encodes the current frame and writes upload + play',
        (tester) async {
      final codec = FakeSpecCodec(
        storedPlan: StoredUploadPlanDto(
          serviceUuid: 'svc',
          uploadWrites: [
            ImageWriteDto(
                characteristicUuid: 'uploader',
                bytes: Uint8List.fromList([10, 11])),
            ImageWriteDto(
                characteristicUuid: 'uploader',
                bytes: Uint8List.fromList([12, 13])),
          ],
          playWrite: ImageWriteDto(
              characteristicUuid: 'ddp', bytes: Uint8List.fromList([9])),
          cid: 900123,
        ),
      );
      final ble = FakeBleService();
      await tester.pumpWidget(_wrap(
        const LedImageWidget(
          deviceId: 'AA:BB',
          imageUpload: _encodableSpec,
          storedUpload: encodableStored,
          specYaml: 'yaml',
        ),
        ble: ble,
        codec: codec,
      ));

      // Paint a pixel so the stored frame is not all-black.
      final grid = find.byKey(const Key('led-image-grid'));
      await tester.tapAt(tester.getTopLeft(grid) + const Offset(4, 4));
      await tester.pump();

      await _scrollAndTap(tester, find.text('Save to device'));
      await tester.pumpAndSettle();

      // The dialog opens; pick a scroll direction and confirm.
      expect(find.text('Save to device'), findsWidgets); // title + button
      await tester.tap(find.byKey(const Key('stored-scroll-dropdown')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Scroll left').last);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();

      // The codec was asked to encode the 4x4 painted frame, with the chosen
      // scroll and a novel high-band cid.
      expect(codec.encodeStoredCalls, hasLength(1));
      final call = codec.encodeStoredCalls.single;
      expect(call.width, 4);
      expect(call.height, 4);
      expect(call.rgb.length, 4 * 4 * 3);
      expect(call.rgb.sublist(0, 3), isNot([0, 0, 0]));
      expect(call.scroll, 'left');
      expect(call.cid, greaterThanOrEqualTo(900001));

      // Both uploader writes then the play write went out, in order.
      expect(ble.writes.map((w) => w.charUuid).toList(),
          ['uploader', 'uploader', 'ddp']);
      expect(ble.writes.map((w) => w.value).toList(), [
        [10, 11],
        [12, 13],
        [9],
      ]);
    });

    testWidgets('the Text kind reveals a text field and blocks an empty save',
        (tester) async {
      // The full text flow rasterises via the engine (Picture.toImage), which
      // does not run headless; the encode itself is covered by the Rust
      // byte-match tests. Here we assert the dialog wiring.
      await tester.pumpWidget(_wrap(
        const LedImageWidget(
          deviceId: 'AA:BB',
          imageUpload: _encodableSpec,
          storedUpload: encodableStored,
          specYaml: 'yaml',
        ),
        ble: FakeBleService(),
        codec: FakeSpecCodec(),
      ));

      await _scrollAndTap(tester, find.text('Save to device'));
      await tester.pumpAndSettle();
      // Picture is the default kind — no text field yet.
      expect(find.byKey(const Key('stored-text-field')), findsNothing);

      await tester.tap(find.text('Text'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('stored-text-field')), findsOneWidget);

      // Empty text keeps the dialog open (nothing to store).
      await tester.enterText(find.byKey(const Key('stored-text-field')), '');
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('stored-text-field')), findsOneWidget,
          reason: 'dialog stays open on empty text');
    });

    testWidgets(
        'saving an animation sends every frame via encodeStoredAnimation',
        (tester) async {
      final codec = FakeSpecCodec();
      final ble = FakeBleService();
      await tester.pumpWidget(_wrap(
        const LedImageWidget(
          deviceId: 'AA:BB',
          imageUpload: _encodableSpec,
          storedUpload: encodableStored,
          specYaml: 'yaml',
        ),
        ble: ble,
        codec: codec,
      ));

      // Enter animation mode and add a frame so there are two.
      await _scrollAndTap(tester, find.text('Animation'));
      await tester.pump();
      await _scrollAndTap(tester, find.byTooltip('Add frame'));
      await tester.pump();

      await _scrollAndTap(tester, find.text('Save to device'));
      await tester.pumpAndSettle();

      // The Animation kind is now selectable.
      await tester.tap(find.text('Animation').last);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();

      expect(codec.encodeAnimationCalls, hasLength(1));
      final call = codec.encodeAnimationCalls.single;
      expect(call.frameCount, 2, reason: 'both frames stored');
      expect(call.width, 4);
      expect(ble.writes, isNotEmpty);
    });

    testWidgets('a failed save surfaces an error and re-enables the button',
        (tester) async {
      final codec = FakeSpecCodec(encodeStoredError: StateError('boom'));
      await tester.pumpWidget(_wrap(
        const LedImageWidget(
          deviceId: 'AA:BB',
          imageUpload: _encodableSpec,
          storedUpload: encodableStored,
          specYaml: 'yaml',
        ),
        ble: FakeBleService(),
        codec: codec,
      ));

      await _scrollAndTap(tester, find.text('Save to device'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Could not save'), findsOneWidget);
      // The button is back to its idle label, not stuck on "Saving…".
      expect(find.text('Save to device'), findsOneWidget);
    });

    testWidgets(
        'saving mid-stream stops the stream, so the played design is not '
        'repainted over', (tester) async {
      final codec = FakeSpecCodec();
      final ble = FakeBleService();
      await tester.pumpWidget(_wrap(
        const LedImageWidget(
          deviceId: 'AA:BB',
          imageUpload: _encodableSpec,
          storedUpload: encodableStored,
          specYaml: 'yaml',
        ),
        ble: ble,
        codec: codec,
      ));

      // Preview the way a user would: animation mode, streaming live.
      await _scrollAndTap(tester, find.text('Animation'));
      await tester.pump();
      await _scrollAndTap(tester, find.text('Stream to device'));
      await tester.pump(const Duration(milliseconds: 450));
      expect(codec.encodeImageCalls, isNotEmpty);

      // Save while the stream is running — the button must be live. Bounded
      // pumps, not pumpAndSettle: the stream's interval timer is still armed
      // until the save stops it.
      await _scrollAndTap(tester, find.text('Save to device'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pump();
      // Drain the in-flight frame, the upload writes and the play write.
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();

      // The stream was stopped by the save, not left racing the playback.
      expect(find.text('Stream to device'), findsOneWidget);
      expect(find.text('Stop streaming'), findsNothing);

      // Give a stray loop two more intervals to betray itself: nothing may
      // follow the play write, or the stored design would be repainted over
      // the moment the device starts playing it.
      final writesAfterSave = ble.writes.length;
      final framesAfterSave = codec.encodeImageCalls.length;
      await tester.pump(const Duration(milliseconds: 500));
      expect(ble.writes.length, writesAfterSave);
      expect(codec.encodeImageCalls.length, framesAfterSave);
      expect(ble.writes.last.charUuid, 'ddp',
          reason: 'the play-by-cid write must be the last thing on the wire');
    });
  });

  testWidgets('animation mode adds frames and streams until stopped',
      (tester) async {
    final codec = FakeSpecCodec();
    final ble = FakeBleService();
    await tester.pumpWidget(_wrap(
      const LedImageWidget(
        deviceId: 'AA:BB',
        imageUpload: _encodableSpec,
        specYaml: 'yaml',
      ),
      ble: ble,
      codec: codec,
    ));

    await _scrollAndTap(tester, find.text('Animation'));
    await tester.pump();
    expect(find.text('Frame every 200ms'), findsOneWidget);

    await _scrollAndTap(tester, find.byTooltip('Add frame'));
    await tester.pump();
    expect(find.widgetWithText(ChoiceChip, '2'), findsOneWidget);

    await _scrollAndTap(tester, find.text('Stream to device'));
    // Let the stream loop push a few frames (200ms interval).
    await tester.pump(const Duration(milliseconds: 450));
    await _scrollAndTap(tester, find.text('Stop streaming'));
    // Drain the in-flight iteration and its interval wait.
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();

    expect(codec.encodeImageCalls.length, greaterThanOrEqualTo(2),
        reason: 'streaming must send successive frames');
    // Frame indexes increase monotonically — the wire serials depend on it.
    final indexes = [for (final c in codec.encodeImageCalls) c.frameIndex];
    expect(indexes, List.generate(indexes.length, (i) => i));
  });

  testWidgets(
      'a stream stopped mid-frame and restarted cannot interleave writes '
      'with the in-flight frame', (tester) async {
    // Stopping a stream only stops the loop — the frame being written keeps
    // going. This pins the send queue: a restart's first frame must not even
    // ENCODE until the old frame's writes finish, and the recorded write
    // order must stay whole-frame sequences, never spliced fragments.
    final gate = Completer<void>();
    final ble = FakeBleService(writeGate: gate.future);
    final codec = FakeSpecCodec(
      imagePlan: ImageWritePlanDto(
        serviceUuid: 's',
        writes: [
          ImageWriteDto(
              characteristicUuid: 'c', bytes: Uint8List.fromList([1])),
          ImageWriteDto(
              characteristicUuid: 'c', bytes: Uint8List.fromList([2])),
        ],
        nextFrameIndex: 1,
      ),
    );
    await tester.pumpWidget(_wrap(
      const LedImageWidget(
        deviceId: 'AA:BB',
        imageUpload: _encodableSpec,
        specYaml: 'yaml',
      ),
      ble: ble,
      codec: codec,
    ));

    await _scrollAndTap(tester, find.text('Animation'));
    await tester.pump();
    await _scrollAndTap(tester, find.text('Stream to device'));
    await tester.pump();
    await tester.pump(); // flush microtasks: encode #1 runs, write #1 parks
    expect(codec.encodeImageCalls, hasLength(1));

    await _scrollAndTap(tester, find.text('Stop streaming'));
    await tester.pump();
    await _scrollAndTap(tester, find.text('Stream to device'));
    await tester.pump();
    await tester.pump();
    // The restarted stream's first send is queued behind the in-flight
    // frame — no second encode while the gate holds the old writes.
    expect(codec.encodeImageCalls, hasLength(1),
        reason: 'queued send must wait for the in-flight frame');

    gate.complete();
    await tester.pump(const Duration(milliseconds: 250));
    await _scrollAndTap(tester, find.text('Stop streaming'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();

    expect(codec.encodeImageCalls.length, greaterThanOrEqualTo(2));
    expect(ble.writes.length, greaterThanOrEqualTo(4));
    for (var i = 0; i < ble.writes.length; i++) {
      expect(ble.writes[i].value, [i.isEven ? 1 : 2],
          reason: 'write $i out of frame order — fragments interleaved');
    }
  });

  testWidgets('spec without animation renders no mode toggle', (tester) async {
    const staticOnly = ImageUploadDto(
      encodable: true,
      resolutionDeviceReported: false,
      animation: false,
      maxWidth: 4,
      maxHeight: 4,
    );
    await tester.pumpWidget(_wrap(
      const LedImageWidget(
        deviceId: 'AA:BB',
        imageUpload: staticOnly,
        specYaml: 'yaml',
      ),
      ble: FakeBleService(),
      codec: FakeSpecCodec(),
    ));

    expect(find.text('Static'), findsNothing);
    expect(find.text('Animation'), findsNothing);
    expect(find.text('Send to device'), findsOneWidget);
  });

  testWidgets('device-reported resolution offers canvas size pickers',
      (tester) async {
    const deviceReported = ImageUploadDto(
      encodable: true,
      resolutionDeviceReported: true,
      animation: true,
      maxWidth: 255,
      maxHeight: 255,
    );
    await tester.pumpWidget(_wrap(
      const LedImageWidget(
        deviceId: 'AA:BB',
        imageUpload: deviceReported,
        specYaml: 'yaml',
      ),
      ble: FakeBleService(),
      codec: FakeSpecCodec(),
    ));

    expect(find.textContaining('Width'), findsOneWidget);
    expect(find.textContaining('Height'), findsOneWidget);

    // Free-form entry: a non-preset size like a real 25-wide panel works.
    await tester.enterText(
        find.byKey(const ValueKey('led-canvas-width-16')), '25');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(find.byKey(const ValueKey('led-canvas-width-25')), findsOneWidget);
  });

  testWidgets('switching to Static stops a running preview', (tester) async {
    await tester.pumpWidget(_wrap(
      const LedImageWidget(
        deviceId: 'AA:BB',
        imageUpload: _encodableSpec,
        specYaml: 'yaml',
      ),
      ble: FakeBleService(),
      codec: FakeSpecCodec(),
    ));

    await _scrollAndTap(tester, find.text('Animation'));
    await tester.pump();
    await _scrollAndTap(tester, find.byTooltip('Add frame'));
    await tester.pump();
    await _scrollAndTap(tester, find.byTooltip('Preview'));
    await tester.pump();

    // Leaving animation mode must cancel the timer: its stop control
    // unmounts, and a hidden timer would keep cycling the canvas (and
    // change which frame Send uploads). If the timer survived, the pending
    // periodic callbacks would fail the test as un-drained timers.
    await _scrollAndTap(tester, find.text('Static'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 700));

    // Back in animation mode the selection is still frame 2 (where the user
    // left it), not somewhere a runaway timer advanced to.
    await _scrollAndTap(tester, find.text('Animation'));
    await tester.pump();
    final chip2 = tester.widget<ChoiceChip>(
      find.widgetWithText(ChoiceChip, '2'),
    );
    expect(chip2.selected, isTrue);
  });

  testWidgets('unimplemented handler states it plainly, offers no send',
      (tester) async {
    const notYet = ImageUploadDto(
      handler: 'popled_json',
      encodable: false,
      resolutionDeviceReported: false,
      animation: true,
      maxWidth: 32,
      maxHeight: 16,
    );
    await tester.pumpWidget(_wrap(
      const LedImageWidget(
        deviceId: 'AA:BB',
        imageUpload: notYet,
        specYaml: 'yaml',
      ),
      ble: FakeBleService(),
      codec: FakeSpecCodec(),
    ));

    expect(find.textContaining('popled_json'), findsOneWidget);
    expect(find.text('Send to device'), findsNothing);
  });

  testWidgets('a spec swapped underneath resizes the canvas with it',
      (tester) async {
    // The panel mounts this under a constant key, so a remote spec-pack
    // refresh that promotes a different candidate updates the widget in place
    // and this State survives. Without didUpdateWidget the editor kept the old
    // geometry and encoded it against the new spec's YAML.
    const wider = ImageUploadDto(
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

    Widget build(ImageUploadDto spec, String yaml) => _wrap(
          LedImageWidget(
            key: const ValueKey('led-image-editor'),
            deviceId: 'AA:BB',
            imageUpload: spec,
            specYaml: yaml,
          ),
          ble: ble,
          codec: codec,
        );

    await tester.pumpWidget(build(_encodableSpec, 'yaml-a'));
    await _scrollAndTap(tester, find.text('Send to device'));
    await tester.pumpAndSettle();
    expect(codec.encodeImageCalls.single.width, 4);
    expect(codec.encodeImageCalls.single.height, 4);

    await tester.pumpWidget(build(wider, 'yaml-b'));
    await tester.pumpAndSettle();
    await _scrollAndTap(tester, find.text('Send to device'));
    await tester.pumpAndSettle();

    final latest = codec.encodeImageCalls.last;
    expect(latest.width, 8);
    expect(latest.height, 2);
    expect(latest.rgb.length, 8 * 2 * 3,
        reason: 'the buffer must match the dimensions it is sent with');
    expect(latest.specYaml, 'yaml-b',
        reason: 'geometry and spec must come from the same snapshot');
    // And the first send is still whole: old spec with old dimensions.
    final first = codec.encodeImageCalls.first;
    expect(first.specYaml, 'yaml-a');
    expect(first.width, 4);
  });

  testWidgets('a send queued before a spec swap keeps its own spec',
      (tester) async {
    // The other direction of the same snapshot. The geometry was captured at
    // enqueue but the YAML was read later, so a send parked behind an
    // in-flight one encoded the PRE-swap dimensions against the POST-swap
    // spec once didUpdateWidget reset the canvas — the sheared image the
    // snapshot exists to prevent, arrived at backwards.
    const wider = ImageUploadDto(
      handler: 'daniao_ddp',
      encodable: true,
      format: 'rgb888',
      maxWidth: 8,
      maxHeight: 2,
      resolutionDeviceReported: false,
      animation: true,
    );
    final gate = Completer<void>();
    final ble = FakeBleService(writeGate: gate.future);
    final codec = FakeSpecCodec();

    Widget build(ImageUploadDto spec, String yaml) => _wrap(
          LedImageWidget(
            key: const ValueKey('led-image-editor'),
            deviceId: 'AA:BB',
            imageUpload: spec,
            specYaml: yaml,
          ),
          ble: ble,
          codec: codec,
        );

    await tester.pumpWidget(build(_encodableSpec, 'yaml-a'));
    await _scrollAndTap(tester, find.text('Animation'));
    await tester.pump();
    await _scrollAndTap(tester, find.text('Stream to device'));
    await tester.pump();
    await tester.pump(); // frame 1 encodes, its write parks on the gate
    expect(codec.encodeImageCalls, hasLength(1));
    expect(codec.encodeImageCalls.single.specYaml, 'yaml-a');

    // Queue a SECOND send behind the parked one. This is the window: it has
    // been enqueued (so its geometry is captured) but not yet encoded, so a
    // late read of widget.specYaml would pick up the swap below.
    await _scrollAndTap(tester, find.text('Stop streaming'));
    await tester.pump();
    await _scrollAndTap(tester, find.text('Stream to device'));
    await tester.pump();
    await tester.pump();
    expect(codec.encodeImageCalls, hasLength(1),
        reason: 'the second send must still be queued');

    // Swap the spec under the widget while that send is still queued.
    await tester.pumpWidget(build(wider, 'yaml-b'));
    await tester.pump();

    gate.complete();
    await tester.pumpAndSettle();
    expect(codec.encodeImageCalls.length, greaterThanOrEqualTo(2));

    for (final call in codec.encodeImageCalls) {
      expect(call.rgb.length, call.width * call.height * 3,
          reason: 'every send must carry a buffer matching its dimensions');
      final expected = call.specYaml == 'yaml-a' ? 4 : 8;
      expect(call.width, expected,
          reason: 'dimensions must match the spec they were encoded against');
    }
  });

  testWidgets('deleting a frame under an in-flight send does not derail it',
      (tester) async {
    // Stopping a stream re-enables the frame controls while the frame being
    // written is still going — the window this reaches through. The queued
    // send used to index the live list on the far side of its awaits, so
    // deleting the last frame under it threw a RangeError out of the write
    // loop; deleting an earlier one silently sent a different image.
    final gate = Completer<void>();
    final ble = FakeBleService(writeGate: gate.future);
    final codec = FakeSpecCodec();
    await tester.pumpWidget(_wrap(
      const LedImageWidget(
        deviceId: 'AA:BB',
        imageUpload: _encodableSpec,
        specYaml: 'yaml',
      ),
      ble: ble,
      codec: codec,
    ));

    await _scrollAndTap(tester, find.text('Animation'));
    await tester.pump();
    await _scrollAndTap(tester, find.byTooltip('Add frame'));
    await tester.pump();
    // _current is now the second (last) frame — the one whose index goes out
    // of range the moment it is removed.
    expect(find.widgetWithText(ChoiceChip, '2'), findsOneWidget);

    await _scrollAndTap(tester, find.text('Stream to device'));
    await tester.pump();
    await tester.pump(); // encode runs, the first write parks on the gate
    expect(codec.encodeImageCalls, hasLength(1));

    // Stop and restart: the restart's frame is queued *behind* the parked one,
    // so it does not read the frame list until the gate opens. That is the
    // window — an enqueued send whose turn has not come yet.
    await _scrollAndTap(tester, find.text('Stop streaming'));
    await tester.pump();
    await _scrollAndTap(tester, find.text('Stream to device'));
    await tester.pump();
    await tester.pump();
    expect(codec.encodeImageCalls, hasLength(1),
        reason: 'the second send must still be queued');

    await _scrollAndTap(tester, find.text('Stop streaming'));
    await tester.pump();
    await _scrollAndTap(tester, find.byTooltip('Delete frame'));
    await tester.pump();
    expect(find.widgetWithText(ChoiceChip, '2'), findsNothing);

    gate.complete();
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(ble.writes, isNotEmpty,
        reason: 'the in-flight frame must still finish its writes');
    expect(codec.encodeImageCalls, hasLength(2),
        reason: 'the queued send must run, not throw on a stale index');
    for (final call in codec.encodeImageCalls) {
      expect(call.rgb.length, call.width * call.height * 3);
    }
  });
}
