// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'spec_codec.dart';

/// One request/reply exchange with a Kasa device over a raw TCP socket.
///
/// Abstracted so tests can answer from canned bytes instead of a socket, the
/// way [SoapControlClient] takes an `http.Client`. The default opens a
/// [Socket], writes the framed request, and reads until the length-prefixed
/// reply has fully arrived.
typedef KasaExchange = Future<Uint8List> Function(
  String host,
  int port,
  List<int> request,
  Duration timeout,
);

/// The transport half of Kasa control: send a rendered JSON command to the
/// device over TCP port 9999, obfuscated by the XOR-autokey cipher.
///
/// The third transport's sibling of [SoapControlClient]/[HttpControlClient].
/// The cipher and the 4-byte length framing live in the Rust codec (one tested
/// place, not re-implemented here), so this client only opens the socket,
/// writes the bytes the codec framed, and hands the reply back to the codec to
/// decode. Reply *parsing* is the caller's job via [kasaSysinfoFields], the
/// same way the SOAP client returns name→value pairs and leaves meaning to the
/// entity decoder.
class KasaControlClient {
  final SpecCodec _codec;
  final KasaExchange _exchange;

  /// One exchange's ceiling. Kasa devices answer on a LAN in milliseconds; a
  /// few seconds is generous while still failing a moved or asleep plug
  /// promptly rather than hanging the control screen.
  static const timeout = Duration(seconds: 5);

  KasaControlClient(this._codec, {KasaExchange? exchange})
      : _exchange = exchange ?? _socketExchange;

  /// Send one rendered command and return the device's decoded JSON reply.
  ///
  /// Transport failures (unreachable host, timeout, truncated frame) throw
  /// [KasaControlException]; the reply's own `err_code` is left to the caller,
  /// which re-polls `get_sysinfo` and shows the true relay state either way.
  Future<String> send(String host, int port, KasaRequestDto request) async {
    final framed = await _codec.kasaEncodeFrame(json: request.json);
    final Uint8List reply;
    try {
      reply = await _exchange(host, port, framed, timeout);
    } on SocketException catch (e) {
      throw KasaControlException('could not reach $host:$port — ${e.message}');
    } on TimeoutException {
      throw KasaControlException(
          '$host:$port did not answer within ${timeout.inSeconds}s');
    }
    try {
      return await _codec.kasaDecodeFrame(frame: reply);
    } catch (e) {
      // A malformed/short frame surfaces from the codec; name it as a device
      // reply problem rather than leaking the FFI error shape.
      throw KasaControlException('$host:$port sent an unreadable reply — $e');
    }
  }
}

/// The default socket exchange: connect, write the framed request, and read
/// until the 4-byte big-endian length prefix's worth of reply has arrived.
Future<Uint8List> _socketExchange(
  String host,
  int port,
  List<int> request,
  Duration timeout,
) async {
  final socket = await Socket.connect(host, port, timeout: timeout);
  try {
    socket.add(request);
    await socket.flush();

    final buffer = BytesBuilder(copy: false);
    int? needed;
    await for (final chunk in socket.timeout(timeout)) {
      buffer.add(chunk);
      if (needed == null && buffer.length >= 4) {
        final head = buffer.toBytes();
        final payload =
            (head[0] << 24) | (head[1] << 16) | (head[2] << 8) | head[3];
        needed = 4 + payload;
      }
      if (needed != null && buffer.length >= needed) break;
    }
    return buffer.toBytes();
  } finally {
    socket.destroy();
  }
}

/// Flatten a Kasa `get_sysinfo` reply into the name→value pairs the generic
/// entity decoder reads — the JSON counterpart of the SOAP client's XML parse.
///
/// The reply is nested (`{"system":{"get_sysinfo":{...}}}`); this lifts the
/// sysinfo object and stringifies its scalar members (so `relay_state` becomes
/// `"1"`), dropping arrays and objects. A reply that is not a sysinfo answer
/// (an on/off ack, say) yields an empty map, which reads as "no state here" —
/// the screen re-polls for state separately.
Map<String, String> kasaSysinfoFields(String replyJson) {
  final Object? decoded;
  try {
    decoded = jsonDecode(replyJson);
  } on FormatException {
    return const {};
  }
  if (decoded is! Map) return const {};
  final system = decoded['system'];
  final sysinfo = system is Map ? system['get_sysinfo'] : null;
  if (sysinfo is! Map) return const {};

  final out = <String, String>{};
  sysinfo.forEach((key, value) {
    if (value is String || value is num || value is bool) {
      out[key.toString()] = value.toString();
    }
  });
  return out;
}

/// The Kasa transport failed: unreachable host, timeout, or an unreadable
/// reply.
class KasaControlException implements Exception {
  final String message;
  const KasaControlException(this.message);
  @override
  String toString() => 'KasaControlException: $message';
}
