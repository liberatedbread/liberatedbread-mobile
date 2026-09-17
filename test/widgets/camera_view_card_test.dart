// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/providers/spec_codec_provider.dart';
import 'package:liberated_bread_mobile/services/camera_feed_service.dart';
import 'package:liberated_bread_mobile/services/spec_codec.dart';
import 'package:liberated_bread_mobile/widgets/camera_view_card.dart';

import '../fakes/fake_spec_codec.dart';

/// A feed whose frames the test drives, so a widget test needs no sockets.
class _FakeFeed implements CameraFeedService {
  final StreamController<Uint8List> controller;
  _FakeFeed(this.controller);

  @override
  Duration get connectTimeout => Duration.zero;
  @override
  Duration get fetchTimeout => Duration.zero;
  @override
  Duration get reconnectDelay => Duration.zero;

  @override
  Stream<Uint8List> frames({
    required String host,
    required CameraStreamDto stream,
    CameraKeepaliveDto? keepalive,
  }) => controller.stream;
}

const _pollCamera = CameraDto(
  streams: [
    CameraStreamDto(
      transport: 'mjpeg_snapshot_poll',
      urlTemplate: 'http://{address}/monitor.jpg',
      targetFps: 1,
    ),
  ],
);

Uint8List _jpeg() => Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xD9]);

/// A 1x1 transparent PNG — a frame the engine can actually decode, so the
/// image cache holds a real entry for it. A fresh list each time: MemoryImage
/// keys the cache on the bytes OBJECT, so two copies are two frames, exactly
/// as two polls of the same camera are.
Uint8List _png() => Uint8List.fromList(const [
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, //
  0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, //
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00, //
  0x0A, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00, //
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49, //
  0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82, //
]);

void main() {
  // Never pumpAndSettle: once a camera resolves the card shows an indeterminate
  // CircularProgressIndicator, whose animation never settles. Drive explicit
  // pumps instead, and dispose the card at the end so its first-frame Timer and
  // feed subscription are cancelled (no pending-timer teardown failure).
  Future<void> pump(
    WidgetTester tester, {
    required CameraDto? camera,
    required StreamController<Uint8List> feed,
  }) {
    return tester.pumpWidget(
      ProviderScope(
        overrides: [
          specCodecProvider.overrideWithValue(
            FakeSpecCodec(cameraResult: camera),
          ),
          cameraFeedServiceProvider.overrideWithValue(_FakeFeed(feed)),
        ],
        child: const MaterialApp(
          home: Scaffold(
            body: CameraViewCard(specYaml: 'yaml', host: '10.0.0.5'),
          ),
        ),
      ),
    );
  }

  // Tear the card down by replacing the tree, so its dispose() runs.
  Future<void> disposeCard(WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: SizedBox())),
    );
    await tester.pump();
  }

  testWidgets('a device with no camera renders nothing', (tester) async {
    // Broadcast: a cameraless card never subscribes, and a single-subscription
    // controller's close() would then block teardown forever waiting for a
    // listener. Broadcast close() completes with no listener.
    final feed = StreamController<Uint8List>.broadcast();
    addTearDown(feed.close);
    await pump(tester, camera: null, feed: feed);
    await tester.pump(); // let the (async) camera resolve to "none"

    expect(find.text('Camera'), findsNothing);
    expect(find.byIcon(Icons.videocam_outlined), findsNothing);
    await disposeCard(tester);
  });

  testWidgets('a camera stream renders its frames', (tester) async {
    final feed = StreamController<Uint8List>.broadcast();
    addTearDown(feed.close);
    await pump(tester, camera: _pollCamera, feed: feed);
    await tester.pump(); // resolve the camera + attach the feed subscription

    expect(find.text('Camera'), findsOneWidget);
    // No frame yet: the spinner is up, not an image.
    expect(find.byType(Image), findsNothing);

    feed.add(_jpeg());
    await tester.pump();
    expect(find.byType(Image), findsOneWidget);

    await disposeCard(tester);
  });

  testWidgets('each frame replaces the last in the image cache', (
    tester,
  ) async {
    // F-028: every polled frame used to be a new ImageCache key, so decoded
    // bitmaps piled up to the cache's 100 MB ceiling for as long as the card
    // was on screen. Now the card owns one provider, evicts the one a new
    // frame replaces, and evicts the last on dispose.
    final cache = PaintingBinding.instance.imageCache;
    cache.clear();
    final feed = StreamController<Uint8List>.broadcast();
    addTearDown(feed.close);

    // runAsync so the engine's (genuinely asynchronous) decode completes and
    // the entries move from pending into the cache proper.
    await tester.runAsync(() async {
      await pump(tester, camera: _pollCamera, feed: feed);
      await tester.pump();

      for (var i = 0; i < 6; i++) {
        feed.add(_png());
        await tester.pump();
        // Let the decode land, then let the eviction's awaited key resolve.
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await tester.pump();
        expect(
          cache.currentSize + cache.pendingImageCount,
          lessThanOrEqualTo(1),
          reason: 'frame $i: only the frame on screen may be cached',
        );
      }
      expect(find.byType(Image), findsOneWidget);

      await disposeCard(tester);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await tester.pump();
      expect(
        cache.currentSize + cache.pendingImageCount,
        0,
        reason: 'dispose evicts the last frame',
      );
    });
  });

  testWidgets('leaving the screen cancels the feed subscription', (
    tester,
  ) async {
    var cancelled = false;
    final feed = StreamController<Uint8List>.broadcast(
      onCancel: () => cancelled = true,
    );
    await pump(tester, camera: _pollCamera, feed: feed);
    await tester.pump(); // resolve + subscribe

    await disposeCard(tester); // disposes CameraViewCard
    expect(
      cancelled,
      isTrue,
      reason: 'dispose must cancel the feed, not leak the subscription',
    );
    await feed.close();
  });
}
