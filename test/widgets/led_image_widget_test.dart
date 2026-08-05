// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
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
    test('floors at the spec-safe 20 bytes for unknown/minimum MTUs', () {
      expect(writePayloadForMtu(23), 20);
      expect(writePayloadForMtu(0), 20);
    });

    test('uses the negotiated MTU minus the 3-byte ATT header', () {
      expect(writePayloadForMtu(512), 509);
      expect(writePayloadForMtu(247), 244);
    });

    test('caps at the 512-byte attribute maximum', () {
      expect(writePayloadForMtu(9999), 512);
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

  group('canvasSizeOptions', () {
    test('offers common sizes up to the platform bound', () {
      expect(canvasSizeOptions(32), [8, 12, 16, 20, 24, 32]);
    });

    test('no bound means the full list', () {
      expect(canvasSizeOptions(null), [8, 12, 16, 20, 24, 32, 48, 64]);
    });

    test('a tiny bound still offers itself', () {
      expect(canvasSizeOptions(5), [5]);
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
        characteristicUuid: 'chr-uuid',
        writes: [
          Uint8List.fromList([1, 2]),
          Uint8List.fromList([3, 4]),
        ],
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
    // ...sized for the fake's 23-byte MTU...
    expect(call.maxPayloadPerWrite, 20);
    // ...and both plan writes went to the plan's service/characteristic.
    expect(ble.writes, hasLength(2));
    expect(ble.writes[0].charUuid, 'chr-uuid');
    expect(ble.writes[0].value, [1, 2]);
    expect(ble.writes[1].value, [3, 4]);
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

    expect(find.text('Width'), findsOneWidget);
    expect(find.text('Height'), findsOneWidget);
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
}
