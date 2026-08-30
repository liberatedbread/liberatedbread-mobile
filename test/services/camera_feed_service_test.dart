// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/services/camera_feed_service.dart';
import 'package:liberated_bread_mobile/services/spec_codec.dart';

// A 3-byte "JPEG": SOI (FF D8) + one payload byte the test varies per frame.
Uint8List jpeg(int tag) => Uint8List.fromList([0xFF, 0xD8, tag]);

void main() {
  group('buildJsonRpcFrame', () {
    test('wraps method + params with an id', () {
      final frame = buildJsonRpcFrame(
          'camera.start_monitor', '{"domain":"lan","interval":0}', 7);
      final decoded = jsonDecode(frame) as Map<String, dynamic>;
      expect(decoded['jsonrpc'], '2.0');
      expect(decoded['method'], 'camera.start_monitor');
      expect(decoded['id'], 7);
      expect(decoded['params'], {'domain': 'lan', 'interval': 0});
    });

    test('omits params when none / unparseable', () {
      expect(jsonDecode(buildJsonRpcFrame('m', null, 1)).containsKey('params'),
          isFalse);
      expect(
          jsonDecode(buildJsonRpcFrame('m', 'not json', 1))
              .containsKey('params'),
          isFalse);
    });
  });

  test('fillCameraUrl substitutes {address} and {port}', () {
    expect(
        fillCameraUrl('http://{address}/x', '10.0.0.9'), 'http://10.0.0.9/x');
    expect(fillCameraUrl('rtsp://{address}:{port}/s', 'h', port: 7447),
        'rtsp://h:7447/s');
  });

  group('frames (loopback poll + websocket keepalive)', () {
    late HttpServer server;
    late String host;
    final wsFramesSeen = <String>[];
    var frameTag = 0;

    setUp(() async {
      wsFramesSeen.clear();
      frameTag = 0;
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      host = '${server.address.address}:${server.port}';
      server.listen((req) async {
        if (req.uri.path == '/websocket' &&
            WebSocketTransformer.isUpgradeRequest(req)) {
          // Server-side socket; torn down by server.close(force: true).
          // ignore: close_sinks
          final ws = await WebSocketTransformer.upgrade(req);
          ws.listen((data) => wsFramesSeen.add(data as String),
              onError: (_) {}, cancelOnError: false);
        } else if (req.uri.path == '/monitor.jpg') {
          frameTag++;
          req.response
            ..statusCode = 200
            ..headers.contentType = ContentType('image', 'jpeg')
            ..add(jpeg(frameTag));
          await req.response.close();
        } else {
          req.response.statusCode = 404;
          await req.response.close();
        }
      });
    });

    tearDown(() async => server.close(force: true));

    CameraStreamDto pollStream() => const CameraStreamDto(
          transport: 'mjpeg_snapshot_poll',
          urlTemplate: 'http://{address}/monitor.jpg',
          targetFps: 30, // fast poll so the test is quick (floored to 200ms)
        );

    CameraKeepaliveDto keepalive() => const CameraKeepaliveDto(
          transport: 'websocket_jsonrpc',
          urlTemplate: 'ws://{address}/websocket',
          startMethod: 'camera.start_monitor',
          startParamsJson: '{"domain":"lan","interval":0}',
          stopMethod: 'camera.stop_monitor',
          stopParamsJson: '{"domain":"lan"}',
          intervalSeconds: 1,
        );

    test('polls JPEG frames and opens the keepalive session', () async {
      const service = CameraFeedService();
      final got = <Uint8List>[];
      final sub = service
          .frames(host: host, stream: pollStream(), keepalive: keepalive())
          .listen(got.add);

      // Wait for at least one frame + the keepalive start.
      final deadline = DateTime.now().add(const Duration(seconds: 3));
      while (got.isEmpty || wsFramesSeen.isEmpty) {
        if (DateTime.now().isAfter(deadline)) break;
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(got, isNotEmpty, reason: 'a JPEG frame should have arrived');
      expect(got.first.sublist(0, 2), [0xFF, 0xD8]);
      expect(wsFramesSeen, isNotEmpty, reason: 'the keepalive start was sent');
      final start = jsonDecode(wsFramesSeen.first) as Map<String, dynamic>;
      expect(start['method'], 'camera.start_monitor');

      await sub.cancel();
    });

    test('cancelling sends the stop method and stops polling', () async {
      const service = CameraFeedService();
      final sub = service
          .frames(host: host, stream: pollStream(), keepalive: keepalive())
          .listen((_) {});
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await sub.cancel();
      // Give the stop frame time to arrive.
      await Future<void>.delayed(const Duration(milliseconds: 200));
      final stops = wsFramesSeen
          .map((f) => jsonDecode(f) as Map<String, dynamic>)
          .where((m) => m['method'] == 'camera.stop_monitor');
      expect(stops, isNotEmpty, reason: 'stop_monitor sent on cancel');

      final framesAfterCancel = frameTag;
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(frameTag, framesAfterCancel,
          reason: 'polling stopped after cancel');
    });

    test('a non-JPEG poll response is dropped, not emitted', () async {
      // Point at a 404 path so the body is never a JPEG.
      const stream = CameraStreamDto(
        transport: 'mjpeg_snapshot_poll',
        urlTemplate: 'http://{address}/nope.jpg',
        targetFps: 30,
      );
      const service = CameraFeedService();
      final got = <Uint8List>[];
      final sub = service.frames(host: host, stream: stream).listen(got.add);
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(got, isEmpty);
      await sub.cancel();
    });
  });
}
