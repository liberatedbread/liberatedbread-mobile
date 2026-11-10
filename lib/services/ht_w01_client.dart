// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge.dart'
    show AnyhowException;

import '../core/error_text.dart';
import '../core/log.dart';
import '../src/rust/api/ht_w01_api.dart';
import '../src/rust/protocol/ht_w01.dart';
import '../src/rust/protocol/readonly.dart';

/// The camera could not be reached or read, in words for the person holding
/// the phone.
class HtW01Exception implements UserFacingException {
  @override
  final String message;
  const HtW01Exception(this.message);
  @override
  String toString() => message;
}

/// One TCP connection's bytes.
abstract interface class HtW01Transport {
  Future<void> open(String host, int port, Duration timeout);
  Future<void> write(List<int> bytes);

  /// The next bytes to arrive. Throws [TimeoutException] when none do and
  /// [SocketException] when the camera has closed.
  Future<List<int>> read(Duration timeout);
  Future<void> close();
}

class SocketHtW01Transport implements HtW01Transport {
  Socket? _socket;
  StreamIterator<Uint8List>? _incoming;
  Future<bool>? _pending;

  @override
  Future<void> open(String host, int port, Duration timeout) async {
    // ignore: close_sinks — held in _socket and destroyed by close().
    final socket = await Socket.connect(host, port, timeout: timeout);
    socket.setOption(SocketOption.tcpNoDelay, true);
    _socket = socket;
    _incoming = StreamIterator(socket);
  }

  @override
  Future<void> write(List<int> bytes) async {
    final socket = _socket;
    if (socket == null) throw StateError('not open');
    socket.add(bytes);
    await socket.flush();
  }

  @override
  Future<List<int>> read(Duration timeout) async {
    final incoming = _incoming;
    if (incoming == null) throw StateError('not open');
    final pending = _pending ??= incoming.moveNext();
    final more = await pending.timeout(timeout);
    _pending = null;
    if (!more) {
      throw const SocketException('the camera closed the connection');
    }
    return incoming.current;
  }

  @override
  Future<void> close() async {
    _socket?.destroy();
    _socket = null;
    _incoming = null;
    _pending = null;
  }
}

/// What a settings read found. A null is a value the camera did not give in
/// the `[parameter, value]` shape this app assumes.
@immutable
class HtW01Settings {
  final int? palette;
  final HtW01Range? range;
  final int? emissivityHundredths;

  /// How many of the reads got any reply at all.
  final int answered;

  const HtW01Settings({
    this.palette,
    this.range,
    this.emissivityHundredths,
    required this.answered,
  });
}

/// What a setting's send heard back.
@immutable
class HtW01Ack {
  /// False when nothing came back within the timeout. The reply format is
  /// not recovered, so silence is reported, not treated as a refusal.
  final bool answered;
  final List<int> data;
  const HtW01Ack({required this.answered, this.data = const []});
}

/// The camera surface the settings screen drives. An interface so a widget
/// test can stand in for the socket and the Rust codec.
abstract interface class HtW01Client {
  List<HtW01PaletteDto> palettes();
  Future<List<ReadOnlyCommandDto>> commandPolicy(String specYaml);
  Future<HtW01Settings> readSettings();
  Future<HtW01Ack> setPalette(int value);
  Future<HtW01Ack> setMeasuringRange(HtW01Range range);
  Future<HtW01Ack> setEmissivity(int hundredths);
  Future<HtW01Ack> refreshShutter();
}

/// The HT-W01 command channel (`ht_w01_command`): TCP 8080 on the camera's
/// own access point.
///
/// Every frame comes from a Rust builder for one named setting; the reset,
/// the restart, the Wi-Fi channel and the distance have no builder and
/// cannot be sent from here. Each call is one short connection that opens
/// with the heartbeat, as the spec's setup step does. The UDP thermal stream
/// is not opened: its layout is not recovered.
class HtW01CameraClient implements HtW01Client {
  final String host;
  final int port;
  final HtW01Transport Function() transportFactory;
  final Duration timeout;

  HtW01CameraClient({
    required this.host,
    required this.port,
    HtW01Transport Function()? transportFactory,
    this.timeout = const Duration(seconds: 3),
  }) : transportFactory = transportFactory ?? SocketHtW01Transport.new;

  static const _getParam = 0x33;
  static const _setParam = 0x34;
  static const _action = 0x35;

