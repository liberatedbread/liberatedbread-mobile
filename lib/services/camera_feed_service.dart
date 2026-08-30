// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/log.dart';
import 'spec_codec.dart';

/// A live camera feed for a device whose spec declares a `camera:` block.
///
/// Handles the one transport the catalogue actually uses today —
/// `mjpeg_snapshot_poll`: fetch a single JPEG at `target_fps`, with the
/// cache-buster the daemon needs. Some cameras only refresh that JPEG while a
/// monitor session is held open (the Snapmaker U1), so when the spec declares a
/// `websocket_jsonrpc` keepalive this also opens a WebSocket and re-sends the
/// start method every `interval_seconds`, stopping it on teardown. Everything
/// but the socket is built on the Rust side of the spec; this only fills the
/// `{address}` placeholder and drives the timers.
///
/// [frames] is a broadcast-free single-subscription stream: listen to start the
/// feed, cancel the subscription to stop it (which closes the keepalive socket).
class CameraFeedService {
  final Duration connectTimeout;
  final Duration fetchTimeout;

  const CameraFeedService({
    this.connectTimeout = const Duration(seconds: 6),
    this.fetchTimeout = const Duration(seconds: 5),
  });

  /// A JPEG-frame stream for [stream] on [host], holding [keepalive] open if the
  /// spec declares one. Poll cadence is `1000/target_fps` ms (default 1 fps).
  Stream<Uint8List> frames({
    required String host,
    required CameraStreamDto stream,
    CameraKeepaliveDto? keepalive,
  }) {
    // Closed in onCancel -> _FeedSession.stop(); the analyzer can't trace that.
    // ignore: close_sinks
    final controller = StreamController<Uint8List>();
    _FeedSession? session;
    controller.onListen = () {
      session = _FeedSession(
        host: host,
        stream: stream,
        keepalive: keepalive,
        connectTimeout: connectTimeout,
        fetchTimeout: fetchTimeout,
        sink: controller,
      );
      unawaited(session!.start());
    };
    controller.onCancel = () async {
      await session?.stop();
    };
    return controller.stream;
  }
}

/// Fill `{address}` (and `{port}`) in a spec URL template.
String fillCameraUrl(String template, String host, {int? port}) {
  var url = template.replaceAll('{address}', host);
  if (port != null) url = url.replaceAll('{port}', '$port');
  return url;
}

/// Build one JSON-RPC 2.0 frame for a keepalive method. `paramsJson` is the
/// spec's params object serialised by Rust; the id is ours per call. Pure so a
/// test can pin the exact frame the Snapmaker expects.
String buildJsonRpcFrame(String method, String? paramsJson, int id) {
  Object? params;
  if (paramsJson != null && paramsJson.isNotEmpty) {
    try {
      params = jsonDecode(paramsJson);
    } catch (_) {
      params = null;
    }
  }
  return jsonEncode({
    'jsonrpc': '2.0',
    'method': method,
    if (params != null) 'params': params,
    'id': id,
  });
}

class _FeedSession {
  final String host;
  final CameraStreamDto stream;
  final CameraKeepaliveDto? keepalive;
  final Duration connectTimeout;
  final Duration fetchTimeout;
  final StreamController<Uint8List> sink;

  final HttpClient _http = HttpClient();
  // Closed in stop(); the analyzer flags the field but can't see the teardown.
  // ignore: close_sinks
  WebSocket? _ws;
  Timer? _pollTimer;
  Timer? _keepaliveTimer;
  int _rpcId = 1;
  bool _stopped = false;

  _FeedSession({
    required this.host,
    required this.stream,
    required this.keepalive,
    required this.connectTimeout,
    required this.fetchTimeout,
    required this.sink,
  });

  Future<void> start() async {
    await _startKeepalive();
    // The keepalive connect awaits; the session may have been stopped meanwhile.
    if (_stopped) return;
    // Poll interval from target_fps (default 1 fps), floored at 200 ms so a
    // hostile spec cannot spin the fetch loop.
    final fps = (stream.targetFps ?? 1).clamp(1, 30);
    final period = Duration(milliseconds: (1000 ~/ fps).clamp(200, 10000));
    // Fetch immediately, then on the interval.
    unawaited(_tick());
    _pollTimer = Timer.periodic(period, (_) => unawaited(_tick()));
  }

  Future<void> _startKeepalive() async {
    final k = keepalive;
    if (k == null || k.transport != 'websocket_jsonrpc') return;
    final urlTemplate = k.urlTemplate;
    final startMethod = k.startMethod;
    if (urlTemplate == null || startMethod == null) return;
    final WebSocket ws;
    try {
      ws = await WebSocket.connect(fillCameraUrl(urlTemplate, host))
          .timeout(connectTimeout);
    } on Object catch (e) {
      Log.spec.debug('camera keepalive connect failed', error: e);
      return; // Some firmware still refreshes without it; keep polling.
    }
    // The connect awaited; if the feed was stopped meanwhile, do not adopt the
    // socket or schedule the keepalive timer — close it and bail, or it leaks.
    if (_stopped) {
      try {
        await ws.close();
      } catch (_) {}
      return;
    }
    _ws = ws;
    void sendStart() {
      final ws = _ws;
      if (ws == null || _stopped) return;
      ws.add(buildJsonRpcFrame(startMethod, k.startParamsJson, _rpcId++));
    }

    sendStart();
    final interval = Duration(seconds: (k.intervalSeconds ?? 5).clamp(1, 60));
    _keepaliveTimer = Timer.periodic(interval, (_) => sendStart());
  }

  Future<void> _tick() async {
    if (_stopped) return;
    try {
      final ts = DateTime.now().microsecondsSinceEpoch;
      final sep = stream.urlTemplate.contains('?') ? '&' : '?';
      final url = '${fillCameraUrl(stream.urlTemplate, host)}${sep}ts=$ts';
      final req = await _http.getUrl(Uri.parse(url)).timeout(fetchTimeout);
      final resp = await req.close().timeout(fetchTimeout);
      if (resp.statusCode != 200) return;
      final bytes = await _collect(resp).timeout(fetchTimeout);
      // A JPEG starts FF D8; ignore anything else (an error page, a partial).
      if (!_stopped &&
          bytes.length > 2 &&
          bytes[0] == 0xFF &&
          bytes[1] == 0xD8) {
        sink.add(bytes);
      }
    } on Object catch (e) {
      Log.spec.debug('camera frame fetch failed', error: e);
      // Transient: keep polling; a persistently-dead feed just shows nothing.
    }
  }

  Future<Uint8List> _collect(HttpClientResponse resp) async {
    final b = BytesBuilder(copy: false);
    await for (final chunk in resp) {
      b.add(chunk);
    }
    return b.toBytes();
  }

  Future<void> stop() async {
    _stopped = true;
    _pollTimer?.cancel();
    _keepaliveTimer?.cancel();
    final ws = _ws;
    _ws = null;
    if (ws != null) {
      final k = keepalive;
      if (k?.stopMethod != null) {
        try {
          ws.add(buildJsonRpcFrame(k!.stopMethod!, k.stopParamsJson, _rpcId++));
        } catch (_) {}
      }
      try {
        await ws.close();
      } catch (_) {}
    }
    _http.close(force: true);
    if (!sink.isClosed) await sink.close();
  }
}

/// The camera feed transport. Tests override with a fake.
final cameraFeedServiceProvider =
    Provider<CameraFeedService>((ref) => const CameraFeedService());
