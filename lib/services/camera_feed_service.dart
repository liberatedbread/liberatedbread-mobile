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

  /// How long to wait before re-opening a keepalive socket the device closed.
  final Duration reconnectDelay;

  /// Largest single frame this service will buffer.
  ///
  /// Same rule as the SOAP and Kasa clients: the DEVICE decides how many
  /// bytes come back, and the fetch loop runs up to five times a second, so
  /// an uncapped read is a repeated allocation something on the LAN sizes.
  /// A snapshot JPEG from the cameras this path exists for is tens to a few
  /// hundred KB — four megabytes is a 4K still, well past anything this
  /// renders, and a body that keeps going past it is not a frame at all.
  /// The tick that trips it logs and keeps polling, exactly like a timeout.
  ///
  /// A constant rather than a constructor argument on purpose: this class is
  /// the Provider's type and the test fakes implement it, so every knob added
  /// here is a knob every fake has to grow. Nothing needs to vary it.
  static const maxFrameBytes = 4 * 1024 * 1024;

  const CameraFeedService({
    this.connectTimeout = const Duration(seconds: 6),
    this.fetchTimeout = const Duration(seconds: 5),
    this.reconnectDelay = const Duration(seconds: 3),
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
        reconnectDelay: reconnectDelay,
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
    'params': ?params,
    'id': id,
  });
}

class _FeedSession {
  final String host;
  final CameraStreamDto stream;
  final CameraKeepaliveDto? keepalive;
  final Duration connectTimeout;
  final Duration fetchTimeout;
  final Duration reconnectDelay;
  final StreamController<Uint8List> sink;

  final HttpClient _http = HttpClient();
  // Closed in stop(); the analyzer flags the field but can't see the teardown.
  // ignore: close_sinks
  WebSocket? _ws;
  Timer? _pollTimer;
  Timer? _keepaliveTimer;
  Timer? _reconnectTimer;
  int _rpcId = 1;
  bool _stopped = false;

  /// A poll fetch is in flight — the periodic timer skips rather than stacking
  /// concurrent requests (each would pin a socket).
  bool _fetching = false;

  /// The keepalive socket has connected at least once — so a later connect
  /// FAILURE is a lost reconnect worth retrying, not an initial absence.
  bool _keepaliveEverConnected = false;

  _FeedSession({
    required this.host,
    required this.stream,
    required this.keepalive,
    required this.connectTimeout,
    required this.fetchTimeout,
    required this.reconnectDelay,
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
      ws = await WebSocket.connect(
        fillCameraUrl(urlTemplate, host),
      ).timeout(connectTimeout);
    } on Object catch (e) {
      Log.spec.debug('camera keepalive connect failed', error: e);
      // An INITIAL failure does not loop — some firmware refreshes without the
      // keepalive, so we just keep polling. But a RECONNECT (we had a working
      // session that dropped) failing to re-open must keep trying, or the
      // monitor session is gone for good and the poll loop renders a frozen
      // frame as if it were live.
      if (_keepaliveEverConnected && !_stopped) {
        _reconnectTimer?.cancel();
        _reconnectTimer = Timer(reconnectDelay, () {
          if (!_stopped) unawaited(_startKeepalive());
        });
      }
      return;
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
    _keepaliveEverConnected = true;
    // If the printer closes the monitor socket (or the network blips), the
    // periodic sendStart would keep writing to a dead socket — surfacing an
    // uncaught error and never re-establishing the session. Watch for closure
    // and reconnect instead. We never read monitor frames off this socket.
    ws.listen(
      (_) {},
      onDone: () => _onKeepaliveClosed(ws),
      onError: (_) => _onKeepaliveClosed(ws),
      cancelOnError: true,
    );
    void sendStart() {
      final ws = _ws;
      if (ws == null || _stopped) return;
      try {
        ws.add(buildJsonRpcFrame(startMethod, k.startParamsJson, _rpcId++));
      } catch (e) {
        // Closed between the guard and the write; the done/error listener drives
        // the reconnect.
        Log.spec.debug('camera keepalive send failed', error: e);
      }
    }

    sendStart();
    final interval = Duration(seconds: (k.intervalSeconds ?? 5).clamp(1, 60));
    _keepaliveTimer = Timer.periodic(interval, (_) => sendStart());
  }

  /// The keepalive socket closed. Unless the feed is stopping (or this is a
  /// stale socket we already replaced), re-open the monitor session after a
  /// short backoff so the JPEG keeps refreshing. The poll loop keeps running
  /// throughout — a dead keepalive only means the frames stop updating.
  void _onKeepaliveClosed(WebSocket closed) {
    if (_stopped || !identical(_ws, closed)) return;
    _keepaliveTimer?.cancel();
    _keepaliveTimer = null;
    _ws = null;
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(reconnectDelay, () {
      if (!_stopped) unawaited(_startKeepalive());
    });
  }

  Future<void> _tick() async {
    // Skip while a fetch is still running: the period can be as low as 200 ms,
    // and a slow/hung exchange stacking concurrent requests pins one socket
    // each — the poll loop must be self-throttling.
    if (_stopped || _fetching) return;
    _fetching = true;
    HttpClientRequest? req;
    try {
      final ts = DateTime.now().microsecondsSinceEpoch;
      final sep = stream.urlTemplate.contains('?') ? '&' : '?';
      final url = '${fillCameraUrl(stream.urlTemplate, host)}${sep}ts=$ts';
      req = await _http.getUrl(Uri.parse(url)).timeout(fetchTimeout);
      final resp = await req.close().timeout(fetchTimeout);
      if (resp.statusCode != 200) {
        // Drain the body or dart:io keeps the connection out of the pool — a
        // busy printer answering 503 each poll would leak a socket per tick.
        await resp.drain<void>().timeout(fetchTimeout);
        return;
      }
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
      // A timeout only abandons the future; abort so a hung exchange releases
      // its socket instead of pinning it until stop().
      try {
        req?.abort();
      } catch (_) {}
      // Transient: keep polling; a persistently-dead feed just shows nothing.
    } finally {
      _fetching = false;
    }
  }

  Future<Uint8List> _collect(HttpClientResponse resp) async {
    final b = BytesBuilder(copy: false);
    await for (final chunk in resp) {
      // Before the append, so a chunk that would carry the frame past the cap
      // is never retained on the way to the exception: the bound is on what
      // this service holds, and dart:io has already allocated the chunk.
      if (b.length + chunk.length > CameraFeedService.maxFrameBytes) {
        // Throwing out of the `await for` cancels the subscription, and the
        // catch in _tick aborts the request — so the socket goes back rather
        // than feeding a buffer nothing will ever render.
        throw HttpException(
          'camera frame exceeded ${CameraFeedService.maxFrameBytes} bytes',
          uri: resp.redirects.isEmpty ? null : resp.redirects.last.location,
        );
      }
      b.add(chunk);
    }
    return b.toBytes();
  }

  Future<void> stop() async {
    _stopped = true;
    _pollTimer?.cancel();
    _keepaliveTimer?.cancel();
    _reconnectTimer?.cancel();
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
final cameraFeedServiceProvider = Provider<CameraFeedService>(
  (ref) => const CameraFeedService(),
);