  @override
  List<HtW01PaletteDto> palettes() => htW01Palettes();

  @override
  Future<List<ReadOnlyCommandDto>> commandPolicy(String specYaml) =>
      htW01CommandPolicy(specYaml: specYaml);

  @override
  Future<HtW01Settings> readSettings() => _session((session) async {
    int? palette, range, emissivity;
    var answered = 0;
    for (final param in [
      HtW01Param.palette,
      HtW01Param.measuringRange,
      HtW01Param.emissivity,
    ]) {
      final reply = await session.ask(htW01Get(param: param), _getParam);
      if (reply == null) continue;
      answered++;
      final value = htW01ReplyValue(reply: reply, param: param);
      switch (param) {
        case HtW01Param.palette:
          palette = value;
        case HtW01Param.measuringRange:
          range = value;
        case HtW01Param.emissivity:
          emissivity = value;
        case HtW01Param.versionInfo:
          break;
      }
    }
    if (answered == 0) {
      throw HtW01Exception(
        'The camera at $host:$port accepted the connection but answered '
        'none of the reads within ${timeout.inSeconds} seconds.',
      );
    }
    return HtW01Settings(
      palette: palette,
      range: switch (range) {
        0 => HtW01Range.large,
        1 => HtW01Range.small,
        _ => null,
      },
      emissivityHundredths: emissivity,
      answered: answered,
    );
  });

  @override
  Future<HtW01Ack> setPalette(int value) =>
      _send(() => htW01SetPalette(value: value), _setParam);

  @override
  Future<HtW01Ack> setMeasuringRange(HtW01Range range) =>
      _send(() => htW01SetMeasuringRange(range: range), _setParam);

  @override
  Future<HtW01Ack> setEmissivity(int hundredths) =>
      _send(() => htW01SetEmissivity(hundredths: hundredths), _setParam);

  @override
  Future<HtW01Ack> refreshShutter() => _send(htW01RefreshShutter, _action);

  /// Build the frame first, so a value the codec refuses never opens a
  /// connection; then send it and listen for a reply of the same type.
  Future<HtW01Ack> _send(Uint8List Function() build, int type) async {
    final Uint8List frame;
    try {
      frame = build();
    } on AnyhowException catch (e) {
      throw HtW01Exception('Not sent: ${e.message}');
    }
    return _session((session) async {
      final reply = await session.ask(frame, type);
      return reply == null
          ? const HtW01Ack(answered: false)
          : HtW01Ack(answered: true, data: reply.data);
    });
  }

  Future<T> _session<T>(Future<T> Function(_Session session) body) async {
    final transport = transportFactory();
    try {
      try {
        await transport.open(host, port, timeout);
      } on Object catch (e) {
        Log.net.debug('HT-W01 connect to $host:$port failed', error: e);
        throw HtW01Exception(
          'Could not reach the camera at $host:$port. Join its HT-W01 Wi-Fi '
          'network first; the phone has no internet while it is joined.',
        );
      }
      final session = _Session(transport, timeout);
      await transport.write(htW01Heartbeat(counter: 1));
      return await body(session);
    } on HtW01Exception {
      rethrow;
    } on SocketException {
      throw const HtW01Exception('The camera closed the connection.');
    } finally {
      await transport.close();
    }
  }
}

class _Session {
  final HtW01Transport transport;
  final Duration timeout;
  var _buffer = <int>[];
  final _frames = <HtW01ReplyDto>[];

  _Session(this.transport, this.timeout);

  /// Send [frame] and wait for a reply of [type]; null when none comes in
  /// time. Other frames (a heartbeat's answer) and garbage are passed over.
  Future<HtW01ReplyDto?> ask(List<int> frame, int type) async {
    await transport.write(frame);
    final deadline = DateTime.now().add(timeout);
    while (true) {
      while (_frames.isNotEmpty) {
        final reply = _frames.removeAt(0);
        if (reply.cmdType == type) return reply;
      }
      final left = deadline.difference(DateTime.now());
      if (left <= Duration.zero) return null;
      final List<int> chunk;
      try {
        chunk = await transport.read(left);
      } on TimeoutException {
        return null;
      }
      final split = htW01SplitStream(buffer: [..._buffer, ...chunk]);
      _buffer = split.rest;
      _frames.addAll(split.frames);
      if (split.discarded > 0) {
        Log.net.debug('HT-W01: passed over ${split.discarded} bytes');
      }
    }
  }
}
